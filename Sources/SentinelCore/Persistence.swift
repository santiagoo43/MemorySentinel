import CSystem
import Foundation

public enum LocalPaths {
  public static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MemorySentinel", isDirectory: true)
  }
}
public struct SettingsStore: Sendable {
  public let url: URL
  public init(directory: URL = LocalPaths.directory) {
    url = directory.appendingPathComponent("settings.json")
  }
  public func load() -> Settings {
    (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: url)))?.validated()
      ?? Settings()
  }
  public func save(_ settings: Settings) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(settings.validated()).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
private final class SQLiteHandle: @unchecked Sendable {
  var pointer: OpaquePointer?
  init(_ path: String) throws {
    if sqlite3_open_v2(
      path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
      != SQLITE_OK
    {
      throw HistoryError.database("Cannot open history database")
    }
    sqlite3_busy_timeout(pointer, 1500)
  }
  deinit { sqlite3_close(pointer) }
}
public enum HistoryError: LocalizedError {
  case database(String)
  public var errorDescription: String? {
    switch self {
    case .database(let message): message
    }
  }
}
public actor HistoryStore {
  private let connection: SQLiteHandle
  public let recoveryMessage: String?
  private var writes = 0
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  public init(directory: URL = LocalPaths.directory) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("history.sqlite")
    var handle = try SQLiteHandle(url.path)
    var recover: String?
    var statement: OpaquePointer?
    let prepare = sqlite3_prepare_v2(handle.pointer, "PRAGMA quick_check", -1, &statement, nil)
    let okay =
      prepare == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW
      && String(cString: sqlite3_column_text(statement, 0)) == "ok"
    sqlite3_finalize(statement)
    if !okay {
      handle = try SQLiteHandle(":memory:")  // closes the corrupt database before moving its files
      let suffix = ".corrupt-\(Int(Date().timeIntervalSince1970))"
      for ext in ["", "-wal", "-shm"] {
        let source = URL(fileURLWithPath: url.path + ext)
        if FileManager.default.fileExists(atPath: source.path) {
          try FileManager.default.moveItem(
            at: source, to: URL(fileURLWithPath: source.path + suffix))
        }
      }
      handle = try SQLiteHandle(url.path)
      recover = "Unreadable history was quarantined locally. A fresh history database is active."
    }
    connection = handle
    recoveryMessage = recover
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=NORMAL;
      PRAGMA wal_autocheckpoint=128;
      PRAGMA journal_size_limit=2097152;
      PRAGMA auto_vacuum=INCREMENTAL;
      CREATE TABLE IF NOT EXISTS samples(t REAL PRIMARY KEY, point TEXT NOT NULL, detail TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS minutes(t REAL PRIMARY KEY, point TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS incidents(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS incident_time ON incidents(t);
      CREATE TABLE IF NOT EXISTS fix_sessions(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS fix_time ON fix_sessions(t);
      """
    guard sqlite3_exec(handle.pointer, schema, nil, nil, nil) == SQLITE_OK else {
      throw HistoryError.database("Cannot initialize history schema")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func execute(_ sql: String, values: [String] = []) throws {
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(connection.pointer, sql, -1, &s, nil) == SQLITE_OK else {
      throw error()
    }
    defer { sqlite3_finalize(s) }
    for (i, value) in values.enumerated() {
      _ = value.withCString {
        sqlite3_bind_text(
          s, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
    }
    var result = sqlite3_step(s)
    while result == SQLITE_ROW { result = sqlite3_step(s) }
    guard result == SQLITE_DONE else { throw error() }
  }
  private func error() -> HistoryError {
    .database(String(cString: sqlite3_errmsg(connection.pointer)))
  }
  private func rows(_ sql: String) throws -> [String] {
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(connection.pointer, sql, -1, &s, nil) == SQLITE_OK else {
      throw error()
    }
    defer { sqlite3_finalize(s) }
    var result: [String] = []
    while true {
      let code = sqlite3_step(s)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw error() }
      if let text = sqlite3_column_text(s, 0) { result.append(String(cString: text)) }
    }
    return result
  }
  private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  public func append(_ snapshot: Snapshot, incidents: [Incident], settings: Settings) throws {
    guard !snapshot.demo else { return }
    var compact = snapshot
    let watched = Array(snapshot.monitored.prefix(96))
    let watchedIDs = Set(watched.map(\.identity))
    compact.processes =
      watched + snapshot.processes.filter { !watchedIDs.contains($0.identity) }.prefix(12)
    var point = snapshot.point
    if point.processes.count > 256 {
      point.processes = Dictionary(
        uniqueKeysWithValues: point.processes.sorted { $0.value > $1.value }.prefix(256).map {
          ($0.key, $0.value)
        })
    }
    let t = snapshot.date.timeIntervalSince1970
    let minute = floor(t / 60) * 60
    try execute("BEGIN IMMEDIATE")
    do {
      try execute(
        "INSERT OR REPLACE INTO samples VALUES(?,?,?)",
        values: [String(t), try json(point), try json(compact)])
      // Minute buckets retain the largest monitored peak and the latest measured group/system values.
      if let old = try rows("SELECT point FROM minutes WHERE t=\(minute)").first,
        let data = old.data(using: .utf8),
        let previous = try? decoder.decode(TimelinePoint.self, from: data)
      {
        if (previous.peak ?? 0) > (point.peak ?? 0) {
          point.peak = previous.peak
          point.peakDate = previous.peakDate ?? previous.date
        }
      }
      try execute(
        "INSERT OR REPLACE INTO minutes VALUES(?,?)", values: [String(minute), try json(point)])
      for incident in incidents {
        try execute(
          "INSERT OR REPLACE INTO incidents VALUES(?,?,?)",
          values: [
            incident.id.uuidString, String(incident.date.timeIntervalSince1970), try json(incident),
          ])
      }
      writes += 1
      if writes % 12 == 1 { try prune(now: snapshot.date, settings: settings) }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
    if writes % 720 == 0 {
      try execute("PRAGMA wal_checkpoint(TRUNCATE)")
      try execute("PRAGMA incremental_vacuum(256)")
    }
  }
  public func prune(now: Date, settings: Settings) throws {
    let t = now.timeIntervalSince1970
    try execute("DELETE FROM samples WHERE t<\(t-Double(settings.detailHours)*3600)")
    try execute("DELETE FROM minutes WHERE t<\(t-Double(settings.aggregateDays)*86400)")
    try execute("DELETE FROM incidents WHERE t<\(t-Double(settings.incidentDays)*86400)")
    try execute("DELETE FROM fix_sessions WHERE t<\(t-Double(settings.incidentDays)*86400)")
    try execute(
      "DELETE FROM fix_sessions WHERE id NOT IN (SELECT id FROM fix_sessions ORDER BY t DESC LIMIT 500)"
    )
    try execute(
      "DELETE FROM samples WHERE t NOT IN (SELECT t FROM samples ORDER BY t DESC LIMIT 20000)")
    // Hard 48 MiB logical payload budget, independent of retention and sample interval.
    try execute(
      "DELETE FROM samples WHERE t IN (SELECT t FROM (SELECT t,SUM(length(point)+length(detail)) OVER (ORDER BY t DESC) AS bytes FROM samples) WHERE bytes>50331648)"
    )
    try execute(
      "DELETE FROM minutes WHERE t NOT IN (SELECT t FROM minutes ORDER BY t DESC LIMIT 10080)")
    try execute(
      "DELETE FROM incidents WHERE id NOT IN (SELECT id FROM incidents ORDER BY t DESC LIMIT 2000)")
  }
  public func timeline(since: Date, maxPoints: Int = 400) throws -> [TimelinePoint] {
    let start = since.timeIntervalSince1970
    let width = max(1, (Date().timeIntervalSince(since)) / Double(max(10, min(2000, maxPoints))))
    // Choose latest row per bucket; raw for recent windows, minute rollups for longer windows.
    let table = Date().timeIntervalSince(since) <= 3600 ? "samples" : "minutes"
    let values = try rows(
      "SELECT point FROM \(table) WHERE t IN (SELECT MAX(t) FROM \(table) WHERE t>=\(start) GROUP BY CAST(t/\(width) AS INTEGER)) ORDER BY t"
    )
    return values.compactMap {
      $0.data(using: .utf8).flatMap { try? decoder.decode(TimelinePoint.self, from: $0) }
    }
  }
  public func incidents(limit: Int = 300) throws -> [Incident] {
    try rows("SELECT payload FROM incidents ORDER BY t DESC LIMIT \(max(1,min(2000,limit)))")
      .compactMap { $0.data(using: .utf8).flatMap { try? decoder.decode(Incident.self, from: $0) } }
  }
  public func context(around date: Date) throws -> [Snapshot] {
    let t = date.timeIntervalSince1970
    return try rows(
      "SELECT detail FROM samples WHERE t BETWEEN \(t-60) AND \(t+60) ORDER BY t LIMIT 61"
    ).compactMap { $0.data(using: .utf8).flatMap { try? decoder.decode(Snapshot.self, from: $0) } }
  }
  public func saveFix(_ session: FixSession) throws {
    guard !session.demo else { return }
    if let previous = try rows(
      "SELECT payload FROM fix_sessions WHERE id='\(session.id.uuidString)' LIMIT 1"
    ).first,
      let data = previous.data(using: .utf8),
      let stored = try? decoder.decode(FixSession.self, from: data),
      (stored.revision ?? 0) > (session.revision ?? 0)
    {
      return
    }
    let payload = try json(session)
    guard payload.utf8.count <= 262144 else {
      throw HistoryError.database("Fix audit exceeded the bounded payload limit")
    }
    try execute(
      "INSERT OR REPLACE INTO fix_sessions VALUES(?,?,?)",
      values: [session.id.uuidString, String(session.updated.timeIntervalSince1970), payload])
    try execute(
      "DELETE FROM fix_sessions WHERE id NOT IN (SELECT id FROM fix_sessions ORDER BY t DESC LIMIT 500)"
    )
  }
  public func fixSessions(limit: Int = 100) throws -> [FixSession] {
    try rows("SELECT payload FROM fix_sessions ORDER BY t DESC LIMIT \(max(1,min(500,limit)))")
      .compactMap {
        $0.data(using: .utf8).flatMap { try? decoder.decode(FixSession.self, from: $0) }
      }
  }
  public func recoverInterruptedFixes() throws {
    for var session in try fixSessions(limit: 500) where session.phase.active {
      session.phase = .finished; session.updated = Date()
      session.message = "Interrupted by application restart. No operation was resumed."
      session.result = FixResult(
        outcome: .interrupted, actionSucceeded: nil, targetResolved: nil, systemImproved: nil,
        after: nil, samples: session.samples, remaining: [], message: session.message,
        nextStep: "Assess a new plan from current measurements.")
      try saveFix(session)
    }
  }
  public func detailedPayloadBytes() throws -> Int {
    Int(try rows("SELECT COALESCE(SUM(length(point)+length(detail)),0) FROM samples").first ?? "0")
      ?? 0
  }
  public func clear() throws {
    try execute("DELETE FROM samples")
    try execute("DELETE FROM minutes")
    try execute("DELETE FROM incidents")
    try execute("DELETE FROM fix_sessions")
    try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    try execute("VACUUM")
  }
  public func counts() throws -> [Int] {
    try ["samples", "minutes", "incidents"].map {
      Int(try rows("SELECT COUNT(*) FROM \($0)").first ?? "0") ?? 0
    }
  }
  public func export(to url: URL, csv: Bool) throws {
    let points = try rows("SELECT point FROM minutes ORDER BY t").compactMap {
      $0.data(using: .utf8).flatMap { try? decoder.decode(TimelinePoint.self, from: $0) }
    }
    let events = try incidents(limit: 2000)
    let fixes = try fixSessions(limit: 500)
    if csv {
      func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
      var text =
        "record_type,timestamp,system_used_bytes,monitored_accounted_bytes,swap_bytes,risk,monitored_peak_bytes,fix_session_id,action,target_pid,target_start,outcome,action_succeeded,target_resolved,system_improved,diagnosis,before_after_json\n"
      let iso = ISO8601DateFormatter()
      for p in points {
        text +=
          "sample,\(iso.string(from:p.date)),\(p.systemUsed.map(String.init(describing:)) ?? ""),\(p.monitored.map(String.init(describing:)) ?? ""),\(p.swap.map(String.init(describing:)) ?? ""),\(p.risk.title),\(p.peak.map(String.init(describing:)) ?? ""),,,,,,,,,,\n"
      }
      let exportEncoder = JSONEncoder(); exportEncoder.dateEncodingStrategy = .iso8601
      for fix in fixes {
        let pid = fix.plan?.target?.process.identity.pid.description ?? ""
        let start = fix.plan?.target?.process.identity.id ?? ""
        let result = fix.result
        let payload = String(decoding: try exportEncoder.encode(fix), as: UTF8.self)
        let fields: [String] = [
          "fix", iso.string(from: fix.updated), "", "", "", "", "", fix.id.uuidString,
          fix.approvedAction?.rawValue ?? "", pid, start,
          result?.outcome.rawValue ?? fix.phase.rawValue,
          result?.actionSucceeded.map { String($0) } ?? "",
          result?.targetResolved.map { String($0) } ?? "",
          result?.systemImproved.map { String($0) } ?? "", fix.plan?.diagnosis.kind.rawValue ?? "",
          payload,
        ]
        text += fields.map(quoted).joined(separator: ",") + "\n"
      }
      try text.write(to: url, atomically: true, encoding: .utf8)
    } else {
      struct Export: Encodable {
        var schema = 2
        var semantics =
          "Byte units; group footprints are attributed accounting, not unique physical RAM. Minute rollups hold latest values and monitored peak. No arguments or environment collected."
        var timeline: [TimelinePoint]
        var incidents: [Incident]
        var fixSessions: [FixSession]
      }
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      e.dateEncodingStrategy = .iso8601
      try e.encode(Export(timeline: points, incidents: events, fixSessions: fixes)).write(
        to: url, options: .atomic)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
