import Foundation

struct ExperienceLearningState: Codable, Sendable {
  var revision: UInt64 = 0
  var baselines: [String: BaselineBucket] = [:]
  var snoozes: [ScopedSnooze] = []
}

/// Consumes the monitoring engine's samples; it never starts a collector, timer or process action.
public actor ExperienceCoordinator {
  private let history: HistoryStore?
  private let maximumPayloadBytes: Int
  public nonisolated let demo: Bool
  private var learning = ExperienceLearningState()
  private var previous: ExperienceFrame?
  private var latest: ExperienceFrame?
  private var ring: [FrameReference] = []
  private var eventRing: [ExperienceEvent] = []
  private var memoryFrames: [UUID: ExperienceFrame] = [:]
  private var readings: [String: [GrowthReading]] = [:]
  private var trendResetReasons: [String: String] = [:]
  private var health: [AppHealth] = []
  private var counters: [String: Int] = [:]
  private var alertGate = AlertGate()
  private var recordings: [FlightRecording] = []
  private var sessions: [WorkSession] = []
  private var followups: [FollowupObservation] = []
  private var activeFixes = Set<UUID>()
  private var seenFixRevisions: [UUID: UInt64] = [:]
  private var fixContexts: [UUID: (String?, String, String?, UUID)] = [:]
  private var fixPhases: [UUID: FixPhase] = [:]
  private var blockedUntilUptime: Double = 0
  private var pendingGap = false
  private var writes = 0
  private var storageBytes = 0
  private var lastError: String?
  private var alerts: [ExperienceAlert] = []

  public init(
    history: HistoryStore?, demo: Bool = false, maximumPayloadBytes: Int = 64 * 1024 * 1024
  ) {
    self.history = history; self.demo = demo
    self.maximumPayloadBytes = max(1024 * 1024, min(64 * 1024 * 1024, maximumPayloadBytes))
  }
  public func restore(now: Date = Date()) async {
    guard let history, !demo else { return }
    do {
      if let data = try await history.experienceState() {
        learning = try JSONDecoder().decode(ExperienceLearningState.self, from: data)
      }
      recordings = try await history.experienceValues(
        FlightRecording.self, kind: "recording", limit: 40)
      sessions = try await history.experienceValues(
        WorkSession.self, kind: "sessionSummary", limit: 100)
      followups = try await history.experienceValues(
        FollowupObservation.self, kind: "followup", limit: 200)
      var batch = ExperienceWrite()
      for i in recordings.indices where recordings[i].status == .recording {
        recordings[i].status = .partial; recordings[i].revision &+= 1
        recordings[i].partialReason =
          "Recording interrupted by application restart. Missing samples were not reconstructed."
        batch.recordings.append(recordings[i])
      }
      for i in sessions.indices where sessions[i].status == .active {
        if var full = try await history.experienceValue(
          WorkSession.self, kind: "session", id: sessions[i].id)
        {
          full.status = .interrupted; full.ended = full.points.last?.date ?? full.started
          full.revision &+= 1; batch.sessions.append(full); sessions[i] = full.summary
        }
      }
      for i in followups.indices where followups[i].status == .observing {
        followups[i].status = .partial; followups[i].revision &+= 1
        followups[i].issue = "Application restart interrupted observation. No action was resumed."
        batch.followups.append(followups[i])
      }
      try await history.persistExperience(batch)
      sessions = sessions.map(\.summary)
      learning.snoozes.removeAll { $0.until <= now }
      let uptime = ProcessInfo.processInfo.systemUptime
      let recent = try await history.recentExperienceFrames(since: now.addingTimeInterval(-600))
        .filter {
          $0.date <= now && $0.date >= now.addingTimeInterval(-uptime)
            && $0.uptime <= uptime && uptime - $0.uptime <= 600
        }
      ring = recent.map(\.reference)
      let restoredEvents = recent.flatMap { $0.events ?? [] } + recordings.flatMap(\.events)
      appendEventRing(
        restoredEvents.filter {
          $0.date <= now && $0.date >= now.addingTimeInterval(-min(600, uptime))
        }, now: now)
      storageBytes = try await history.experiencePayloadBytes()
      try await enforceQuotas()
    } catch { lastError = "Experience history: \(error.localizedDescription)" }
  }
  public func summary() -> ExperienceSummary {
    var result = ExperienceSummary()
    result.profileID = latest?.profileID; result.configuration = latest?.configuration
    result.historyAvailable = history != nil || demo
    result.apps = health; result.alerts = alerts
    result.recordings = recordings; result.sessions = sessions.map(\.summary)
    result.followups = followups; result.snoozes = learning.snoozes
    result.storageBytes = storageBytes; result.error = lastError
    return result
  }
  public var trackedFixRevisionCount: Int { seenFixRevisions.count }
  private func key(profile: UUID, app: AppObservation, configuration: String) -> String {
    profile.uuidString + "|" + app.baselineKey + "|" + configuration
  }
  public func ingest(
    snapshot: Snapshot, incidents: [Incident], settings: Settings,
    uptime: Double
  ) async -> ExperienceSummary {
    guard snapshot.demo == demo else { return summary() }
    if latest?.date == snapshot.date { return summary() }
    var frame = AppAttribution.frame(snapshot: snapshot, settings: settings, uptime: uptime)
    let prior = pendingGap ? nil : previous
    let dt = ObservationContinuity.interval(prior, frame)
    let discontinuity = latest != nil && (dt == nil || pendingGap)
    let profile = settings.activeProfile
    var events = incidentEvents(incidents, frame: frame)
    if discontinuity {
      events.append(
        ExperienceEvent(
          date: frame.date, kind: .gap,
          text: "Sampling, profile or configuration continuity changed; no values were filled in."))
      readings = [:]; counters = [:]
    }
    if let latest, latest.profileID != frame.profileID {
      events.append(
        ExperienceEvent(
          date: frame.date, kind: .profile,
          text: "Active profile changed from \(latest.profileName) to \(frame.profileName)."))
    }
    if let prior {
      let before = Set(prior.processes.map(\.id)), after = Set(frame.processes.map(\.id))
      for p in frame.processes.filter({ !before.contains($0.id) }).prefix(12) {
        let started = p.id.startDate > prior.date && p.id.startDate <= frame.date
        events.append(
          ExperienceEvent(
            date: frame.date, kind: started ? .processStarted : .note,
            text: started
              ? "\(p.name) started with a new process identity."
              : "\(p.name) entered the captured process subset.", appKey: p.appKey, process: p.id
          ))
      }
      if frame.complete && frame.omittedProcesses == 0 && prior.omittedProcesses == 0 {
        let currentIdentities = Set(snapshot.processes.map(\.identity))
        for p in prior.processes.filter({ process in
          process.group != nil && !after.contains(process.id)
            && !currentIdentities.contains(process.id)
            && snapshot.unreadablePIDs?.contains(process.id.pid) != true
            && snapshot.processesAvailable == true
        }).prefix(12) {
          events.append(
            ExperienceEvent(
              date: frame.date, kind: .processExited,
              text: "\(p.name) is no longer in the measured process set.", appKey: p.appKey,
              process: p.id))
        }
      }
    }
    learning.snoozes.removeAll { $0.until <= frame.date }
    health = []
    var freshAlerts: [ExperienceAlert] = []
    alerts = []
    for app in frame.apps {
      let appKey = key(profile: frame.profileID, app: app, configuration: frame.configuration)
      if discontinuity {
        trendResetReasons[appKey] = "A sampling gap or changed monitoring context reset the trend."
      }
      let budget = profile.budget(for: app)
      let existingRange = learning.baselines[appKey]?.range
      let abnormal =
        existingRange?.ready == true
        && app.footprint.map { value in
          existingRange?.upper.map { value > max($0 * 1.25, $0 + 128 * MiB) } ?? false
        } == true
      let exceedsBudget = app.footprint.flatMap { value in budget.map { value > $0 } } ?? false
      if let generation = readings[appKey]?.last?.generation, generation != app.generation {
        trendResetReasons[appKey] =
          "The application instance changed; a new trend is being collected."
        readings[appKey] = []
      }
      readings[appKey, default: []].append(
        GrowthReading(
          date: frame.date, uptime: uptime,
          value: app.footprint, generation: app.generation))
      readings[appKey]?.removeAll { frame.date.timeIntervalSince($0.date) > 900 }
      if readings[appKey]!.count > 460 {
        readings[appKey]!.removeFirst(readings[appKey]!.count - 460)
      }
      if !demo, !exceedsBudget, !abnormal, activeFixes.isEmpty, uptime > blockedUntilUptime,
        frame.complete,
        frame.risk == .normal, prior?.risk == .normal, prior?.complete == true, app.risk == .normal,
        frame.system.pressure == .normal, prior?.system.pressure == .normal,
        let old = prior?.apps.first(where: {
          $0.baselineKey == app.baselineKey && $0.generation == app.generation
        }),
        old.complete, old.risk == .normal, app.complete, let value = app.footprint, let dt,
        old.footprint.map({ priorValue in budget.map { priorValue <= $0 } ?? true }) == true
      {
        learning.baselines[appKey, default: BaselineBucket()].observe(
          value: value, at: frame.date, seconds: dt)
      }
      let normal =
        learning.baselines[appKey]?.range ?? NormalRange(lower: nil, upper: nil, coveredSeconds: 0)
      let over = app.footprint.flatMap { value in budget.map { value > $0 } } ?? false
      let unusual =
        normal.ready
        && app.footprint.map { value in
          normal.upper.map { value > max($0 * 1.25, $0 + 128 * MiB) } ?? false
        } == true
      var forecast = BudgetPredictor.predict(
        readings: readings[appKey] ?? [], budget: budget, interval: frame.interval)
      if forecast.available {
        trendResetReasons.removeValue(forKey: appKey)
      } else if let reason = trendResetReasons[appKey], forecast.reason.contains("Collecting") {
        forecast.reason += " " + reason
      }
      health.append(
        AppHealth(
          app: app, budget: budget, normal: normal, forecast: forecast,
          unusual: unusual, overBudget: over, measuredAt: frame.date))
      for (kind, condition) in [(ExperienceEventKind.budget, over), (.unusual, unusual)] {
        let counterKey = appKey + "|" + kind.rawValue
        counters[counterKey] =
          condition && app.complete ? min(3, (counters[counterKey] ?? 0) + 1) : 0
        guard counters[counterKey] == 3 else { continue }
        let message =
          kind == .budget
          ? "\(app.name) footprint \(Format.bytes(app.footprint)) exceeds its \(Format.bytes(budget)) reference budget."
          : "\(app.name) footprint \(Format.bytes(app.footprint)) exceeds its observed normal range \(Format.bytes(normal.lower))–\(Format.bytes(normal.upper))."
        let event = ExperienceEvent(
          date: frame.date, kind: kind, text: message,
          appKey: app.key, process: app.root, level: .warning)
        let snoozed = isSnoozed(
          profile: frame.profileID, app: app.key, kind: kind, level: .warning, now: frame.date)
        let alert = ExperienceAlert(
          event: event,
          title:
            "\(app.name) · \(kind == .budget ? "Reference budget reached" : "Unusual memory use")",
          evidence: message,
          nextStep: "Review current measurements and save work before opening a Fix plan.",
          level: .warning, snoozed: snoozed)
        alerts.append(alert)
        if alertGate.permits(
          key: counterKey, level: .warning, date: frame.date, cooldown: settings.cooldown)
        {
          freshAlerts.append(alert); events.append(event)
        }
      }
    }
    ring.append(frame.reference)
    ring.removeAll { uptime - $0.uptime > 600 || uptime < $0.uptime }
    if ring.count > 320 { ring.removeFirst(ring.count - 320) }
    appendEventRing(events, now: frame.date)
    frame.events = Array(
      events.sorted { ($0.level ?? .normal) > ($1.level ?? .normal) }.prefix(128))
    frame.omittedEvents = max(0, events.count - 128)
    if demo { memoryFrames[frame.id] = frame }
    var batch = ExperienceWrite(frame: frame)
    // Close elapsed windows before a new trigger can merge with them or append a late sample.
    for i in recordings.indices
    where recordings[i].status == .recording
      && uptime > recordings[i].deadlineUptime
    {
      if (recordings[i].references.last?.uptime ?? 0)
        < recordings[i].deadlineUptime - Double(max(15, frame.interval * 3))
      {
        recordings[i].partialReason =
          "The capture ended with missing observations before its deadline."
      }
      recordings[i].status = recordings[i].partialReason == nil ? .complete : .partial
      recordings[i].revision &+= 1; batch.recordings.append(recordings[i])
    }
    if (history != nil || demo), events.contains(where: { ($0.level ?? .normal) >= .warning }) {
      triggerRecording(title: "Memory event", frame: frame)
    }
    for i in recordings.indices where recordings[i].status == .recording {
      if discontinuity || !frame.complete || frame.omittedProcesses > 0 {
        recordings[i].partialReason = Self.incompleteCaptureReason
      }
      if !recordings[i].references.contains(where: { $0.id == frame.id }) {
        recordings[i].references.append(frame.reference)
      }
      let existing = Set(recordings[i].events.map(\.id))
      recordings[i].events.append(contentsOf: events.filter { !existing.contains($0.id) })
      if recordings[i].events.count > 256 {
        recordings[i].omittedEvents += recordings[i].events.count - 256
        recordings[i].events.removeFirst(recordings[i].events.count - 256)
      }
      if recordings[i].references.count >= 640 {
        recordings[i].status = .partial;
        recordings[i].partialReason = "The bounded 640-frame capture limit was reached."
      } else if uptime >= recordings[i].deadlineUptime {
        recordings[i].status = recordings[i].partialReason == nil ? .complete : .partial
      }
      recordings[i].revision &+= 1; batch.recordings.append(recordings[i])
    }
    if let i = sessions.firstIndex(where: { $0.status == .active }) {
      let sessionPrior = prior.flatMap { $0.date >= sessions[i].started ? $0 : nil }
      sessions[i].observe(frame, previous: sessionPrior, events: events)
      if pendingGap || discontinuity { sessions[i].points[sessions[i].points.count - 1].gap = true }
      batch.sessions.append(sessions[i])
    }
    for i in followups.indices where followups[i].status == .observing {
      followups[i].observe(frame: frame, previous: prior, snapshot: snapshot)
      batch.followups.append(followups[i])
    }
    previous = frame; latest = frame; pendingGap = false; writes += 1
    if writes % 12 == 1 {
      trimLearning(now: frame.date)
      learning.revision &+= 1
      batch.state = try? JSONEncoder().encode(learning); batch.stateRevision = learning.revision
    }
    do {
      if let history, !demo {
        try await history.persistExperience(batch); lastError = nil
        storageBytes = try await history.experiencePayloadBytes()
      } else if demo {
        storageBytes += (try? JSONEncoder().encode(frame).count) ?? 0
      }
      if writes % 12 == 1 || storageBytes > maximumPayloadBytes
        || recordings.filter({ $0.status != .expired }).count > 20
      {
        try await enforceQuotas()
      }
    } catch {
      lastError = "Experience storage: \(error.localizedDescription)"
    }
    var result = summary()
    result.newAlerts = freshAlerts
    result.suppressedIncidentIDs = incidents.compactMap { event in
      let app = frame.processes.first { $0.id == event.identity }?.appKey ?? "system"
      return isSnoozed(
        profile: frame.profileID, app: app, kind: incidentKind(event), level: event.level,
        now: frame.date) ? event.id : nil
    }
    return result
  }
  private func trimLearning(now: Date) {
    for key in learning.baselines.keys {
      learning.baselines[key]?.minutes.removeAll {
        now.timeIntervalSince1970 - $0.minute > 7 * 86400
      }
    }
    if learning.baselines.count > 128 {
      for key in learning.baselines.sorted(by: { $0.value.updated > $1.value.updated }).dropFirst(
        128
      ).map(\.key) {
        learning.baselines.removeValue(forKey: key)
      }
    }
    if readings.count > 128 {
      readings = Dictionary(
        uniqueKeysWithValues: readings.sorted {
          ($0.value.last?.date ?? .distantPast) > ($1.value.last?.date ?? .distantPast)
        }.prefix(128).map { ($0.key, $0.value) })
    }
    if counters.count > 384 { counters = [:] }
    if trendResetReasons.count > 128 {
      trendResetReasons = trendResetReasons.filter { readings[$0.key] != nil }
    }
  }
  private func incidentKind(_ event: Incident) -> ExperienceEventKind {
    if let problem = event.problem {
      switch problem {
      case .highFootprint: return .footprint
      case .sustainedGrowth: return .growth
      case .systemPressure: return .pressure
      case .swapGrowth: return .swap
      case .lowDisk: return .storage
      case .unavailableMetrics, .monitoringFailure: return .metrics
      default: return .warning
      }
    }
    let reason = event.reason.lowercased()
    if reason.contains("swap") { return .swap }
    if reason.contains("pressure") { return .pressure }
    if reason.contains("storage") { return .storage }
    if reason.contains("unavailable") { return .metrics }
    if reason.contains("growth") || reason.contains("growing") { return .growth }
    return event.identity == nil ? .warning : .footprint
  }
  private func incidentEvents(_ incidents: [Incident], frame: ExperienceFrame) -> [ExperienceEvent]
  {
    incidents.map { event in
      ExperienceEvent(
        date: event.date, kind: incidentKind(event), text: event.reason,
        appKey: frame.processes.first { $0.id == event.identity }?.appKey,
        process: event.identity, level: event.level)
    }
  }
  private func isSnoozed(
    profile: UUID, app: String, kind: ExperienceEventKind, level: RiskLevel, now: Date
  ) -> Bool {
    learning.snoozes.contains {
      $0.suppresses(profile: profile, app: app, kind: kind, level: level, now: now)
    }
  }
  private static let incompleteCaptureReason =
    "The capture includes unavailable readings, sampling gaps, a changed context or bounded process omissions."
  private func triggerRecording(title: String, frame: ExperienceFrame) {
    if let i = recordings.firstIndex(where: { $0.status == .recording }) {
      let origin = recordings[i].references.first?.uptime ?? frame.uptime
      recordings[i].deadlineUptime = min(frame.uptime + 600, origin + 1800)
      recordings[i].deadline = frame.date.addingTimeInterval(
        recordings[i].deadlineUptime - frame.uptime)
      return
    }
    var recording = FlightRecording(
      title: title, trigger: frame.date,
      deadline: frame.date.addingTimeInterval(600), deadlineUptime: frame.uptime + 600,
      references: ring, events: Array(eventRing.suffix(256)),
      omittedEvents: max(0, eventRing.count - 256), demo: demo)
    if !frame.complete || frame.omittedProcesses > 0
      || ring.contains(where: { $0.complete == false })
      || eventRing.contains(where: { $0.kind == .gap })
    {
      recording.partialReason = Self.incompleteCaptureReason
    }
    recordings.insert(recording, at: 0)
  }
  private func appendEventRing(_ incoming: [ExperienceEvent], now: Date) {
    var existing = Set(eventRing.map(\.id))
    let additions = incoming.filter { existing.insert($0.id).inserted }
    let outOfOrder =
      eventRing.last.map { last in additions.contains { $0.date < last.date } } == true
      || zip(additions, additions.dropFirst()).contains { $0.date > $1.date }
    eventRing.append(contentsOf: additions)
    if outOfOrder {
      eventRing.sort {
        $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
      }
    }
    eventRing.removeAll { now.timeIntervalSince($0.date) > 600 }
    if eventRing.count > 1024 { eventRing.removeFirst(eventRing.count - 1024) }
  }
  private func saveState() async throws {
    learning.revision &+= 1
    var batch = ExperienceWrite(); batch.state = try JSONEncoder().encode(learning)
    batch.stateRevision = learning.revision
    if let history, !demo { try await history.persistExperience(batch) }
  }
  private func retainedIDs() -> [UUID] {
    ring.map(\.id) + recordings.filter { $0.status != .expired }.flatMap { $0.references.map(\.id) }
  }
  private func enforceQuotas() async throws {
    var expired: [FlightRecording] = []
    while recordings.filter({ $0.status != .expired }).count > 20 {
      guard
        let i = recordings.lastIndex(where: { $0.status != .expired && $0.status != .recording })
      else { break }
      expireRecording(at: i); expired.append(recordings[i])
    }
    if recordings.count > 40 { recordings = Array(recordings.prefix(40)) }
    if sessions.count > 100 { sessions = Array(sessions.prefix(100)) }
    if followups.count > 200 { followups = Array(followups.prefix(200)) }
    if !expired.isEmpty, let history, !demo {
      var batch = ExperienceWrite(); batch.recordings = expired
      try await history.persistExperience(batch); expired = []
    }
    try await refreshStorageSize()
    while storageBytes > maximumPayloadBytes {
      if let i = recordings.lastIndex(where: { $0.status != .expired && $0.status != .recording }) {
        expireRecording(at: i); expired.append(recordings[i])
      } else if let i = sessions.lastIndex(where: { $0.status != .active }) {
        let removed = sessions.remove(at: i)
        try await history?.removeExperienceItems(kind: "session", ids: [removed.id])
      } else if let i = followups.lastIndex(where: { $0.status != .observing }) {
        let removed = followups.remove(at: i)
        try await history?.removeExperienceItems(kind: "followup", ids: [removed.id])
      } else if let oldest = learning.baselines.min(by: { $0.value.updated < $1.value.updated })?
        .key
      {
        learning.baselines.removeValue(forKey: oldest); try await saveState()
      } else if let i = recordings.firstIndex(where: { $0.status == .recording }) {
        recordings[i].status = .partial
        recordings[i].partialReason = "The storage quota ended this capture early."
        recordings[i].references = Array(
          recordings[i].references.suffix(max(1, recordings[i].references.count / 2)))
        recordings[i].revision &+= 1; expired.append(recordings[i])
      } else if !ring.isEmpty {
        ring.removeFirst(max(1, ring.count / 4))
      } else {
        throw HistoryError.database(
          "The experience storage quota is full. Existing observations remain available.")
      }
      if !expired.isEmpty, let history, !demo {
        var batch = ExperienceWrite(); batch.recordings = expired
        try await history.persistExperience(batch); expired = []
      }
      try await refreshStorageSize()
    }
    if !expired.isEmpty, let history, !demo {
      var batch = ExperienceWrite(); batch.recordings = expired
      try await history.persistExperience(batch)
      storageBytes = try await history.experiencePayloadBytes()
    }
  }
  private func refreshStorageSize() async throws {
    if let history, !demo {
      storageBytes = try await history.pruneExperience(retaining: retainedIDs())
    } else {
      let ids = Set(retainedIDs()); memoryFrames = memoryFrames.filter { ids.contains($0.key) }
      storageBytes = memoryFrames.values.reduce(0) {
        $0 + ((try? JSONEncoder().encode($1).count) ?? 0)
      }
    }
  }
  private func expireRecording(at i: Int) {
    recordings[i].status = .expired; recordings[i].references = []; recordings[i].events = []
    recordings[i].partialReason = "Expired by the automatic count or storage quota."
    recordings[i].revision &+= 1
  }
}

