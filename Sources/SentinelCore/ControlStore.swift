import Darwin
import Foundation

public struct ProcessTaskLabel: Codable, Sendable, Identifiable {
  public var identity: ProcessIdentity
  public var uid: UInt32
  public var path: String
  public var name: String
  public var created: Date
  public var id: ProcessIdentity { identity }
  public init(process: ProcessRecord, name: String, created: Date = Date()) {
    identity = process.identity; uid = process.uid; path = process.path
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    self.created = created
  }
  public func matches(_ process: ProcessRecord) -> Bool {
    process.identity == identity && process.uid == uid && process.path == path
  }
}

public struct ControlActivity: Codable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case observation, selfRepair, automatic, manual, notification, suppressed, permission
  }
  public var id = UUID()
  public var date: Date
  public var kind: Kind
  public var title: String
  public var detail: String
  public var episodeID: UUID?
  public var fixSessionID: UUID?
  public init(
    date: Date = Date(), kind: Kind, title: String, detail: String,
    episodeID: UUID? = nil, fixSessionID: UUID? = nil
  ) {
    self.date = date; self.kind = kind; self.title = String(title.prefix(180))
    self.detail = String(detail.prefix(1500)); self.episodeID = episodeID
    self.fixSessionID = fixSessionID
  }
}

public struct ControlState: Codable, Sendable {
  public var schemaVersion = 1
  public var revision: UInt64 = 0
  public var problems = ProblemEpisodes()
  public var labels: [ProcessTaskLabel] = []
  public var activity: [ControlActivity] = []
  public var automationRules: [AutomationRule]? = nil
  public var automaticAttempts: [AutomaticAttempt]? = nil
  public var rules: [AutomationRule] {
    get { automationRules ?? [] }
    set { automationRules = newValue }
  }
  public var attempts: [AutomaticAttempt] {
    get { automaticAttempts ?? [] }
    set { automaticAttempts = newValue }
  }
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, revision, problems, labels, activity, automationRules, automaticAttempts
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    problems =
      try values.decodeIfPresent(ProblemEpisodes.self, forKey: .problems) ?? ProblemEpisodes()
    labels = try values.decodeIfPresent([ProcessTaskLabel].self, forKey: .labels) ?? []
    activity = try values.decodeIfPresent([ControlActivity].self, forKey: .activity) ?? []
    automationRules = try values.decodeIfPresent([AutomationRule].self, forKey: .automationRules)
    automaticAttempts = try values.decodeIfPresent(
      [AutomaticAttempt].self, forKey: .automaticAttempts)
  }
  public mutating func append(_ item: ControlActivity) {
    activity.insert(item, at: 0)
    if activity.count > 500 { activity.removeLast(activity.count - 500) }
  }
  public mutating func name(_ process: ProcessRecord, value: String, now: Date = Date()) {
    labels.removeAll { $0.identity == process.identity }
    let label = ProcessTaskLabel(process: process, name: value, created: now)
    if !label.name.isEmpty { labels.insert(label, at: 0) }
    if labels.count > 512 { labels = Array(labels.prefix(512)) }
  }
  public func label(for process: ProcessRecord) -> String? {
    labels.first { $0.matches(process) }?.name
  }
}

/// A separate versioned, atomic control store leaves schema-2 historical evidence unchanged.
public actor ControlStore {
  public nonisolated let url: URL
  private var loaded = false
  private var writtenRevision: UInt64?
  private var writtenData: Data?
  public init(directory: URL = LocalPaths.directory) {
    url = directory.appendingPathComponent("control-state.json")
  }
  public func load() throws -> ControlState {
    guard FileManager.default.fileExists(atPath: url.path) else {
      loaded = true; return ControlState()
    }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 4 * 1024 * 1024 else {
      throw HistoryError.database("Control state exceeds 4 MiB; the original file was preserved.")
    }
    let data = try Data(contentsOf: url)
    var state = try JSONDecoder().decode(ControlState.self, from: data)
    guard (0...1).contains(state.schemaVersion) else {
      throw HistoryError.database(
        "Unsupported control-state version; external automation remains unavailable.")
    }
    if state.schemaVersion == 0 {
      let backup = url.deletingLastPathComponent().appendingPathComponent(
        "control-state.pre-v1.json")
      if !FileManager.default.fileExists(atPath: backup.path) {
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
      }
      state.schemaVersion = 1
    }
    guard state.problems.episodes.count <= 128, state.labels.count <= 512,
      state.activity.count <= 500, state.rules.count <= 64, state.attempts.count <= 256
    else {
      throw HistoryError.database(
        "Control-state bounds are invalid; the source was preserved for recovery.")
    }
    loaded = true; writtenRevision = state.revision; writtenData = data
    return state
  }
  public func save(_ state: ControlState, durable: Bool = false) throws {
    if !loaded { _ = try load() }
    guard state.schemaVersion == 1, state.problems.episodes.count <= 128,
      state.labels.count <= 512, state.activity.count <= 500, state.rules.count <= 64,
      state.attempts.count <= 256
    else {
      throw HistoryError.database("Invalid control state; no file was replaced.")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4 * 1024 * 1024 else {
      throw HistoryError.database("Control state exceeds its 4 MiB limit.")
    }
    if let writtenRevision {
      guard
        state.revision > writtenRevision
          || (state.revision == writtenRevision && data == writtenData)
      else {
        throw HistoryError.database("Stale control-state revision was rejected.")
      }
    }
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    if durable {
      for path in [url.path, folder.path] {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let code = fsync(descriptor), failure = errno; close(descriptor)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
      }
    }
    writtenRevision = state.revision; writtenData = data
  }
}
