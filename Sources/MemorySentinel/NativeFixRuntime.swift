import AppKit
import SentinelCore
import ServiceManagement

@MainActor final class NativeFixRuntime: FixRuntime {
  let engine: MonitoringEngine
  let service: ProcessActionService
  let gate: InterventionGate
  init(engine: MonitoringEngine, gate: InterventionGate) {
    self.engine = engine; self.gate = gate; service = ProcessActionService(gate: gate)
  }
  func freshSnapshot() async throws -> Snapshot { try await engine.freshSnapshot() }
  func resolve(process: ProcessRecord, in snapshot: Snapshot) async throws -> FixTarget {
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
  func validate(target: FixTarget, token: InterventionToken) async throws {
    guard gate.current() == token else {
      throw FixError.invalidated("The execution context changed.")
    }
    if token.demo { return }
    try service.validate(target: target, token: token)
  }
  func perform(
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
      let fresh = try await engine.freshSnapshot()
      guard gate.current() == token, !fresh.demo,
        FixDiagnosis.isStillRelevant(plan, snapshot: fresh)
      else {
        throw FixError.invalidated(
          "The warning or mode changed immediately before execution. No action was sent.")
      }
      guard let target else { throw FixError.refused("No selected target.") }
      try service.perform(
        action: action, target: target, token: token, forceConfirmed: forceConfirmed)
    } else if action == .restartMonitoring {
      // No process effect is involved. The existing engine owns and replaces its sole loop.
      guard gate.current() == token else { throw FixError.invalidated("Mode changed.") }
      try await engine.restart()
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
  func relaunch(target: FixTarget, token: InterventionToken) async throws -> ProcessIdentity {
    guard gate.current() == token else {
      throw FixError.invalidated("The context changed before reopening.")
    }
    if token.demo { return try await engine.simulateRelaunch(target: target) }
    return try await service.relaunch(target: target, token: token)
  }
}
