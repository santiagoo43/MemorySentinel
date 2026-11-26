import Darwin
import Foundation
import SentinelCore

private actor PolicyFixtureRuntime: FixRuntime {
  var sample: Snapshot
  let intervention: InterventionGate
  let policyGate: AutomationGate
  var effects = 0
  private var holdEffect = false
  private var effectRelease: CheckedContinuation<Void, Never>?
  init(sample: Snapshot, intervention: InterventionGate, policyGate: AutomationGate) {
    self.sample = sample; self.intervention = intervention; self.policyGate = policyGate
  }
  func freshSnapshot() -> Snapshot { sample.date = Date(); return sample }
  func resolve(process: ProcessRecord, in snapshot: Snapshot) -> FixTarget {
    FixTarget(process: process, source: process)
  }
  func validate(target: FixTarget, token: InterventionToken) throws {
    guard intervention.current() == token else { throw FixError.invalidated("Context changed") }
  }
  func perform(
    action: FixAction, target: FixTarget?, token: InterventionToken,
    forceConfirmed: Bool, plan: FixPlan
  ) async throws {
    if holdEffect {
      await withCheckedContinuation { effectRelease = $0 }
    }
    if let policy = plan.automation, let target {
      guard action == policy.rule.operation.action, !forceConfirmed, action != .forceQuit else {
        throw FixError.refused("Policy cannot Force Quit")
      }
      try policyGate.effect(
        policy.permit, planID: plan.id, target: target.id,
        operation: policy.rule.operation, stage: .primary, executable: policy.rule.executable
      ) { _ in
        try intervention.liveEffect(token: token) { effects += 1 }
      }
      sample.processes.removeAll { $0.identity == target.id }
    } else if action == .restartMonitoring {
      effects += 1; sample.system.pressure = .normal
    } else {
      throw FixError.refused("Unexpected fixture operation")
    }
  }
  func relaunch(target: FixTarget, token: InterventionToken) throws -> ProcessIdentity {
    throw FixError.refused("Manual relaunch was not requested")
  }
  func holdNextEffect() { holdEffect = true }
  func isWaitingForEffect() -> Bool { effectRelease != nil }
  func releaseEffect() {
    holdEffect = false
    effectRelease?.resume(); effectRelease = nil
  }
  func effectCount() -> Int { effects }
}

final class ReadinessTestServer: @unchecked Sendable {
  let directory: URL
  let path: String
  let descriptor: Int32
  init() throws {
    directory = URL(fileURLWithPath: "/private/tmp/ms-ready-\(UUID().uuidString)")
    path = directory.appendingPathComponent("r").path
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw FixError.unavailable("Fixture socket unavailable") }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: Array(path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
      close(descriptor); throw FixError.unavailable("Fixture socket bind failed")
    }
  }
  deinit { close(descriptor); try? FileManager.default.removeItem(at: directory) }
  func answer(mode requestedMode: String, modeURL: URL? = nil) -> Task<Void, Never> {
    Task.detached { [self] in
      var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&waiting, 1, 2000) > 0 else { return }
      let peer = accept(descriptor, nil, nil)
      guard peer >= 0 else { return }; defer { close(peer) }
      var noPipe: Int32 = 1
      setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
      var bytes = [UInt8](repeating: 0, count: 2048)
      waiting = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
      guard poll(&waiting, 1, 2000) > 0 else { return }
      let count = read(peer, &bytes, bytes.count)
      guard count > 0 else { print("Fixture readiness read failed: \(count)"); return }
      let request: ReadinessRequest
      do {
        request = try JSONDecoder().decode(ReadinessRequest.self, from: Data(bytes.prefix(count)))
      } catch { print("Fixture readiness request decode: \(error)"); return }
      let mode = modeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? requestedMode
      if mode == "timeout" { usleep(1_300_000); return }
      var reply = ReadinessResponse(
        nonce: request.nonce, identity: request.identity,
        idle: mode != "busy", unsavedWork: mode == "unsaved" || mode == "save",
        leaseMilliseconds: 2000)
      if mode == "nonce" { reply.nonce = UUID() }
      if mode == "identity" { reply.identity.seconds += 1 }
      guard var response = try? JSONEncoder().encode(reply) else { return }
      response.append(10)
      let sent = response.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
      if sent != response.count {
        print("Fixture readiness send failed: \(sent) / \(response.count)")
      }
      if mode != "closed" {
        // A cooperative peer stays connected until the client completes its kernel recheck.
        waiting = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        if poll(&waiting, 1, 1500) > 0 { _ = read(peer, &bytes, 1) }
      }
    }
  }
}

