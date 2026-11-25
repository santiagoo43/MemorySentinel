import Foundation

public enum SessionSeries {
  public static func reduce(_ points: [SessionPoint], limit: Int = 600) -> [SessionPoint] {
    let cap = max(10, limit)
    guard points.count > cap else { return points }
    var essential: Set<Int> = [0, points.count - 1]
    if let peak = points.indices.max(by: {
      (points[$0].monitored ?? -1) < (points[$1].monitored ?? -1)
    }) {
      essential.insert(peak)
    }
    let gaps = points.indices.filter { points[$0].gap || points[$0].monitored == nil }
    let gapStride = max(1, Int(ceil(Double(gaps.count) / Double(cap / 4))))
    for i in stride(from: 0, to: gaps.count, by: gapStride) { essential.insert(gaps[i]) }
    var selected = essential
    let width = max(1, Int(ceil(Double(points.count) / Double(cap / 3))))
    for start in stride(from: 0, to: points.count, by: width) {
      let indices = start..<min(points.count, start + width)
      if let lo = indices.filter({ points[$0].monitored != nil }).min(by: {
        points[$0].monitored! < points[$1].monitored!
      }) {
        selected.insert(lo)
      }
      if let hi = indices.filter({ points[$0].monitored != nil }).max(by: {
        points[$0].monitored! < points[$1].monitored!
      }) {
        selected.insert(hi)
      }
    }
    if selected.count > cap {
      let spare = selected.subtracting(essential).sorted()
      let room = cap - essential.count
      selected = essential
      for i in 0..<max(0, room) {
        selected.insert(spare[min(spare.count - 1, i * spare.count / max(1, room))])
      }
    }
    var previous = -1
    return selected.sorted().map { index in
      var point = points[index]
      if previous >= 0
        && points[(previous + 1)...index].contains(where: {
          $0.gap || $0.monitored == nil
        })
      {
        point.gap = true
      }
      previous = index
      return point
    }
  }
}

extension WorkSession {
  mutating func observe(
    _ frame: ExperienceFrame, previous: ExperienceFrame?, events incoming: [ExperienceEvent]
  ) {
    let dt = ObservationContinuity.interval(previous, frame)
    elapsedSeconds = max(elapsedSeconds, frame.uptime - startedUptime)
    if let dt, let previous {
      if previous.complete && frame.complete { observedSeconds += dt }
      if let a = previous.monitored, let b = frame.monitored {
        byteSeconds += (a + b) * 0.5 * dt; memorySeconds += dt
      }
      if previous.system.pressure != .unavailable && frame.system.pressure != .unavailable {
        pressureSeconds[previous.system.pressure.rawValue, default: 0] += dt / 2
        pressureSeconds[frame.system.pressure.rawValue, default: 0] += dt / 2
      }
      for app in frame.apps {
        guard
          let old = previous.apps.first(where: {
            $0.baselineKey == app.baselineKey && $0.generation == app.generation
          }),
          let a = old.footprint, let b = app.footprint
        else { continue }
        if let i = consumers.firstIndex(where: { $0.id == app.baselineKey }) {
          consumers[i].byteSeconds += (a + b) * 0.5 * dt
          consumers[i].observedSeconds += dt
        }
      }
    }
    for app in frame.apps {
      if let i = consumers.firstIndex(where: { $0.id == app.baselineKey }) {
        if let value = app.footprint { consumers[i].peak = max(consumers[i].peak ?? value, value) }
      } else if consumers.count < 64 {
        consumers.append(
          SessionConsumer(
            id: app.baselineKey, name: app.name, version: app.version, sourcePath: app.sourcePath,
            peak: app.footprint, byteSeconds: 0, observedSeconds: 0))
      }
    }
    if let value = frame.monitored { peak = max(peak ?? value, value) }
    if firstSwap == nil { firstSwap = frame.system.swap }
    lastSwap = frame.system.swap
    warningCount += incoming.filter { ($0.level ?? .normal) >= .warning }.count
    if !configurations.contains(frame.configuration), configurations.count < 64 {
      configurations.append(frame.configuration)
    }
    if !profileIDs.contains(frame.profileID), profileIDs.count < 12 {
      profileIDs.append(frame.profileID)
    }
    points.append(
      SessionPoint(
        date: frame.date, elapsed: elapsedSeconds, monitored: frame.monitored,
        swap: frame.system.swap, risk: frame.risk, gap: previous != nil && dt == nil))
    if points.count > 1200 { points = SessionSeries.reduce(points) }
    events.append(contentsOf: incoming)
    if events.count > 200 { events.removeFirst(events.count - 200) }
    revision &+= 1
  }
  var summary: Self { var copy = self; copy.points = []; copy.events = []; return copy }
}

