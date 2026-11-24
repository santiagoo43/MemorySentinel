import Foundation
import SentinelCore

actor FixTestRuntime: FixRuntime {
  var sample: Snapshot
  let gate: InterventionGate
  var calls: [FixAction] = []
  var freshCalls = 0
  var launches = 0
  var quitExits = true
  var reject = false
  var delay: Double = 0
  var app = true
  var root: ProcessRecord?
  var sourceInRelated = true
  var nativeEffects = 0
  init(gate: InterventionGate, demo: Bool = false) {
    self.gate = gate
    var analyzer = Analyzer()
    sample =
      analyzer.evaluate(
        Simulator().sample(step: 0, scenario: .warning, origin: Date()), settings: Settings(),
        demo: demo
      ).snapshot
    sample.processesAvailable = true
    sample.system.pressure = .warning
    sample.system.swap = 2 * GiB
  }
  func freshSnapshot() async throws -> Snapshot {
    freshCalls += 1; if delay > 0 { try await Task.sleep(for: .seconds(delay)) };
    sample.date = Date(); return sample
  }
  func resolve(process: ProcessRecord, in snapshot: Snapshot) async throws -> FixTarget {
    guard let current = snapshot.processes.first(where: { $0.identity == process.identity }),
      current.path == process.path
    else { throw FixError.invalidated("Identity changed") }
    let application =
      app
      ? ApplicationIdentity(
        bundleID: current.bundleID ?? "test.app", bundlePath: "/Fixture.app",
        executablePath: (root ?? current).path, fingerprint: current.bundleID ?? "fixture") : nil
    return FixTarget(
      process: root ?? current, source: current, application: application,
      related: root == nil || !sourceInRelated ? [] : [current.identity])
  }
  func validate(target: FixTarget, token: InterventionToken) async throws {
    guard gate.current() == token else { throw FixError.invalidated("Mode changed") }
    if reject { throw FixError.refused("Protected target") }
  }
  func perform(
    action: FixAction, target: FixTarget?, token: InterventionToken, forceConfirmed: Bool,
    plan: FixPlan
  ) async throws {
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    guard gate.current() == token else { throw FixError.invalidated("Mode changed before effect") }
    if action == .forceQuit && !forceConfirmed { throw FixError.refused("No confirmation") }
    if reject { throw FixError.refused("Quit refused") }
    calls.append(action); if !token.demo { nativeEffects += 1 }
    if action.isProcessAction, quitExits, let target {
      sample.processes.removeAll { $0.identity == target.process.identity }
    }
    if action == .restartMonitoring {
      sample.system.used = 8 * GiB; sample.system.available = 10 * GiB;
      sample.system.pressure = .normal; sample.risk = .normal
    }
  }
  func relaunch(target: FixTarget, token: InterventionToken) async throws -> ProcessIdentity {
    guard gate.current() == token else { throw FixError.invalidated("Mode changed") }
    launches += 1
    var p = target.process; p.identity.pid += 1; p.identity.seconds += 1; p.footprint = GiB;
    p.growth = 0; p.risk = .normal
    sample.processes = [p]; return p.identity
  }
  func set(_ value: Snapshot) { sample = value }
  func options(
    exits: Bool = true, reject: Bool = false, delay: Double = 0, app: Bool = true,
    root: ProcessRecord? = nil, sourceInRelated: Bool = true
  ) {
    self.quitExits = exits; self.reject = reject; self.delay = delay; self.app = app;
    self.root = root; self.sourceInRelated = sourceInRelated
  }
  func healthy() {
    sample.system.pressure = .normal; sample.system.used = 8 * GiB;
    sample.system.available = 10 * GiB; sample.risk = .normal
  }
  func metricsMissing() { sample.system.used = nil }
  func counts() -> (Int, Int, Int) { (calls.count, launches, nativeEffects) }
  func actions() -> [FixAction] { calls }
}
@MainActor final class FixTests {
  func setup(
    exit: Double = 0.5, verify: Double = 1, demo: Bool = false,
    save: @escaping FixCoordinator.Save = { _ in }
  ) -> (FixCoordinator, FixTestRuntime, InterventionGate) {
    let gate = InterventionGate(); if demo { gate.invalidate(demo: true) }
    let runtime = FixTestRuntime(gate: gate, demo: demo)
    let coordinator = FixCoordinator(
      runtime: runtime, gate: gate, exitSeconds: exit, verificationSeconds: verify, save: save,
      publish: { _ in })
    return (coordinator, runtime, gate)
  }
  func waitPhase(_ coordinator: FixCoordinator, _ phase: FixPhase) async -> FixSession? {
    for _ in 0..<400 {
      if let value = await coordinator.current(), value.phase == phase { return value };
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Did not reach \(phase)"); return await coordinator.current()
  }
  func approve(_ coordinator: FixCoordinator, _ action: FixAction, force: Bool = false) async {
    guard let session = await coordinator.current(), let plan = session.plan else {
      XCTFail("Missing plan"); return
    }
    await coordinator.approve(
      sessionID: session.id, planID: plan.id, action: action, forceConfirmed: force)
  }
  func post(_ coordinator: FixCoordinator, _ runtime: FixTestRuntime, count: Int = 1) async throws {
    for _ in 0..<count {
      try await Task.sleep(for: .milliseconds(3));
      await coordinator.observe(try await runtime.freshSnapshot())
    }
  }
  func testPlanningAndManualSelection() async throws {
    let (c, r, _) = setup(); let s = try await r.freshSnapshot(); let id = s.processes[0].identity
    await c.prepare(origin: FixOrigin(identity: id), settings: Settings())
    let plan = await c.current()?.plan
    XCTAssertEqual(plan?.diagnosis.kind, .highFootprint);
    XCTAssertTrue(plan!.actions.contains(.quitApplication));
    XCTAssertTrue(plan!.actions.contains(.restartApplication))
    await c.cancel()
    await c.prepare(origin: FixOrigin(), settings: Settings()); let global = await c.current()?.plan
    XCTAssertNil(global?.target);
    XCTAssertFalse(global!.actions.contains(where: { $0.isProcessAction }));
    XCTAssertFalse(global!.candidates.isEmpty)
    await c.cancel()
    var low = s; low.system.pressure = .normal; low.system.diskFree = GiB;
    low.processes[0].footprint = GiB
    await r.set(low); await c.prepare(origin: FixOrigin(), settings: Settings())
    let disk = await c.current()?.plan; XCTAssertEqual(disk?.diagnosis.kind, .lowDisk);
    XCTAssertTrue(disk!.actions.contains(.storageSettings)); await c.cancel()
    await c.prepare(origin: FixOrigin(issue: .notifications), settings: Settings());
    let settingsPlan = await c.current()?.plan
    XCTAssertEqual(settingsPlan?.diagnosis.kind, .notifications);
    XCTAssertTrue(settingsPlan!.actions.contains(.notificationSettings)); await c.cancel()
  }
  func testOldIncidentAndPIDReuse() async throws {
    for mutation in 0..<4 {
      let (c, r, _) = setup(); var s = try await r.freshSnapshot();
      let original = s.processes[0].identity
      await c.prepare(
        origin: FixOrigin(incidentID: UUID(), identity: original), settings: Settings())
      switch mutation {
      case 0: s.processes[0].identity.seconds += 1;
      case 1: s.processes = [];
      case 2: s.processes[0].path = "/tmp/replaced";
      default: s.processes[0].footprint = MiB
      }
      await r.set(s); await approve(c, .quitApplication)
      let final = await c.current(); let counts = await r.counts()
      XCTAssertEqual(final?.phase, .finished); XCTAssertEqual(final?.result?.outcome, .needsAction);
      XCTAssertEqual(counts.0, 0)
      await c.prepare(
        origin: FixOrigin(incidentID: UUID(), identity: original), settings: Settings())
      let current = await c.current()?.plan
      if mutation < 2 {
        XCTAssertNil(current?.target);
        XCTAssertFalse(current!.actions.contains(where: { $0.isProcessAction }))
      }
      await c.cancel()
    }
  }
  func testProtectedAndInvalidatedPlans() async throws {
    let (c, r, gate) = setup(); let s = try await r.freshSnapshot()
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings())
    await r.options(reject: true); await approve(c, .quitApplication)
    XCTAssertEqual(await r.counts().0, 0)
    await r.options();
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings())
    gate.invalidate(demo: true); await approve(c, .quitApplication)
    XCTAssertEqual(await r.counts().0, 0);
    XCTAssertEqual(await c.current()?.result?.outcome, .needsAction)
    gate.invalidate(demo: false)
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings())
    let old = await c.current()!
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings())
    let replacement = await c.current()!
    await c.approve(
      sessionID: old.id, planID: old.plan!.id, action: .forceQuit, forceConfirmed: true)
    XCTAssertEqual(await r.counts().0, 0)
    XCTAssertEqual(await c.current()?.id, replacement.id)
    await c.cancel()
  }
  func testDuplicateApprovalAndCancellation() async throws {
    let (c, r, _) = setup(); var s = try await r.freshSnapshot(); s.date = Date()
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings())
    let session = await c.current()!; let plan = session.plan!
    async let first: Void = c.approve(
      sessionID: session.id, planID: plan.id, action: .quitApplication)
    async let second: Void = c.approve(
      sessionID: session.id, planID: plan.id, action: .quitApplication)
    _ = await (first, second)
    for _ in 0..<30 {
      if await r.counts().0 > 0 { break }; try await Task.sleep(for: .milliseconds(3))
    }
    XCTAssertEqual(await r.counts().0, 1); await c.cancel();
    XCTAssertEqual(await c.current()?.result?.outcome, .cancelled)
    let (c2, r2, _) = setup(); let s2 = try await r2.freshSnapshot()
    await c2.prepare(origin: FixOrigin(identity: s2.processes[0].identity), settings: Settings());
    await r2.options(delay: 0.04)
    await approve(c2, .quitApplication); await c2.cancel();
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(await r2.counts().0, 0)
  }
  func testRefusalTimeoutAndSeparateForceConfirmation() async throws {
    let (c, r, _) = setup(exit: 0.05); let s = try await r.freshSnapshot()
    await r.options(exits: false);
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
    await approve(c, .quitApplication)
    let timed = await waitPhase(c, .finished)
    XCTAssertEqual(timed?.result?.outcome, .needsAction);
    XCTAssertEqual(await r.actions(), [.quitApplication])
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
    await approve(c, .forceQuit)
    XCTAssertEqual(await c.current()?.phase, .awaitingApproval);
    XCTAssertEqual(await r.counts().0, 1)
    await approve(c, .forceQuit, force: true); _ = await waitPhase(c, .finished)
    XCTAssertEqual(await r.actions(), [.quitApplication, .forceQuit])
    let (c2, r2, _) = setup(); let s2 = try await r2.freshSnapshot();
    await c2.prepare(origin: FixOrigin(identity: s2.processes[0].identity), settings: Settings());
    await r2.options(reject: true); await approve(c2, .quitApplication)
    XCTAssertEqual(await c2.current()?.result?.outcome, .needsAction);
    XCTAssertEqual(await r2.counts().0, 0)
  }
  func testVerificationAndUnchangedSwap() async throws {
    for healthy in [true, false] {
      let (c, r, _) = setup(); let s = try await r.freshSnapshot()
      await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
      await approve(c, .quitApplication)
      try await Task.sleep(for: .milliseconds(15)); if healthy { await r.healthy() }
      try await post(c, r); _ = await waitPhase(c, .verifying); try await post(c, r, count: 3)
      let result = await c.current()?.result
      XCTAssertEqual(result?.actionSucceeded, true); XCTAssertEqual(result?.targetResolved, true);
      XCTAssertEqual(result?.systemImproved, healthy)
      XCTAssertEqual(result?.outcome, healthy ? .solved : .improved);
      XCTAssertEqual(result?.samples, 3); XCTAssertEqual(result?.after?.system.swap, s.system.swap)
    }
  }
  func testRestartReplacementAndRemainingHelpers() async throws {
    let (c, r, _) = setup(); let s = try await r.freshSnapshot(); let id = s.processes[0].identity
    await c.prepare(origin: FixOrigin(identity: id), settings: Settings());
    await approve(c, .restartApplication)
    try await Task.sleep(for: .milliseconds(15)); await r.healthy(); try await post(c, r)
    _ = await waitPhase(c, .verifying); try await post(c, r, count: 3)
    let result = await c.current(); XCTAssertEqual(result?.result?.outcome, .solved);
    XCTAssertTrue(result?.replacement != id); XCTAssertEqual(await r.counts().1, 1)
    let (c2, r2, _) = setup(); var s2 = try await r2.freshSnapshot(); var root = s2.processes[0];
    root.identity.pid += 99; root.footprint = MiB
    s2.processes.append(root); await r2.set(s2); await r2.options(root: root)
    await c2.prepare(origin: FixOrigin(identity: s2.processes[0].identity), settings: Settings());
    await approve(c2, .quitApplication)
    try await Task.sleep(for: .milliseconds(15)); try await post(c2, r2);
    _ = await waitPhase(c2, .verifying); try await post(c2, r2, count: 3)
    let remaining = await c2.current()?.result; XCTAssertEqual(remaining?.targetResolved, false);
    XCTAssertEqual(remaining?.remaining.count, 1); XCTAssertEqual(await r2.counts().0, 1)
  }
  func testMissingMetricsDeadlineAndGuidance() async throws {
    let (c, r, _) = setup(verify: 0.08); let s = try await r.freshSnapshot()
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
    await approve(c, .quitApplication)
    try await Task.sleep(for: .milliseconds(15)); try await post(c, r);
    _ = await waitPhase(c, .verifying)
    await r.metricsMissing(); try await post(c, r, count: 3)
    let result = await waitPhase(c, .finished);
    XCTAssertEqual(result?.result?.outcome, .unverifiable);
    XCTAssertNil(result?.result?.targetResolved)
    let (c2, r2, _) = setup();
    await c2.prepare(origin: FixOrigin(issue: .loginItem), settings: Settings());
    await approve(c2, .loginSettings)
    let guide = await waitPhase(c2, .finished);
    XCTAssertEqual(guide?.result?.outcome, .needsAction);
    XCTAssertNil(guide?.result?.targetResolved); XCTAssertEqual(await r2.counts().0, 1)
  }
  func testMonitoringRestartAndDemo() async throws {
    let (c, r, _) = setup(); await r.metricsMissing();
    await c.prepare(origin: FixOrigin(issue: .monitoringFailure), settings: Settings());
    await approve(c, .restartMonitoring)
    _ = await waitPhase(c, .verifying); try await post(c, r, count: 3);
    XCTAssertEqual(await c.current()?.result?.targetResolved, true)
    XCTAssertNil(await c.current()?.result?.systemImproved)
    let (demo, r2, _) = setup(demo: true); let s = try await r2.freshSnapshot()
    await demo.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
    await approve(demo, .quitApplication)
    try await Task.sleep(for: .milliseconds(15)); await r2.healthy(); try await post(demo, r2);
    _ = await waitPhase(demo, .verifying); try await post(demo, r2, count: 3)
    XCTAssertEqual(await demo.current()?.result?.outcome, .solved);
    XCTAssertEqual(await r2.counts().2, 0)
    let recorder = UpdateRecorder();
    let engine = MonitoringEngine(settings: Settings(), history: nil) { await recorder.add($0) }
    await engine.start(); await engine.start(); XCTAssertEqual(await engine.samplingLoopCount, 1)
    XCTAssertEqual(await engine.monitoringActivityCount, 1)
    try await engine.restart(); XCTAssertEqual(await engine.samplingLoopCount, 1)
    XCTAssertEqual(await engine.monitoringActivityCount, 1)
    await engine.pause(true)
    XCTAssertEqual(await engine.monitoringActivityCount, 0)
    await engine.pause(false)
    XCTAssertEqual(await engine.monitoringActivityCount, 1)
    await engine.pause(true); let fresh = try await engine.freshSnapshot();
    XCTAssertFalse(fresh.demo)
    await engine.mode(demo: true, scenario: .missingMetrics)
    await engine.pause(true)
    try await engine.simulate(action: .restartMonitoring, target: nil)
    XCTAssertEqual(await engine.isPaused, false)
    XCTAssertEqual(await engine.samplingLoopCount, 1)
    let recovered = try await engine.freshSnapshot()
    XCTAssertNotNil(recovered.system.swap)
    XCTAssertNotNil(recovered.system.used)
    XCTAssertEqual(recovered.system.pressure, .normal)
    XCTAssertEqual(recovered.monitored.count, 1)
    XCTAssertNotNil(recovered.monitored.first?.footprint)
    await engine.stop(); XCTAssertEqual(await engine.samplingLoopCount, 0)
    XCTAssertEqual(await engine.monitoringActivityCount, 0)
  }
  func testSystemComparisonRequiresMeasuredImprovement() async throws {
    // Fresh complete readings can prove monitoring recovery without inventing a
    // system comparison against an unavailable or incompatible baseline.
    for missing in 0..<5 {
      let (c, r, _) = setup()
      var before = try await r.freshSnapshot()
      switch missing {
      case 0: before.system.used = nil
      case 1: before.system.available = nil
      case 2: before.system.swap = nil
      case 3: before.system.pressure = .unavailable
      default: before.system.total = nil
      }
      await r.set(before)
      await c.prepare(origin: FixOrigin(issue: .monitoringFailure), settings: Settings())
      await approve(c, .restartMonitoring)
      _ = await waitPhase(c, .verifying)
      var after = try await r.freshSnapshot()
      after.system.total = 18 * GiB; after.system.swap = 2 * GiB
      await r.set(after); try await post(c, r, count: 3)
      XCTAssertEqual(await c.current()?.result?.targetResolved, true)
      XCTAssertNil(await c.current()?.result?.systemImproved)
    }
    let (stable, r, _) = setup(); await r.healthy()
    await stable.prepare(origin: FixOrigin(issue: .monitoringFailure), settings: Settings())
    await approve(stable, .restartMonitoring)
    _ = await waitPhase(stable, .verifying); try await post(stable, r, count: 3)
    XCTAssertEqual(await stable.current()?.result?.targetResolved, true)
    XCTAssertEqual(await stable.current()?.result?.systemImproved, false)

    let (worse, r2, _) = setup()
    await worse.prepare(origin: FixOrigin(issue: .monitoringFailure), settings: Settings())
    await approve(worse, .restartMonitoring); _ = await waitPhase(worse, .verifying)
    var critical = try await r2.freshSnapshot()
    critical.system.pressure = .critical; critical.risk = .critical
    await r2.set(critical); try await post(worse, r2, count: 3)
    XCTAssertEqual(await worse.current()?.result?.targetResolved, true)
    XCTAssertEqual(await worse.current()?.result?.systemImproved, false)
  }
  func testIncompleteMonitoringRepairCannotSucceed() async throws {
    let (c, r, _) = setup(verify: 0.12)
    await r.healthy(); var partial = try await r.freshSnapshot()
    partial.processes[0].footprint = nil; await r.set(partial)
    await c.prepare(origin: FixOrigin(), settings: Settings())
    let plan = await c.current()!.plan!
    XCTAssertEqual(plan.diagnosis.kind, .unavailableMetrics)
    XCTAssertTrue(plan.actions.contains(.restartMonitoring))
    await approve(c, .restartMonitoring); _ = await waitPhase(c, .verifying)
    try await post(c, r, count: 3)
    let result = await waitPhase(c, .finished)
    XCTAssertEqual(result?.result?.outcome, .unverifiable)
    XCTAssertNil(result?.result?.targetResolved)
  }
  func testFixHistoryRecoveryAndExport() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let history = try HistoryStore(directory: dir)
    let (c, r, _) = setup(save: { try await history.saveFix($0) });
    let s = try await r.freshSnapshot(); let incident = UUID()
    await c.prepare(
      origin: FixOrigin(incidentID: incident, identity: s.processes[0].identity),
      settings: Settings())
    let records = try await history.fixSessions(); XCTAssertEqual(records.count, 1);
    XCTAssertEqual(records[0].phase, .awaitingApproval)
    try await history.recoverInterruptedFixes(); let recovered = try await history.fixSessions()
    XCTAssertEqual(recovered[0].result?.outcome, .interrupted);
    XCTAssertEqual(recovered[0].origin.incidentID, incident)
    try await history.export(to: dir.appendingPathComponent("fix.json"), csv: false);
    try await history.export(to: dir.appendingPathComponent("fix.csv"), csv: true)
    let data =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: dir.appendingPathComponent("fix.json"))) as! [String: Any]
    XCTAssertEqual((data["fixSessions"] as? [Any])?.count, 1)
    let csv = try String(contentsOf: dir.appendingPathComponent("fix.csv"), encoding: .utf8);
    XCTAssertTrue(csv.contains("target_resolved")); XCTAssertTrue(csv.contains("interrupted"))
    let parser = Process(); parser.executableURL = URL(fileURLWithPath: "/usr/bin/env");
    parser.arguments = [
      "python3", "-c",
      "import csv,sys; rows=list(csv.reader(open(sys.argv[1]))); assert all(len(r)==17 for r in rows); assert rows[1][0]=='fix'",
      dir.appendingPathComponent("fix.csv").path,
    ]
    try parser.run(); parser.waitUntilExit(); XCTAssertEqual(parser.terminationStatus, 0)
    await c.cancel()
    let (demo, r2, _) = setup(demo: true, save: { try await history.saveFix($0) });
    let ds = try await r2.freshSnapshot();
    await demo.prepare(origin: FixOrigin(identity: ds.processes[0].identity), settings: Settings());
    let count = try await history.fixSessions(); XCTAssertEqual(count.count, 1); await demo.cancel()
  }
}

