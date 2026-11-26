import Foundation
import SentinelCore

@MainActor final class AutomationTests {
  let origin = Date(timeIntervalSince1970: 1_900_000_000)
  func fixture() throws -> (
    URL, ExecutableIdentity, Settings, Snapshot, AutomationRule, ProblemEpisode
  ) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AutomationIdentity-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("owned-fixture")
    try Data("disposable fixture bytes".utf8).write(to: file)
    let code = try ExecutableIdentity.capture(file.path)
    var settings = Settings().validated();
    settings.controlPreferences?.externalActionsEnabled = true
    var sample = ExperienceTests().sample(0)
    sample.date = origin.addingTimeInterval(600); sample.system.pressure = .warning
    sample.processes[0].path = code.path
    let target = sample.processes[0]
    let rule = AutomationRule(
      label: "Disposable fixture", subject: .taskInstance,
      profileID: settings.activeProfile.id, configuration: settings.analysisSignature,
      owner: target.uid, instance: target.identity, executable: code,
      operation: .stopTask, trigger: .sustainedPressure, now: origin.addingTimeInterval(-20000))
    var reducer = ProblemEpisodes()
    for i in 0...120 {
      _ = reducer.ingest(
        [
          ProblemSignal(
            key: "system:memory", label: "System", kind: .systemPressure,
            level: .warning, evidence: "fixture")
        ], date: origin.addingTimeInterval(Double(i) * 5),
        uptime: Double(i) * 5, interval: 5, complete: true, preferences: ControlPreferences(),
        deliveryAllowed: false)
    }
    return (dir, code, settings, sample, rule, reducer.active.first!)
  }
  func reason(
    _ rule: AutomationRule, _ episode: ProblemEpisode, _ snapshot: Snapshot,
    _ settings: Settings, _ code: ExecutableIdentity, journal: [AutomaticAttempt] = [],
    warmup: Double = 60,
    manual: Bool = false
  ) -> String? {
    AutomationEligibility.reason(
      rule: rule, episode: episode, snapshot: snapshot, settings: settings,
      journal: journal, executable: code, currentUser: rule.owner,
      now: origin.addingTimeInterval(600),
      warmupSeconds: warmup, manualBusy: manual)
  }
  func testExactIdentityAndLaunchSpecification() throws {
    let (dir, code, settings, snapshot, rule, episode) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertNil(reason(rule, episode, snapshot, settings, code))
    XCTAssertEqual(try ExecutableIdentity.capture(code.path), code)
    try code.validateCurrentMetadata()
    XCTAssertTrue(ManagedLaunchSpecification(executable: code, arguments: []).valid)
    XCTAssertFalse(ManagedLaunchSpecification(executable: code, arguments: ["a\0b"]).valid)
    XCTAssertFalse(
      ManagedLaunchSpecification(executable: code, arguments: [], directory: "relative").valid)
    try Data("replaced executable bytes".utf8).write(
      to: URL(fileURLWithPath: code.path), options: .atomic)
    let changed = try ExecutableIdentity.capture(code.path)
    XCTAssertThrowsError(try code.validateCurrentMetadata())
    XCTAssertTrue(changed != code)
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, changed))
    var restart = rule; restart.operation = .restartTask
    XCTAssertNotNil(restart.configurationError)
    restart.launch = ManagedLaunchSpecification(executable: code, arguments: ["/explicit/worker"])
    XCTAssertNil(restart.configurationError)
    XCTAssertEqual(
      Set(AutomaticOperation.allCases.map(\.rawValue)),
      Set(["stopTask", "restartTask", "restartApplication"]))
  }
  func testScopeFreshnessAndManualPriority() throws {
    let (dir, code, settings, snapshot, rule, episode) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var off = settings; off.controlPreferences?.externalActionsEnabled = false
    XCTAssertNotNil(reason(rule, episode, snapshot, off, code))
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, manual: true))
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, warmup: 59))
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, warmup: .nan))
    var replaced = snapshot; replaced.processes[0].identity.seconds += 1
    XCTAssertNotNil(reason(rule, episode, replaced, settings, code))
    replaced = snapshot; replaced.processes[0].uid += 1
    XCTAssertNotNil(reason(rule, episode, replaced, settings, code))
    replaced = snapshot; replaced.demo = true
    XCTAssertNotNil(reason(rule, episode, replaced, settings, code))
    replaced = snapshot; replaced.date = origin
    XCTAssertNotNil(reason(rule, episode, replaced, settings, code))
    replaced = snapshot; replaced.system.used = nil
    XCTAssertNotNil(reason(rule, episode, replaced, settings, code))
    var wrong = rule; wrong.profileID = UUID()
    XCTAssertNotNil(reason(wrong, episode, snapshot, settings, code))
    wrong = rule; wrong.configuration = "different context"
    XCTAssertNotNil(reason(wrong, episode, snapshot, settings, code))
    wrong = rule; wrong.enabled = false
    XCTAssertNotNil(reason(wrong, episode, snapshot, settings, code))
    wrong = rule; wrong.expires = origin
    XCTAssertNotNil(reason(wrong, episode, snapshot, settings, code))
    var bad = episode; bad.knownSeconds = .nan
    XCTAssertNotNil(reason(rule, bad, snapshot, settings, code))
    bad = episode; bad.key = "advisory-budget"
    XCTAssertNotNil(reason(rule, bad, snapshot, settings, code))
  }
  func testAttemptQuotasAndBreaker() throws {
    let (dir, code, settings, snapshot, rule, episode) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var attempt = AutomaticAttempt(
      rule: rule, episodeID: UUID(), now: snapshot.date.addingTimeInterval(-100))
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, journal: [attempt]))
    attempt.status = .finished
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, journal: [attempt]))
    attempt.created = snapshot.date.addingTimeInterval(-7200)
    XCTAssertNil(reason(rule, episode, snapshot, settings, code, journal: [attempt]))
    attempt.episodeID = episode.id
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, journal: [attempt]))
    attempt.episodeID = UUID(); attempt.failed = true
    var second = attempt; second.id = UUID();
    second.created = snapshot.date.addingTimeInterval(-8000)
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, journal: [attempt, second]))
    var reviewed = rule; reviewed.reviewedAt = snapshot.date
    XCTAssertNil(reason(reviewed, episode, snapshot, settings, code, journal: [attempt, second]))
    let other = (0..<3).map { i in
      var record = attempt; record.id = UUID(); record.failed = false
      record.subjectKey = "other-task:\(i)"; record.ruleID = UUID(); return record
    }
    XCTAssertNotNil(reason(rule, episode, snapshot, settings, code, journal: other))
  }
  func testOneUsePermitAndRevocation() throws {
    let (dir, code, settings, snapshot, rule, episode) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let intervention = InterventionGate(), gate = AutomationGate(intervention: intervention)
    var context = AutomationContext(
      profileID: settings.activeProfile.id, configuration: settings.analysisSignature,
      owner: rule.owner, enabled: true)
    let target = FixTarget(process: snapshot.processes[0], source: snapshot.processes[0])
    gate.configure(context: context, rules: [rule])
    let permit = try gate.issue(
      rule: rule, episodeID: episode.id, target: target,
      token: intervention.current(), now: snapshot.date)
    var calls = 0
    let plan = UUID()
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: plan, target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    try gate.claim(permit, sessionID: UUID(), planID: plan, now: snapshot.date)
    XCTAssertThrowsError(
      try gate.claim(permit, sessionID: UUID(), planID: UUID(), now: snapshot.date))
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: UUID(), target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: plan, target: target.id,
        operation: .restartTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: plan, target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in
        calls += 1; throw FixError.unavailable("Effect outcome is uncertain")
      })
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: plan, target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    XCTAssertThrowsError(
      try gate.effect(
        permit, planID: plan, target: target.id,
        operation: .stopTask, stage: .reopen, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    XCTAssertEqual(calls, 1)
    gate.release(permit.id)
    let second = try gate.issue(
      rule: rule, episodeID: UUID(), target: target,
      token: intervention.current(), now: snapshot.date)
    try gate.claim(second, sessionID: UUID(), planID: plan, now: snapshot.date)
    context.enabled = false; gate.configure(context: context, rules: [rule])
    XCTAssertEqual(gate.activePermitCount, 0)
    XCTAssertThrowsError(
      try gate.effect(
        second, planID: plan, target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    context.enabled = true; gate.configure(context: context, rules: [rule])
    let third = try gate.issue(
      rule: rule, episodeID: UUID(), target: target,
      token: intervention.current(), now: snapshot.date)
    try gate.claim(third, sessionID: UUID(), planID: plan, now: snapshot.date)
    intervention.invalidate()
    XCTAssertThrowsError(
      try gate.effect(
        third, planID: plan, target: target.id,
        operation: .stopTask, stage: .primary, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    XCTAssertEqual(calls, 1)
  }
  func testBoundedReopenAndContextChanges() throws {
    let (dir, code, settings, snapshot, original, episode) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var rule = original; rule.operation = .restartTask
    rule.launch = ManagedLaunchSpecification(executable: code, arguments: [])
    let intervention = InterventionGate(), gate = AutomationGate(intervention: intervention)
    var context = AutomationContext(
      profileID: settings.activeProfile.id,
      configuration: settings.analysisSignature, owner: rule.owner, enabled: true)
    let target = FixTarget(process: snapshot.processes[0], source: snapshot.processes[0])
    let plan = UUID(); var calls = 0
    func permit() throws -> AutomationPermit {
      gate.invalidate(); gate.configure(context: context, rules: [rule])
      let p = try gate.issue(
        rule: rule, episodeID: episode.id, target: target,
        token: intervention.current(), now: snapshot.date)
      try gate.claim(p, sessionID: UUID(), planID: plan, now: snapshot.date); return p
    }
    var p = try permit()
    XCTAssertThrowsError(
      try gate.effect(
        p, planID: plan, target: target.id,
        operation: .restartTask, stage: .reopen, executable: code, now: snapshot.date
      ) { _ in calls += 1 })
    try gate.effect(
      p, planID: plan, target: target.id, operation: .restartTask,
      stage: .primary, executable: code, now: snapshot.date
    ) { _ in calls += 1 }
    try gate.effect(
      p, planID: plan, target: target.id, operation: .restartTask,
      stage: .reopen, executable: code, now: snapshot.date.addingTimeInterval(40)
    ) { _ in calls += 1 }
    XCTAssertThrowsError(
      try gate.effect(
        p, planID: plan, target: target.id,
        operation: .restartTask, stage: .reopen, executable: code,
        now: snapshot.date.addingTimeInterval(41)
      ) { _ in calls += 1 })
    p = try permit()
    XCTAssertThrowsError(
      try gate.effect(
        p, planID: plan, target: target.id,
        operation: .restartTask, stage: .primary, executable: code,
        now: snapshot.date.addingTimeInterval(31)
      ) { _ in calls += 1 })
    for change in 0..<4 {
      p = try permit()
      switch change {
      case 0: context.manualBusy = true
      case 1: context.demo = true
      case 2: context.profileID = UUID()
      default: rule.revision += 1
      }
      gate.configure(context: context, rules: [rule])
      XCTAssertThrowsError(
        try gate.effect(
          p, planID: plan, target: target.id,
          operation: .restartTask, stage: .primary, executable: code, now: snapshot.date
        ) { _ in calls += 1 })
      context.manualBusy = false; context.demo = false;
      context.profileID = settings.activeProfile.id
    }
    p = try permit()
    try gate.effect(
      p, planID: plan, target: target.id, operation: .restartTask,
      stage: .primary, executable: code, now: snapshot.date
    ) { _ in calls += 1 }
    XCTAssertThrowsError(
      try gate.effect(
        p, planID: plan, target: target.id,
        operation: .restartTask, stage: .reopen, executable: code,
        now: snapshot.date.addingTimeInterval(46)
      ) { _ in calls += 1 })
    XCTAssertEqual(calls, 3)
  }
}