extension FollowupObservation {
  mutating func observe(frame: ExperienceFrame, previous: ExperienceFrame?, snapshot: Snapshot) {
    guard status == .observing else { return }
    revision &+= 1
    // A sample arriving after the window cannot add evidence or a warning to that window.
    if frame.uptime > deadlineUptime { finishWindow(); return }
    guard frame.profileID == profileID else {
      status = .partial; issue = "The active profile changed during follow-up."; return
    }
    guard ObservationContinuity.interval(previous, frame) != nil || samples == 0 else {
      status = .partial; issue = "A measurement gap or settings change interrupted follow-up.";
      return
    }
    guard frame.complete else {
      status = .partial; issue = "Some required measurements are unavailable."; return
    }
    if let appKey, let app = frame.apps.first(where: { $0.key == appKey }), app.version != version {
      status = .partial; issue = "The application version changed during follow-up."; return
    }
    samples += 1
    if ObservationContinuity.interval(previous, frame) != nil, let previous {
      let from = max(previous.uptime, deadlineUptime - 300)
      coveredSeconds = min(300, coveredSeconds + max(0, frame.uptime - from))
    }
    let app = appKey.flatMap { key in frame.apps.first { $0.key == key } }
    let target = snapshot.processes.first { $0.identity == targetIdentity }
    let related = snapshot.processes.filter { relatedIdentities.contains($0.identity) }
    if let targetIdentity, target == nil,
      snapshot.unreadablePIDs?.contains(targetIdentity.pid) == true
    {
      status = .partial; issue = "The approved process identity could not be read."; return
    }
    if related.contains(where: { $0.footprint == nil }) {
      status = .partial; issue = "A known related process has unavailable memory readings."; return
    }
    last = FixMeasurement(snapshot: snapshot, target: targetIdentity)
    switch problem {
    case .systemPressure:
      warningReturned =
        warningReturned || frame.system.pressure == .warning || frame.system.pressure == .critical
    case .swapGrowth:
      guard let growth = snapshot.swapGrowth else {
        status = .partial; issue = "Swap trend is unavailable."; return
      }
      warningReturned = warningReturned || growth > swapThreshold
    case .highFootprint:
      if let target, let value = target.footprint, let total = frame.system.total {
        warningReturned = warningReturned || value > total * warningFraction
      }
      warningReturned =
        warningReturned || related.contains { $0.risk >= .warning }
        || app.map { $0.risk >= .warning } == true
    case .sustainedGrowth:
      if let target {
        guard let growth = target.growth
        else {
          if frame.uptime >= deadlineUptime {
            status = .partial; issue = "The target's replacement trend is not yet available."
          }
          return
        }
        warningReturned = warningReturned || growth > growthThreshold
      }
    case .selectedContributor:
      warningReturned =
        warningReturned || target.map { $0.risk >= .warning } == true
        || related.contains { $0.risk >= .warning } || app.map { $0.risk >= .warning } == true
    case .unavailableMetrics, .monitoringFailure:
      warningReturned = warningReturned || !frame.complete
    default: warningReturned = warningReturned || frame.risk >= .warning
    }
    if frame.uptime >= deadlineUptime { finishWindow() }
  }
  private mutating func finishWindow() {
    if coveredSeconds < 270 || samples < 3 {
      status = .partial; issue = "Less than 90% of the five-minute window was covered."
    } else if warningReturned {
      status = .returned; issue = "A related warning was observed during the follow-up window."
    } else {
      status = .stable;
      issue = "No related warning was observed in the available five-minute samples."
    }
  }
}