extension FixTests {
  func testExpiryIndividualSelectionAndFreshSamples() async throws {
    let gate = InterventionGate(); let r = FixTestRuntime(gate: gate)
    let expired = FixCoordinator(
      runtime: r, gate: gate, approvalSeconds: 0.01, save: { _ in }, publish: { _ in })
    let initial = try await r.freshSnapshot()
    await expired.prepare(
      origin: FixOrigin(identity: initial.processes[0].identity), settings: Settings())
    try await Task.sleep(for: .milliseconds(20)); await approve(expired, .quitApplication)
    XCTAssertEqual(await r.counts().0, 0);
    XCTAssertEqual(await expired.current()?.result?.outcome, .needsAction)
    let (c, r2, _) = setup(); var unknown = try await r2.freshSnapshot()
    unknown.processes[0].name = "node"; unknown.processes[0].group = nil;
    unknown.processes[0].bundleID = nil; unknown.processes[0].uncertain = true
    await r2.set(unknown); await c.prepare(origin: FixOrigin(), settings: Settings())
    let autoPlan = await c.current()!.plan!
    XCTAssertFalse(autoPlan.actions.contains(where: { $0.isProcessAction }))
    await c.cancel();
    await c.prepare(
      origin: FixOrigin(identity: unknown.processes[0].identity, individualProcess: true),
      settings: Settings())
    XCTAssertNil(await c.current()?.plan?.target?.application)
    let individualPlan = await c.current()!.plan!
    XCTAssertTrue(individualPlan.actions.contains(.terminateProcess))
    let unchanged = try await r2.freshSnapshot()
    XCTAssertNil(unchanged.processes[0].group)
    await approve(c, .terminateProcess); try await Task.sleep(for: .milliseconds(15));
    await r2.healthy(); try await post(c, r2); _ = await waitPhase(c, .verifying)
    let same = try await r2.freshSnapshot()
    await c.observe(same); await c.observe(same); await c.observe(same)
    XCTAssertEqual(await c.current()?.samples, 1); XCTAssertNil(await c.current()?.result)
    var old = same; old.date = Date().addingTimeInterval(-60); await c.observe(old);
    XCTAssertEqual(await c.current()?.samples, 1)
    try await post(c, r2, count: 2); XCTAssertEqual(await c.current()?.result?.outcome, .solved)
  }
  func testRapidSwapAndNewWorkersPreventFalseSuccess() async throws {
    let (c, r, _) = setup(); var s = try await r.freshSnapshot(); s.swapGrowth = 500 * MiB;
    await r.set(s)
    await c.prepare(origin: FixOrigin(identity: s.processes[0].identity), settings: Settings());
    await approve(c, .quitApplication)
    try await Task.sleep(for: .milliseconds(15)); await r.healthy(); try await post(c, r);
    _ = await waitPhase(c, .verifying); try await post(c, r, count: 3)
    XCTAssertEqual(await c.current()?.result?.outcome, .improved)
    let (c2, r2, _) = setup(); let original = try await r2.freshSnapshot()
    await c2.prepare(
      origin: FixOrigin(identity: original.processes[0].identity), settings: Settings());
    await approve(c2, .restartApplication)
    try await Task.sleep(for: .milliseconds(15)); await r2.healthy(); try await post(c2, r2);
    _ = await waitPhase(c2, .verifying)
    var restarted = try await r2.freshSnapshot(); var helper = restarted.processes[0];
    helper.identity.pid += 100; helper.ppid = restarted.processes[0].identity.pid;
    helper.footprint = 8 * GiB; restarted.processes.append(helper); await r2.set(restarted)
    try await post(c2, r2, count: 3)
    XCTAssertEqual(await c2.current()?.result?.targetResolved, false)
    let workerResult = await c2.current()?.result
    XCTAssertTrue(workerResult?.outcome != .solved)
    XCTAssertEqual(workerResult?.remaining.first?.identity, helper.identity)
  }
}

