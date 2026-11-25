import Foundation

public enum AppAttribution {
  public static func frame(snapshot: Snapshot, settings: Settings, uptime: Double)
    -> ExperienceFrame
  {
    let profile = settings.activeProfile
    let records = Dictionary(
      snapshot.processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var members: [String: [ProcessRecord]] = [:]
    var sources: [String: [ProcessRecord]] = [:]
    var processApps: [ProcessIdentity: String] = [:]
    for p in snapshot.monitored {
      var source = p
      var visited: Set<Int32> = [p.identity.pid]
      for _ in 0..<64 {
        guard let parent = records[source.ppid], parent.group == p.group, parent.uid == source.uid,
          parent.identity.startDate <= source.identity.startDate,
          visited.insert(parent.identity.pid).inserted
        else { break }
        source = parent
      }
      let root: String
      if let range = source.path.range(of: ".app/") {
        root = String(source.path[..<range.lowerBound]) + ".app"
      } else {
        root = source.path
      }
      let key =
        "app:\(source.uid):"
        + [p.group ?? "", root].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
      members[key, default: []].append(p)
      if sources[key]?.contains(where: { $0.identity == source.identity }) != true {
        sources[key, default: []].append(source)
      }
      processApps[p.identity] = key
    }
    let apps = members.keys.sorted().prefix(64).compactMap { key -> AppObservation? in
      guard let values = members[key], let roots = sources[key],
        let root = roots.min(by: {
          $0.identity.startDate < $1.identity.startDate
        })
      else { return nil }
      let versions = Set(roots.compactMap(\.appVersion))
      let complete =
        snapshot.processesAvailable != false
        && values.allSatisfy {
          !$0.uncertain && $0.footprint.map { $0.isFinite && $0 >= 0 } == true
        }
      let footprint = complete ? values.compactMap(\.footprint).reduce(0, +) : nil
      let rss =
        values.allSatisfy { $0.rss.map { $0.isFinite && $0 >= 0 } == true }
        ? values.compactMap(\.rss).reduce(0, +) : nil
      return AppObservation(
        key: key, name: root.group ?? root.name, group: root.group ?? root.name,
        sourcePath: root.path,
        version: versions.count == 1 && roots.allSatisfy { $0.appVersion != nil }
          ? versions.first : nil,
        generation: roots.map { $0.identity.id }.sorted().joined(separator: ","),
        root: root.identity,
        footprint: footprint, rss: rss, members: values.count, complete: complete,
        risk: values.map(\.risk).max() ?? .normal)
    }
    let watched = Array(snapshot.monitored.prefix(96))
    let ids = Set(watched.map(\.identity))
    let others = snapshot.processes.filter { !ids.contains($0.identity) }.sorted {
      ($0.footprint ?? 0) > ($1.footprint ?? 0)
    }.prefix(12)
    let captured = watched + others
    let processes = captured.map {
      FlightProcess(
        id: $0.identity, name: $0.name, appKey: processApps[$0.identity],
        group: $0.group, footprint: $0.footprint, rss: $0.rss)
    }
    let allMemory = snapshot.monitored.allSatisfy { $0.footprint != nil }
    return ExperienceFrame(
      date: snapshot.date, uptime: uptime, interval: settings.interval,
      profileID: profile.id, profileName: profile.name, configuration: settings.analysisSignature,
      system: snapshot.system, risk: snapshot.risk,
      monitored: allMemory ? snapshot.monitoredBytes : nil, apps: Array(apps), processes: processes,
      omittedProcesses: max(0, snapshot.monitored.count - watched.count),
      complete: !snapshot.hasUnavailableMemoryReadings && members.count <= 64,
      demo: snapshot.demo)
  }
}

public struct BaselineMinute: Codable, Sendable {
  public var minute: Double
  public var value: Double
  public var seconds: Double
}
public struct BaselineBucket: Codable, Sendable {
  public var minutes: [BaselineMinute] = []
  public var updated: Date = .distantPast
  public init() {}
  public var range: NormalRange {
    let values = minutes.map(\.value).sorted()
    guard values.count >= 30 else {
      return NormalRange(
        lower: nil, upper: nil, coveredSeconds: minutes.reduce(0) { $0 + $1.seconds })
    }
    return NormalRange(
      lower: values[Int(Double(values.count - 1) * 0.10)],
      upper: values[Int(Double(values.count - 1) * 0.90)],
      coveredSeconds: minutes.reduce(0) { $0 + $1.seconds })
  }
  public mutating func observe(value: Double, at date: Date, seconds: Double) {
    guard value.isFinite, value >= 0, seconds.isFinite, seconds > 0, seconds <= 90 else { return }
    let minute = floor(date.timeIntervalSince1970 / 60) * 60
    if let i = minutes.lastIndex(where: { $0.minute == minute }) {
      let accepted = min(seconds, max(0, 60 - minutes[i].seconds))
      let total = minutes[i].seconds + accepted
      if total > 0 {
        minutes[i].value = (minutes[i].value * minutes[i].seconds + value * accepted) / total
        minutes[i].seconds = total
      }
    } else {
      minutes.append(BaselineMinute(minute: minute, value: value, seconds: min(60, seconds)))
    }
    minutes.removeAll { date.timeIntervalSince1970 - $0.minute > 7 * 86400 }
    if minutes.count > 360 { minutes.removeFirst(minutes.count - 360) }
    updated = date
  }
}

public struct GrowthReading: Sendable {
  public var date: Date
  public var uptime: Double
  public var value: Double?
  public var generation: String
  public init(date: Date, uptime: Double, value: Double?, generation: String) {
    self.date = date; self.uptime = uptime; self.value = value; self.generation = generation
  }
}

public enum BudgetPredictor {
  public static func predict(readings: [GrowthReading], budget: Double?, interval: Int)
    -> BudgetForecast
  {
    func unavailable(_ reason: String, growth: Double? = nil) -> BudgetForecast {
      BudgetForecast(lowerMinutes: nil, upperMinutes: nil, growthPerMinute: growth, reason: reason)
    }
    guard let budget, budget.isFinite, budget > 0 else {
      return unavailable("Set a reference budget to enable a forecast.")
    }
    guard let last = readings.last, let current = last.value, current.isFinite, current >= 0 else {
      return unavailable("Current footprint is unavailable.")
    }
    if current >= budget { return unavailable("The reference budget has been reached.") }
    let values = readings.filter { last.date.timeIntervalSince($0.date) <= 900 }
    guard values.count >= 30, let first = values.first,
      last.date.timeIntervalSince(first.date) >= 600
    else {
      return unavailable("Collecting at least 10 minutes of fresh observations.")
    }
    guard values.allSatisfy({ $0.generation == last.generation }) else {
      return unavailable("The application instance changed. Collecting a new trend.")
    }
    guard values.allSatisfy({ $0.value.map { $0.isFinite && $0 >= 0 } == true }) else {
      return unavailable("The recent window contains unavailable readings.")
    }
    for (a, b) in zip(values, values.dropFirst()) {
      let dt = b.date.timeIntervalSince(a.date)
      guard dt > 0, dt <= Double(interval) * 3,
        abs((b.uptime - a.uptime) - dt) <= 2
      else {
        return unavailable("A measurement gap or clock change interrupted this trend.")
      }
    }
    var fits: [(slope: Double, r2: Double)] = []
    for window in [300.0, 600.0, 900.0] {
      let slice = values.filter { last.date.timeIntervalSince($0.date) <= window }
      guard slice.count >= 15, let begin = slice.first,
        last.date.timeIntervalSince(begin.date) >= min(window, 600) * 0.8
      else { continue }
      let x = slice.map { $0.date.timeIntervalSince(begin.date) / 60 }
      let y = slice.map { $0.value! }
      let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
      let xx = x.reduce(0) { $0 + pow($1 - mx, 2) }
      guard xx > 0 else { continue }
      let xy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
      let slope = xy / xx
      let total = y.reduce(0) { $0 + pow($1 - my, 2) }
      let residual = zip(x, y).reduce(0) { $0 + pow($1.1 - (my + slope * ($1.0 - mx)), 2) }
      fits.append((slope, total > 0 ? max(0, 1 - residual / total) : 0))
    }
    guard fits.count >= 2 else { return unavailable("Not enough well-covered time windows.") }
    let growth = fits[1].slope
    guard fits.allSatisfy({ $0.slope > MiB && $0.r2 >= 0.70 }),
      let low = fits.map(\.slope).min(), let high = fits.map(\.slope).max(), high / low <= 1.8
    else {
      return unavailable(
        "The growth trend is flat, noisy or inconsistent across windows.", growth: growth)
    }
    let range =
      (values.compactMap(\.value).max() ?? current) - (values.compactMap(\.value).min() ?? current)
    guard
      zip(values, values.dropFirst()).allSatisfy({
        abs($1.value! - $0.value!) < max(512 * MiB, range * 0.35)
      })
    else {
      return unavailable("A sudden jump makes extrapolation unreliable.", growth: growth)
    }
    let lower = (budget - current) / (high * 1.2)
    let upper = (budget - current) / (low * 0.8)
    guard lower.isFinite, upper.isFinite, upper <= 120 else {
      return unavailable(
        "The reference budget is beyond the two-hour forecast horizon.", growth: growth)
    }
    return BudgetForecast(
      lowerMinutes: max(0, lower), upperMinutes: max(lower, upper),
      growthPerMinute: growth,
      reason:
        "Conditional on the measured trend continuing; this is not a system out-of-memory prediction."
    )
  }
}

public enum SessionComparison {
  public static func cautions(_ a: WorkSession, _ b: WorkSession) -> [String] {
    var values = ["Observational comparison; different workloads can explain differences."]
    if a.profileID != b.profileID || a.profileIDs.count > 1 || b.profileIDs.count > 1 {
      values.append("Profiles differ or changed during a session.")
    }
    if a.configurations != b.configurations { values.append("Monitoring settings differ.") }
    let av = Set(a.consumers.map { $0.id + "|" + ($0.version ?? "unknown") })
    let bv = Set(b.consumers.map { $0.id + "|" + ($0.version ?? "unknown") })
    if av != bv {
      values.append(
        "Applications or versions differ; unknown versions cannot establish equivalence.")
    } else if a.consumers.contains(where: { $0.version == nil })
      || b.consumers.contains(where: { $0.version == nil })
    {
      values.append("Some application versions are unavailable; equivalence cannot be established.")
    }
    if a.coverage < 0.9 || b.coverage < 0.9 {
      values.append("At least one session has less than 90% observation coverage.")
    }
    if a.status == .interrupted || b.status == .interrupted {
      values.append("An interrupted session has an incomplete ending.")
    }
    return values
  }
}