extension ExperienceCoordinator {
  public func reload() async {
    resetMemory()
    if !demo { await restore() }
  }
  public func resetDemo() {
    guard demo else { return }
    resetMemory()
  }
  private func resetMemory() {
    learning = ExperienceLearningState(); previous = nil; latest = nil; ring = []; eventRing = [];
    memoryFrames = [:]
    readings = [:]; trendResetReasons = [:]; health = []; counters = [:]; alertGate = AlertGate();
    recordings = []
    sessions = []; followups = []; activeFixes = []; seenFixRevisions = [:]; fixContexts = [:]
    fixPhases = [:]; blockedUntilUptime = 0; pendingGap = false; writes = 0; storageBytes = 0
    lastError = nil; alerts = []
  }
  public func recordNow(now: Date = Date()) async throws -> UUID {
    guard history != nil || demo else {
      throw HistoryError.database(
        "History is unavailable. Restore storage before starting a recording.")
    }
    guard let frame = latest,
      abs(now.timeIntervalSince(frame.date)) <= Double(max(15, frame.interval * 3))
    else {
      throw HistoryError.database(
        "A fresh sample is needed before recording. Resume monitoring first.")
    }
    triggerRecording(title: "Manual recording", frame: frame)
    guard let i = recordings.firstIndex(where: { $0.status == .recording }) else {
      throw HistoryError.database("Cannot start recording")
    }
    recordings[i].events.append(
      ExperienceEvent(date: now, kind: .note, text: "Record now was requested."))
    recordings[i].revision &+= 1
    let recordingID = recordings[i].id
    var batch = ExperienceWrite(); batch.recordings = [recordings[i]]
    if let history, !demo { try await history.persistExperience(batch) }
    try await enforceQuotas()
    return recordingID
  }
  public func frames(recordingID: UUID) async throws -> [ExperienceFrame] {
    guard let recording = recordings.first(where: { $0.id == recordingID }) else { return [] }
    return try await frames(for: recording)
  }
  public func frames(for recording: FlightRecording) async throws -> [ExperienceFrame] {
    guard recording.demo == demo else { return [] }
    if let history, !demo {
      return try await history.experienceFrames(ids: recording.references.map(\.id))
    }
    return recording.references.compactMap { memoryFrames[$0.id] }
  }
  public func startSession(
    name: String, note: String, profile: WorkProfile,
    now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime
  ) async throws -> UUID {
    guard history != nil || demo else {
      throw HistoryError.database(
        "History is unavailable. Restore storage before starting a session.")
    }
    guard !sessions.contains(where: { $0.status == .active }) else {
      throw HistoryError.database("End the active work session first.")
    }
    let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    let value = WorkSession(
      name: title.isEmpty ? "Work session" : title, note: String(note.prefix(2000)),
      profileID: profile.id, profileName: profile.name, started: now, startedUptime: uptime,
      demo: demo)
    sessions.insert(value, at: 0)
    var batch = ExperienceWrite(); batch.sessions = [value]
    if let history, !demo { try await history.persistExperience(batch) }
    return value.id
  }
  public func endSession(now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime)
    async throws
  {
    guard let i = sessions.firstIndex(where: { $0.status == .active }) else { return }
    sessions[i].status = .completed; sessions[i].ended = now
    sessions[i].elapsedSeconds = max(sessions[i].elapsedSeconds, uptime - sessions[i].startedUptime)
    sessions[i].revision &+= 1
    let sessionID = sessions[i].id
    var batch = ExperienceWrite(); batch.sessions = [sessions[i]]
    if let history, !demo {
      try await history.persistExperience(batch)
      if let current = sessions.firstIndex(where: { $0.id == sessionID }) {
        sessions[current] = sessions[current].summary
      }
    }
    try await enforceQuotas()
  }
  public func sessionDetails(id: UUID) async throws -> WorkSession? {
    if let current = sessions.first(where: { $0.id == id }),
      current.status == .active || history == nil
    {
      return current
    }
    return try await history?.experienceValue(WorkSession.self, kind: "session", id: id)
  }
  public func snooze(
    profile: UUID, app: String, kind: ExperienceEventKind, minutes: Int, now: Date = Date()
  ) async throws {
    guard
      [.budget, .unusual, .footprint, .growth, .swap, .pressure, .metrics, .storage, .warning]
        .contains(kind),
      [15, 30, 60].contains(minutes)
    else {
      throw HistoryError.database("Choose a supported warning type and 15, 30 or 60 minutes.")
    }
    learning.snoozes.removeAll { $0.profileID == profile && $0.appKey == app && $0.kind == kind }
    learning.snoozes.append(
      ScopedSnooze(
        profileID: profile, appKey: app, kind: kind,
        until: now.addingTimeInterval(Double(minutes) * 60)))
    if learning.snoozes.count > 64 { learning.snoozes.removeFirst(learning.snoozes.count - 64) }
    try await saveState()
  }
  public func cancelSnooze(id: UUID) async throws {
    learning.snoozes.removeAll { $0.id == id }; try await saveState()
  }
  public func resetNormalRange(profile: UUID, appKey: String? = nil) async throws {
    let prefix = profile.uuidString + "|" + (appKey.map { $0 + "|version:" } ?? "")
    learning.baselines = learning.baselines.filter { !$0.key.hasPrefix(prefix) }
    for i in health.indices where appKey == nil || health[i].app.key == appKey {
      health[i].normal = NormalRange(lower: nil, upper: nil, coveredSeconds: 0)
      health[i].unusual = false
    }
    try await saveState()
  }
  public func interrupt(reason: String, now: Date = Date(), kind: ExperienceEventKind = .gap) async
  {
    pendingGap = true; previous = nil; readings = [:]; counters = [:]
    let event = ExperienceEvent(date: now, kind: kind, text: reason)
    appendEventRing([event], now: now)
    var batch = ExperienceWrite()
    for i in recordings.indices where recordings[i].status == .recording {
      recordings[i].status = .partial; recordings[i].partialReason = reason
      recordings[i].events.append(event); recordings[i].revision &+= 1;
      batch.recordings.append(recordings[i])
    }
    for i in sessions.indices where sessions[i].status == .active {
      sessions[i].events.append(event); sessions[i].revision &+= 1;
      batch.sessions.append(sessions[i])
    }
    for i in followups.indices where followups[i].status == .observing {
      followups[i].status = .partial; followups[i].issue = reason
      followups[i].revision &+= 1; batch.followups.append(followups[i])
    }
    do { if let history, !demo { try await history.persistExperience(batch) } } catch {
      lastError = error.localizedDescription
    }
  }
  public func observeFix(_ fix: FixSession) async {
    guard fix.demo == demo else { return }
    let revision = fix.revision ?? 0
    if let seen = seenFixRevisions[fix.id], revision <= seen { return }
    seenFixRevisions[fix.id] = revision
    if seenFixRevisions.count > 512 {
      let retained = Set(followups.map(\.id)).union(activeFixes).union([fix.id])
      seenFixRevisions = seenFixRevisions.filter { retained.contains($0.key) }
      fixPhases = fixPhases.filter { retained.contains($0.key) }
      fixContexts = fixContexts.filter { retained.contains($0.key) }
    }
    guard let action = fix.approvedAction, !action.isGuidance, let plan = fix.plan else { return }
    if fixContexts[fix.id] == nil {
      let target =
        plan.target?.source.identity ?? plan.source?.identity ?? plan.target?.process.identity
      let appKey = latest?.processes.first { $0.id == target }?.appKey
      let app = latest?.apps.first { $0.key == appKey }
      fixContexts[fix.id] = (
        appKey, app?.name ?? plan.target?.process.name ?? "System monitoring",
        app?.version ?? plan.target?.source.appVersion, latest?.profileID ?? WorkProfile.generalID
      )
    }
    if fix.phase.active { activeFixes.insert(fix.id) } else { activeFixes.remove(fix.id) }
    blockedUntilUptime = max(blockedUntilUptime, (latest?.uptime ?? 0) + 300)
    var batch = ExperienceWrite()
    if fixPhases[fix.id] != fix.phase, let frame = latest {
      let event = ExperienceEvent(
        date: fix.updated, kind: .fix,
        text:
          "\(action.title(target: plan.target)): \(fix.phase == .finished ? fix.result?.outcome.title ?? "Finished" : fix.phase.rawValue)",
        appKey: fixContexts[fix.id]?.0, process: plan.target?.process.identity)
      appendEventRing([event], now: fix.updated)
      if fixPhases[fix.id] == nil && (history != nil || demo) {
        triggerRecording(title: "Manual Fix", frame: frame)
      }
      fixPhases[fix.id] = fix.phase
      for i in recordings.indices where recordings[i].status == .recording {
        if !recordings[i].events.contains(where: { $0.id == event.id }) {
          recordings[i].events.append(event)
        }
        recordings[i].revision &+= 1;
        batch.recordings.append(recordings[i])
      }
      if let i = sessions.firstIndex(where: { $0.status == .active }) {
        if !sessions[i].fixIDs.contains(fix.id), sessions[i].fixIDs.count < 500 {
          sessions[i].fixIDs.append(fix.id)
        }
        sessions[i].events.append(event); sessions[i].revision &+= 1;
        batch.sessions.append(sessions[i])
      }
    }
    if fix.phase == .finished, fix.actionSentAt != nil, let result = fix.result,
      !followups.contains(where: { $0.id == fix.id }), let context = fixContexts[fix.id]
    {
      var compact = result; compact.remaining = Array(compact.remaining.prefix(8))
      var value = FollowupObservation(
        id: fix.id, profileID: context.3, appKey: context.0,
        appName: context.1, version: context.2, problem: plan.diagnosis.kind, action: action,
        before: plan.before, immediate: compact, swapThreshold: plan.swapThreshold,
        warningFraction: plan.warningFraction, growthThreshold: plan.growthThreshold,
        started: fix.updated, deadlineUptime: (latest?.uptime ?? 0) + 300, demo: demo)
      value.targetIdentity = fix.replacement ?? plan.target?.process.identity
      value.relatedIdentities = Array(
        Set((plan.target?.related ?? []) + compact.remaining.map(\.identity)).prefix(128))
      followups.insert(value, at: 0); batch.followups = [value]
    }
    do { if let history, !demo { try await history.persistExperience(batch) } } catch {
      lastError = error.localizedDescription
    }
  }
}
