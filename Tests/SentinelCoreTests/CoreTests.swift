import Foundation
import SentinelCore

@MainActor
final class CoreTests {
  let origin = Date(timeIntervalSince1970: 1_800_000_000)
  func record(
    _ pid: Int32, _ start: UInt64, parent: Int32 = 1, path: String = "/tmp/node",
    bundle: String? = nil
  ) -> ProcessRecord {
    ProcessRecord(
      identity: .init(pid: pid, seconds: start), ppid: parent,
      name: URL(fileURLWithPath: path).lastPathComponent, path: path, bundleID: bundle,
      footprint: GiB)
  }
  func testGenericRuntimeRequiresEvidence() {
    let values = [
      record(10, 10), record(11, 11, path: "/tmp/codex"), record(12, 12, path: "/tmp/codex-ish"),
    ]
    let result = Classifier.classify(values, settings: Settings())
    XCTAssertTrue(result.allSatisfy { $0.group == nil })
    XCTAssertTrue(result[1].uncertain)
  }
  func testBundleAndAncestryAndExcludedProcess() {
    let values = [
      record(10, 10, path: "/Apps/Codex", bundle: "com.openai.codex"), record(11, 11, parent: 10),
      record(12, 12, parent: 11),
    ]
    let result = Classifier.classify(values, settings: Settings())
    XCTAssertEqual(result.map(\.group), ["Codex", "Codex", "Codex"])
    var settings = Settings()
    settings.excludedPaths = ["/tmp/node"]
    XCTAssertNil(Classifier.classify(values, settings: settings)[1].group)
  }
  func testNewerParentAndGroupDoNotEstablishAncestry() {
    var root = record(10, 30, path: "/Apps/Codex", bundle: "com.openai.codex")
    root.pgid = 10
    var child = record(11, 20, parent: 10)
    child.pgid = 10
    XCTAssertNil(Classifier.classify([root, child], settings: Settings())[1].group)
  }
  func testCustomExactPath() {
    var settings = Settings()
    settings.watchRules = [.init(label: "My worker", value: "/tmp/node", kind: .executable)]
    XCTAssertEqual(Classifier.classify([record(4, 2)], settings: settings)[0].group, "My worker")
    XCTAssertFalse(Classifier.isCodexCLI("/tmp/codex"))
    XCTAssertTrue(Classifier.isCodexCLI("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"))
  }
  func testRegressionWindowsAndBound() {
    var window = TrendWindow()
    for i in 0..<1000 {
      window.append(
        date: origin.addingTimeInterval(Double(i) * 2), value: GiB + Double(i) * 2 * MiB)
    }
    XCTAssertEqual(window.slope(seconds: 60)! / MiB, 60, accuracy: 0.001)
    XCTAssertEqual(window.slope(seconds: 300)! / MiB, 60, accuracy: 0.001)
    XCTAssertLessThanOrEqual(window.readings.count, 460)
    window.append(date: origin.addingTimeInterval(5000), value: GiB)
    XCTAssertNil(window.slope(seconds: 60))
  }
  func testHysteresisAndCriticalBypass() {
    var latch = RiskLatch()
    XCTAssertEqual(latch.update(.warning), .normal)
    XCTAssertEqual(latch.update(.warning), .normal)
    XCTAssertEqual(latch.update(.warning), .warning)
    for _ in 0..<5 { XCTAssertEqual(latch.update(.normal), .warning) }
    XCTAssertEqual(latch.update(.normal), .normal)
    XCTAssertEqual(latch.update(.critical, immediate: true), .critical)
  }
  func testCooldownPerIdentityAndEscalation() {
    var gate = AlertGate()
    XCTAssertTrue(gate.permits(key: "a", level: .warning, date: origin, cooldown: 300))
    XCTAssertFalse(
      gate.permits(key: "a", level: .warning, date: origin.addingTimeInterval(5), cooldown: 300))
    XCTAssertTrue(
      gate.permits(key: "a", level: .critical, date: origin.addingTimeInterval(6), cooldown: 300))
    XCTAssertTrue(
      gate.permits(key: "b", level: .warning, date: origin.addingTimeInterval(7), cooldown: 300))
    XCTAssertTrue(
      gate.permits(key: "a", level: .warning, date: origin.addingTimeInterval(400), cooldown: 300))
  }
  func testAllScenariosAndPIDReuse() {
    for scenario in SimulationScenario.allCases {
      var analyzer = Analyzer()
      var results: [Evaluation] = []
      for i in 0..<80 {
        results.append(
          analyzer.evaluate(
            Simulator().sample(step: i, scenario: scenario, origin: origin), settings: Settings(),
            demo: true))
      }
      let last = results.last!.snapshot
      switch scenario {
      case .stable: XCTAssertEqual(last.risk, .normal)
      case .gradualGrowth: XCTAssertGreaterThanOrEqual(last.risk, .warning)
      case .critical: XCTAssertEqual(results[0].snapshot.risk, .critical)
      case .warning: XCTAssertGreaterThanOrEqual(last.risk, .warning)
      case .processExit: XCTAssertTrue(last.processes.isEmpty)
      case .pidReuse, .newPID: XCTAssertNil(results[11].snapshot.processes[0].growth)
      case .uncertain:
        XCTAssertEqual(last.monitored.count, 0)
        XCTAssertTrue(last.processes[0].uncertain)
      case .missingMetrics:
        XCTAssertNil(last.monitoredBytes)
        XCTAssertEqual(last.system.pressure, .unavailable)
      case .suddenJump: XCTAssertTrue(results[12].snapshot.reasons.contains { $0.contains("jump") })
      }
    }
  }
  func testLiveMetrics() {
    let sample = LiveCollector().collect()
    XCTAssertGreaterThan(sample.system.total ?? 0, 0)
    XCTAssertFalse(sample.processes.isEmpty)
    XCTAssertTrue(
      sample.processes.contains { $0.identity.pid == ProcessInfo.processInfo.processIdentifier })
  }
  func testSettingsPersistenceAndValidation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(directory: dir)
    var settings = Settings()
    settings.interval = 2
    settings.cooldown = 1
    settings.warningFraction = 2
    try store.save(settings)
    let restored = store.load()
    XCTAssertEqual(restored.interval, 2)
    XCTAssertEqual(restored.cooldown, 60)
    XCTAssertGreaterThan(restored.criticalFraction, restored.warningFraction)
  }
  func testHistoryPersistenceRetentionExportAndDemoIsolation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    var analyzer = Analyzer()
    let now = Date()
    let raw = Simulator().sample(step: 0, scenario: .critical, origin: now)
    let result = analyzer.evaluate(raw, settings: Settings())
    try await store.append(result.snapshot, incidents: result.incidents, settings: Settings())
    let restored = try HistoryStore(directory: dir)
    let counts = try await restored.counts()
    XCTAssertEqual(counts[0], 1)
    XCTAssertGreaterThan(counts[2], 0)
    let context = try await store.context(around: now)
    XCTAssertEqual(context.count, 1)
    var demo = result.snapshot
    demo.demo = true
    try await store.append(demo, incidents: [], settings: Settings())
    let counts2 = try await store.counts()
    XCTAssertEqual(counts2[0], 1)
    try await store.export(to: dir.appendingPathComponent("export.json"), csv: false)
    try await store.export(to: dir.appendingPathComponent("export.csv"), csv: true)
    let exportedCSV = try String(
      contentsOf: dir.appendingPathComponent("export.csv"), encoding: .utf8)
    XCTAssertTrue(exportedCSV.contains("monitored_accounted_bytes"))
    try await store.prune(now: now.addingTimeInterval(91 * 86400), settings: Settings())
    let empty = try await store.counts()
    XCTAssertEqual(empty, [0, 0, 0])
    try await store.clear()
  }
  func testCorruptHistoryRecovery() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("history.sqlite"))
    let store = try HistoryStore(directory: dir)
    let message = await store.recoveryMessage
    XCTAssertNotNil(message)
    let counts = try await store.counts()
    XCTAssertEqual(counts, [0, 0, 0])
  }
  func testProtectedSignal() {
    if let parent = LiveCollector.readProcess(getppid()) {
      // Read-only validation: never send a signal to the test runner's real ancestors.
      XCTAssertThrowsError(try LiveCollector.validateTarget(parent))
    } else {
      XCTFail("Parent identity is unavailable for the ancestry guard test")
    }

    guard
      let p = LiveCollector().collect().processes.first(where: {
        $0.identity.pid == ProcessInfo.processInfo.processIdentifier
      })
    else { return XCTFail("self not found") }
    XCTAssertThrowsError(try LiveCollector.signal(p, force: false))
    var reused = p
    reused.identity.seconds += 1
    XCTAssertThrowsError(try LiveCollector.signal(reused, force: true))
  }
}

