import AppKit
import ServiceManagement

@MainActor public final class NativeFixRuntime: FixRuntime {
  public let engine: MonitoringEngine
  public let service: ProcessActionService
  public let gate: InterventionGate
  public let automationGate: AutomationGate
  public let repairObservers: @MainActor @Sendable () -> Void
  public init(
    engine: MonitoringEngine, gate: InterventionGate, automationGate: AutomationGate,
    repairObservers: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    self.engine = engine; self.gate = gate; self.automationGate = automationGate
    self.repairObservers = repairObservers
    service = ProcessActionService(gate: gate)
  }
  public func freshSnapshot() async throws -> Snapshot { try await engine.freshSnapshot() }
  public func resolve(process: ProcessRecord, in snapshot: Snapshot) async throws -> FixTarget {
    if snapshot.demo {
      guard snapshot.processes.contains(where: { $0.identity == process.identity }) else {
        throw FixError.invalidated("The simulated target exited.")
      }
      let app = process.bundleID.map {
        ApplicationIdentity(
          bundleID: $0, bundlePath: "/Simulation/Codex.app", executablePath: process.path,
          fingerprint: "simulation-only")
      }
      return FixTarget(process: process, source: process, application: app)
    }
    return try service.resolve(process: process, in: snapshot)
  }
  public func validate(target: FixTarget, token: InterventionToken) async throws {
    guard gate.current() == token else {
      throw FixError.invalidated("The execution context changed.")
    }
    if token.demo { return }
    try service.validate(target: target, token: token)
  }
  public func perform(
    action: FixAction, target: FixTarget?, token: InterventionToken, forceConfirmed: Bool,
    plan: FixPlan
  ) async throws {
    guard gate.current() == token else {
      throw FixError.invalidated("The approved context changed.")
    }
    if token.demo { try await engine.simulate(action: action, target: target); return }
    if action.isProcessAction {
      guard await !engine.isPaused else {
        throw FixError.refused(
          "Resume monitoring before executing an action that needs verification.")
      }
      let executable: ExecutableIdentity?
      if let automatic = plan.automation {
        guard action == automatic.rule.operation.action, action != .forceQuit, !forceConfirmed
        else {
          throw FixError.refused(
            "Automatic authority cannot expand to Force Quit or another operation.")
        }
        let path = automatic.rule.executable.path
        executable = try await Task.detached(priority: .utility) {
          try ExecutableIdentity.capture(path)
        }.value
      } else {
        guard action != .restartManagedTask else {
          throw FixError.refused("Managed task restart requires a separate policy grant.")
        }
        executable = nil
      }
      let fresh = try await engine.freshSnapshot()
      guard gate.current() == token, !fresh.demo,
        FixDiagnosis.isStillRelevant(plan, snapshot: fresh)
      else {
        throw FixError.invalidated(
          "The warning or mode changed immediately before execution. No action was sent.")
      }
      guard let target else { throw FixError.refused("No selected target.") }
      if let automatic = plan.automation, let executable {
        var proof: ApplicationReadiness?
        if automatic.rule.subject == .application, let endpoint = automatic.rule.cooperativeEndpoint
        {
          proof = try await CooperativeReadiness.query(endpoint: endpoint, target: target.process)
        }
        try automationGate.effect(
          automatic.permit, planID: plan.id, target: target.id,
          operation: automatic.rule.operation, stage: .primary, executable: executable
        ) { _ in
          try executable.validateCurrentMetadata()
          if automatic.rule.subject == .application {
            guard let proof, proof.identity == target.id, proof.peerVerified, proof.idle,
              !proof.unsavedWork, proof.expires > Date()
            else {
              throw FixError.refused(
                "The application is busy, has unsaved work or cannot prove a current safe quit state."
              )
            }
          }
          try service.perform(
            action: action, target: target, token: token, forceConfirmed: false,
            automaticTask: automatic.rule.subject == .taskInstance)
        }
      } else {
        try service.perform(
          action: action, target: target, token: token, forceConfirmed: forceConfirmed)
      }
    } else if action == .restartMonitoring {
      // No process effect is involved. The existing engine owns and replaces its sole loop.
      guard gate.current() == token else { throw FixError.invalidated("Mode changed.") }
      repairObservers()
      try await engine.restart(if: { [gate] in gate.current() == token })
    } else {
      try gate.liveEffect(token: token) {
        if action == .loginSettings {
          SMAppService.openSystemSettingsLoginItems()
        } else {
          let bundleID =
            action == .activityMonitor ? "com.apple.ActivityMonitor" : "com.apple.systempreferences"
          guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            NSWorkspace.shared.open(url)
          else {
            throw FixError.unavailable("The requested system application could not be opened.")
          }
        }
      }
    }
  }
  public func relaunch(target: FixTarget, token: InterventionToken) async throws -> ProcessIdentity
  {
    guard gate.current() == token else {
      throw FixError.invalidated("The context changed before reopening.")
    }
    if token.demo { return try await engine.simulateRelaunch(target: target) }
    return try await service.relaunch(target: target, token: token)
  }
  public func relaunchAutomatic(plan: FixPlan) async throws -> ProcessIdentity {
    guard let automatic = plan.automation, let target = plan.target,
      gate.current() == plan.token, !plan.token.demo
    else {
      throw FixError.invalidated("The policy reopening context changed.")
    }
    let path = automatic.rule.executable.path
    let code = try await Task.detached(priority: .utility) { try ExecutableIdentity.capture(path) }
      .value
    if automatic.rule.operation == .restartTask {
      return try await service.launchManagedTask(
        plan: plan, policyGate: automationGate, executable: code)
    }
    guard automatic.rule.operation == .restartApplication else {
      throw FixError.refused("This rule grants no reopening.")
    }
    return try await service.relaunch(
      target: target, token: plan.token, policy: automatic,
      policyGate: automationGate, planID: plan.id, executable: code)
  }
}
