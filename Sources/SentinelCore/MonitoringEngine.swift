import Foundation

public struct EngineUpdate: Sendable {
  public var snapshot: Snapshot
  public var incidents: [Incident]
  public var seed: [TimelinePoint]?
  public var error: String?
  public var experience: ExperienceSummary? = nil
  public var configuration: String? = nil
}
public actor MonitoringEngine {
  private var settings: Settings
  private var analyzer = Analyzer()
  private let collector = LiveCollector()
  private let history: HistoryStore?
  private let experience: ExperienceCoordinator?
  private let demoExperience: ExperienceCoordinator?
  private var seedingID: UUID?
  private var lastConfigurationRevision: UInt64 = 0
  private var maintenance = false
  private var loop: Task<Void, Never>?
  private var monitoringActivity: (any NSObjectProtocol)?
  private var latest: Snapshot?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var loopID = UUID()
  private var demoRemoved = Set<ProcessIdentity>()
  private var demoReplacement: ProcessIdentity?
  private var demoRecovered = false
  private var paused = false
  private var demo = false
  private var scenario: SimulationScenario = .stable
  private var step = 0
  private var origin = Date()
  private var eventPressure: Pressure?
  private var sampling = false
  private var forcedNext: Pressure?
  private var generation = 0
  private let sink: @Sendable (EngineUpdate) async -> Void
  public init(
    settings: Settings, history: HistoryStore?, experience: ExperienceCoordinator? = nil,
    demoExperience: ExperienceCoordinator? = nil,
    sink: @escaping @Sendable (EngineUpdate) async -> Void
  ) {
    self.settings = settings
    self.history = history
    self.experience = experience; self.demoExperience = demoExperience
    self.sink = sink
  }
  public func start() {
    guard loop == nil && !maintenance else { return }
    let id = UUID(); loopID = id
    // The user requested a continuous watchdog, including when all windows are closed.
    // Allow system/display sleep while preventing App Nap from deferring its sampling loop.
    monitoringActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "Continuous memory monitoring")
    if paused { endMonitoringActivity() }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, await self.isCurrentLoop(id) else { return }
        let tick = ContinuousClock.now
        await self.sample()
        let interval = await self.interval()
        do {
          try await Task.sleep(until: tick.advanced(by: .seconds(interval)), clock: .continuous)
        } catch { return }
      }
    }
  }
  private func interval() -> Int { settings.interval }
  private func isCurrentLoop(_ id: UUID) -> Bool { loopID == id }
  public var isPaused: Bool { paused }
  public var samplingLoopCount: Int { loop == nil ? 0 : 1 }
  public var monitoringActivityCount: Int { monitoringActivity == nil ? 0 : 1 }
  private func endMonitoringActivity() {
    if let activity = monitoringActivity {
      ProcessInfo.processInfo.endActivity(activity)
      monitoringActivity = nil
    }
  }
  public func freshSnapshot() async throws -> Snapshot {
    guard seedingID == nil && !maintenance else { throw FixError.busy }
    while sampling {
      guard waiters.count < 8 else { throw FixError.busy }
      await withCheckedContinuation { waiters.append($0) }
      try Task.checkCancellation()
      guard !maintenance else { throw FixError.busy }
    }
    // Claim synchronously before any actor suspension; no scheduled tick can steal this request.
    sampling = true
    guard let fresh = await collectSample(), abs(fresh.date.timeIntervalSinceNow) < 10 else {
      throw FixError.unavailable("A fresh monitoring sample could not be obtained.")
    }
    return fresh
  }
  public func restart() async throws {
    stop(); analyzer = Analyzer(); eventPressure = nil; forcedNext = nil; paused = false
    start(); _ = try await freshSnapshot()
  }
  public func simulate(action: FixAction, target: FixTarget?) throws {
    guard demo else {
      throw FixError.refused("Simulation effects cannot operate on live monitoring.")
    }
    if action == .restartMonitoring {
      stop(); analyzer = Analyzer(); paused = false; start()
    }
    if action.isProcessAction, let target { demoRemoved.insert(target.process.identity) }
    if !action.isGuidance { demoRecovered = true }
  }
  public func simulateRelaunch(target: FixTarget) throws -> ProcessIdentity {
    guard demo else { throw FixError.refused("Not in Simulation Mode.") }
    let id = ProcessIdentity(
      pid: target.process.identity.pid + 1000, seconds: UInt64(Date().timeIntervalSince1970),
      microseconds: 1)
    demoReplacement = id; demoRecovered = true; return id
  }
  public func stop() {
    loopID = UUID()
    loop?.cancel()
    loop = nil
    endMonitoringActivity()
  }
  public func suspendForMaintenance() async {
    maintenance = true; paused = true; stop()
    while sampling { await withCheckedContinuation { waiters.append($0) } }
    await experience?.interrupt(reason: "History maintenance interrupted observation.")
  }
  public func finishMaintenance() {
    maintenance = false; paused = true; start()
  }
  public func configure(_ value: Settings, revision: UInt64? = nil) {
    if let revision {
      guard revision > lastConfigurationRevision else { return }
      lastConfigurationRevision = revision
    }
    let valid = value.validated()
    if valid.analysisSignature != settings.analysisSignature { generation += 1; latest = nil }
    if valid.watchRules != settings.watchRules || valid.excludedPaths != settings.excludedPaths
      || valid.activeProfileID != settings.activeProfileID
      || valid.disabledBuiltIns != settings.disabledBuiltIns
    {
      analyzer = Analyzer()
    }
    settings = valid
  }
  public func pause(_ value: Bool) {
    paused = value
    if value {
      endMonitoringActivity()
    } else {
      analyzer = Analyzer()
      if loop != nil && monitoringActivity == nil {
        monitoringActivity = ProcessInfo.processInfo.beginActivity(
          options: .userInitiatedAllowingIdleSystemSleep, reason: "Continuous memory monitoring")
      }
    }
  }
  public func resetAfterWake() {
    analyzer = Analyzer()
    eventPressure = nil
  }
  public func pressureEvent(_ value: Pressure) async {
    eventPressure = value
    if !paused && !demo {
      forcedNext = value
      await sample()
    }
  }
  public func mode(demo value: Bool, scenario: SimulationScenario) async {
    guard !maintenance else { return }
    generation += 1
    let modeGeneration = generation, seedID = UUID()
    seedingID = seedID
    defer { if seedingID == seedID { seedingID = nil } }
    if value && !demo {
      await experience?.interrupt(reason: "Simulation Mode interrupted live observation.")
    }
    guard generation == modeGeneration else { return }
    if value { await demoExperience?.resetDemo() }
    guard generation == modeGeneration else { return }
    demo = value
    forcedNext = nil
    demoRemoved = []; demoReplacement = nil; demoRecovered = false; latest = nil
    self.scenario = scenario
    analyzer = Analyzer()
    step = 0
    origin = Date().addingTimeInterval(-895)
    if value {
      var points: [TimelinePoint] = []
      var result: Evaluation?
      var events: [Incident] = []
      var experienceSummary: ExperienceSummary?
      let uptimeOrigin = ProcessInfo.processInfo.systemUptime - 895
      for i in 0..<180 {
        guard generation == modeGeneration else { return }
        let raw = Simulator().sample(step: i, scenario: scenario, origin: origin)
        result = analyzer.evaluate(raw, settings: settings, demo: true)
        points.append(result!.snapshot.point)
        events.append(contentsOf: result!.incidents)
        experienceSummary = await demoExperience?.ingest(
          snapshot: result!.snapshot,
          incidents: result!.incidents, settings: settings, uptime: uptimeOrigin + Double(i) * 5)
      }
      step = 180
      guard generation == modeGeneration else { return }
      if let result {
        await sink(
          EngineUpdate(
            snapshot: result.snapshot, incidents: Array(events.suffix(300)), seed: points,
            error: nil, experience: experienceSummary, configuration: settings.analysisSignature))
      }
    } else {
      if seedingID == seedID { seedingID = nil }
      await sample()
    }
  }
  public func sample(force: Bool = false) async {
    guard (!paused || force) && !sampling && seedingID == nil && !maintenance else { return }
    sampling = true
    _ = await collectSample()
  }
  private func collectSample() async -> Snapshot? {
    let activeGeneration = generation
    let sampleSettings = settings

    var raw: RawSample
    if demo {
      raw = Simulator().sample(step: step, scenario: scenario, origin: origin)
      raw.date = Date()
      step += 1
      raw.processes.removeAll { demoRemoved.contains($0.identity) }
      if let replacement = demoReplacement {
        var p = Simulator().sample(step: 0, scenario: .stable, origin: origin).processes[0]
        p.identity = replacement; p.footprint = 128 * MiB; p.rss = 96 * MiB; raw.processes.append(p)
      }
      if demoRecovered {
        raw.system.pressure = .normal; raw.system.used = 7 * GiB; raw.system.available = 11 * GiB
        raw.system.swap = raw.system.swap ?? 0
        if scenario == .missingMetrics {
          let restored = Simulator().sample(
            step: max(0, step - 1), scenario: .stable, origin: origin)
          for index in raw.processes.indices {
            if let synthetic = restored.processes.first(where: {
              $0.identity == raw.processes[index].identity
            }) {
              raw.processes[index].footprint = synthetic.footprint
              raw.processes[index].rss = synthetic.rss
            }
          }
        }
      }
    } else {
      raw = collector.collect()
      if let forcedNext {
        raw.system.pressure = forcedNext
        self.forcedNext = nil
      } else if let eventPressure, raw.system.pressure == .unavailable {
        raw.system.pressure = eventPressure
      }
    }
    let result = analyzer.evaluate(raw, settings: sampleSettings, demo: demo)
    var error: String?
    do {
      try await history?.append(
        result.snapshot, incidents: result.incidents, settings: sampleSettings)
    } catch let issue { error = issue.localizedDescription }
    var experienceSummary: ExperienceSummary?
    if activeGeneration == generation {
      experienceSummary = await (result.snapshot.demo ? demoExperience : experience)?.ingest(
        snapshot: result.snapshot, incidents: result.incidents, settings: sampleSettings,
        uptime: ProcessInfo.processInfo.systemUptime)
    }
    if activeGeneration == generation {
      latest = result.snapshot
      await sink(
        EngineUpdate(
          snapshot: result.snapshot, incidents: result.incidents, seed: nil, error: error,
          experience: experienceSummary, configuration: sampleSettings.analysisSignature))
    }
    sampling = false
    let waiting = waiters; waiters = []; for waiter in waiting { waiter.resume() }
    if forcedNext != nil && !demo && !paused { Task { [weak self] in await self?.sample() } }
    return activeGeneration == generation ? result.snapshot : nil
  }
}
