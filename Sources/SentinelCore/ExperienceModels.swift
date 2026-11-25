import Foundation

public struct MemoryBudget: Codable, Equatable, Sendable, Identifiable {
  public enum Scope: String, Codable, CaseIterable, Sendable { case group, application }
  public var id = UUID()
  public var scope: Scope
  public var target: String
  public var bytes: Double
  public var label: String? = nil
  public init(id: UUID = UUID(), scope: Scope = .group, target: String, bytes: Double) {
    self.id = id; self.scope = scope; self.target = target; self.bytes = bytes
  }
}

public struct WorkProfile: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var watchRules: [WatchRule]
  public var excludedPaths: [String]
  public var disabledBuiltIns: [String]
  public var notifications: Bool
  public var budgets: [MemoryBudget]
  public init(
    id: UUID = UUID(), name: String, watchRules: [WatchRule] = [], excludedPaths: [String] = [],
    disabledBuiltIns: [String] = [], notifications: Bool = true, budgets: [MemoryBudget] = []
  ) {
    self.id = id; self.name = name; self.watchRules = watchRules
    self.excludedPaths = excludedPaths; self.disabledBuiltIns = disabledBuiltIns
    self.notifications = notifications; self.budgets = budgets
  }
  public static let generalID = UUID(uuidString: "58EC8CA0-D066-4EC5-93F0-000000000001")!
  public static func defaults(settings: Settings) -> [Self] {
    let budgets = [
      MemoryBudget(
        id: UUID(uuidString: "58EC8CA0-D066-4EC5-93F1-000000000001")!, target: "ChatGPT",
        bytes: 6 * GiB),
      MemoryBudget(
        id: UUID(uuidString: "58EC8CA0-D066-4EC5-93F1-000000000002")!, target: "Codex",
        bytes: 6 * GiB),
      MemoryBudget(
        id: UUID(uuidString: "58EC8CA0-D066-4EC5-93F1-000000000003")!, target: "Codex CLI",
        bytes: 4 * GiB),
    ]
    return [
      Self(
        id: generalID, name: "General", watchRules: settings.watchRules,
        excludedPaths: settings.excludedPaths, disabledBuiltIns: settings.disabledBuiltIns ?? [],
        notifications: settings.notifications, budgets: budgets),
      Self(
        id: UUID(uuidString: "58EC8CA0-D066-4EC5-93F0-000000000002")!, name: "Coding",
        budgets: budgets),
      Self(
        id: UUID(uuidString: "58EC8CA0-D066-4EC5-93F0-000000000003")!, name: "Heavy workload",
        budgets: budgets),
    ]
  }
  public func budget(for app: AppObservation) -> Double? {
    let match =
      budgets.first { $0.scope == .application && $0.target == app.key }
      ?? budgets.first { $0.scope == .group && $0.target == app.group }
    return match.flatMap { $0.bytes.isFinite && $0.bytes > 0 ? $0.bytes : nil }
  }
  public func applying(to settings: Settings) -> Settings {
    var result = settings
    result.activeProfileID = id; result.watchRules = watchRules;
    result.excludedPaths = excludedPaths
    result.disabledBuiltIns = disabledBuiltIns; result.notifications = notifications
    return result
  }
  public func validated() -> Self {
    var p = self
    p.name = String(p.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    if p.name.isEmpty { p.name = "Untitled profile" }
    p.watchRules = Array(p.watchRules.prefix(64))
    p.excludedPaths = Array(p.excludedPaths.prefix(128))
    p.disabledBuiltIns = Array(
      Set(p.disabledBuiltIns).intersection(["ChatGPT", "Codex", "Codex CLI"])
    ).sorted()
    p.budgets = Array(
      p.budgets.filter { !$0.target.isEmpty && $0.bytes.isFinite && $0.bytes >= MiB }.prefix(64))
    for i in p.budgets.indices { p.budgets[i].bytes = min(1024 * GiB, p.budgets[i].bytes) }
    var seen = Set<String>()
    p.budgets = p.budgets.reversed().filter {
      seen.insert($0.scope.rawValue + ":" + Data($0.target.utf8).base64EncodedString()).inserted
    }.reversed()
    return p
  }
}

