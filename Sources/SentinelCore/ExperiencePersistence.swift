import CSystem
import Foundation

enum ExperienceMigration {
  static func version(_ handle: SQLiteHandle) throws -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(handle.pointer, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK
    else {
      throw HistoryError.database("Cannot read the history schema version")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw HistoryError.database("Missing schema version")
    }
    return Int(sqlite3_column_int(statement, 0))
  }
  static func copy(from source: SQLiteHandle, to target: SQLiteHandle) throws {
    guard let backup = sqlite3_backup_init(target.pointer, "main", source.pointer, "main") else {
      throw HistoryError.database("Cannot start the consistent history backup")
    }
    var code = SQLITE_OK
    var retries = 0
    repeat {
      code = sqlite3_backup_step(backup, 256)
      if code == SQLITE_BUSY || code == SQLITE_LOCKED {
        retries += 1
        if retries > 25 { break }
        Thread.sleep(forTimeInterval: 0.02)
      }
    } while code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED
    let finished = sqlite3_backup_finish(backup)
    guard code == SQLITE_DONE && finished == SQLITE_OK else {
      throw HistoryError.database("The history backup could not complete; the source was preserved")
    }
  }
  static func snapshot(_ handle: SQLiteHandle, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".backup-\(UUID().uuidString).sqlite")
    defer {
      for ext in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: temporary.path + ext)
      }
    }
    do {
      let target = try SQLiteHandle(temporary.path)
      try copy(from: handle, to: target)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
  static func prepare(_ handle: SQLiteHandle, directory: URL) throws {
    let oldVersion = try version(handle)
    guard oldVersion <= 2 else { throw HistoryError.database("Unsupported history schema") }
    if oldVersion < 2 {
      let backup = directory.appendingPathComponent("history.pre-v2.sqlite")
      if !FileManager.default.fileExists(atPath: backup.path) { try snapshot(handle, to: backup) }
    }
    let migration = """
      BEGIN IMMEDIATE;
      CREATE TABLE IF NOT EXISTS experience_frames(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL,bytes INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS experience_frame_time ON experience_frames(t);
      CREATE INDEX IF NOT EXISTS experience_frame_bytes ON experience_frames(bytes);
      CREATE TABLE IF NOT EXISTS experience_items(kind TEXT NOT NULL,id TEXT NOT NULL,t REAL NOT NULL,payload TEXT NOT NULL,rev INTEGER NOT NULL DEFAULT 0,bytes INTEGER NOT NULL,PRIMARY KEY(kind,id));
      CREATE INDEX IF NOT EXISTS experience_item_time ON experience_items(kind,t);
      CREATE INDEX IF NOT EXISTS experience_item_bytes ON experience_items(bytes);
      PRAGMA user_version=2;
      COMMIT;
      """
    guard sqlite3_exec(handle.pointer, migration, nil, nil, nil) == SQLITE_OK else {
      sqlite3_exec(handle.pointer, "ROLLBACK", nil, nil, nil)
      throw HistoryError.database(
        "History migration failed. The previous schema and backup are available.")
    }
  }
}

public struct ExperienceWrite: Sendable {
  public var frame: ExperienceFrame?
  public var recordings: [FlightRecording] = []
  public var sessions: [WorkSession] = []
  public var followups: [FollowupObservation] = []
  public var state: Data?
  public var stateRevision: UInt64 = 0
  public init(frame: ExperienceFrame? = nil) { self.frame = frame }
}

