import Foundation

public struct ControlSummary: Sendable {
  public var episodes: [ProblemEpisode] = []
  public var labels: [ProcessTaskLabel] = []
  public var activity: [ControlActivity] = []
  public var error: String?
  public var persistent = false
  public var rules: [AutomationRule] = []
  public var attempts: [AutomaticAttempt] = []
  public init() {}
  public var active: [ProblemEpisode] { episodes.filter { $0.resolvedAt == nil } }
  public func taskName(_ process: ProcessRecord) -> String? {
    labels.first { $0.matches(process) }?.name
      ?? rules.first {
        $0.subject == .taskInstance && $0.instance == process.identity
          && $0.owner == process.uid && $0.executable.path == process.path
      }?.label
  }
}
public struct ControlUpdate: Sendable {
  public var summary: ControlSummary
  public var notices: [EpisodeNotice]
}

/// One consumer of existing measurements. Notification reservations survive an app restart.
public actor ControlCoordinator {
  private let store: ControlStore?
  public nonisolated let demo: Bool
  private var state = ControlState()
  private var restored = false
  private var available = false
  private var error: String?
  private var checkpoint: Date = .distantPast
  private var fixRevisions: [UUID: (UInt64, FixPhase)] = [:]
  public init(store: ControlStore?, demo: Bool = false) { self.store = store; self.demo = demo }
  public func restore() async {
    guard !restored else { return }
    restored = true
    if demo { available = true; return }
    do {
      guard let store else { throw HistoryError.database("Control history is unavailable.") }
      state = try await store.load()
      // Fresh evidence is required; notices and acknowledgement remain reserved across restart.
      state.problems.previous = nil
      available = true; error = nil
      var interrupted = false
      for i in state.attempts.indices where state.attempts[i].active {
        interrupted = true; state.attempts[i].status = .interrupted; state.attempts[i].failed = true
        state.attempts[i].message =
          "The previous run ended with an uncertain outcome. This action will not be replayed."
        markAttemptFailure(state.attempts[i])
      }
      if interrupted { _ = await persist(durable: true) }
    } catch {
      self.error =
        "Control history: \(error.localizedDescription) The source is preserved; external automation is unavailable."
    }
  }
  public func summary() -> ControlSummary {
    var value = ControlSummary()
    value.episodes = state.problems.episodes; value.labels = state.labels
    value.activity = state.activity; value.error = error; value.persistent = available && !demo
    value.rules = state.rules; value.attempts = state.attempts
    return value
  }
  public func ingest(
    snapshot: Snapshot, settings: Settings, experience: ExperienceSummary,
    uptime: Double, deliveryAllowed: Bool
  ) async -> ControlUpdate {
    guard snapshot.demo == demo else { return ControlUpdate(summary: summary(), notices: []) }
    if !restored { await restore() }
    let before = Dictionary(
      state.problems.episodes.map { ($0.id, ($0.status, $0.level)) },
      uniquingKeysWith: { a, _ in a })
    var signals = ProblemSignals.build(
      snapshot: snapshot, settings: settings, experience: experience)
    for rule in state.rules
    where rule.enabled && rule.reviewReason == nil
      && rule.trigger == .taskFootprint && rule.profileID == settings.activeProfile.id
      && rule.configuration == settings.analysisSignature
    {
      if let process = snapshot.processes.first(where: { $0.identity == rule.instance }),
        process.uid == rule.owner, process.path == rule.executable.path,
        let footprint = process.footprint, footprint >= (rule.footprintLimit ?? .infinity)
      {
        signals.append(
          ProblemSignal(
            key: "automation-rule:\(rule.id):\(rule.revision)",
            label: rule.label, kind: .highFootprint, level: .warning,
            evidence:
              "Registered task footprint \(Format.bytes(footprint)); explicit stop threshold \(Format.bytes(rule.footprintLimit)). Advisory budgets remain separate.",
            identities: [process.identity],
            correlatedTo: signals.contains(where: { $0.key == "system:memory" })
              ? "system:memory" : nil))
      }
    }
    if let attempt = state.attempts.first(where: \.active),
      let rule = state.rules.first(where: { $0.id == attempt.ruleID }),
      let i = signals.firstIndex(where: { $0.key == "system:memory" })
    {
      signals[i].evidence +=
        " An authorized \(rule.operation.title.lowercased()) attempt is \(attempt.status.rawValue)."
      if signals[i].humanReason != nil {
        signals[i].humanReason =
          "An authorized automatic step is in progress. Save work and review Activity; system recovery has not yet been established."
      }
    }
    var notices = state.problems.ingest(
      signals, date: snapshot.date, uptime: uptime,
      interval: settings.interval, complete: !snapshot.hasUnavailableMemoryReadings,
      unreadable: Set(snapshot.unreadablePIDs ?? []), preferences: settings.controls,
      deliveryAllowed: deliveryAllowed && !demo)
    var transition = false
    for episode in state.problems.episodes {
      let previous = before[episode.id]
      if previous?.0 != episode.status || previous?.1 != episode.level {
        transition = true
        state.append(
          ControlActivity(
            date: snapshot.date, kind: .observation,
            title: "\(episode.label) · \(episode.status.title)", detail: episode.evidence,
            episodeID: episode.id))
        if episode.resolvedAt == nil, !notices.contains(where: { $0.episodeID == episode.id }),
          let reason = episode.noticeDecision
        {
          state.append(
            ControlActivity(
              date: snapshot.date, kind: .suppressed,
              title: "No new native alert", detail: reason, episodeID: episode.id))
        }
      }
    }
    for notice in notices {
      state.append(
        ControlActivity(
          date: snapshot.date, kind: .notification,
          title: "Notification reserved · \(notice.kind.rawValue)", detail: notice.body,
          episodeID: notice.episodeID))
    }
    if transition || !notices.isEmpty || snapshot.date.timeIntervalSince(checkpoint) >= 60 {
      let saved = await persist(at: snapshot.date)
      if !saved { notices.removeAll { $0.kind == .warning } }
    }
    return ControlUpdate(summary: summary(), notices: notices)
  }
  public func reviewing(_ id: UUID, value: Bool) async {
    state.problems.reviewing(id, value: value)
    state.append(
      ControlActivity(
        kind: .observation,
        title: value ? "Reviewing this issue" : "Review acknowledgement cleared",
        detail: "Acknowledgement affects reminders; it does not establish recovery.", episodeID: id)
    )
    _ = await persist()
  }
  public func name(_ process: ProcessRecord, value: String) async {
    state.name(process, value: value)
    state.append(
      ControlActivity(
        kind: .observation, title: "Task label updated",
        detail:
          "This name applies only to the same PID, start time, owner and executable. It grants no process action."
      ))
    _ = await persist()
  }
  public func deliveryFailed(_ notice: EpisodeNotice, message: String) async {
    state.problems.deliveryFailed(notice, message: message)
    state.append(
      ControlActivity(
        kind: .notification, title: "Native delivery failed",
        detail: message, episodeID: notice.episodeID))
    _ = await persist()
  }
  public func cancelReservation(_ notice: EpisodeNotice) async {
    state.problems.cancelReservation(notice)
    state.append(
      ControlActivity(
        kind: .suppressed, title: "Native request not submitted",
        detail: "The mode or notification preference changed before submission.",
        episodeID: notice.episodeID))
    _ = await persist()
  }
  public func resetDemo() {
    guard demo else { return }
    state = ControlState(); fixRevisions = [:]; error = nil; available = true; restored = true
  }
  public func observeFix(_ fix: FixSession) async {
    guard fix.demo == demo else { return }
    let revision = fix.revision ?? 0, previous = fixRevisions[fix.id]
    if let previous, previous.0 >= revision { return }
    fixRevisions[fix.id] = (revision, fix.phase)
    if fixRevisions.count > 512 {
      let retained = Set(state.problems.episodes.flatMap(\.fixSessionIDs) + [fix.id])
      fixRevisions = fixRevisions.filter { retained.contains($0.key) }
    }
    guard previous?.1 != fix.phase else { return }
    let authority = fix.authority ?? .manual
    if authority == .policy, let policy = fix.plan?.automation,
      let i = state.attempts.firstIndex(where: {
        $0.ruleID == policy.rule.id && $0.episodeID == policy.permit.episodeID
          && ($0.fixSessionID == nil || $0.fixSessionID == fix.id)
      })
    {
      state.attempts[i].fixSessionID = fix.id; state.attempts[i].message = fix.message
      if let replacement = fix.replacement, policy.rule.subject == .taskInstance,
        var record = fix.plan?.target?.process
      {
        record.identity = replacement
        state.name(record, value: policy.rule.label)
      }
      switch fix.phase {
      case .verifying: state.attempts[i].status = .verifying
      case .finished:
        state.attempts[i].status = .finished
        state.attempts[i].failed =
          fix.result?.actionSucceeded != true || fix.result?.targetResolved != true
        if state.attempts[i].failed { markAttemptFailure(state.attempts[i]) }
        if let e = state.problems.episodes.firstIndex(where: { $0.id == policy.permit.episodeID }) {
          state.problems.episodes[e].automaticAttemptID = nil
          if !state.attempts[i].failed {
            state.problems.episodes[e].status = .observing
          }
        }
      default: state.attempts[i].status = .executing
      }
    }
    let kind: ControlActivity.Kind =
      authority == .manual ? .manual : authority == .selfRepair ? .selfRepair : .automatic
    var episodeID = fix.origin.episodeID
    if episodeID == nil {
      let ids = [fix.plan?.target?.process.identity, fix.plan?.source?.identity].compactMap { $0 }
      episodeID =
        state.problems.active.first { ep in ep.identities.contains { ids.contains($0) } }?.id
    }
    if let episodeID, let i = state.problems.episodes.firstIndex(where: { $0.id == episodeID }) {
      if !state.problems.episodes[i].fixSessionIDs.contains(fix.id) {
        state.problems.episodes[i].fixSessionIDs.append(fix.id)
        state.problems.episodes[i].fixSessionIDs = Array(
          state.problems.episodes[i].fixSessionIDs.suffix(32))
      }
    }
    state.append(
      ControlActivity(
        date: fix.updated, kind: kind,
        title: "\(authority.title) · \(fix.phase.rawValue)", detail: fix.message,
        episodeID: episodeID, fixSessionID: fix.id))
    _ = await persist(durable: authority == .policy)
  }
  public func register(_ rule: AutomationRule) async throws {
    guard !demo, available, error == nil, state.rules.count < 64 else {
      throw FixError.unavailable("A writable local audit and fewer than 64 rules are required.")
    }
    if let issue = rule.configurationError { throw FixError.refused(issue) }
    guard !state.rules.contains(where: { $0.id == rule.id }) else {
      throw FixError.refused("This rule already exists.")
    }
    state.rules.append(rule)
    state.append(
      ControlActivity(
        kind: .permission, title: "Automatic permission registered",
        detail:
          "\(rule.label) · \(rule.operation.title). Exact executable, owner, profile and trigger; no Force Quit."
      ))
    guard await persist(durable: true) else {
      state.rules.removeAll { $0.id == rule.id }
      throw FixError.unavailable("The permission could not be saved durably and was not armed.")
    }
  }
  public func revoke(_ id: UUID) async {
    guard let i = state.rules.firstIndex(where: { $0.id == id }) else { return }
    state.rules[i].enabled = false; state.rules[i].revision &+= 1
    state.rules[i].reviewReason = "Revoked by you. Register a new exact permission to resume."
    state.append(
      ControlActivity(kind: .permission, title: "Permission revoked", detail: state.rules[i].label))
    _ = await persist(durable: true)
  }
  public func requireReview(_ rule: AutomationRule, reason: String) async {
    guard
      let i = state.rules.firstIndex(where: { $0.id == rule.id && $0.revision == rule.revision }),
      state.rules[i].reviewReason == nil
    else { return }
    state.rules[i].reviewReason = String(reason.prefix(600)); state.rules[i].revision &+= 1
    state.append(
      ControlActivity(kind: .permission, title: "Permission needs review", detail: reason))
    _ = await persist(durable: true)
  }
  public func review(_ id: UUID, now: Date = Date()) async throws {
    guard let i = state.rules.firstIndex(where: { $0.id == id }), state.rules[i].enabled else {
      throw FixError.refused("A revoked permission cannot be silently re-enabled.")
    }
    state.rules[i].reviewedAt = now; state.rules[i].reviewReason = nil;
    state.rules[i].revision &+= 1
    state.append(
      ControlActivity(kind: .permission, title: "Permission reviewed", detail: state.rules[i].label)
    )
    guard await persist(durable: true) else {
      throw FixError.unavailable("The review could not be saved.")
    }
  }
  public func reserve(
    rule: AutomationRule, episode: ProblemEpisode, snapshot: Snapshot,
    settings: Settings, executable: ExecutableIdentity, currentUser: UInt32,
    warmupSeconds: Double, manualBusy: Bool, readiness: ApplicationReadiness? = nil,
    now: Date = Date()
  ) async throws -> AutomaticAttempt {
    guard !demo, available, error == nil, state.rules.contains(rule),
      state.problems.active.contains(where: { $0.id == episode.id }),
      state.problems.active.first(where: { $0.id == episode.id })?.automaticAttemptID == nil
    else {
      throw FixError.unavailable("The current permission, episode or durable audit is unavailable.")
    }
    if let reason = AutomationEligibility.reason(
      rule: rule, episode: episode, snapshot: snapshot,
      settings: settings, journal: state.attempts, executable: executable, currentUser: currentUser,
      now: now, warmupSeconds: warmupSeconds, manualBusy: manualBusy,
      readiness: readiness, nonce: readiness?.nonce)
    {
      throw FixError.refused(reason)
    }
    let attempt = AutomaticAttempt(rule: rule, episodeID: episode.id, now: now)
    state.attempts.insert(attempt, at: 0)
    if state.attempts.count > 256 { state.attempts = Array(state.attempts.prefix(256)) }
    if let i = state.problems.episodes.firstIndex(where: { $0.id == episode.id }) {
      state.problems.episodes[i].automaticAttemptID = attempt.id
      state.problems.episodes[i].status = .automaticAction
    }
    state.append(
      ControlActivity(
        kind: .automatic, title: "Automatic attempt reserved",
        detail:
          "\(rule.label) · \(rule.operation.title). Durable reservation precedes the one-use permit.",
        episodeID: episode.id))
    guard await persist(durable: true) else {
      await abandon(
        attempt.id, message: "Durable reservation failed. No external request was authorized.")
      throw FixError.unavailable("The automatic reservation could not be saved durably.")
    }
    return attempt
  }
  public func abandon(_ id: UUID, message: String) async {
    guard let i = state.attempts.firstIndex(where: { $0.id == id && $0.active }) else { return }
    state.attempts[i].status = .interrupted; state.attempts[i].failed = true
    state.attempts[i].message = message; markAttemptFailure(state.attempts[i])
    state.append(
      ControlActivity(
        kind: .automatic, title: "Automatic attempt stopped", detail: message,
        episodeID: state.attempts[i].episodeID))
    _ = await persist(durable: true)
  }
  private func markAttemptFailure(_ attempt: AutomaticAttempt) {
    if let e = state.problems.episodes.firstIndex(where: { $0.id == attempt.episodeID }) {
      state.problems.episodes[e].automaticAttemptID = nil
      state.problems.episodes[e].automaticFailure = attempt.message
      state.problems.episodes[e].humanReason = attempt.message
      state.problems.episodes[e].status = .actionRequired
    }
    if let r = state.rules.firstIndex(where: { $0.id == attempt.ruleID }),
      state.attempts.filter({
        $0.ruleID == attempt.ruleID && $0.failed
          && $0.created >= (state.rules[r].reviewedAt ?? state.rules[r].created)
      }).count >= 2
    {
      state.rules[r].reviewReason =
        "Two automatic attempts failed. Review this permission before resuming."
    }
  }
  public func clearHistory() async {
    state.problems = ProblemEpisodes(); state.activity = []
    _ = await persist()
  }
  @discardableResult private func persist(at date: Date = Date(), durable: Bool = false) async
    -> Bool
  {
    if demo { return true }
    guard available, let store else { return false }
    state.revision &+= 1
    let copy = state
    do {
      try await store.save(copy, durable: durable)
      checkpoint = date; error = nil; return true
    } catch {
      if state.revision == copy.revision {
        self.error =
          "Control history: \(error.localizedDescription) Automatic external actions require a durable audit."
      }
      return false
    }
  }
}