extension FixTests {
  func testModeProvenanceAndAuditOrdering() async throws {
    let (c, r, gate) = setup(demo: true); let initial = try await r.freshSnapshot()
    await c.prepare(
      origin: FixOrigin(identity: initial.processes[0].identity), settings: Settings())
    let origin = await c.current()!.origin
    XCTAssertEqual(origin.demoSource, true)
    await c.cancel(); gate.invalidate(demo: false)
    var live = initial; live.demo = false; await r.set(live)
    await c.prepare(origin: origin, settings: Settings())
    XCTAssertEqual(await c.current()?.phase, .finished); XCTAssertEqual(await r.counts().2, 0)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let history = try HistoryStore(directory: dir)
    let (c2, r2, _) = setup(); let current = try await r2.freshSnapshot()
    await c2.prepare(
      origin: FixOrigin(identity: current.processes[0].identity), settings: Settings())
    let pending = await c2.current()!; await c2.cancel(); let final = await c2.current()!
    try await history.saveFix(final); try await history.saveFix(pending)
    let restored = try await history.fixSessions()
    XCTAssertEqual(restored[0].phase, .finished);
    XCTAssertEqual(restored[0].result?.outcome, .cancelled)
    let recorder = UpdateRecorder()
    let engine = MonitoringEngine(settings: Settings(), history: nil) { await recorder.add($0) }
    await engine.start()
    let values = try await withThrowingTaskGroup(of: Snapshot.self) { group in
      for _ in 0..<4 { group.addTask { try await engine.freshSnapshot() } }
      var result: [Snapshot] = []; for try await value in group { result.append(value) };
      return result
    }
    XCTAssertEqual(values.count, 4); XCTAssertEqual(Set(values.map(\.date)).count, 4);
    XCTAssertEqual(await engine.samplingLoopCount, 1)
    await engine.stop()
    let (selectedCoordinator, selectedRuntime, _) = setup()
    var large = try await selectedRuntime.freshSnapshot()
    let selectedTarget = large.processes[0]
    large.processes =
      (0..<600).map { index in
        var process = selectedTarget
        process.identity.pid += Int32(index + 100)
        process.footprint = MiB; process.growth = 0; process.risk = .normal
        return process
      } + [selectedTarget]
    await selectedRuntime.set(large)
    await selectedCoordinator.prepare(
      origin: FixOrigin(identity: selectedTarget.identity), settings: Settings())
    let selectedPlan = await selectedCoordinator.current()?.plan
    XCTAssertEqual(selectedPlan?.diagnosis.identity, selectedTarget.identity)
    XCTAssertEqual(selectedPlan?.diagnosis.kind, .highFootprint)
    await selectedCoordinator.cancel()
  }
}