extension CoreTests {
  func testOrphanAttribution() {
    var analyzer = Analyzer()
    var raw = Simulator().sample(step: 0, scenario: .stable, origin: origin)
    raw.processes = [
      record(10, 10, path: "/Apps/Codex", bundle: "com.openai.codex"), record(11, 11, parent: 10),
    ]
    _ = analyzer.evaluate(raw, settings: Settings())
    raw.date = origin.addingTimeInterval(5); raw.processes = [record(11, 11)]
    let orphan = analyzer.evaluate(raw, settings: Settings()).snapshot.processes[0]
    XCTAssertEqual(orphan.group, "Codex"); XCTAssertTrue(orphan.evidence!.contains("parent exited"))
    raw.date = origin.addingTimeInterval(10); raw.processes[0].path = "/tmp/different"
    XCTAssertNil(analyzer.evaluate(raw, settings: Settings()).snapshot.processes[0].group)
  }
  func testLongRunAndBoundedIdentityHistory() {
    var analyzer = Analyzer()
    for step in 0..<12000 {
      var raw = Simulator().sample(step: step, scenario: .stable, origin: origin)
      raw.processes[0].identity.seconds += UInt64(step / 100)
      _ = analyzer.evaluate(raw, settings: Settings())
      if step % 1000 == 0 { XCTAssertEqual(analyzer.trackedIdentityCount, 1) }
    }
    var raw = Simulator().sample(step: 12000, scenario: .stable, origin: origin)
    raw.processes = (1...800).map { record(Int32($0 + 5000), UInt64($0)) }
    _ = analyzer.evaluate(raw, settings: Settings())
    XCTAssertEqual(analyzer.trackedIdentityCount, 512)
    raw.date = raw.date.addingTimeInterval(5); raw.processes = []
    _ = analyzer.evaluate(raw, settings: Settings());
    XCTAssertEqual(analyzer.trackedIdentityCount, 0)
  }
  func testPressureWarningIsVisibleWhileConfirming() {
    var analyzer = Analyzer()
    var raw = Simulator().sample(step: 0, scenario: .stable, origin: origin)
    raw.system.pressure = .warning
    XCTAssertEqual(analyzer.evaluate(raw, settings: Settings()).snapshot.risk, .elevated)
    for i in 1...2 {
      raw.date = origin.addingTimeInterval(Double(i) * 5);
      _ = analyzer.evaluate(raw, settings: Settings())
    }
    raw.date = origin.addingTimeInterval(15)
    XCTAssertEqual(analyzer.evaluate(raw, settings: Settings()).snapshot.risk, .warning)
  }
  func testEnginePressurePauseAndDemo() async throws {
    let recorder = UpdateRecorder()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    let engine = MonitoringEngine(settings: Settings(), history: store) { await recorder.add($0) }
    await engine.pressureEvent(.critical)
    let critical = await recorder.last(); XCTAssertEqual(critical?.snapshot.risk, .critical)
    await engine.pause(true); let before = await recorder.count()
    await engine.sample(); let after = await recorder.count(); XCTAssertEqual(before, after)
    await engine.pause(false)
    let counts = try await store.counts()
    await engine.mode(demo: true, scenario: .critical)
    let demo = await recorder.last(); XCTAssertTrue(demo!.snapshot.demo);
    XCTAssertFalse(demo!.incidents.isEmpty)
    let unchanged = try await store.counts(); XCTAssertEqual(counts, unchanged)
    await engine.mode(demo: false, scenario: .stable)
    let live = await recorder.last(); XCTAssertFalse(live!.snapshot.demo)
    await engine.stop()
  }
  func testStorageBudget() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    var analyzer = Analyzer(); let now = Date()
    var snapshot = analyzer.evaluate(
      Simulator().sample(step: 0, scenario: .stable, origin: now), settings: Settings()
    ).snapshot
    snapshot.reasons = [String(repeating: "x", count: 300_000)]
    for i in 0..<190 {
      snapshot.date = now.addingTimeInterval(Double(i) * 5);
      try await store.append(snapshot, incidents: [], settings: Settings())
    }
    try await store.prune(now: snapshot.date, settings: Settings())
    let bytes = try await store.detailedPayloadBytes(); XCTAssertLessThanOrEqual(bytes, 50_331_648)
    let counts = try await store.counts(); XCTAssertTrue(counts[0] < 190 && counts[0] > 100)
  }
}
actor UpdateRecorder {
  private var values: [EngineUpdate] = []
  func add(_ value: EngineUpdate) { values.append(value) }
  func last() -> EngineUpdate? { values.last }
  func count() -> Int { values.count }
}

