import AppKit
import Foundation

/// All app and process effects, including the legacy Process Detail buttons, share this service.
@MainActor public final class ProcessActionService {
  public let gate: InterventionGate
  private var managedChildren: [Process] = []
  public init(gate: InterventionGate) { self.gate = gate }
  public func validateDisposableTask(_ process: ProcessRecord) throws {
    try LiveCollector.validateTarget(process)
    // A bundle wrapper also exists around some CLI interpreters. Native activation policy,
    // rather than the bundle path or runtime name, identifies an interactive application.
    if let app = NSRunningApplication(processIdentifier: process.identity.pid),
      app.activationPolicy != .prohibited
    {
      throw FixError.refused(
        "An interactive application requires the cooperative application permission and a fresh work-state assessment."
      )
    }
  }
  public func resolve(process source: ProcessRecord, in snapshot: Snapshot) throws -> FixTarget {
    guard !snapshot.demo,
      let current = snapshot.processes.first(where: { $0.identity == source.identity }),
      current.path == source.path, current.uid == source.uid, current.bundleID == source.bundleID
    else { throw FixError.invalidated("The selected process changed or exited.") }
    var applications = NSWorkspace.shared.runningApplications
    var ancestors: Set<ProcessIdentity> = [current.identity]
    var child = current
    for _ in 0..<64 {
      guard let parent = snapshot.processes.first(where: { $0.identity.pid == child.ppid }),
        parent.uid == child.uid,
        parent.identity.startDate <= child.identity.startDate,
        ancestors.insert(parent.identity).inserted
      else { break }
      child = parent
    }
    for id in ancestors where !applications.contains(where: { $0.processIdentifier == id.pid }) {
      if let app = NSRunningApplication(processIdentifier: id.pid) { applications.append(app) }
    }
    // Prefer the owning GUI application, never send a blanket signal to its helpers.
    for app in applications where app.bundleURL != nil && app.executableURL != nil {
      guard
        let root = snapshot.processes.first(where: { $0.identity.pid == app.processIdentifier }),
        root.uid == current.uid
      else { continue }
      let bundlePath = app.bundleURL!.resolvingSymlinksInPath().path
      let insideBundle =
        normalized(current.path).hasPrefix(bundlePath + "/")
        && current.bundleID == app.bundleIdentifier
      guard ancestors.contains(root.identity) || insideBundle else { continue }
      guard normalized(root.path) == app.executableURL!.resolvingSymlinksInPath().path else {
        continue
      }
      try LiveCollector.validateTarget(root)
      let identity = try applicationIdentity(bundlePath: bundlePath)
      guard identity.bundleID == app.bundleIdentifier,
        identity.executablePath == normalized(root.path)
      else {
        continue
      }
      let related = Array(
        snapshot.processes.filter { p in
          guard p.identity != root.identity, p.uid == root.uid else { return false }
          if normalized(p.path).hasPrefix(bundlePath + "/") { return true }
          var c = p; var seen = Set<ProcessIdentity>()
          for _ in 0..<64 {
            guard seen.insert(c.identity).inserted,
              let parent = snapshot.processes.first(where: { $0.identity.pid == c.ppid }),
              parent.uid == c.uid,
              parent.identity.startDate <= c.identity.startDate
            else { return false }
            if parent.identity == root.identity { return true }; c = parent
          }; return false
        }.prefix(128).map(\.identity))
      return FixTarget(process: root, source: current, application: identity, related: related)
    }
    try LiveCollector.validateTarget(current)
    return FixTarget(process: current, source: current)
  }
  public func validate(target: FixTarget, token: InterventionToken) throws {
    guard gate.current() == token, !token.demo else {
      throw FixError.invalidated(
        "Native actions are disabled in Simulation Mode or this context expired.")
    }
    guard let p = LiveCollector.readProcess(target.process.identity.pid),
      p.identity == target.process.identity, p.path == target.process.path,
      p.uid == target.process.uid
    else { throw FixError.invalidated("The process identity changed or is unreadable.") }
    if let application = target.application {
      guard try applicationIdentity(bundlePath: application.bundlePath) == application,
        let app = NSRunningApplication(processIdentifier: p.identity.pid),
        app.bundleIdentifier == application.bundleID,
        app.bundleURL?.resolvingSymlinksInPath().path == application.bundlePath,
        app.executableURL?.resolvingSymlinksInPath().path == normalized(p.path)
      else {
        throw FixError.invalidated("The application bundle, executable or relationship changed.")
      }
    }
    try LiveCollector.validateTarget(p)
  }
  public func perform(
    action: FixAction, target: FixTarget, token: InterventionToken, forceConfirmed: Bool = false,
    automaticTask: Bool = false
  ) throws {
    try gate.liveEffect(token: token) {
      // This validation deliberately repeats at the synchronous effect boundary, under the gate.
      guard let p = LiveCollector.readProcess(target.process.identity.pid),
        p.identity == target.process.identity, p.path == target.process.path,
        p.uid == target.process.uid
      else { throw FixError.invalidated("The selected process exited or changed identity.") }
      if let application = target.application,
        try applicationIdentity(bundlePath: application.bundlePath) != application
      {
        throw FixError.invalidated("The app bundle changed after approval.")
      }
      guard let source = LiveCollector.readProcess(target.source.identity.pid),
        source.identity == target.source.identity, source.path == target.source.path,
        source.uid == target.source.uid, source.bundleID == target.source.bundleID
      else {
        throw FixError.invalidated("The originating process changed or exited before the action.")
      }
      if source.identity != p.identity {
        var related =
          target.application.map {
            normalized(source.path).hasPrefix($0.bundlePath + "/") && source.bundleID == $0.bundleID
          } ?? false
        var child = source
        for _ in 0..<64 where !related {
          guard let parent = LiveCollector.readProcess(child.ppid),
            parent.uid == child.uid,
            parent.identity.startDate <= child.identity.startDate, parent.identity != child.identity
          else { break }
          if parent.identity == p.identity { related = true; break }; child = parent
        }
        guard related else {
          throw FixError.invalidated("The source no longer belongs to the selected application.")
        }
      }
      try LiveCollector.validateTarget(p)
      if automaticTask { try validateDisposableTask(p) }
      switch action {
      case .quitApplication, .restartApplication:
        guard let application = target.application,
          let app = NSRunningApplication(processIdentifier: p.identity.pid),
          app.bundleIdentifier == application.bundleID,
          app.bundleURL?.resolvingSymlinksInPath().path == application.bundlePath,
          app.executableURL?.resolvingSymlinksInPath().path == application.executablePath,
          app.terminate()
        else {
          throw FixError.refused(
            "The normal Quit request was refused or could not be sent. No Force Quit was sent.")
        }
      case .terminateProcess, .restartManagedTask: try LiveCollector.signal(p, force: false)
      case .forceQuit:
        guard forceConfirmed else {
          throw FixError.refused("Force Quit needs its own explicit confirmation.")
        }
        try LiveCollector.signal(p, force: true)
      default: throw FixError.refused("This is not a process action.")
      }
    }
  }
  public func relaunch(
    target: FixTarget, token: InterventionToken,
    policy: AutomationExecution? = nil, policyGate: AutomationGate? = nil,
    planID: UUID? = nil, executable: ExecutableIdentity? = nil
  ) async throws -> ProcessIdentity {
    guard let application = target.application else {
      throw FixError.refused("No verified app bundle to reopen.")
    }
    let result: Int32 = try await withCheckedThrowingContinuation { continuation in
      let completion = RelaunchCompletion(continuation)
      completion.startTimeout()
      do {
        let submit = {
          try self.gate.liveEffect(token: token) {
            guard try self.applicationIdentity(bundlePath: application.bundlePath) == application
            else {
              throw FixError.invalidated("The app bundle changed; it will not be reopened.")
            }
            if let original = LiveCollector.readProcess(target.process.identity.pid) {
              guard original.identity != target.process.identity else {
                throw FixError.refused("The original app has not exited.")
              }
            } else if LiveCollector.processExists(target.process.identity.pid) {
              throw FixError.refused("The old process is unreadable; exit cannot be verified.")
            }
            if let existing = NSRunningApplication.runningApplications(
              withBundleIdentifier: application.bundleID
            ).first(where: {
              !$0.isTerminated
                && $0.bundleURL?.resolvingSymlinksInPath().path == application.bundlePath
                && $0.executableURL?.resolvingSymlinksInPath().path == application.executablePath
                && Self.verifiedReplacement(
                  LiveCollector.readProcess($0.processIdentifier), target: target) != nil
            }) {
              completion.finish(.success(existing.processIdentifier)); return
            }
            let configuration = NSWorkspace.OpenConfiguration();
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(
              at: URL(fileURLWithPath: application.bundlePath), configuration: configuration
            ) { @Sendable app, error in
              if let error {
                completion.finish(.failure(FixError.unavailable(error.localizedDescription)))
              } else if let app {
                completion.finish(.success(app.processIdentifier))
              } else {
                completion.finish(
                  .failure(FixError.unavailable("Application launch did not return an identity.")))
              }
            }
          }
        }
        if let policy {
          guard let policyGate, let planID, let executable else {
            throw FixError.refused("The policy reopen permit is unavailable.")
          }
          try policyGate.effect(
            policy.permit, planID: planID, target: target.id,
            operation: policy.rule.operation, stage: .reopen, executable: executable
          ) { _ in
            try executable.validateCurrentMetadata()
            try submit()
          }
        } else {
          try submit()
        }
      } catch { completion.finish(.failure(error)) }
    }
    // AppKit lifecycle properties can lag until a common-mode main-run-loop turn.
    // Only a fresh kernel identity can establish the replacement; no second open is sent.
    for _ in 0..<60 {
      try Task.checkCancellation()
      guard gate.current() == token, !token.demo else {
        throw FixError.invalidated("The reopen approval changed during identity verification.")
      }
      guard try applicationIdentity(bundlePath: application.bundlePath) == application else {
        throw FixError.invalidated("The application changed while it was being reopened.")
      }
      if let identity = Self.verifiedReplacement(LiveCollector.readProcess(result), target: target)
      {
        return identity
      }
      for app in NSRunningApplication.runningApplications(
        withBundleIdentifier: application.bundleID)
      where app.bundleURL?.resolvingSymlinksInPath().path == application.bundlePath {
        if let identity = Self.verifiedReplacement(
          LiveCollector.readProcess(app.processIdentifier), target: target)
        {
          return identity
        }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw FixError.unavailable(
      "The reopened instance could not be verified. No additional launch was requested.")
  }
  public func launchManagedTask(
    plan: FixPlan, policyGate: AutomationGate,
    executable: ExecutableIdentity
  ) async throws -> ProcessIdentity {
    guard let policy = plan.automation, let spec = policy.rule.launch, spec.valid,
      policy.rule.operation == .restartTask, spec.executable == executable,
      let target = plan.target
    else {
      throw FixError.refused("No separately approved managed launch specification is available.")
    }
    managedChildren.removeAll { !$0.isRunning }
    guard managedChildren.count < 16 else {
      throw FixError.refused("The bounded managed-child tracking limit is reached.")
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: spec.executable.path)
    child.arguments = spec.arguments
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    child.currentDirectoryURL = spec.directory.map { URL(fileURLWithPath: $0) }
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try policyGate.effect(
      policy.permit, planID: plan.id, target: target.id,
      operation: .restartTask, stage: .reopen, executable: executable
    ) { _ in
      try gate.liveEffect(token: plan.token) {
        try executable.validateCurrentMetadata()
        if let old = LiveCollector.readProcess(target.id.pid) {
          guard old.identity != target.id else {
            throw FixError.refused("The old task has not exited.")
          }
        } else if LiveCollector.processExists(target.id.pid) {
          throw FixError.refused("The old task is unreadable; its exit is not verified.")
        }
        try child.run()
        managedChildren.append(child)
      }
    }
    for _ in 0..<100 {
      try Task.checkCancellation()
      guard gate.current() == plan.token else {
        throw FixError.invalidated("The context changed during launch.")
      }
      if let record = LiveCollector.readProcess(child.processIdentifier),
        record.identity != target.id, record.uid == policy.rule.owner,
        record.path == spec.executable.path
      {
        return record.identity
      }
      guard child.isRunning else { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw FixError.unavailable(
      "The requested task launch could not be verified. No retry was sent.")
  }
  public nonisolated static func verifiedReplacement(_ record: ProcessRecord?, target: FixTarget)
    -> ProcessIdentity?
  {
    guard let record, let application = target.application,
      record.identity != target.process.identity,
      record.uid == target.process.uid,
      URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path == application.executablePath
    else { return nil }
    return record.identity
  }
  private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
  public func applicationIdentity(bundlePath: String) throws -> ApplicationIdentity {
    let url = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath()
    guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
      let executable = bundle.executableURL?.resolvingSymlinksInPath()
    else { throw FixError.unavailable("The application metadata is unavailable.") }
    let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
    let infoAttributes = try FileManager.default.attributesOfItem(
      atPath: url.appendingPathComponent("Contents/Info.plist").path)
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    let infoModified = (infoAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    let fingerprint =
      "\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")|\(modified)|\(infoModified)|\(bundle.object(forInfoDictionaryKey:"CFBundleVersion") ?? "")"
    return ApplicationIdentity(
      bundleID: identifier, bundlePath: url.path, executablePath: executable.path,
      fingerprint: fingerprint)
  }
}

private final class RelaunchCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Int32, Error>?
  private var timeout: Task<Void, Never>?
  init(_ continuation: CheckedContinuation<Int32, Error>) { self.continuation = continuation }
  func startTimeout() {
    let task = Task.detached { [self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      finish(
        .failure(
          FixError.unavailable(
            "Application launch timed out; an already submitted launch cannot be undone.")))
    }
    lock.lock(); timeout = task; lock.unlock()
  }
  func finish(_ result: Result<Int32, Error>) {
    lock.lock(); let waiting = continuation; continuation = nil; let task = timeout; timeout = nil;
    lock.unlock()
    task?.cancel(); waiting?.resume(with: result)
  }
}
