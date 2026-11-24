import Foundation

public enum ProblemKind: String, Codable, Sendable {
  case highFootprint, sustainedGrowth, systemPressure, swapGrowth, lowDisk, unavailableMetrics
  case monitoringFailure, historyFailure, notifications, loginItem, selectedContributor,
    noActiveProblem
  public var title: String {
    switch self {
    case .highFootprint: "High process footprint"
    case .sustainedGrowth: "Suspicious sustained growth"
    case .systemPressure: "System memory pressure"
    case .swapGrowth: "Rapid swap growth"
    case .lowDisk: "Low free storage"
    case .unavailableMetrics: "Memory readings unavailable"
    case .monitoringFailure: "Monitoring needs attention"
    case .historyFailure: "History storage needs attention"
    case .notifications: "Notification permission"
    case .loginItem: "Launch at login unavailable"
    case .selectedContributor: "Manually selected memory contributor"
    case .noActiveProblem: "No current actionable problem"
    }
  }
}
public struct ProblemDiagnosis: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var kind: ProblemKind
  public var severity: RiskLevel
  public var identity: ProcessIdentity?
  public var summary: String
  public var evidence: [String: Double]
  public var certainty: String
}
public struct FixOrigin: Codable, Sendable {
  public var incidentID: UUID?
  public var identity: ProcessIdentity?
  public var issue: ProblemKind?
  public var demoSource: Bool? = nil
  public var individualProcess: Bool? = nil
  public init(
    incidentID: UUID? = nil, identity: ProcessIdentity? = nil, issue: ProblemKind? = nil,
    individualProcess: Bool = false, demoSource: Bool? = nil
  ) {
    self.incidentID = incidentID; self.identity = identity; self.issue = issue
    self.individualProcess = individualProcess
    self.demoSource = demoSource
  }
}
public struct InterventionToken: Codable, Equatable, Sendable {
  public var epoch: UInt64
  public var demo: Bool
  public init(epoch: UInt64 = 0, demo: Bool = false) { self.epoch = epoch; self.demo = demo }
}
// Synchronous checks at the actual effect boundary prevent a queued action crossing a mode switch.
public final class InterventionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var token = InterventionToken()
  public init() {}
  public func current() -> InterventionToken { lock.lock(); defer { lock.unlock() }; return token }
  @discardableResult public func invalidate(demo: Bool? = nil) -> InterventionToken {
    lock.lock(); defer { lock.unlock() }; token.epoch &+= 1
    if let demo { token.demo = demo }; return token
  }
  public func liveEffect<T>(token expected: InterventionToken, _ effect: () throws -> T) throws -> T
  {
    lock.lock(); defer { lock.unlock() }
    guard token == expected, !token.demo else {
      throw FixError.invalidated("Mode changed or simulation is active. No native action was sent.")
    }
    return try effect()
  }
}
public struct ApplicationIdentity: Codable, Equatable, Sendable {
  public var bundleID: String
  public var bundlePath: String
  public var executablePath: String
  public var fingerprint: String
  public init(bundleID: String, bundlePath: String, executablePath: String, fingerprint: String) {
    self.bundleID = bundleID; self.bundlePath = bundlePath; self.executablePath = executablePath;
    self.fingerprint = fingerprint
  }
}
public struct FixTarget: Codable, Sendable, Identifiable {
  public var process: ProcessRecord
  public var source: ProcessRecord
  public var application: ApplicationIdentity?
  public var related: [ProcessIdentity]
  public var id: ProcessIdentity { process.identity }
  public var manualSelection: Bool
  public init(
    process: ProcessRecord, source: ProcessRecord, application: ApplicationIdentity? = nil,
    related: [ProcessIdentity] = [], manualSelection: Bool = true
  ) {
    self.process = process; self.source = source; self.application = application;
    self.related = Array(related.prefix(128)); self.manualSelection = manualSelection
  }
}
public enum FixAction: String, Codable, CaseIterable, Sendable, Identifiable {
  case quitApplication, restartApplication, terminateProcess, forceQuit, restartMonitoring
  case activityMonitor, storageSettings, notificationSettings, loginSettings
  public var id: String { rawValue }
  public var isProcessAction: Bool {
    [.quitApplication, .restartApplication, .terminateProcess, .forceQuit].contains(self)
  }
  public var isGuidance: Bool {
    [.activityMonitor, .storageSettings, .notificationSettings, .loginSettings].contains(self)
  }
  public func title(target: FixTarget?) -> String {
    let name = target?.process.name ?? "selected process"
    switch self {
    case .quitApplication: return "Quit \(name)"
    case .restartApplication: return "Quit and reopen \(name)"
    case .terminateProcess: return "Stop \(name) · SIGTERM"
    case .forceQuit: return "Force Quit \(name)…"
    case .restartMonitoring: return "Restart monitoring"
    case .activityMonitor: return "Open Activity Monitor"
    case .storageSettings: return "Open System Settings · Storage"
    case .notificationSettings: return "Open notification settings"
    case .loginSettings: return "Open Login Items settings"
    }
  }
}
public struct FixPlan: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var created: Date
  public var expires: Date
  public var token: InterventionToken
  public var origin: FixOrigin
  public var diagnosis: ProblemDiagnosis
  public var findings: [ProblemDiagnosis]
  public var target: FixTarget?
  public var candidates: [ProcessRecord]
  public var source: ProcessRecord? = nil
  public var actions: [FixAction]
  public var before: FixMeasurement
  public var warningFraction: Double
  public var growthThreshold: Double
  public var swapThreshold: Double
  public var explanation: String
}
public struct FixMeasurement: Codable, Sendable {
  public var date: Date
  public var system: SystemMetrics
  public var swapGrowth: Double?
  public var risk: RiskLevel
  public var targetFootprint: Double?
  public var targetGrowth: Double?
  public init(snapshot: Snapshot, target: ProcessIdentity?) {
    date = snapshot.date; system = snapshot.system; swapGrowth = snapshot.swapGrowth;
    risk = snapshot.risk
    let process = snapshot.processes.first { $0.identity == target }
    targetFootprint = process?.footprint; targetGrowth = process?.growth
  }
}
public enum FixPhase: String, Codable, Sendable {
  case assessing, awaitingApproval, executing, verifying, finished
  public var active: Bool { self != .finished }
}
public enum FixOutcome: String, Codable, Sendable {
  case solved, improved, unresolved, unverifiable, needsAction, interrupted, cancelled
  public var title: String {
    switch self {
    case .solved: "Resolved"
    case .improved: "Improved · keep watching"
    case .unresolved: "Not resolved"
    case .unverifiable: "Cannot verify"
    case .needsAction: "Further action needed"
    case .interrupted: "Interrupted"
    case .cancelled: "Cancelled"
    }
  }
}
public struct FixResult: Codable, Sendable {
  public var outcome: FixOutcome
  public var actionSucceeded: Bool?
  public var targetResolved: Bool?
  public var systemImproved: Bool?
  public var after: FixMeasurement?
  public var samples: Int
  public var remaining: [ProcessRecord]
  public var message: String
  public var nextStep: String
}
public struct FixSession: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var revision: UInt64? = nil
  public var started = Date()
  public var updated = Date()
  public var origin: FixOrigin
  public var demo: Bool
  public var phase: FixPhase = .assessing
  public var plan: FixPlan?
  public var approvedAction: FixAction?
  public var approvedAt: Date?
  public var forceConfirmed: Bool = false
  public var actionSentAt: Date?
  public var replacement: ProcessIdentity?
  public var result: FixResult?
  public var samples: Int = 0
  public var message: String = "Collecting fresh evidence…"
}
public enum FixError: LocalizedError, Sendable {
  case invalidated(String), refused(String), unavailable(String), busy
  public var errorDescription: String? {
    switch self {
    case .invalidated(let s), .refused(let s), .unavailable(let s): s
    case .busy: "A Fix session is already running."
    }
  }
}
public protocol FixRuntime: Sendable {
  func freshSnapshot() async throws -> Snapshot
  func resolve(process: ProcessRecord, in snapshot: Snapshot) async throws -> FixTarget
  func validate(target: FixTarget, token: InterventionToken) async throws
  func perform(
    action: FixAction, target: FixTarget?, token: InterventionToken, forceConfirmed: Bool,
    plan: FixPlan)
    async throws
  func relaunch(target: FixTarget, token: InterventionToken) async throws -> ProcessIdentity
}
