import AppKit
import Foundation
import SentinelCore

@MainActor private final class NativeFixtureDelegate: NSObject, NSApplicationDelegate {
  private var folder: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
  func applicationDidFinishLaunching(_ notification: Notification) {
    try? "ready".write(
      to: folder.appendingPathComponent("ready-\(ProcessInfo.processInfo.processIdentifier)"),
      atomically: true, encoding: .utf8)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    try? "normal-quit-request".write(
      to: folder.appendingPathComponent("quit.log"), atomically: true, encoding: .utf8)
    let behavior =
      (try? String(contentsOf: folder.appendingPathComponent("behavior.txt"), encoding: .utf8))
      ?? "accept"
    return behavior == "refuse" ? .terminateCancel : .terminateNow
  }
}

@MainActor final class NativeFixTests {
  // The test executable also hosts the disposable AppKit fixture. A bundle flag
  // survives verified relaunch without command-line arguments or a runtime compiler.
  static func runFixtureIfRequested() -> Bool {
    guard Bundle.main.object(forInfoDictionaryKey: "MemorySentinelTestFixture") as? Bool == true
    else {
      return false
    }
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "Disposable native Fix test")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let application = NSApplication.shared
    let delegate = NativeFixtureDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
    return true
  }
  func command(_ path: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path);
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw FixError.unavailable("Fixture build failed: \(path)")
    }
  }
  func buildFixture(_ dir: URL) throws -> URL {
    let bundle = dir.appendingPathComponent("SentinelFixFixture.app")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "local.memorysentinel.fixture.\(UUID().uuidString)",
      "CFBundleExecutable": "SentinelFixFixture", "CFBundleName": "Sentinel Fix Fixture",
      "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": true,
      "MemorySentinelTestFixture": true,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
      to: contents.appendingPathComponent("Info.plist"))
    guard let executable = Bundle.main.executableURL else {
      throw FixError.unavailable("Test executable unavailable")
    }
    try FileManager.default.copyItem(
      at: executable, to: contents.appendingPathComponent("MacOS/SentinelFixFixture"))
    try command("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
    return bundle.resolvingSymlinksInPath()
  }
  func launch(_ bundle: URL) async throws -> ProcessIdentity {
    let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
      let options = NSWorkspace.OpenConfiguration(); options.activates = false
      NSWorkspace.shared.openApplication(at: bundle, configuration: options) {
        @Sendable app, error in
        if let app {
          continuation.resume(returning: app.processIdentifier)
        } else {
          continuation.resume(
            throwing: FixError.unavailable(error?.localizedDescription ?? "Fixture did not launch"))
        }
      }
    }
    var ready = false
    defer {
      if !ready, let process = LiveCollector.readProcess(pid),
        URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path
          == bundle.appendingPathComponent("Contents/MacOS/SentinelFixFixture").path
      {
        try? LiveCollector.signal(process, force: true)
      }
    }
    for _ in 0..<500 {
      if let record = LiveCollector.readProcess(pid),
        FileManager.default.fileExists(
          atPath: bundle.deletingLastPathComponent().appendingPathComponent("ready-\(pid)").path)
      {
        ready = true
        return record.identity
      };
      try await Task.sleep(for: .milliseconds(20))
    }
    throw FixError.unavailable("Fixture identity unavailable")
  }
  func waitExit(_ identity: ProcessIdentity) async throws {
    for _ in 0..<150 {
      if LiveCollector.readProcess(identity.pid)?.identity != identity { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw FixError.unavailable("Disposable fixture did not exit")
  }
  func target(_ identity: ProcessIdentity, service: ProcessActionService) throws -> FixTarget {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    guard let record = LiveCollector.readProcess(identity.pid) else {
      throw FixError.unavailable("Fixture missing")
    }
    var analyzer = Analyzer();
    let snapshot = analyzer.evaluate(LiveCollector().collect(), settings: Settings()).snapshot
    return try service.resolve(process: record, in: snapshot)
  }
  func testNativeQuitRelaunchAndBackendGuards() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MemorySentinel-Fix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bundle = try buildFixture(dir)
    var owned = Set<ProcessIdentity>()
    defer {
      for identity in owned {
        if let p = LiveCollector.readProcess(identity.pid), p.identity == identity,
          URL(fileURLWithPath: p.path).resolvingSymlinksInPath().path.hasPrefix(
            dir.resolvingSymlinksInPath().path + "/")
        {
          try? LiveCollector.signal(p, force: true)
        }
      }
      try? FileManager.default.removeItem(at: dir)
    }
    let gate = InterventionGate(); let service = ProcessActionService(gate: gate)
    let original = try await launch(bundle); owned.insert(original)
    let planTarget = try target(original, service: service)
    if planTarget.application == nil {
      let info = NSRunningApplication(processIdentifier: original.pid)
      print(
        "CANON app=\(info?.bundleURL?.resolvingSymlinksInPath().path ?? "nil") exec=\(info?.executableURL?.resolvingSymlinksInPath().path ?? "nil") bundleExec=\(info?.bundleURL.flatMap { Bundle(url:$0)?.executableURL?.resolvingSymlinksInPath().path } ?? "nil")"
      )
      print(
        "FIXTURE METADATA pid=\(original.pid) path=\(planTarget.process.path) bundle=\(info?.bundleURL?.path ?? "nil") executable=\(info?.executableURL?.path ?? "nil") id=\(info?.bundleIdentifier ?? "nil") C-bundle=\(planTarget.process.bundleID ?? "nil")"
      )
    }
    XCTAssertNotNil(planTarget.application)
    let token = gate.current()
    try service.validate(target: planTarget, token: token)
    // Even the real executor cannot reach a native signal with a demo or obsolete token.
    gate.invalidate(demo: true)
    XCTAssertThrowsError(
      try service.perform(
        action: .forceQuit, target: planTarget, token: gate.current(), forceConfirmed: true))
    XCTAssertEqual(LiveCollector.readProcess(original.pid)?.identity, original)
    gate.invalidate(demo: false)
    XCTAssertThrowsError(
      try service.perform(action: .terminateProcess, target: planTarget, token: token))
    XCTAssertThrowsError(
      try service.perform(
        action: .forceQuit, target: planTarget, token: gate.current(), forceConfirmed: false))
    var changed = planTarget; changed.process.identity.seconds += 1
    XCTAssertThrowsError(
      try service.perform(action: .terminateProcess, target: changed, token: gate.current()))
    changed = planTarget; changed.process.uid += 1
    XCTAssertThrowsError(
      try service.perform(action: .terminateProcess, target: changed, token: gate.current()))
    // The fixture writes this marker only for the native normal Quit event.
    try service.perform(action: .quitApplication, target: planTarget, token: gate.current())
    try await waitExit(original)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("quit.log").path))
    let replacement = try await service.relaunch(target: planTarget, token: gate.current());
    owned.insert(replacement)
    XCTAssertTrue(replacement != original)
    for _ in 0..<100 {
      if FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("ready-\(replacement.pid)").path)
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let current = try target(replacement, service: service)
    try "refuse".write(
      to: dir.appendingPathComponent("behavior.txt"), atomically: true, encoding: .utf8)
    try service.perform(action: .quitApplication, target: current, token: gate.current())
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(LiveCollector.readProcess(replacement.pid)?.identity, replacement)
    var refused = false
    do { _ = try await service.relaunch(target: current, token: gate.current()) } catch {
      refused = true
    }
    XCTAssertTrue(refused)
    // A separately confirmed force action is exercised only on our disposable fixture.
    try service.perform(
      action: .forceQuit, target: current, token: gate.current(), forceConfirmed: true)
    try await waitExit(replacement)
    XCTAssertTrue(LiveCollector.readProcess(replacement.pid)?.identity != replacement)
    let third = try await launch(bundle); owned.insert(third)
    let thirdTarget = try target(third, service: service)
    try service.perform(action: .terminateProcess, target: thirdTarget, token: gate.current())
    try await waitExit(third)
    XCTAssertTrue(LiveCollector.readProcess(third.pid)?.identity != third)
    // Self protection remains enforced through the same service used by all Fix entry points.
    if let own = LiveCollector.readProcess(ProcessInfo.processInfo.processIdentifier) {
      XCTAssertThrowsError(
        try service.perform(
          action: .terminateProcess, target: FixTarget(process: own, source: own),
          token: gate.current()))
    }
  }
}