public struct AppObservation: Codable, Sendable, Identifiable {
  public var key: String
  public var id: String { key }
  public var name: String
  public var group: String
  public var sourcePath: String
  public var version: String?
  public var generation: String
  public var root: ProcessIdentity
  public var footprint: Double?
  public var rss: Double?
  public var members: Int
  public var complete: Bool
  public var risk: RiskLevel
  public var baselineKey: String {
    key + "|version:" + Data((version ?? "unavailable").utf8).base64EncodedString()
  }
}

public struct FlightProcess: Codable, Sendable, Identifiable {
  public var id: ProcessIdentity
  public var name: String
  public var appKey: String?
  public var group: String?
  public var footprint: Double?
  public var rss: Double?
}

public struct ExperienceFrame: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var date: Date
  public var uptime: Double
  public var interval: Int
  public var profileID: UUID
  public var profileName: String
  public var configuration: String
  public var system: SystemMetrics
  public var risk: RiskLevel
  public var monitored: Double?
  public var apps: [AppObservation]
  public var processes: [FlightProcess]
  public var omittedProcesses: Int
  public var complete: Bool
  public var demo: Bool
  public var reference: FrameReference {
    .init(id: id, date: date, uptime: uptime, complete: complete)
  }
  public var events: [ExperienceEvent]? = nil
  public var omittedEvents: Int? = nil
}
public struct FrameReference: Codable, Sendable, Identifiable {
  public var id: UUID
  public var date: Date
  public var uptime: Double
  public var complete: Bool? = nil
}
public enum ObservationContinuity {
  public static func interval(_ previous: ExperienceFrame?, _ current: ExperienceFrame) -> Double? {
    guard let previous, previous.demo == current.demo, previous.profileID == current.profileID,
      previous.configuration == current.configuration
    else { return nil }
    let dt = current.date.timeIntervalSince(previous.date)
    let monotonic = current.uptime - previous.uptime
    guard dt > 0, monotonic > 0, dt <= Double(max(previous.interval, current.interval)) * 3,
      abs(dt - monotonic) <= 2
    else { return nil }
    return dt
  }
}

public struct NormalRange: Codable, Sendable {
  public var lower: Double?
  public var upper: Double?
  public var coveredSeconds: Double
  public var ready: Bool { coveredSeconds >= 3600 && lower != nil && upper != nil }
}
public struct BudgetForecast: Codable, Sendable {
  public var lowerMinutes: Double?
  public var upperMinutes: Double?
  public var growthPerMinute: Double?
  public var reason: String
  public var available: Bool { lowerMinutes != nil && upperMinutes != nil }
}
public struct AppHealth: Sendable, Identifiable {
  public var app: AppObservation
  public var id: String { app.key }
  public var budget: Double?
  public var normal: NormalRange
  public var forecast: BudgetForecast
  public var unusual: Bool
  public var overBudget: Bool
  public var measuredAt: Date
}

public enum ExperienceEventKind: String, Codable, CaseIterable, Sendable {
  case warning, critical, budget, unusual, processStarted, processExited, profile, fix, gap, note
  case footprint, growth, swap, pressure, metrics, storage
  public var title: String {
    switch self {
    case .processStarted: "Process appeared"
    case .processExited: "Process exited"
    case .budget: "Reference budget"
    case .unusual: "Unusual footprint"
    case .metrics: "Measurement availability"
    default: rawValue.capitalized
    }
  }
}
public struct ExperienceEvent: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var date: Date
  public var kind: ExperienceEventKind
  public var text: String
  public var appKey: String?
  public var process: ProcessIdentity?
  public var level: RiskLevel?
  public init(
    date: Date, kind: ExperienceEventKind, text: String, appKey: String? = nil,
    process: ProcessIdentity? = nil, level: RiskLevel? = nil
  ) {
    self.date = date; self.kind = kind; self.text = String(text.prefix(500))
    self.appKey = appKey; self.process = process; self.level = level
  }
}
public struct ScopedSnooze: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var profileID: UUID
  public var appKey: String
  public var kind: ExperienceEventKind
  public var until: Date
  public init(profileID: UUID, appKey: String, kind: ExperienceEventKind, until: Date) {
    self.profileID = profileID; self.appKey = appKey; self.kind = kind; self.until = until
  }
  public func suppresses(
    profile: UUID, app: String, kind: ExperienceEventKind,
    level: RiskLevel, now: Date
  ) -> Bool {
    level < .critical && profile == profileID && app == appKey && kind == self.kind && until > now
  }
}
public struct ExperienceAlert: Sendable, Identifiable {
  public var event: ExperienceEvent
  public var id: UUID { event.id }
  public var title: String
  public var evidence: String
  public var nextStep: String
  public var level: RiskLevel
  public var snoozed: Bool
}

