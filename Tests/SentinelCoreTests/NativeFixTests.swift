import AppKit
import Darwin
import Foundation
import SentinelCore

@MainActor private final class NativeFixtureDelegate: NSObject, NSApplicationDelegate {
  private var folder: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
  private var saveWindow: NSWindow?
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let server = try? ReadinessTestServer() {
      let behavior = folder.appendingPathComponent("behavior.txt")
      Task.detached {
        while !Task.isCancelled { await server.answer(mode: "ready", modeURL: behavior).value }
      }
      try? server.path.write(
        to: folder.appendingPathComponent("readiness-\(getpid()).txt"),
        atomically: true, encoding: .utf8)
    }
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
    if behavior == "save" {
      if saveWindow == nil {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Disposable Fix fixture"; window.isReleasedWhenClosed = false
        saveWindow = window; window.orderFront(nil)
        let alert = NSAlert(); alert.messageText = "Disposable fixture: unsaved work"
        alert.informativeText = "This test dialog is never accepted by automation."
        alert.addButton(withTitle: "Keep editing")
        alert.beginSheetModal(for: window) { _ in sender.reply(toApplicationShouldTerminate: false)
        }
        try? "shown".write(
          to: folder.appendingPathComponent("save-prompt-shown"), atomically: true, encoding: .utf8)
      }
      return .terminateLater
    }
    return behavior == "refuse" ? .terminateCancel : .terminateNow
  }
}

