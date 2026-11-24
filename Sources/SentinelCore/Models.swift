import Foundation

public let MiB = 1_048_576.0
public let GiB = 1_073_741_824.0

public struct ProcessIdentity: Codable, Hashable, Sendable, Identifiable {
  public var pid: Int32
  public var seconds: UInt64
  public var microseconds: UInt64
  public var id: String { "\(pid):\(seconds):\(microseconds)" }
  public var startDate: Date {
    Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1e6)
  }
  public init(pid: Int32, seconds: UInt64, microseconds: UInt64 = 0) {
    self.pid = pid
    self.seconds = seconds
    self.microseconds = microseconds
  }
}
public enum Pressure: String, Codable, Sendable { case normal, warning, critical, unavailable }
public enum RiskLevel: Int, Codable, CaseIterable, Comparable, Sendable {
  case normal, elevated, warning, critical
  public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
  public var title: String { String(describing: self).uppercased() }
}
public struct SystemMetrics: Codable, Sendable {
  public var total: Double?
  public var used: Double?
  public var available: Double?
  public var compressed: Double?
  public var swap: Double?
  public var diskFree: Double?
  public var pressure: Pressure
  public init(
    total: Double?, used: Double? = nil, available: Double? = nil, compressed: Double? = nil,
    swap: Double? = nil, diskFree: Double? = nil, pressure: Pressure = .unavailable
  ) {
    self.total = total
    self.used = used
    self.available = available
    self.compressed = compressed
    self.swap = swap
    self.diskFree = diskFree
    self.pressure = pressure
  }
}
public struct ProcessRecord: Codable, Sendable, Identifiable {
  public var identity: ProcessIdentity
  public var id: ProcessIdentity { identity }
  public var ppid: Int32
  public var pgid: Int32
  public var uid: UInt32
  public var name: String
  public var path: String
  public var bundleID: String?
  public var footprint: Double?
  public var rss: Double?
  public var group: String?
  public var evidence: String?
  public var uncertain: Bool
  public var peak: Double
  public var growth: Double?
  public var observedSince: Date
  public var risk: RiskLevel
  public init(
    identity: ProcessIdentity, ppid: Int32 = 1, pgid: Int32 = 0, uid: UInt32 = 501, name: String,
    path: String, bundleID: String? = nil, footprint: Double? = nil, rss: Double? = nil,
    group: String? = nil, evidence: String? = nil, uncertain: Bool = false, peak: Double = 0,
    growth: Double? = nil, observedSince: Date = Date(), risk: RiskLevel = .normal
  ) {
    self.identity = identity
    self.ppid = ppid
    self.pgid = pgid
    self.uid = uid
    self.name = name
    self.path = path
    self.bundleID = bundleID
    self.footprint = footprint
    self.rss = rss
    self.group = group
    self.evidence = evidence
    self.uncertain = uncertain
    self.peak = peak
    self.growth = growth
    self.observedSince = observedSince
    self.risk = risk
  }
}
public struct WatchRule: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var label: String
  public var value: String
  public var kind: Kind
  public enum Kind: String, Codable, CaseIterable, Sendable { case executable, bundle }
  public init(label: String, value: String, kind: Kind) {
    id = UUID()
    self.label = label
    self.value = value
    self.kind = kind
  }
}
public struct Settings: Codable, Equatable, Sendable {
  public var interval: Int = 5
  public var warningFraction: Double = 0.30
  public var criticalFraction: Double = 0.45
  public var growthMiB: Double = 100
  public var swapGrowthMiB: Double = 150
  public var notifications: Bool = true
  public var cooldown: Double = 300
  public var detailHours: Int = 24
  public var aggregateDays: Int = 7
  public var incidentDays: Int = 30
  public var theme: String = "system"
  public var menuMetric: String = "monitored"
  public var menuIcon: Bool = true
  public var watchRules: [WatchRule] = []
  public var excludedPaths: [String] = []
  public var onboardingComplete = false
  public init() {}
  public func validated() -> Self {
    var s = self
    if ![2, 5, 10, 15, 30].contains(s.interval) { s.interval = 5 }
    s.warningFraction = s.warningFraction.isFinite ? min(0.8, max(0.05, s.warningFraction)) : 0.30
    s.criticalFraction =
      s.criticalFraction.isFinite
      ? min(0.95, max(s.warningFraction + 0.05, s.criticalFraction)) : 0.45
    s.growthMiB = s.growthMiB.isFinite ? min(4096, max(10, s.growthMiB)) : 100
    s.swapGrowthMiB = s.swapGrowthMiB.isFinite ? min(4096, max(10, s.swapGrowthMiB)) : 150
    s.cooldown = s.cooldown.isFinite ? min(3600, max(60, s.cooldown)) : 300
    s.detailHours = min(24, max(1, s.detailHours))
    s.aggregateDays = min(7, max(1, s.aggregateDays))
    s.incidentDays = min(90, max(1, s.incidentDays))
    s.watchRules = Array(s.watchRules.prefix(64))
    s.excludedPaths = Array(s.excludedPaths.prefix(128))
    return s
  }
}
public struct Incident: Codable, Sendable, Identifiable {
  public var id: UUID = UUID()
  public var date: Date
  public var level: RiskLevel
  public var identity: ProcessIdentity?
  public var processName: String?
  public var footprint: Double?
  public var growth: Double?
  public var reason: String
  public var demo: Bool? = nil
  public var system: SystemMetrics
}
public struct TimelinePoint: Codable, Sendable, Identifiable {
  public var date: Date
  public var id: Date { date }
  public var systemUsed: Double?
  public var monitored: Double?
  public var swap: Double?
  public var groups: [String: Double]
  public var processes: [String: Double]
  public var risk: RiskLevel
  public var peak: Double?
  public var peakDate: Date? = nil
}
public struct Snapshot: Codable, Sendable {
  public var date: Date
  public var system: SystemMetrics
  public var processes: [ProcessRecord]
  public var risk: RiskLevel
  public var reasons: [String]
  public var swapGrowth: Double?
  public var groupGrowth: [String: Double]
  public var demo: Bool
  public var processesAvailable: Bool? = nil
  public var unreadablePIDs: [Int32]? = nil
  public var monitored: [ProcessRecord] { processes.filter { $0.group != nil } }
  public var hasUnavailableMemoryReadings: Bool {
    system.total == nil || system.used == nil || system.available == nil || system.swap == nil
      || system.pressure == .unavailable || processesAvailable == false
      || monitored.contains { $0.footprint == nil }
  }
  public var monitoredBytes: Double? {
    let values = monitored.compactMap(\.footprint)
    return values.isEmpty ? (monitored.isEmpty ? 0 : nil) : values.reduce(0, +)
  }
  public var point: TimelinePoint {
    var groups: [String: Double] = [:]
    var members: [String: Double] = [:]
    for p in monitored {
      if let f = p.footprint {
        groups[p.group!, default: 0] += f
        members[p.identity.id] = f
      }
    }
    return TimelinePoint(
      date: date, systemUsed: system.used, monitored: monitoredBytes, swap: system.swap,
      groups: groups, processes: members, risk: risk, peak: monitoredBytes,
      peakDate: monitoredBytes == nil ? nil : date)
  }
}
public enum Format {
  public static func bytes(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "Unavailable" }
    if value >= GiB { return String(format: "%.2f GiB", value / GiB) }
    return String(format: "%.0f MiB", value / MiB)
  }
  public static func growth(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "Collecting…" }
    return String(format: "%+.1f MiB/min", value / MiB)
  }
}