public enum RecordingStatus: String, Codable, Sendable {
  case recording, complete, partial, expired
}
public struct FlightRecording: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var revision: UInt64 = 0
  public var title: String
  public var trigger: Date
  public var deadline: Date
  public var deadlineUptime: Double
  public var status: RecordingStatus = .recording
  public var references: [FrameReference] = []
  public var events: [ExperienceEvent] = []
  public var omittedEvents = 0
  public var partialReason: String?
  public var demo: Bool
  public var start: Date { references.first?.date ?? trigger }
  public var end: Date { references.last?.date ?? trigger }
}

public enum WorkSessionStatus: String, Codable, Sendable { case active, completed, interrupted }
public struct SessionPoint: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var date: Date
  public var elapsed: Double
  public var monitored: Double?
  public var swap: Double?
  public var risk: RiskLevel
  public var gap: Bool
}
public struct SessionConsumer: Codable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var version: String?
  public var sourcePath: String? = nil
  public var peak: Double?
  public var byteSeconds: Double
  public var observedSeconds: Double
}
public struct WorkSession: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var revision: UInt64 = 0
  public var name: String
  public var note: String
  public var profileID: UUID
  public var profileName: String
  public var started: Date
  public var startedUptime: Double
  public var ended: Date?
  public var status: WorkSessionStatus = .active
  public var elapsedSeconds: Double = 0
  public var observedSeconds: Double = 0
  public var memorySeconds: Double = 0
  public var byteSeconds: Double = 0
  public var peak: Double?
  public var firstSwap: Double?
  public var lastSwap: Double?
  public var pressureSeconds: [String: Double] = [:]
  public var warningCount = 0
  public var fixIDs: [UUID] = []
  public var points: [SessionPoint] = []
  public var consumers: [SessionConsumer] = []
  public var configurations: [String] = []
  public var profileIDs: [UUID] = []
  public var events: [ExperienceEvent] = []
  public var demo: Bool
  public var mean: Double? { memorySeconds > 0 ? byteSeconds / memorySeconds : nil }
  public var coverage: Double { elapsedSeconds > 0 ? min(1, observedSeconds / elapsedSeconds) : 0 }
  public var warningsPerHour: Double? {
    observedSeconds > 0 ? Double(warningCount) * 3600 / observedSeconds : nil
  }
  public var swapChange: Double? { firstSwap.flatMap { a in lastSwap.map { $0 - a } } }
}

public struct FollowupObservation: Codable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case observing, stable, returned, partial, unavailable
  }
  public var id: UUID
  public var revision: UInt64 = 0
  public var profileID: UUID
  public var appKey: String?
  public var appName: String
  public var version: String?
  public var problem: ProblemKind
  public var action: FixAction
  public var before: FixMeasurement
  public var immediate: FixResult
  public var swapThreshold: Double
  public var warningFraction: Double
  public var growthThreshold: Double
  public var started: Date
  public var deadlineUptime: Double
  public var status: Status = .observing
  public var coveredSeconds: Double = 0
  public var samples: Int = 0
  public var last: FixMeasurement?
  public var warningReturned = false
  public var issue: String?
  public var demo: Bool
  public var targetIdentity: ProcessIdentity? = nil
  public var relatedIdentities: [ProcessIdentity] = []
}

public struct ExperienceSummary: Sendable {
  public var profileID: UUID?
  public var configuration: String?
  public var historyAvailable = true
  public var apps: [AppHealth] = []
  public var alerts: [ExperienceAlert] = []
  public var newAlerts: [ExperienceAlert] = []
  public var suppressedIncidentIDs: [UUID] = []
  public var recordings: [FlightRecording] = []
  public var sessions: [WorkSession] = []
  public var followups: [FollowupObservation] = []
  public var snoozes: [ScopedSnooze] = []
  public var storageBytes = 0
  public var error: String?
  public init() {}
}