extension HistoryStore {
  public func schemaVersion() throws -> Int { try ExperienceMigration.version(connection) }
  public func createRecoverySnapshot() throws -> URL {
    let url = directory.appendingPathComponent("history.recovery.sqlite")
    try ExperienceMigration.snapshot(connection, to: url)
    return url
  }
  public func restorePreV2Backup() throws {
    let url = directory.appendingPathComponent("history.pre-v2.sqlite")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw HistoryError.database("No pre-migration backup is available")
    }
    let source = try SQLiteHandle(url.path)
    let version = try ExperienceMigration.version(source)
    guard version < 2 else {
      throw HistoryError.database("The selected backup is not a pre-migration database")
    }
    var check: OpaquePointer?
    guard sqlite3_prepare_v2(source.pointer, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK
    else {
      throw HistoryError.database("The backup cannot be checked")
    }
    let valid =
      sqlite3_step(check) == SQLITE_ROW && String(cString: sqlite3_column_text(check, 0)) == "ok"
    sqlite3_finalize(check)
    guard valid else {
      throw HistoryError.database("Backup integrity check failed; current history is unchanged")
    }
    try ExperienceMigration.snapshot(
      connection, to: directory.appendingPathComponent("history.before-restore.sqlite"))
    try ExperienceMigration.copy(from: source, to: connection)
    try ExperienceMigration.prepare(connection, directory: directory)
  }
  public func experienceValues<T: Decodable & Sendable>(
    _ type: T.Type, kind: String, limit: Int = 100
  ) throws -> [T] {
    guard ["recording", "session", "sessionSummary", "followup", "state"].contains(kind) else {
      return []
    }
    return try rows(
      "SELECT payload FROM experience_items WHERE kind='\(kind)' ORDER BY t DESC LIMIT \(max(1, min(500, limit)))"
    )
    .compactMap { $0.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
  }
  public func experienceState() throws -> Data? {
    try rows("SELECT payload FROM experience_items WHERE kind='state' AND id='current' LIMIT 1")
      .first?.data(using: .utf8)
  }
  public func experienceValue<T: Decodable & Sendable>(_ type: T.Type, kind: String, id: UUID)
    throws -> T?
  {
    guard ["recording", "session", "followup"].contains(kind) else { return nil }
    return try rows(
      "SELECT payload FROM experience_items WHERE kind='\(kind)' AND id='\(id.uuidString)' LIMIT 1"
    )
    .first?.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
  }
  public func persistExperience(_ batch: ExperienceWrite) throws {
    guard batch.frame?.demo != true else { return }
    try execute("BEGIN IMMEDIATE")
    do {
      if let frame = batch.frame {
        let payload = try json(frame)
        guard payload.utf8.count <= 262144 else {
          throw HistoryError.database("Observation exceeds the 256 KiB frame limit")
        }
        try execute(
          "INSERT OR IGNORE INTO experience_frames VALUES(?,?,?,?)",
          values: [
            frame.id.uuidString, String(frame.date.timeIntervalSince1970), payload,
            String(payload.utf8.count),
          ])
      }
      func store<T: Encodable>(
        _ value: T, kind: String, id: UUID, date: Date, demo: Bool, revision: UInt64
      ) throws {
        guard !demo else { return }
        let payload = try json(value)
        guard payload.utf8.count <= 524288 else {
          throw HistoryError.database("\(kind) exceeds its 512 KiB record limit")
        }
        try execute(
          "INSERT INTO experience_items VALUES(?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET t=excluded.t,payload=excluded.payload,rev=excluded.rev,bytes=excluded.bytes WHERE experience_items.rev<=excluded.rev",
          values: [
            kind, id.uuidString, String(date.timeIntervalSince1970), payload, String(revision),
            String(payload.utf8.count),
          ])
      }
      for value in batch.recordings {
        try store(
          value, kind: "recording", id: value.id, date: value.trigger, demo: value.demo,
          revision: value.revision)
      }
      for value in batch.sessions {
        try store(
          value, kind: "session", id: value.id, date: value.started, demo: value.demo,
          revision: value.revision)
        try store(
          value.summary, kind: "sessionSummary", id: value.id, date: value.started,
          demo: value.demo, revision: value.revision)
      }
      for value in batch.followups {
        try store(
          value, kind: "followup", id: value.id, date: value.started, demo: value.demo,
          revision: value.revision)
      }
      if let data = batch.state {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
          throw HistoryError.database("Learning state exceeds its 8 MiB limit")
        }
        try execute(
          "INSERT INTO experience_items VALUES('state','current',?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET t=excluded.t,payload=excluded.payload,rev=excluded.rev,bytes=excluded.bytes WHERE experience_items.rev<=excluded.rev",
          values: [
            String(Date().timeIntervalSince1970), text, String(batch.stateRevision),
            String(data.count),
          ])
      }
      for (kind, limit) in [
        ("recording", 40), ("session", 100), ("sessionSummary", 100), ("followup", 200),
      ] {
        try execute(
          "DELETE FROM experience_items WHERE kind='\(kind)' AND id NOT IN (SELECT id FROM experience_items WHERE kind='\(kind)' ORDER BY t DESC LIMIT \(limit))"
        )
      }
      try execute("COMMIT")
    } catch { try? execute("ROLLBACK"); throw error }
  }
  public func experienceFrames(ids: [UUID]) throws -> [ExperienceFrame] {
    guard !ids.isEmpty else { return [] }
    let requested = Array(ids.prefix(1280))
    let literals = requested.map { "'\($0.uuidString)'" }.joined(separator: ",")
    let decoded = try rows("SELECT payload FROM experience_frames WHERE id IN (\(literals))")
      .compactMap {
        $0.data(using: .utf8).flatMap { try? JSONDecoder().decode(ExperienceFrame.self, from: $0) }
      }
    let indexed = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return requested.compactMap { indexed[$0] }
  }
  public func pruneExperience(retaining ids: [UUID]) throws -> Int {
    let values = Array(Set(ids).prefix(14000))
    if values.isEmpty {
      try execute("DELETE FROM experience_frames")
    } else {
      let literals = values.map { "'\($0.uuidString)'" }.joined(separator: ",")
      try execute("DELETE FROM experience_frames WHERE id NOT IN (\(literals))")
    }
    return try experiencePayloadBytes()
  }
  public func recentExperienceFrames(since: Date, limit: Int = 320) throws -> [ExperienceFrame] {
    try rows(
      "SELECT payload FROM (SELECT t,payload FROM experience_frames WHERE t>=\(since.timeIntervalSince1970) ORDER BY t DESC LIMIT \(max(1, min(320, limit)))) ORDER BY t"
    )
    .compactMap {
      $0.data(using: .utf8).flatMap { try? JSONDecoder().decode(ExperienceFrame.self, from: $0) }
    }
  }
  public func experiencePayloadBytes() throws -> Int {
    let sql =
      "SELECT (SELECT COALESCE(SUM(bytes),0) FROM experience_frames)+(SELECT COALESCE(SUM(bytes),0) FROM experience_items)"
    return Int(try rows(sql).first ?? "0") ?? 0
  }
  public func removeExperienceItems(kind: String, ids: [UUID]) throws {
    guard ["recording", "session", "followup"].contains(kind), !ids.isEmpty else { return }
    let literals = ids.prefix(500).map { "'\($0.uuidString)'" }.joined(separator: ",")
    try execute("DELETE FROM experience_items WHERE kind='\(kind)' AND id IN (\(literals))")
    if kind == "session" {
      try execute(
        "DELETE FROM experience_items WHERE kind='sessionSummary' AND id IN (\(literals))")
    }
  }
}
