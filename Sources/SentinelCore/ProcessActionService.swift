import AppKit
import Foundation

/// All app and process effects, including the legacy Process Detail buttons, share this service.
@MainActor public final class ProcessActionService {
  public let gate: InterventionGate
  public init(gate: InterventionGate) { self.gate = gate }
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
    action: FixAction, target: FixTarget, token: InterventionToken, forceConfirmed: Bool = false
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
            parent.identity.startDate <= child.identity.startDate, parent.identity != child.identity
          else { break }
          if parent.identity == p.identity { related = true; break }; child = parent
        }
        guard related else {
          throw FixError.invalidated("The source no longer belongs to the selected application.")
        }
      }
      try LiveCollector.validateTarget(p)
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
      case .terminateProcess: try LiveCollector.signal(p, force: false)
      case .forceQuit:
        guard forceConfirmed else {
          throw FixError.refused("Force Quit needs its own explicit confirmation.")
        }
        try LiveCollector.signal(p, force: true)
      default: throw FixError.refused("This is not a process action.")
      }
    }
  }
  public func relaunch(target: FixTarget, token: InterventionToken) async throws -> ProcessIdentity
  {
    guard let application = target.application else {
      throw FixError.refused("No verified app bundle to reopen.")
    }
    let result: Int32 = try await withCheckedThrowingContinuation { continuation in
      let completion = RelaunchCompletion(continuation)
      completion.startTimeout()
      do {
        try gate.liveEffect(token: token) {
          guard try applicationIdentity(bundlePath: application.bundlePath) == application else {
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
      } catch { completion.finish(.failure(error)) }
    }
    guard let current = LiveCollector.readProcess(result),
      normalized(current.path) == application.executablePath, current.uid == target.process.uid,
      current.identity != target.process.identity
    else { throw FixError.unavailable("The reopened instance could not be verified.") }
    return current.identity
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