@MainActor final class NativeFixTests {
  // The test executable also hosts the disposable AppKit fixture. A bundle flag
  // survives verified relaunch without command-line arguments or a runtime compiler.
  static func runFixtureIfRequested() -> Bool {
    if CommandLine.arguments.contains("--managed-task-fixture") {
      let memory = UnsafeMutableRawPointer.allocate(byteCount: 24 * 1024 * 1024, alignment: 4096)
      memory.initializeMemory(as: UInt8.self, repeating: 1, count: 24 * 1024 * 1024)
      withExtendedLifetime(memory) { while true { _ = Darwin.pause() } }
      return true
    }
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
  func testNativePolicyManagedTaskRestart() async throws {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      throw FixError.unavailable("The owned test executable is unavailable")
    }
    let began = Date()
    let kernelExecutablePath = LiveCollector.readProcess(getpid())?.path ?? executable.path
    let child = Process(); child.executableURL = executable
    child.arguments = ["--managed-task-fixture"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
      // Include a replacement whose launch succeeded before identity verification failed.
      for record in LiveCollector().collect().processes
      where record.ppid == getpid() && record.path == kernelExecutablePath
        && record.identity.startDate >= began.addingTimeInterval(-1) && record.uid == getuid()
      {
        try? LiveCollector.signal(record, force: true)
      }
      child.waitUntilExit()
    }
    var process: ProcessRecord?
    for _ in 0..<100 {
      if let record = LiveCollector.readProcess(child.processIdentifier),
        (record.footprint ?? 0) >= 16 * MiB
      {
        process = record; break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let process else {
      throw FixError.unavailable("Owned managed fixture did not become ready")
    }
    var settings = Settings().validated()
    settings.disabledBuiltIns = ["ChatGPT", "Codex", "Codex CLI"]
    settings.controlPreferences?.externalActionsEnabled = true
    let intervention = InterventionGate(), gate = AutomationGate(intervention: intervention)
    let engine = MonitoringEngine(settings: settings, history: nil, sink: { _ in })
    let runtime = NativeFixRuntime(engine: engine, gate: intervention, automationGate: gate)
    let coordinator = FixCoordinator(
      runtime: runtime, gate: intervention, exitSeconds: 5,
      verificationSeconds: 5, save: { _ in }, publish: { _ in }, automationGate: gate)
    let code = try ExecutableIdentity.capture(process.path)
    let rule = AutomationRule(
      label: "Owned disposable task", subject: .taskInstance,
      profileID: settings.activeProfile.id, configuration: settings.analysisSignature,
      owner: process.uid, instance: process.identity, executable: code, operation: .restartTask,
      trigger: .taskFootprint, footprintLimit: 16 * MiB,
      launch: ManagedLaunchSpecification(executable: code, arguments: ["--managed-task-fixture"]))
    gate.configure(
      context: AutomationContext(
        profileID: rule.profileID, configuration: rule.configuration,
        owner: rule.owner, enabled: true), rules: [rule])
    let sample = try await engine.freshSnapshot()
    let target = FixTarget(process: process, source: process)
    let permit = try gate.issue(
      rule: rule, episodeID: UUID(), target: target, token: intervention.current())
    _ = try await coordinator.executeAutomatic(
      rule: rule, permit: permit, target: target,
      snapshot: sample, settings: settings)
    for _ in 0..<150 {
      let current = await coordinator.current()
      if current?.phase == .finished { break }
      let sample = try await engine.freshSnapshot()
      await coordinator.observe(sample)
      try await Task.sleep(for: .milliseconds(30))
    }
    let result = await coordinator.current()
    if result?.result?.actionSucceeded != true {
      print("Native managed task result: \(result?.message ?? "No session")")
    }
    XCTAssertEqual(result?.authority, .policy)
    XCTAssertEqual(result?.approvedAction, .restartManagedTask)
    XCTAssertEqual(result?.phase, .finished)
    XCTAssertEqual(result?.result?.actionSucceeded, true)
    XCTAssertNotNil(result?.replacement)
    XCTAssertTrue(result?.replacement != process.identity)
    XCTAssertFalse(result?.forceConfirmed ?? true)
    XCTAssertTrue(LiveCollector.readProcess(process.identity.pid)?.identity != process.identity)
    XCTAssertEqual(gate.activePermitCount, 0)
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
      // A failed reopen can create a fixture before returning its identity to this test.
      for app in NSWorkspace.shared.runningApplications
      where app.bundleURL?.resolvingSymlinksInPath() == bundle {
        if let p = LiveCollector.readProcess(app.processIdentifier),
          URL(fileURLWithPath: p.path).resolvingSymlinksInPath().path.hasPrefix(
            dir.resolvingSymlinksInPath().path + "/")
        {
          owned.insert(p.identity)
        }
      }
      for identity in owned {
        if let p = LiveCollector.readProcess(identity.pid), p.identity == identity,
          URL(fileURLWithPath: p.path).resolvingSymlinksInPath().path.hasPrefix(
            dir.resolvingSymlinksInPath().path + "/")
        {
          try? LiveCollector.signal(p, force: true)
        }
      }
      for file
        in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
        ?? []
      where file.lastPathComponent.hasPrefix("readiness-") {
        if let path = try? String(contentsOf: file, encoding: .utf8) {
          let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
          if parent.path.hasPrefix("/private/tmp/ms-ready-")
            || parent.path.hasPrefix("/tmp/ms-ready-")
          {
            try? FileManager.default.removeItem(at: parent)
          }
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
    XCTAssertThrowsError(try service.validateDisposableTask(planTarget.process))
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
    let endpoint = try String(
      contentsOf: dir.appendingPathComponent("readiness-\(original.pid).txt"), encoding: .utf8)
    let proof = try await CooperativeReadiness.query(endpoint: endpoint, target: planTarget.process)
    XCTAssertTrue(proof.peerVerified && proof.idle && !proof.unsavedWork)
    let code = try ExecutableIdentity.capture(planTarget.process.path),
      settings = Settings().validated()
    let rule = AutomationRule(
      label: "Owned cooperative app", subject: .application,
      profileID: settings.activeProfile.id, configuration: settings.analysisSignature,
      owner: planTarget.process.uid, instance: nil, executable: code,
      application: planTarget.application,
      operation: .restartApplication, trigger: .sustainedPressure, cooperativeEndpoint: endpoint)
    let policy = AutomationGate(intervention: gate)
    policy.configure(
      context: AutomationContext(
        profileID: rule.profileID, configuration: rule.configuration,
        owner: rule.owner, enabled: true), rules: [rule])
    let permit = try policy.issue(
      rule: rule, episodeID: UUID(), target: planTarget, token: gate.current())
    let planID = UUID(); try policy.claim(permit, sessionID: UUID(), planID: planID)
    // The fixture owns the readiness contract and the only native target in this controlled gate test.
    try policy.effect(
      permit, planID: planID, target: original, operation: .restartApplication,
      stage: .primary, executable: code
    ) { _ in
      guard proof.expires > Date() else { throw FixError.invalidated("Fixture lease expired") }
      try service.perform(action: .restartApplication, target: planTarget, token: gate.current())
    }
    try await waitExit(original)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("quit.log").path))
    let replacement = try await service.relaunch(
      target: planTarget, token: gate.current(),
      policy: AutomationExecution(rule: rule, permit: permit), policyGate: policy,
      planID: planID, executable: try ExecutableIdentity.capture(code.path));
    policy.release(permit.id)
    owned.insert(replacement)
    XCTAssertTrue(replacement != original)
    XCTAssertNil(ProcessActionService.verifiedReplacement(planTarget.process, target: planTarget))
    var impostor = planTarget.process; impostor.identity.seconds += 1; impostor.uid += 1
    XCTAssertNil(ProcessActionService.verifiedReplacement(impostor, target: planTarget))
    impostor.uid = planTarget.process.uid; impostor.path = "/different/executable"
    XCTAssertNil(ProcessActionService.verifiedReplacement(impostor, target: planTarget))
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
    try "save".write(
      to: dir.appendingPathComponent("behavior.txt"), atomically: true, encoding: .utf8)
    let currentEndpoint = try String(
      contentsOf: dir.appendingPathComponent("readiness-\(replacement.pid).txt"), encoding: .utf8)
    let unsaved = try await CooperativeReadiness.query(
      endpoint: currentEndpoint, target: current.process)
    XCTAssertTrue(unsaved.unsavedWork)
    try service.perform(action: .quitApplication, target: current, token: gate.current())
    for _ in 0..<50 {
      if FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("save-prompt-shown").path)
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("save-prompt-shown").path))
    XCTAssertEqual(LiveCollector.readProcess(replacement.pid)?.identity, replacement)
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