extension FixTests {
  func testUnreadablePIDsNeverProveRecovery() async throws {
    let (c, r, _) = setup(exit: 2)
    let initial = try await r.freshSnapshot(); let identity = initial.processes[0].identity
    await c.prepare(origin: FixOrigin(identity: identity), settings: Settings())
    await approve(c, .quitApplication)
    try await Task.sleep(for: .milliseconds(15))
    var unreadable = try await r.freshSnapshot(); unreadable.unreadablePIDs = [identity.pid]
    await r.set(unreadable); try await post(c, r, count: 3)
    XCTAssertEqual(await c.current()?.phase, .executing)
    XCTAssertNil(await c.current()?.result)
    await c.cancel()
    await c.prepare(origin: FixOrigin(identity: identity), settings: Settings())
    let unreadablePlan = await c.current()!.plan!
    XCTAssertEqual(unreadablePlan.diagnosis.kind, .unavailableMetrics)
    XCTAssertFalse(unreadablePlan.actions.contains(where: \.isProcessAction))
    await c.cancel()

    let (c2, r2, _) = setup(exit: 2, verify: 0.12)
    var snapshot = try await r2.freshSnapshot(); let source = snapshot.processes[0]
    var root = source; root.identity.pid += 99; root.footprint = MiB
    snapshot.processes.append(root); await r2.set(snapshot); await r2.options(root: root)
    await c2.prepare(origin: FixOrigin(identity: source.identity), settings: Settings())
    await approve(c2, .quitApplication); try await Task.sleep(for: .milliseconds(15))
    try await post(c2, r2); _ = await waitPhase(c2, .verifying)
    await r2.healthy(); var missingWorker = try await r2.freshSnapshot()
    missingWorker.processes = []; missingWorker.unreadablePIDs = [source.identity.pid]
    await r2.set(missingWorker); try await post(c2, r2, count: 3)
    let result = await waitPhase(c2, .finished)
    XCTAssertEqual(result?.result?.outcome, .unverifiable)
    XCTAssertNil(result?.result?.targetResolved)

    var raw = Simulator().sample(step: 0, scenario: .stable, origin: Date())
    raw.unreadablePIDs = [12345]; var analyzer = Analyzer()
    let measured = analyzer.evaluate(raw, settings: Settings()).snapshot
    XCTAssertEqual(measured.unreadablePIDs, [12345])
    var legacy =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(measured)) as! [String: Any]
    legacy.removeValue(forKey: "unreadablePIDs")
    let decoded = try JSONDecoder().decode(
      Snapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(decoded.unreadablePIDs)
  }
}

