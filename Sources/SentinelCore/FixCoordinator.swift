import Foundation

public actor FixCoordinator {
  public typealias Save = @Sendable (FixSession) async throws -> Void
  public typealias Publish = @Sendable (FixSession) async -> Void
  private let runtime: any FixRuntime
  private let gate: InterventionGate
  private let automationGate: AutomationGate?
  private let save: Save
  private let publish: Publish
  private var session: FixSession?
  private var revision: UInt64 = 0
  private var deadline: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var awaitingExit = false
  private var receiptReady = false
  private var verificationStarted: Date?
  private var lastSample: Date?
  private var comparable: [Snapshot] = []
  private let approvalSeconds: Double
  private let exitSeconds: Double
  private let verificationSeconds: Double
  public init(
    runtime: any FixRuntime, gate: InterventionGate, exitSeconds: Double = 45,
    verificationSeconds: Double = 120, approvalSeconds: Double = 120, save: @escaping Save,
    publish: @escaping Publish, automationGate: AutomationGate? = nil
  ) {
    self.runtime = runtime; self.gate = gate; self.automationGate = automationGate;
    self.exitSeconds = exitSeconds;
    self.approvalSeconds = min(120, max(0.001, approvalSeconds))
    self.verificationSeconds = min(120, verificationSeconds); self.save = save;
    self.publish = publish
  }
  public func current() -> FixSession? { session }
  private func resolve(
    process: ProcessRecord, in snapshot: Snapshot, origin: FixOrigin, token: InterventionToken
  ) async throws -> FixTarget {
    if origin.individualProcess == true {
      guard let fresh = snapshot.processes.first(where: { $0.identity == process.identity }),
        fresh.path == process.path, fresh.uid == process.uid
      else { throw FixError.invalidated("The manually selected individual process changed.") }
      let target = FixTarget(process: fresh, source: fresh)
      try await runtime.validate(target: target, token: token)
      return target
    }
    return try await runtime.resolve(process: process, in: snapshot)
  }

  public func prepare(origin requestedOrigin: FixOrigin, settings: Settings) async {
    if let session, [FixPhase.assessing, .executing, .verifying].contains(session.phase) { return }
    if session?.phase == .awaitingApproval {
      await cancel(message: "Replaced by a newly selected target.")
    }
    let token = gate.current()
    var origin = requestedOrigin
    if let source = origin.demoSource, source != token.demo { return }
    origin.demoSource = token.demo
    let value = FixSession(origin: origin, demo: token.demo)
    session = value; comparable = []; lastSample = nil; receiptReady = false; awaitingExit = false
    do {
      try await record()
      let fresh = try await runtime.freshSnapshot()
      guard session?.id == value.id, session?.phase == .assessing else { return }
      guard gate.current() == token, fresh.demo == token.demo,
        abs(fresh.date.timeIntervalSinceNow) < 10
      else { throw FixError.invalidated("The monitoring mode or sample changed. Assess again.") }
      var target: FixTarget?; var explanation = ""
      if let id = origin.identity, let p = fresh.processes.first(where: { $0.identity == id }) {
        do { target = try await resolve(process: p, in: fresh, origin: origin, token: token) } catch
        {
          explanation = error.localizedDescription
        }
      }
      guard session?.id == value.id, session?.phase == .assessing, gate.current() == token else {
        return
      }
      session?.plan = FixDiagnosis.plan(
        snapshot: fresh, settings: settings, origin: origin, target: target, token: token,
        explanation: explanation)
      session?.plan?.expires = Date().addingTimeInterval(approvalSeconds)
      session?.phase = .awaitingApproval
      session?.message =
        "Review the fresh evidence and choose one concrete action. Nothing has been stopped."
      try await record()
    } catch {
      guard session?.id == value.id, session?.phase == .assessing else { return }
      await finish(
        .needsAction, message: error.localizedDescription,
        next: "Refresh the diagnosis or review Activity Monitor.")
    }
  }
  public func approve(
    sessionID: UUID, planID: UUID, action: FixAction, forceConfirmed: Bool = false
  ) async {
    guard session?.authority == nil || session?.authority == .manual else { return }
    await execute(
      sessionID: sessionID, planID: planID, action: action,
      forceConfirmed: forceConfirmed)
  }
  /// A policy grant has its own entry point and one-use permit; it never calls manual approval.
  @discardableResult public func executeAutomatic(
    rule: AutomationRule, permit: AutomationPermit, target: FixTarget,
    snapshot: Snapshot, settings: Settings
  ) async throws -> UUID {
    guard session?.phase.active != true, let automationGate,
      gate.current() == permit.token, !permit.token.demo,
      target.id == permit.target, rule.id == permit.ruleID,
      rule.revision == permit.ruleRevision, rule.operation == permit.operation,
      rule.configurationError == nil
    else { throw FixError.busy }
    let origin = FixOrigin(
      identity: target.id, individualProcess: target.application == nil,
      demoSource: false, episodeID: permit.episodeID)
    var plan = FixDiagnosis.plan(
      snapshot: snapshot, settings: settings,
      origin: origin, target: target, token: permit.token)
    plan.automation = AutomationExecution(rule: rule, permit: permit)
    guard plan.automation?.currentlyRelevant(snapshot) == true else {
      throw FixError.invalidated("The approved automatic trigger no longer has fresh evidence.")
    }
    plan.actions = [rule.operation.action]; plan.expires = permit.expires
    if rule.trigger == .taskFootprint {
      plan.diagnosis = ProblemDiagnosis(
        kind: .highFootprint, severity: .warning,
        identity: target.id, summary: "The separately approved task stop threshold is sustained.",
        evidence: ["explicitStopBytes": rule.footprintLimit ?? 0],
        certainty: "Explicit automation threshold; advisory budgets grant no action.")
      plan.warningFraction = (rule.footprintLimit ?? .infinity) / max(1, snapshot.system.total ?? 1)
    } else {
      plan.diagnosis = ProblemDiagnosis(
        kind: .selectedContributor, severity: snapshot.risk,
        identity: target.id, summary: "Registered target under measured system pressure.",
        evidence: [:], certainty: "The permission selects this target; causation is not inferred.")
    }
    var value = FixSession(origin: origin, demo: false)
    value.authority = .policy; value.plan = plan; value.phase = .awaitingApproval
    try automationGate.claim(permit, sessionID: value.id, planID: plan.id)
    session = value; comparable = []; lastSample = nil; receiptReady = false; awaitingExit = false
    await execute(
      sessionID: value.id, planID: plan.id, action: rule.operation.action,
      forceConfirmed: false)
    return value.id
  }
  /// Restricted to the app's own monitor. No process action is accepted by this API.
  @discardableResult public func repairMonitoring(snapshot: Snapshot, settings: Settings)
    async throws -> UUID
  {
    guard session?.phase.active != true, !snapshot.demo, !gate.current().demo else {
      throw FixError.busy
    }
    let origin = FixOrigin(issue: .monitoringFailure, demoSource: false)
    var plan = FixDiagnosis.plan(
      snapshot: snapshot, settings: settings, origin: origin,
      target: nil, token: gate.current())
    plan.actions = [.restartMonitoring]
    var value = FixSession(origin: origin, demo: false)
    value.authority = .selfRepair; value.plan = plan; value.phase = .awaitingApproval
    session = value; comparable = []; lastSample = nil; receiptReady = false; awaitingExit = false
    await execute(
      sessionID: value.id, planID: plan.id, action: .restartMonitoring, forceConfirmed: false,
      repairSample: snapshot)
    return value.id
  }
  private func execute(
    sessionID: UUID, planID: UUID, action: FixAction, forceConfirmed: Bool,
    repairSample: Snapshot? = nil
  ) async {
    guard var current = session, current.id == sessionID, current.phase == .awaitingApproval,
      let plan = current.plan, plan.id == planID, plan.actions.contains(action)
    else { return }
    guard action != .forceQuit || forceConfirmed else { return }
    // Claim before the first suspension: a second click cannot approve the same session twice.
    current.phase = .executing; current.approvedAction = action; current.approvedAt = Date();
    current.forceConfirmed = forceConfirmed
    current.message = "Rechecking target identity and current conditions…"; session = current
    do {
      guard Date() <= plan.expires, gate.current() == plan.token else {
        throw FixError.invalidated(
          "This plan expired or the monitoring context changed. Assess again.")
      }
      try await record()
      let fresh: Snapshot
      if current.authority == .selfRepair, action == .restartMonitoring, let repairSample {
        fresh = repairSample
      } else {
        fresh = try await runtime.freshSnapshot()
      }
      guard stillExecuting(current.id), gate.current() == plan.token, fresh.demo == plan.token.demo
      else { throw FixError.invalidated("Execution was cancelled or the mode changed.") }
      if action.isProcessAction {
        guard let target = plan.target, FixDiagnosis.isStillRelevant(plan, snapshot: fresh) else {
          throw FixError.invalidated(
            "The original warning or process changed. No action was sent; assess again.")
        }
        let resolved = try await resolve(
          process: target.source, in: fresh, origin: plan.origin, token: plan.token)
        guard resolved.process.identity == target.process.identity,
          resolved.process.path == target.process.path, resolved.process.uid == target.process.uid,
          resolved.application == target.application
        else {
          throw FixError.invalidated(
            "Application identity or relationship changed. No action was sent.")
        }
        try await runtime.validate(target: target, token: plan.token)
      }
      guard stillExecuting(current.id), gate.current() == plan.token else {
        throw FixError.invalidated("Execution was cancelled.")
      }
      // Rebase measurements immediately before the approved effect, not on an old alert.
      session?.plan?.before = FixMeasurement(snapshot: fresh, target: plan.target?.process.identity)
      session?.message =
        action.isProcessAction
        ? "Approved request is being sent. It cannot be undone once sent."
        : "Performing the approved action…"
      try await record()
      guard stillExecuting(current.id), gate.current() == plan.token else { return }
      armDeadline(seconds: exitSeconds, id: current.id, verification: false)
      operation = Task { [weak self] in
        do {
          try await self?.runtime.perform(
            action: action, target: plan.target, token: plan.token, forceConfirmed: forceConfirmed,
            plan: plan);
          await self?.didPerform(id: current.id, action: action)
        } catch { await self?.didFail(id: current.id, error: error.localizedDescription) }
      }
    } catch {
      guard stillExecuting(current.id) else { return }
      await finish(
        .needsAction, message: error.localizedDescription,
        next: "Create a fresh plan. A rejected request never escalates automatically.")
    }
  }
  private func stillExecuting(_ id: UUID) -> Bool {
    session?.id == id && session?.phase == .executing
  }
  private func didFail(id: UUID, error: String) async {
    guard stillExecuting(id) else { return }
    await finish(
      .needsAction, message: error,
      next: "Save work and review the target. Force Quit requires a new explicit confirmation.",
      actionSucceeded: false)
  }
  private func didPerform(id: UUID, action: FixAction) async {
    guard stillExecuting(id) else { return }
    session?.actionSentAt = Date()
    receiptReady = true
    if action.isGuidance {
      await finish(
        .needsAction,
        message: session?.demo == true
          ? "Simulation: opening the tool was simulated. No native application was opened."
          : "The requested tool was opened. This does not establish that the problem is fixed.",
        next: "Complete the indicated step, then assess fresh measurements again.",
        actionSucceeded: true)
    } else if action.isProcessAction {
      awaitingExit = true;
      session?.message =
        "Waiting for the original process to exit. A save prompt or refusal may keep it running."
      try? await record()
    } else {
      await beginVerification(id: id)
    }
  }
  public func observe(_ s: Snapshot) async {
    guard !Task.isCancelled else { return }
    guard let current = session, current.phase == .executing || current.phase == .verifying,
      let plan = current.plan
    else { return }
    guard gate.current() == plan.token, s.demo == current.demo else {
      await cancel(message: "Monitoring mode changed; remaining steps were cancelled."); return
    }
    guard abs(s.date.timeIntervalSinceNow) < 10, lastSample.map({ s.date > $0 }) ?? true else {
      return
    }
    lastSample = s.date
    if current.phase == .executing, receiptReady, awaitingExit, let target = plan.target {
      guard s.processesAvailable == true || s.demo,
        !(s.unreadablePIDs?.contains(target.process.identity.pid) ?? false)
      else { return }
      if !s.processes.contains(where: { $0.identity == target.process.identity }) {
        awaitingExit = false
        if current.approvedAction == .restartApplication
          || current.approvedAction == .restartManagedTask
        {
          session?.message = "The old instance exited. Revalidating the bundle before reopening…"
          try? await record()
          guard stillExecuting(current.id), gate.current() == plan.token else { return }
          operation = Task { [weak self] in
            do {
              let identity: ProcessIdentity?
              if plan.automation != nil {
                identity = try await self?.runtime.relaunchAutomatic(plan: plan)
              } else {
                identity = try await self?.runtime.relaunch(target: target, token: plan.token)
              }
              await self?.didRelaunch(id: current.id, identity: identity)
            } catch { await self?.didFail(id: current.id, error: error.localizedDescription) }
          }
        } else {
          await beginVerification(id: current.id)
        }
      }
      return
    }
    guard current.phase == .verifying, let started = verificationStarted, s.date > started else {
      return
    }
    session?.samples += 1
    if comparable.count >= 3 { comparable.removeFirst() }; comparable.append(s)
    let sampleCount = session?.samples ?? 0
    session?.message =
      "Checking fresh measurements: \(sampleCount) samples. Up to 120 seconds; missing readings cannot prove recovery."
    if comparable.count == 3,
      let result = assessment(plan: plan, session: session!, samples: comparable)
    {
      await complete(result)
    } else {
      try? await record()
    }
  }
  private func didRelaunch(id: UUID, identity: ProcessIdentity?) async {
    guard stillExecuting(id), let identity else { return }
    session?.replacement = identity; await beginVerification(id: id)
  }
  private func beginVerification(id: UUID) async {
    guard stillExecuting(id) else { return }
    session?.phase = .verifying;
    session?.message = "Action completed. Waiting for at least three fresh comparable samples…"
    verificationStarted = Date(); comparable = []; lastSample = nil
    armDeadline(seconds: verificationSeconds, id: id, verification: true)
    try? await record()
  }
  private func armDeadline(seconds: Double, id: UUID, verification: Bool) {
    deadline?.cancel()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      await self?.timedOut(id: id, verification: verification)
    }
  }
  private func timedOut(id: UUID, verification: Bool) async {
    guard session?.id == id,
      session?.phase == (verification ? FixPhase.verifying : .executing)
    else { return }
    if verification {
      await finish(
        .unverifiable,
        message: "The verification deadline elapsed without three comparable readings.",
        next: "Keep monitoring; missing data is not recovery.", actionSucceeded: true)
    } else {
      await finish(
        .needsAction,
        message:
          "The request was declined or did not finish within the allowed time. No Force Quit was sent.",
        next:
          "Check for an unsaved-work dialog. You may create a new plan and explicitly choose Force Quit.",
        actionSucceeded: false)
    }
  }
  private func assessment(plan: FixPlan, session: FixSession, samples: [Snapshot]) -> FixResult? {
    guard let last = samples.last else { return nil }
    guard
      samples.allSatisfy({
        $0.system.total != nil && $0.system.used != nil && $0.system.available != nil
          && $0.system.swap != nil && $0.system.pressure != .unavailable
          && ($0.processesAvailable == true || $0.demo)
      })
    else { return nil }
    if plan.findings.contains(where: { $0.kind == .swapGrowth })
      && samples.contains(where: { $0.swapGrowth == nil })
    {
      return nil
    }
    var requiredPIDs = Set(plan.target?.related.map(\.pid) ?? [])
    if let target = plan.target {
      requiredPIDs.insert(target.process.identity.pid)
      requiredPIDs.insert(target.source.identity.pid)
    }
    if let identity = plan.origin.identity { requiredPIDs.insert(identity.pid) }
    if let replacement = session.replacement { requiredPIDs.insert(replacement.pid) }
    guard samples.allSatisfy({ Set($0.unreadablePIDs ?? []).isDisjoint(with: requiredPIDs) }) else {
      return nil
    }
    let systemHealthy = samples.allSatisfy {
      $0.system.pressure == .normal && $0.risk < .warning
        && ($0.system.available ?? 0) > ($0.system.total ?? .infinity) * 0.08
        && (!plan.findings.contains(where: { $0.kind == .swapGrowth })
          || ($0.swapGrowth ?? .infinity) <= plan.swapThreshold)
        && (!plan.findings.contains(where: { $0.kind == .lowDisk })
          || ($0.system.diskFree ?? 0) >= 5 * GiB)
    }
    let before = plan.before
    let systemImproved: Bool?
    if let total = before.system.total, total > 0,
      before.system.used != nil, let available = before.system.available,
      before.system.swap != nil, before.system.pressure != .unavailable,
      samples.allSatisfy({ $0.system.total == total })
    {
      // A healthy current state does not establish a change from the baseline.
      // Compare actual readings, and never let a free-memory gain hide worse pressure.
      let notWorse = samples.allSatisfy {
        pressureRank($0.system.pressure) <= pressureRank(before.system.pressure)
          && $0.risk <= before.risk
      }
      let pressureImproved = samples.allSatisfy {
        pressureRank($0.system.pressure) < pressureRank(before.system.pressure)
      }
      let riskImproved = samples.allSatisfy { $0.risk < before.risk }
      let availableImproved = samples.allSatisfy {
        ($0.system.available ?? 0) > available + 256 * MiB
      }
      let swapRateImproved =
        before.swapGrowth.map { rate in
          rate > plan.swapThreshold
            && samples.allSatisfy { ($0.swapGrowth ?? .infinity) <= plan.swapThreshold }
        } ?? false
      systemImproved =
        notWorse && (pressureImproved || riskImproved || availableImproved || swapRateImproved)
    } else {
      systemImproved = nil
    }
    var targetResolved: Bool?
    var related = Set(plan.target?.related ?? [])
    if let target = plan.target, target.source.identity != target.process.identity {
      related.insert(target.source.identity)
    }
    func workers(in sample: Snapshot) -> [ProcessRecord] {
      guard let target = plan.target else { return [] }
      return sample.processes.filter { process in
        guard process.identity != target.process.identity, process.identity != session.replacement
        else { return false }
        if related.contains(process.identity) { return true }
        guard process.uid == target.process.uid else { return false }
        if let app = target.application,
          URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path.hasPrefix(
            app.bundlePath + "/")
        {
          return true
        }
        return process.ppid == target.process.identity.pid
          || session.replacement.map { process.ppid == $0.pid } == true
      }
    }
    func riskyWorker(_ process: ProcessRecord, in sample: Snapshot) -> Bool {
      (process.footprint ?? 0) >= (sample.system.total ?? .infinity) * plan.warningFraction
        || (process.growth ?? 0) > plan.growthThreshold || process.risk >= .elevated
    }
    let remaining = Array(
      workers(in: last).sorted { left, right in
        let leftIsSource = left.identity == plan.target?.source.identity
        let rightIsSource = right.identity == plan.target?.source.identity
        if leftIsSource != rightIsSource { return leftIsSource }
        return (left.footprint ?? 0) > (right.footprint ?? 0)
      }.prefix(32))
    guard
      samples.allSatisfy({
        workers(in: $0).allSatisfy {
          $0.footprint != nil && (plan.diagnosis.kind != .sustainedGrowth || $0.growth != nil)
        }
      })
    else {
      return nil
    }
    if session.approvedAction == .restartMonitoring {
      guard samples.allSatisfy({ !$0.hasUnavailableMemoryReadings }) else { return nil }
      targetResolved = true
    } else if let target = plan.target {
      if let replacement = session.replacement {
        let replacements = samples.compactMap { sample in
          sample.processes.first { $0.identity == replacement }
        }
        guard replacements.count == 3,
          replacements.allSatisfy({ process in
            process.footprint != nil && process.uid == target.process.uid
              && process.bundleID == target.process.bundleID
              && URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: target.process.path).resolvingSymlinksInPath().path
          })
        else {
          return nil
        }
        if plan.diagnosis.kind == .sustainedGrowth
          && replacements.contains(where: { $0.growth == nil })
        {
          return nil
        }
        let workersRecovered = samples.allSatisfy { sample in
          !workers(in: sample).contains {
            $0.identity == target.source.identity || riskyWorker($0, in: sample)
          }
        }
        targetResolved =
          workersRecovered
          && replacements.allSatisfy { p in
            (p.footprint ?? .infinity) < (last.system.total ?? 0) * plan.warningFraction
              && (p.growth ?? 0) <= plan.growthThreshold
          }
      } else {
        let originalGone = samples.allSatisfy { sample in
          !sample.processes.contains { $0.identity == target.process.identity }
        }
        let workersRecovered = samples.allSatisfy { sample in
          !workers(in: sample).contains {
            $0.identity == target.source.identity || riskyWorker($0, in: sample)
          }
        }
        targetResolved = originalGone && workersRecovered
      }
    }
    let outcome: FixOutcome
    if targetResolved == true {
      outcome = systemHealthy ? .solved : .improved
    } else {
      outcome = systemImproved == true ? .improved : .unresolved
    }
    return FixResult(
      outcome: outcome, actionSucceeded: true, targetResolved: targetResolved,
      systemImproved: systemImproved,
      after: FixMeasurement(
        snapshot: last, target: session.replacement ?? plan.target?.process.identity),
      samples: session.samples, remaining: remaining,
      message: targetResolved == true
        ? "The selected target recovered. System recovery is reported separately; footprint accounting is not unique physical RAM."
        : "The action completed, but the selected problem or related workers remain.",
      nextStep: systemHealthy && targetResolved == true
        ? "Continue normal monitoring."
        : "Review remaining workers and other large consumers. A new action needs a new approval.")
  }
  private func pressureRank(_ value: Pressure) -> Int {
    switch value {
    case .normal: 0;
    case .warning: 1;
    case .critical: 2;
    case .unavailable: 3
    }
  }
  public func cancel(message: String = "Cancelled by you. A request already sent cannot be undone.")
    async
  {
    guard session?.phase.active == true else { return }
    gate.invalidate();
    await finish(
      .cancelled, message: message, next: "No further steps will be sent. Keep monitoring.")
  }
  private func finish(
    _ outcome: FixOutcome, message: String, next: String, actionSucceeded: Bool? = nil
  ) async {
    await complete(
      FixResult(
        outcome: outcome, actionSucceeded: actionSucceeded, targetResolved: nil,
        systemImproved: nil,
        after: comparable.last.map {
          FixMeasurement(
            snapshot: $0, target: session?.replacement ?? session?.plan?.target?.process.identity)
        }, samples: session?.samples ?? 0, remaining: [],
        message: message, nextStep: next))
  }
  private func complete(_ result: FixResult) async {
    let id = session?.id
    if let permit = session?.plan?.automation?.permit { automationGate?.release(permit.id) }
    gate.invalidate()
    deadline?.cancel(); deadline = nil; operation?.cancel(); operation = nil
    session?.phase = .finished; session?.result = result; session?.message = result.message
    do { try await record() } catch {
      if var value = session, value.id == id {
        value.message += " Audit write failed: \(error.localizedDescription)"; session = value;
        await publish(value)
      }
    }
  }
  private func record() async throws {
    guard var value = session else { return }
    revision &+= 1
    let version = revision
    value.updated = Date(); value.revision = version; session = value
    if !value.demo { try await save(value) }
    guard session?.id == value.id, revision == version else { return }
    await publish(value)
  }
}
