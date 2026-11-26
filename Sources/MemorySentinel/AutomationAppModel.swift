import AppKit
import SentinelCore

extension AppModel {
  func startSelfCare() {
    guard selfCareTask == nil else { return }
    selfCareTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard let self else { return }
        await self.checkSelfCare()
      }
    }
  }
  private func checkSelfCare() async {
    guard !demo, !paused, !maintenance, fixReady, settings.controls.selfRepair,
      let snapshot, let coordinator = fixCoordinator
    else {
      selfCareBudget.resetContinuity(); return
    }
    let uptime = ProcessInfo.processInfo.systemUptime
    let stale = uptime - sampleHeartbeat > Double(max(30, settings.interval * 4))
    let missing =
      snapshot.system.total == nil || snapshot.system.used == nil
      || snapshot.system.available == nil || snapshot.system.swap == nil
      || snapshot.system.pressure == .unavailable || snapshot.processesAvailable == false
    selfCareBudget.observe(healthy: !stale && !missing, uptime: uptime)
    selfCareStatus =
      selfCareBudget.reason(uptime: uptime) ?? "A bounded monitor repair is eligible."
    guard !manualRequestPending, (await coordinator.current())?.phase.active != true,
      selfCareBudget.reserve(uptime: uptime)
    else { return }
    do {
      selfCareStatus =
        "Restarting the sole sampler and pressure observer; checking fresh evidence next."
      _ = try await coordinator.repairMonitoring(snapshot: snapshot, settings: settings)
    } catch { selfCareStatus = error.localizedDescription }
  }
  func registerAutomation(
    process: ProcessRecord, label: String, application: Bool,
    restart: Bool, trigger: AutomaticTrigger, limit: Double, hold: Double,
    endpoint: String, argumentsJSON: String, directory: String, days: Int
  ) async throws {
    guard !demo, !paused, !maintenance, let runtime = nativeRuntime else {
      throw FixError.refused("Live monitoring is required.")
    }
    let signature = settings.analysisSignature, profile = settings.activeProfile.id
    let fresh = try await runtime.freshSnapshot()
    guard let exact = fresh.processes.first(where: { $0.identity == process.identity }),
      exact.path == process.path, exact.uid == process.uid, exact.uid == getuid()
    else {
      throw FixError.invalidated("The selected process instance changed.")
    }
    let target: FixTarget
    if application {
      target = try await runtime.resolve(process: exact, in: fresh)
      guard target.id == exact.identity, target.application != nil else {
        throw FixError.refused(
          "Select the verified application's main process for an application rule.")
      }
    } else {
      try runtime.service.validateDisposableTask(exact)
      target = FixTarget(process: exact, source: exact)
    }
    try await runtime.validate(target: target, token: interventionGate.current())
    let path = exact.path
    let code = try await Task.detached(priority: .utility) { try ExecutableIdentity.capture(path) }
      .value
    guard signature == settings.analysisSignature, profile == settings.activeProfile.id,
      !demo, code.path == exact.path
    else {
      throw FixError.invalidated(
        "The profile, mode or executable path changed during registration.")
    }
    var launch: ManagedLaunchSpecification?
    if restart && !application {
      let arguments = try JSONDecoder().decode([String].self, from: Data(argumentsJSON.utf8))
      launch = ManagedLaunchSpecification(
        executable: code, arguments: arguments,
        directory: directory.isEmpty ? nil : directory)
    }
    var rule = AutomationRule(
      label: label, subject: application ? .application : .taskInstance,
      profileID: profile, configuration: signature, owner: exact.uid,
      instance: application ? nil : exact.identity, executable: code,
      application: target.application,
      operation: application ? .restartApplication : restart ? .restartTask : .stopTask,
      trigger: trigger, footprintLimit: trigger == .taskFootprint ? limit : nil, launch: launch,
      cooperativeEndpoint: application ? endpoint : nil)
    rule.holdSeconds = hold;
    rule.expires = rule.created.addingTimeInterval(Double(min(30, max(1, days))) * 86400)
    try await liveControl.register(rule)
    control = await controller.summary(); configureAutomation()
    automationMessage =
      "Permission saved. External automation remains \(settings.controls.externalActionsEnabled ? "on" : "off")."
  }
  func automationStatus(_ process: ProcessRecord) -> String {
    guard
      let rule = control.rules.first(where: {
        $0.enabled
          && ($0.subject == .taskInstance
            ? $0.instance == process.identity
            : $0.executable.path == process.path && $0.owner == process.uid)
      })
    else { return "No automatic permission" }
    if let review = rule.reviewReason { return "Review required · \(review)" }
    return settings.controls.externalActionsEnabled
      ? "Registered · \(automationReasons[rule.id] ?? "Waiting for fresh evaluation")"
      : "Registered · automation off"
  }
  func configureAutomation() {
    let busy =
      manualRequestPending || (fixSession?.phase.active == true && fixSession?.authority != .policy)
    automationGate.configure(
      context: AutomationContext(
        profileID: settings.activeProfile.id,
        configuration: settings.analysisSignature, owner: getuid(),
        enabled: settings.controls.externalActionsEnabled && control.persistent
          && control.error == nil,
        demo: demo, paused: paused || maintenance, manualBusy: busy), rules: control.rules)
  }
  func stopAutomation() {
    automationGate.invalidate(); automationTask?.cancel()
    settings.controlPreferences?.externalActionsEnabled = false
    automationMessage = "Automation stopped. A quit request already sent cannot be undone."
  }
  func revokeAutomation(_ id: UUID) {
    // Invalidate synchronously before crossing the actor or storage boundary.
    automationGate.invalidate(); automationTask?.cancel()
    if fixSession?.authority == .policy { invalidateFix("An automatic permission was revoked.") }
    Task {
      await liveControl.revoke(id); control = await controller.summary()
      if control.error != nil { settings.controlPreferences?.externalActionsEnabled = false }
      configureAutomation()
    }
  }
  func reviewAutomation(_ rule: AutomationRule) {
    Task {
      do {
        guard
          let process = snapshot?.processes.first(where: {
            rule.subject == .taskInstance
              ? $0.identity == rule.instance
              : $0.path == rule.executable.path && $0.uid == rule.owner
          }), process.uid == rule.owner
        else {
          throw FixError.refused(
            "The exact target is no longer available. Register a new permission.")
        }
        let path = process.path
        let code = try await Task.detached(priority: .utility) {
          try ExecutableIdentity.capture(path)
        }.value
        guard code == rule.executable, rule.profileID == settings.activeProfile.id,
          rule.configuration == settings.analysisSignature
        else {
          throw FixError.refused(
            "The executable or profile changed. Register a new exact permission.")
        }
        try await liveControl.review(rule.id); control = await controller.summary();
        configureAutomation()
      } catch { automationMessage = error.localizedDescription }
    }
  }
  func scheduleAutomation(_ sample: Snapshot) {
    let uptime = ProcessInfo.processInfo.systemUptime
    if let previous = lastAutomationSample {
      let wall = sample.date.timeIntervalSince(previous.0), elapsed = uptime - previous.1
      if wall <= 0 || elapsed <= 0 || wall > Double(max(15, settings.interval * 3))
        || abs(wall - elapsed) > 3
      {
        automationWarmup = nil; automationGate.invalidate()
      }
    }
    lastAutomationSample = (sample.date, uptime)
    if !sample.demo && !sample.hasUnavailableMemoryReadings && !paused && !maintenance {
      if automationWarmup == nil { automationWarmup = uptime }
    } else {
      automationWarmup = nil
    }
    guard automationTask == nil, !demo, !paused, !maintenance,
      settings.controls.externalActionsEnabled, fixReady
    else { return }
    let token = interventionGate.current()
    automationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.automationTask = nil }
      await self.evaluateAutomation(sample, expected: token)
    }
  }
  private func evaluateAutomation(_ sample: Snapshot, expected token: InterventionToken) async {
    guard let runtime = nativeRuntime, let coordinator = fixCoordinator else { return }
    for rule in control.rules where rule.enabled {
      guard !Task.isCancelled, interventionGate.current() == token, !demo, !paused,
        settings.controls.externalActionsEnabled, control.error == nil, control.persistent
      else { return }
      let key =
        rule.trigger == .taskFootprint
        ? "automation-rule:\(rule.id):\(rule.revision)" : "system:memory"
      guard let episode = control.active.first(where: { $0.key == key }) else {
        automationReasons[rule.id] = "No current issue matches this trigger."; continue
      }
      guard
        let process = sample.processes.first(where: {
          rule.subject == .taskInstance
            ? $0.identity == rule.instance
            : $0.path == rule.executable.path && $0.uid == rule.owner
              && $0.bundleID == rule.application?.bundleID
        })
      else { automationReasons[rule.id] = "The exact registered target is not running."; continue }
      let preflightWarmup =
        ProcessInfo.processInfo.systemUptime
        - (automationWarmup ?? ProcessInfo.processInfo.systemUptime)
      // Preflight only schedules fresh code/peer assessment. It cannot reserve or execute an action.
      if let reason = AutomationEligibility.reason(
        rule: rule, episode: episode, snapshot: sample,
        settings: settings, journal: control.attempts, executable: rule.executable,
        currentUser: getuid(), now: Date(), warmupSeconds: preflightWarmup,
        manualBusy: manualRequestPending || fixSession?.phase.active == true,
        requireReadiness: false)
      {
        automationReasons[rule.id] = reason; continue
      }
      var reserved: UUID?
      var issued: UUID?
      do {
        let path = rule.executable.path
        let code = try await Task.detached(priority: .utility) {
          try ExecutableIdentity.capture(path)
        }.value
        if code != rule.executable {
          await liveControl.requireReview(
            rule, reason: "The executable changed. Register its new exact identity before resuming."
          )
          throw FixError.invalidated("The executable changed; this permission now requires review.")
        }
        try Task.checkCancellation()
        let fresh = try await runtime.freshSnapshot()
        let target: FixTarget
        if rule.subject == .application {
          target = try await runtime.resolve(process: process, in: fresh)
          guard target.id == process.identity, target.application == rule.application else {
            await liveControl.requireReview(
              rule,
              reason:
                "The application bundle or executable identity changed. Register a new exact permission."
            )
            throw FixError.invalidated("The exact application identity changed.")
          }
        } else {
          guard let exact = fresh.processes.first(where: { $0.identity == rule.instance }) else {
            throw FixError.invalidated("The registered task instance exited or changed.")
          }
          target = FixTarget(process: exact, source: exact)
        }
        guard target.process.path == rule.executable.path, target.process.uid == rule.owner else {
          await liveControl.requireReview(
            rule,
            reason:
              "The registered executable path or process owner changed. Review the target before resuming."
          )
          throw FixError.invalidated("The exact target owner or executable path changed.")
        }
        try await runtime.validate(target: target, token: token)
        var proof: ApplicationReadiness?
        if rule.subject == .application, let endpoint = rule.cooperativeEndpoint {
          proof = try await CooperativeReadiness.query(endpoint: endpoint, target: target.process)
        }
        let warmup =
          ProcessInfo.processInfo.systemUptime
          - (automationWarmup ?? ProcessInfo.processInfo.systemUptime)
        let currentFix = await coordinator.current()
        let busy = manualRequestPending || currentFix?.phase.active == true
        if let reason = AutomationEligibility.reason(
          rule: rule, episode: episode, snapshot: fresh,
          settings: settings, journal: control.attempts, executable: code, currentUser: getuid(),
          now: Date(), warmupSeconds: warmup, manualBusy: busy, readiness: proof,
          nonce: proof?.nonce)
        {
          automationReasons[rule.id] = reason; continue
        }
        try Task.checkCancellation()
        guard interventionGate.current() == token else { return }
        let attempt = try await liveControl.reserve(
          rule: rule, episode: episode, snapshot: fresh,
          settings: settings, executable: code, currentUser: getuid(), warmupSeconds: warmup,
          manualBusy: busy, readiness: proof)
        reserved = attempt.id
        try Task.checkCancellation()
        guard interventionGate.current() == token, !manualRequestPending else {
          throw FixError.invalidated("A manual action or monitoring change took priority.")
        }
        let permit = try automationGate.issue(
          rule: rule, episodeID: episode.id,
          target: target, token: token)
        issued = permit.id
        _ = try await coordinator.executeAutomatic(
          rule: rule, permit: permit, target: target,
          snapshot: fresh, settings: settings)
        automationReasons[rule.id] = "The policy-authorized attempt is recorded in Activity."
        control = await liveControl.summary(); configureAutomation(); return
      } catch {
        if let issued { automationGate.release(issued) }
        if let reserved { await liveControl.abandon(reserved, message: error.localizedDescription) }
        automationReasons[rule.id] = error.localizedDescription
        control = await liveControl.summary(); configureAutomation()
      }
    }
  }
}