extension CoreTests {
  func testMissingMetricsDoNotImplyRecoveryOrInventRAM() {
    var analyzer = Analyzer()
    var raw = Simulator().sample(step: 0, scenario: .critical, origin: origin)
    _ = analyzer.evaluate(raw, settings: Settings())
    raw.system.pressure = .unavailable
    raw.system.total = nil
    raw.processes[0].footprint = nil
    for i in 1...10 {
      raw.date = origin.addingTimeInterval(Double(i) * 5);
      _ = analyzer.evaluate(raw, settings: Settings())
    }
    raw.date = origin.addingTimeInterval(60)
    let result = analyzer.evaluate(raw, settings: Settings()).snapshot
    XCTAssertEqual(result.risk, .critical); XCTAssertNil(result.system.total)
    XCTAssertTrue(result.reasons.contains { $0.contains("suspended") })
  }
  func testControlledChildTermination() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = dir.appendingPathComponent("sentinel-sleep-fixture")
    let source = dir.appendingPathComponent("idle.c")
    try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(
      to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["clang", source.path, "-o", executable.path]
    try compiler.run()
    compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus, 0)
    for force in [false, true] {
      let child = Process(); child.executableURL = executable; child.arguments = ["30"];
      try child.run()
      defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
      guard
        let record = LiveCollector().collect().processes.first(where: {
          $0.identity.pid == child.processIdentifier
        })
      else { XCTFail("Fixture missing"); continue }
      try LiveCollector.signal(record, force: force)
      child.waitUntilExit()
      XCTAssertEqual(child.terminationReason, .uncaughtSignal)
      XCTAssertEqual(child.terminationStatus, force ? 9 : 15)
    }
  }
}

extension CoreTests {
  func testMinutePeakPreservesExactTimestamp() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 + 1)
    var analyzer = Analyzer()
    var snapshot = analyzer.evaluate(
      Simulator().sample(step: 0, scenario: .critical, origin: start), settings: Settings()
    ).snapshot
    try await store.append(snapshot, incidents: [], settings: Settings())
    snapshot.date = start.addingTimeInterval(10); snapshot.processes[0].footprint = GiB
    try await store.append(snapshot, incidents: [], settings: Settings())
    let points = try await store.timeline(since: Date().addingTimeInterval(-7200))
    XCTAssertEqual(points.count, 1)
    XCTAssertEqual(points[0].peak, 8 * GiB)
    XCTAssertEqual(points[0].peakDate, start)
  }
}