@MainActor final class AutomationIntegrationTests {
  func testPolicyExecutionAndRevocation() async throws {
    let (dir, _, settings, original, originalRule, _) = try AutomationTests().fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var snapshot = original; snapshot.date = Date()
    var rule = originalRule; rule.created = Date().addingTimeInterval(-20000);
    rule.expires = Date().addingTimeInterval(86400)
    for revoke in [false, true] {
      let intervention = InterventionGate(), gate = AutomationGate(intervention: intervention)
      var context = AutomationContext(
        profileID: rule.profileID, configuration: rule.configuration,
        owner: rule.owner, enabled: true)
      gate.configure(context: context, rules: [rule])
      let target = FixTarget(process: snapshot.processes[0], source: snapshot.processes[0])
      let permit = try gate.issue(
        rule: rule, episodeID: UUID(), target: target, token: intervention.current())
      let runtime = PolicyFixtureRuntime(
        sample: snapshot, intervention: intervention, policyGate: gate)
      if revoke { await runtime.holdNextEffect() }
      let coordinator = FixCoordinator(
        runtime: runtime, gate: intervention, exitSeconds: 10,
        verificationSeconds: 10, save: { _ in }, publish: { _ in }, automationGate: gate)
      let id = try await coordinator.executeAutomatic(
        rule: rule, permit: permit, target: target,
        snapshot: snapshot, settings: settings)
      let executing = await coordinator.current()
      XCTAssertEqual(executing?.authority, .policy)
      XCTAssertEqual(executing?.id, id)
      XCTAssertEqual(executing?.approvedAction, .terminateProcess)
      XCTAssertFalse(executing?.forceConfirmed ?? true)
      await coordinator.approve(
        sessionID: id, planID: executing!.plan!.id, action: .forceQuit, forceConfirmed: true)
      if revoke {
        // Revoke at the effect boundary, independent of scheduler speed or runner load.
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline {
          if await runtime.isWaitingForEffect() { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        guard await runtime.isWaitingForEffect() else {
          await runtime.releaseEffect()
          throw FixError.unavailable("The fixture did not reach its policy effect barrier.")
        }
        context.enabled = false; gate.configure(context: context, rules: [rule])
        await runtime.releaseEffect()
      }
      let finishDeadline = Date().addingTimeInterval(5)
      while Date() < finishDeadline {
        if !revoke {
          var sample = await runtime.freshSnapshot(); sample.date = Date()
          await coordinator.observe(sample)
        }
        if await coordinator.current()?.phase == .finished { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let finished = await coordinator.current()
      XCTAssertEqual(finished?.phase, .finished)
      XCTAssertEqual(await runtime.effectCount(), revoke ? 0 : 1)
      if revoke {
        XCTAssertEqual(finished?.result?.outcome, .needsAction)
        XCTAssertTrue(finished?.result?.message.contains("permission") ?? false)
      } else {
        XCTAssertEqual(finished?.phase, .finished)
        XCTAssertEqual(finished?.result?.targetResolved, true)
        XCTAssertEqual(finished?.result?.systemImproved, false)
        XCTAssertEqual(gate.activePermitCount, 0)
        let report = ReportBuilder.fix(finished!, followup: nil).markdown
        XCTAssertTrue(report.contains("Explicit automation rule"))
        XCTAssertFalse(report.contains(rule.executable.path))
        XCTAssertFalse(report.contains(rule.label))
      }
    }
  }
  func testDurableReservationAndNoReplay() async throws {
    let (dir, code, settings, original, originalRule, _) = try AutomationTests().fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var rule = originalRule; rule.created = Date().addingTimeInterval(-20000);
    rule.expires = Date().addingTimeInterval(86400)
    let store = ControlStore(directory: dir),
      coordinator = ControlCoordinator(store: ControlStore(directory: dir))
    await coordinator.restore(); try await coordinator.register(rule)
    let now = Date(); var snapshot = original
    for i in 0...12 {
      snapshot.date = now.addingTimeInterval(Double(i) * 5 - 60)
      _ = await coordinator.ingest(
        snapshot: snapshot, settings: settings, experience: ExperienceSummary(),
        uptime: Double(i) * 5, deliveryAllowed: false)
    }
    let episode = await coordinator.summary().active.first { $0.key == "system:memory" }!
    let attempt = try await coordinator.reserve(
      rule: rule, episode: episode, snapshot: snapshot,
      settings: settings, executable: code, currentUser: rule.owner, warmupSeconds: 60,
      manualBusy: false, now: now)
    XCTAssertEqual(try await store.load().attempts.first?.id, attempt.id)
    let restarted = ControlCoordinator(store: ControlStore(directory: dir))
    await restarted.restore()
    let restored = await restarted.summary()
    XCTAssertEqual(restored.attempts.first?.status, .interrupted)
    XCTAssertEqual(restored.attempts.first?.failed, true)
    XCTAssertNil(restored.episodes.first(where: { $0.id == episode.id })?.automaticAttemptID)
    XCTAssertNotNil(restored.episodes.first(where: { $0.id == episode.id })?.automaticFailure)
    do {
      _ = try await restarted.reserve(
        rule: rule, episode: episode, snapshot: snapshot,
        settings: settings, executable: code, currentUser: rule.owner, warmupSeconds: 60,
        manualBusy: false, now: now)
      XCTFail("An interrupted attempt must not be replayed")
    } catch {}
    await restarted.revoke(rule.id)
    XCTAssertEqual(await restarted.summary().rules.first?.enabled, false)
    await restarted.clearHistory()
    XCTAssertEqual(await restarted.summary().attempts.count, 1)
    XCTAssertEqual(await restarted.summary().rules.count, 1)
  }
  func testChangedPermissionReviewSurvivesRestart() async throws {
    let (dir, code, settings, snapshot, rule, episode) = try AutomationTests().fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let coordinator = ControlCoordinator(store: ControlStore(directory: dir))
    await coordinator.restore(); try await coordinator.register(rule)
    await coordinator.requireReview(rule, reason: "The exact executable changed.")
    await coordinator.requireReview(
      rule, reason: "Stale update must not replace the review reason.")
    let restarted = ControlCoordinator(store: ControlStore(directory: dir))
    await restarted.restore()
    let locked = await restarted.summary().rules.first!
    XCTAssertEqual(locked.revision, rule.revision + 1)
    XCTAssertEqual(locked.reviewReason, "The exact executable changed.")
    XCTAssertNotNil(AutomationTests().reason(locked, episode, snapshot, settings, code))
    var incomplete = locked; incomplete.reviewReason = nil;
    incomplete.executable.changedSeconds = nil
    XCTAssertNotNil(incomplete.configurationError)
    try await restarted.review(rule.id, now: snapshot.date)
    let reviewed = await restarted.summary().rules.first!
    XCTAssertNil(reviewed.reviewReason)
    XCTAssertEqual(reviewed.reviewedAt, snapshot.date)
  }
  func testSelfRepairBackoffAndStableRecovery() {
    var budget = SelfRepairBudget()
    budget.observe(healthy: false, uptime: 0)
    XCTAssertFalse(budget.reserve(uptime: 1))
    XCTAssertTrue(budget.reserve(uptime: 2))
    XCTAssertFalse(budget.reserve(uptime: 11))
    XCTAssertTrue(budget.reserve(uptime: 12))
    XCTAssertFalse(budget.reserve(uptime: 41))
    XCTAssertTrue(budget.reserve(uptime: 42))
    budget.observe(healthy: false, uptime: 400)
    XCTAssertFalse(budget.reserve(uptime: 500))
    budget.observe(healthy: true, uptime: 501)
    for i in 1...24 { budget.observe(healthy: true, uptime: 501 + Double(i) * 5) }
    XCTAssertEqual(budget.consecutive, 0)
    budget.observe(healthy: false, uptime: 626)
    XCTAssertTrue(budget.reserve(uptime: 628))
    budget.resetContinuity()
    XCTAssertNotNil(budget.reason(uptime: .nan))
  }
  func testCooperativeReadinessProtocol() async throws {
    let target = LiveCollector.readProcess(getpid())!
    for mode in ["ready", "busy", "unsaved", "nonce", "identity", "timeout"] {
      let server = try ReadinessTestServer(), started = ContinuousClock.now
      let task = server.answer(mode: mode)
      do {
        let proof = try await CooperativeReadiness.query(endpoint: server.path, target: target)
        XCTAssertTrue(["ready", "busy", "unsaved"].contains(mode))
        XCTAssertTrue(proof.peerVerified)
        XCTAssertEqual(proof.idle, mode != "busy")
        XCTAssertEqual(proof.unsavedWork, mode == "unsaved")
      } catch {
        if ["ready", "busy", "unsaved"].contains(mode) {
          XCTFail("Readiness \(mode): \(error.localizedDescription)")
        } else {
          XCTAssertTrue(["nonce", "identity", "timeout"].contains(mode))
        }
      }
      XCTAssertTrue(started.duration(to: .now) < .seconds(2))
      await task.value
    }
    let server = try ReadinessTestServer()
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: server.path)
    do {
      _ = try await CooperativeReadiness.query(endpoint: server.path, target: target)
      XCTFail("A publicly writable readiness socket must be rejected")
    } catch {}
  }
}
