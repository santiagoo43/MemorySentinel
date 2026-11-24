import Foundation

public struct Reading: Sendable {
  public var date: Date
  public var value: Double
  public init(_ date: Date, _ value: Double) {
    self.date = date
    self.value = value
  }
}
public struct TrendWindow: Sendable {
  public private(set) var readings: [Reading] = []
  public init() {}
  public mutating func append(date: Date, value: Double) {
    guard value.isFinite && value >= 0 else { return }
    if let last = readings.last, date <= last.date || date.timeIntervalSince(last.date) > 90 {
      readings.removeAll(keepingCapacity: true)
    }
    readings.append(Reading(date, value))
    readings.removeAll { date.timeIntervalSince($0.date) > 900 }
    if readings.count > 460 { readings.removeFirst(readings.count - 460) }
  }
  public func slope(seconds: Double, minimumSpan: Double = 30) -> Double? {
    guard let last = readings.last else { return nil }
    let items = readings.filter { last.date.timeIntervalSince($0.date) <= seconds }
    guard items.count >= 3, let first = items.first,
      last.date.timeIntervalSince(first.date) >= minimumSpan
    else { return nil }
    let xs = items.map { $0.date.timeIntervalSince(first.date) / 60 }
    let ys = items.map(\.value)
    let mx = xs.reduce(0, +) / Double(xs.count)
    let my = ys.reduce(0, +) / Double(ys.count)
    let variance = xs.reduce(0) { $0 + pow($1 - mx, 2) }
    guard variance > 0 else { return nil }
    return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / variance
  }
  public var jump: Double? {
    guard readings.count >= 2 else { return nil }
    return readings.last!.value - readings[readings.count - 2].value
  }
  public var deviation: Double? {
    guard readings.count >= 12, let last = readings.last else { return nil }
    let history = Array(readings.dropLast().suffix(60)).map(\.value)
    let mean = history.reduce(0, +) / Double(history.count)
    let sd = sqrt(history.reduce(0) { $0 + pow($1 - mean, 2) } / Double(history.count))
    guard sd > MiB else { return nil }
    return (last.value - mean) / sd
  }
}
public struct RiskLatch: Sendable {
  public private(set) var level: RiskLevel = .normal
  private var pending: RiskLevel = .normal
  private var count = 0
  public init() {}
  public mutating func update(_ candidate: RiskLevel, immediate: Bool = false) -> RiskLevel {
    if immediate {
      level = candidate
      pending = candidate
      count = 0
      return level
    }
    if candidate == level {
      pending = level
      count = 0
      return level
    }
    if candidate == pending {
      count += 1
    } else {
      pending = candidate
      count = 1
    }
    if count >= (candidate > level ? 3 : 6) {
      level = candidate
      count = 0
    }
    return level
  }
}
public struct AlertGate: Sendable {
  private var sent: [String: (Date, RiskLevel)] = [:]
  public init() {}
  public mutating func permits(key: String, level: RiskLevel, date: Date, cooldown: Double) -> Bool
  {
    guard level >= .warning else { return false }
    if let prior = sent[key], date.timeIntervalSince(prior.0) < cooldown, level <= prior.1 {
      return false
    }
    sent[key] = (date, level)
    sent = sent.filter { date.timeIntervalSince($0.value.0) < 86400 }
    if sent.count > 2048, let oldest = sent.min(by: { $0.value.0 < $1.value.0 })?.key {
      sent.removeValue(forKey: oldest)
    }
    return true
  }
}
private struct ProcessState: Sendable {
  var window = TrendWindow()
  var peak = 0.0
  var since: Date
  var highSince: Date?
  var jumpUntil: Date?
  var attributedGroup: String?
  var attributedPath: String?
  var ancestryEvidence: String?
  var latch = RiskLatch()
}
public struct Evaluation: Sendable {
  public var snapshot: Snapshot
  public var incidents: [Incident]
}
public struct Analyzer: Sendable {
  private var states: [ProcessIdentity: ProcessState] = [:]
  private var groups: [String: TrendWindow] = [:]
  private var swap = TrendWindow()
  private var systemLatch = RiskLatch()
  private var gate = AlertGate()
  private var lastDate: Date?
  public init() {}
  public var trackedIdentityCount: Int { states.count }
  public mutating func evaluate(_ raw: RawSample, settings: Settings, demo: Bool = false)
    -> Evaluation
  {
    if let lastDate, raw.date.timeIntervalSince(lastDate) > 90 || raw.date <= lastDate {
      self = Analyzer()
    }
    lastDate = raw.date
    var processes = Classifier.classify(raw.processes, settings: settings)
    let tracked = Set(
      processes.sorted {
        if ($0.group != nil) != ($1.group != nil) { return $0.group != nil }
        return ($0.footprint ?? -1) > ($1.footprint ?? -1)
      }.prefix(512).map(\.identity))
    let active = Set(processes.map(\.identity))
    states = states.filter { active.contains($0.key) && tracked.contains($0.key) }
    var incidents: [Incident] = []
    var reasons: [String] = []
    var candidate: RiskLevel = .normal
    let total = raw.system.total ?? 0
    var groupValues: [String: Double] = [:]
    var growingGroups: [String: Int] = [:]
    for i in processes.indices {
      var p = processes[i]
      var state = states[p.identity] ?? ProcessState(since: raw.date)
      if p.group == nil, p.ppid == 1, state.attributedPath == p.path,
        !settings.excludedPaths.contains(p.path), let group = state.attributedGroup
      {
        p.group = group;
        p.evidence =
          "Previously verified ancestry; parent exited. " + (state.ancestryEvidence ?? "")
        p.uncertain = false
      }
      if p.evidence?.hasPrefix("Verified ancestry") == true {
        state.attributedGroup = p.group; state.attributedPath = p.path;
        state.ancestryEvidence = p.evidence
      }
      var c: RiskLevel = .normal
      var why: [String] = []
      if let bytes = p.footprint {
        state.window.append(date: raw.date, value: bytes)
        state.peak = max(state.peak, bytes)
        p.peak = state.peak
        p.growth = state.window.slope(seconds: 300)
        p.observedSince = state.since
        if total > 0 && bytes >= total * settings.warningFraction {
          if state.highSince == nil { state.highSince = raw.date }
        } else {
          state.highSince = nil
        }
        if let group = p.group {
          groupValues[group, default: 0] += bytes
          if total > 0 && bytes >= total * settings.criticalFraction {
            c = .warning
            why.append("Footprint exceeds critical process threshold")
          }
          if let since = state.highSince, raw.date.timeIntervalSince(since) >= 30 {
            c = max(c, .warning)
            why.append("Sustained high footprint")
          } else if total > 0 && bytes >= total * settings.warningFraction {
            c = max(c, .elevated)
            why.append("High footprint")
          }
          if let rapid = state.window.slope(seconds: 60), rapid > 2 * settings.growthMiB * MiB {
            c = max(c, .elevated); why.append("Rapid 1 minute growth: \(Format.growth(rapid))")
          }
          if let growth = p.growth, growth > settings.growthMiB * MiB {
            c = max(c, .elevated)
            why.append("Suspicious sustained growth: \(Format.growth(growth))")
            growingGroups[group, default: 0] += 1
            if let long = state.window.slope(seconds: 900, minimumSpan: 240),
              long > settings.growthMiB * MiB
            {
              c = max(c, .warning)
            }
          }
          if let jump = state.window.jump, jump > max(512 * MiB, total * 0.04) {
            state.jumpUntil = raw.date.addingTimeInterval(Double(settings.interval * 3))
            why.append("Sudden footprint jump: \(Format.bytes(jump))")
          }
          if let until = state.jumpUntil, raw.date <= until {
            c = max(c, .elevated)
            why.append("Recent sudden footprint increase")
          }
          if let deviation = state.window.deviation, deviation > 4,
            (state.window.jump ?? 0) > 256 * MiB
          {
            c = max(c, .elevated)
            why.append("Unusual change against recent baseline")
          }
          if c >= .warning && raw.system.pressure == .critical { c = .critical }
        }
      }
      if p.footprint != nil {
        p.risk = state.latch.update(
          c, immediate: raw.system.pressure == .critical && p.group != nil && c >= .warning)
      } else {
        p.risk = state.latch.level
        state.highSince = nil
      }
      if tracked.contains(p.identity) { states[p.identity] = state }
      processes[i] = p
      if p.group != nil {
        candidate = max(candidate, p.risk)
        if !why.isEmpty {
          reasons.append("\(p.name), PID \(p.identity.pid): \(why.joined(separator:" · "))")
        }
        if gate.permits(
          key: p.identity.id, level: p.risk, date: raw.date, cooldown: settings.cooldown)
        {
          incidents.append(
            Incident(
              date: raw.date, level: p.risk, identity: p.identity, processName: p.name,
              footprint: p.footprint, growth: p.growth, reason: why.joined(separator: ". "),
              demo: demo,
              system: raw.system))
        }
      }
    }
    if processes.count > 512 {
      reasons.append(
        "Per-process trend history is limited to 512 prioritized identities; other rows show current measurements only."
      )
    }
    groups = groups.filter { groupValues[$0.key] != nil }
    var groupGrowth: [String: Double] = [:]
    for (group, value) in groupValues {
      var window = groups[group] ?? TrendWindow()
      window.append(date: raw.date, value: value)
      groups[group] = window
      if let rate = window.slope(seconds: 300) { groupGrowth[group] = rate }
    }
    let monitored = groupValues.values.reduce(0, +)
    if total > 0 && monitored > total * settings.criticalFraction {
      candidate = max(candidate, .warning)
      reasons.append(
        "Combined attributed footprint exceeds \(Int(settings.criticalFraction*100))% of physical memory; this sum can include shared accounting."
      )
    }
    for (group, count) in growingGroups where count >= 2 {
      candidate = max(candidate, .warning)
      reasons.append("\(count) processes in \(group) show sustained growth together.")
    }
    if let value = raw.system.swap { swap.append(date: raw.date, value: value) }
    let swapGrowth = raw.system.swap == nil ? nil : swap.slope(seconds: 300)
    if let rate = swapGrowth, rate > settings.swapGrowthMiB * MiB {
      candidate = max(candidate, .warning)
      reasons.append("Swap is growing \(Format.growth(rate)).")
    }
    if raw.system.pressure == .warning {
      candidate = max(candidate, .warning)
      reasons.append("macOS reports elevated memory pressure.")
    }
    if raw.system.pressure == .warning, total > 0, monitored > total * settings.criticalFraction,
      (swapGrowth ?? 0) > settings.swapGrowthMiB * MiB
    {
      candidate = .critical
      reasons.append(
        "High attributed footprint, elevated system pressure and rapid swap growth coincide.")
    }
    if raw.system.pressure == .critical {
      candidate = .critical
      reasons.insert(
        "macOS reports CRITICAL memory pressure. Save work and review large processes now.", at: 0)
    }
    if let available = raw.system.available, available < total * 0.08 {
      candidate = max(candidate, .elevated)
      reasons.append("Estimated available memory is low.")
    }
    if let disk = raw.system.diskFree, disk < 5 * GiB {
      candidate = max(candidate, .warning)
      reasons.append("Less than 5 GiB of free storage remains; swap growth may be constrained.")
    }
    if raw.system.used == nil { reasons.append("System used-memory estimate is unavailable.") }
    if total <= 0 {
      reasons.append("Physical memory is unavailable; RAM-relative thresholds are suspended.")
    }
    if raw.system.pressure == .unavailable {
      if systemLatch.level >= .warning {
        candidate = max(candidate, systemLatch.level);
        reasons.append("Risk is held while the pressure signal is unavailable.")
      }
      reasons.append("System pressure is unavailable; other measured signals remain active.")
    }
    if processes.contains(where: { $0.group != nil && $0.footprint == nil }) {
      reasons.append("Some monitored footprints are unavailable; group totals are incomplete.")
    }
    if raw.system.pressure == .warning && systemLatch.level == .normal {
      _ = systemLatch.update(.elevated, immediate: true)
    }
    let level = systemLatch.update(candidate, immediate: raw.system.pressure == .critical)
    if gate.permits(key: "system", level: level, date: raw.date, cooldown: settings.cooldown) {
      incidents.insert(
        Incident(
          date: raw.date, level: level, identity: nil, processName: nil, footprint: monitored,
          growth: nil, reason: reasons.prefix(4).joined(separator: " "), demo: demo,
          system: raw.system), at: 0)
    }
    processes.sort { ($0.footprint ?? -1) > ($1.footprint ?? -1) }
    return Evaluation(
      snapshot: Snapshot(
        date: raw.date, system: raw.system, processes: processes, risk: level,
        reasons: Array(reasons.prefix(32)), swapGrowth: swapGrowth, groupGrowth: groupGrowth,
        demo: demo, processesAvailable: raw.processesAvailable,
        unreadablePIDs: raw.unreadablePIDs), incidents: incidents)
  }
}