extension FixTests {
  func testSelectedSourceSurvivesRelationLimit() async throws {
    let (c, r, _) = setup()
    var snapshot = try await r.freshSnapshot(); let source = snapshot.processes[0]
    var root = source; root.identity.pid += 99; root.footprint = MiB
    snapshot.processes.append(root); await r.set(snapshot)
    await r.options(root: root, sourceInRelated: false)
    await c.prepare(origin: FixOrigin(identity: source.identity), settings: Settings())
    await approve(c, .quitApplication); try await Task.sleep(for: .milliseconds(15))
    await r.healthy(); try await post(c, r); _ = await waitPhase(c, .verifying)
    var changedOwner = try await r.freshSnapshot()
    changedOwner.processes[0].uid += 1
    await r.set(changedOwner)
    try await post(c, r, count: 3)
    let result = await c.current()?.result
    XCTAssertEqual(result?.targetResolved, false)
    XCTAssertEqual(result?.remaining.first?.identity, source.identity)
    XCTAssertTrue(result?.outcome != .solved)
  }
}

extension FixTests {
  func testMissingWorkerTrendNeverProvesRecovery() async throws {
    let (c, r, _) = setup(exit: 2, verify: 0.12)
    var original = try await r.freshSnapshot()
    original.processes[0].footprint = GiB; original.processes[0].growth = 200 * MiB
    await r.set(original)
    await c.prepare(
      origin: FixOrigin(identity: original.processes[0].identity, issue: .sustainedGrowth),
      settings: Settings())
    await approve(c, .restartApplication)
    try await Task.sleep(for: .milliseconds(15)); await r.healthy(); try await post(c, r)
    _ = await waitPhase(c, .verifying)
    var restarted = try await r.freshSnapshot(); var worker = restarted.processes[0]
    worker.identity.pid += 100; worker.ppid = restarted.processes[0].identity.pid
    worker.footprint = MiB; worker.growth = nil; worker.risk = .normal
    restarted.processes.append(worker); await r.set(restarted)
    try await post(c, r, count: 3)
    let result = await waitPhase(c, .finished)
    XCTAssertEqual(result?.result?.outcome, .unverifiable)
    XCTAssertNil(result?.result?.targetResolved)
  }

  func testReplacementMetadataMustRemainComparable() async throws {
    for change in 0..<3 {
      let (c, r, _) = setup(exit: 2, verify: 0.12)
      let initial = try await r.freshSnapshot()
      await c.prepare(
        origin: FixOrigin(identity: initial.processes[0].identity), settings: Settings())
      await approve(c, .restartApplication); try await Task.sleep(for: .milliseconds(15))
      await r.healthy(); try await post(c, r); _ = await waitPhase(c, .verifying)
      var changed = try await r.freshSnapshot()
      if change == 0 { changed.processes[0].path = "/Changed/executable" }
      if change == 1 { changed.processes[0].uid += 1 }
      if change == 2 { changed.processes[0].bundleID = "unrelated.application" }
      await r.set(changed); try await post(c, r, count: 3)
      let result = await waitPhase(c, .finished)
      XCTAssertEqual(result?.result?.outcome, .unverifiable)
      XCTAssertNil(result?.result?.targetResolved)
    }
  }
}
