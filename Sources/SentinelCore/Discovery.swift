import CSystem
import Foundation

public enum Classifier {
  public static func classify(_ input: [ProcessRecord], settings: Settings) -> [ProcessRecord] {
    var records = input
    let positions = Dictionary(
      uniqueKeysWithValues: records.enumerated().map { ($0.element.identity.pid, $0.offset) })
    for i in records.indices {
      let p = records[i]
      if settings.excludedPaths.contains(p.path) { continue }
      if let rule = settings.watchRules.first(where: {
        $0.kind == .bundle ? p.bundleID == $0.value : p.path == $0.value
      }) {
        records[i].group = rule.label
        records[i].evidence = "Custom \(rule.kind.rawValue) rule: \(rule.value)"
      } else if p.bundleID == "com.openai.chat"
        && !(settings.disabledBuiltIns ?? []).contains("ChatGPT")
      {
        records[i].group = "ChatGPT"
        records[i].evidence = "Bundle ID com.openai.chat"
      } else if p.bundleID == "com.openai.codex"
        && !(settings.disabledBuiltIns ?? []).contains("Codex")
      {
        records[i].group = "Codex"
        records[i].evidence = "Bundle ID com.openai.codex"
      } else if isCodexCLI(p.path) && !(settings.disabledBuiltIns ?? []).contains("Codex CLI") {
        records[i].group = "Codex CLI"
        records[i].evidence = "Codex distribution executable path"
      } else if p.name.lowercased().contains("codex") || p.name.lowercased().contains("chatgpt") {
        records[i].uncertain = true
        records[i].evidence = "Name resembles a target; attribution unverified"
      }
    }
    // Only current, older parents establish ancestry. PGID alone never establishes ownership.
    for i in records.indices
    where records[i].group == nil && !settings.excludedPaths.contains(records[i].path) {
      var pid = records[i].ppid
      var visited = Set<Int32>()
      var childStart = records[i].identity.startDate
      for _ in 0..<64 {
        guard visited.insert(pid).inserted, let j = positions[pid],
          records[j].uid == records[i].uid,
          records[j].identity.startDate <= childStart
        else { break }
        if let group = records[j].group {
          records[i].group = group
          records[i].evidence = "Verified ancestry → PID \(pid) (\(records[j].name))"
          records[i].uncertain = false
          break
        }
        if settings.excludedPaths.contains(records[j].path) { break }
        childStart = records[j].identity.startDate
        pid = records[j].ppid
      }
    }
    return records
  }
  public static func isCodexCLI(_ path: String) -> Bool {
    guard URL(fileURLWithPath: path).lastPathComponent == "codex" else { return false }
    return path.contains("/@openai/codex/") || path.contains("/Cellar/codex/")
      || path.contains("/Caskroom/codex/") || path.contains("/.codex/bin/")
  }
}
public struct RawSample: Sendable {
  public var date: Date
  public var system: SystemMetrics
  public var processes: [ProcessRecord]
  public var processesAvailable: Bool = true
  public var unreadablePIDs: [Int32] = []
}
public struct LiveCollector: Sendable {
  public init() {}
  public func collect() -> RawSample {
    let date = Date()
    var system = MSSystem()
    ms_system(&system)
    let pressure: Pressure =
      system.pressure == 0
      ? .normal : system.pressure == 1 ? .warning : system.pressure == 2 ? .critical : .unavailable
    let metrics = SystemMetrics(
      total: system.total > 0 ? Double(system.total) : nil,
      used: system.vm_valid != 0 ? Double(system.used) : nil,
      available: system.vm_valid != 0 ? Double(system.available) : nil,
      compressed: system.vm_valid != 0 ? Double(system.compressed) : nil,
      swap: system.swap_valid != 0 ? Double(system.swap_used) : nil,
      diskFree: system.disk_valid != 0 ? Double(system.disk_free) : nil, pressure: pressure)
    var ids = [Int32](repeating: 0, count: 4096)
    var count = Int(ms_pids(&ids, Int32(ids.count)))
    if count >= ids.count {
      ids = [Int32](repeating: 0, count: 32768)
      count = Int(ms_pids(&ids, Int32(ids.count)))
    }
    var result: [ProcessRecord] = []
    var unreadable: [Int32] = []
    result.reserveCapacity(max(0, count))
    // Bundle lookups are cached per sample; no argument or environment inspection.
    var bundles: [String: (String?, String?, ApplicationDescriptor)] = [:]
    for pid in ids.prefix(max(0, min(count, ids.count))) where pid > 0 {
      if let record = Self.readProcess(pid, bundles: &bundles) {
        result.append(record)
      } else if Self.processExists(pid) {
        // An existing but unreadable PID must not be mistaken for a verified exit.
        unreadable.append(pid)
      }
    }
    return RawSample(
      date: date, system: metrics, processes: result,
      processesAvailable: count > 0 && count < ids.count && !result.isEmpty,
      unreadablePIDs: unreadable)
  }
  public static func readProcess(_ pid: Int32) -> ProcessRecord? {
    var bundles: [String: (String?, String?, ApplicationDescriptor)] = [:]
    return readProcess(pid, bundles: &bundles)
  }
  private static func readProcess(
    _ pid: Int32, bundles: inout [String: (String?, String?, ApplicationDescriptor)]
  )
    -> ProcessRecord?
  {
    var p = MSProcess(); guard ms_process(pid, &p) != 0 else { return nil }
    let name = withUnsafePointer(to: &p.name) {
      $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
    }
    let path = withUnsafePointer(to: &p.path) {
      $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
    }
    var bundleID: String?
    var version: String?
    var application: ApplicationDescriptor?
    if let range = path.range(of: ".app/") {
      let root = String(path[..<range.lowerBound]) + ".app"
      if let cached = bundles[root] {
        bundleID = cached.0; version = cached.1; application = cached.2
      } else {
        let bundle = Bundle(path: root)
        bundleID = bundle?.bundleIdentifier
        let short = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        version = short.map { $0 + (build.map { " (\($0))" } ?? "") } ?? build
        let name =
          bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
          ?? URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
        let descriptor = ApplicationDescriptor(
          name: name, bundleID: bundleID,
          bundlePath: root, executablePath: bundle?.executableURL?.resolvingSymlinksInPath().path)
        application = descriptor; bundles[root] = (bundleID, version, descriptor)
      }
    }
    var record = ProcessRecord(
      identity: .init(pid: pid, seconds: p.start_sec, microseconds: p.start_usec), ppid: p.ppid,
      pgid: p.pgid, uid: p.uid, name: name, path: path, bundleID: bundleID,
      footprint: p.memory_valid != 0 ? Double(p.footprint) : nil,
      rss: p.memory_valid != 0 ? Double(p.rss) : nil, appVersion: version)
    record.applicationMetadata = application
    return record
  }
  public static func validateTarget(_ record: ProcessRecord) throws {
    let code = record.path.withCString {
      ms_validate_target(
        record.identity.pid, record.identity.seconds, record.identity.microseconds, $0)
    }
    if code != 0 {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(code),
        userInfo: [
          NSLocalizedDescriptionKey:
            "Protected, exited or changed process: \(String(cString:strerror(code)))."
        ])
    }
  }
  public static func processExists(_ pid: Int32) -> Bool { ms_process_exists(pid) != 0 }
  public static func signal(_ record: ProcessRecord, force: Bool) throws {
    let code = record.path.withCString {
      ms_signal_checked(
        record.identity.pid, record.identity.seconds, record.identity.microseconds, $0,
        force ? 9 : 15)
    }
    if code != 0 {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(code),
        userInfo: [
          NSLocalizedDescriptionKey:
            "Process action refused: \(String(cString:strerror(code))). The process may have exited, changed identity, or be protected."
        ])
    }
  }
}
