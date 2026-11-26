import Foundation
import SentinelCore

@MainActor final class ControlTests {
  let origin = Date(timeIntervalSince1970: 1_900_000_000)
  func signal(key: String = "app:editor", critical: Bool = false, snoozed: Bool = false)
    -> ProblemSignal
  {
    ProblemSignal(
      key: key, label: "Editor", kind: .highFootprint,
      level: critical ? .critical : .warning, evidence: "Measured footprint remains high.",
      identities: [ProcessIdentity(pid: 100, seconds: 1)], criticalSystem: critical,
      humanReason: critical ? "System pressure is critical. Review current workloads." : nil,
      snoozed: snoozed)
  }
  func observe(
    _ reducer: inout ProblemEpisodes, _ signals: [ProblemSignal], at seconds: Double,
    preferences: ControlPreferences = ControlPreferences(), complete: Bool = true
  ) -> [EpisodeNotice] {
    reducer.ingest(
      signals, date: origin.addingTimeInterval(seconds), uptime: seconds,
      interval: 5, complete: complete, preferences: preferences, deliveryAllowed: true)
  }
  func testUnchangedWarningAndRestart() throws {
    var quiet = ProblemEpisodes(), count = 0
    for i in 0...720 { count += observe(&quiet, [signal()], at: Double(i) * 5).count }
    XCTAssertEqual(count, 0); XCTAssertEqual(quiet.active.count, 1)
    XCTAssertEqual(quiet.active.first?.status, .warning)
    var settings = ControlPreferences(); settings.warningBanners = true
    var reducer = ProblemEpisodes(), notices: [EpisodeNotice] = []
    for i in 0...720 {
      var changedPID = signal();
      changedPID.identities = [ProcessIdentity(pid: Int32(100 + i), seconds: UInt64(i))]
      notices += observe(&reducer, [changedPID], at: Double(i) * 5, preferences: settings)
      if i == 300 {
        reducer = try JSONDecoder().decode(
          ProblemEpisodes.self, from: JSONEncoder().encode(reducer))
      }
    }
    XCTAssertEqual(notices.count, 1); XCTAssertEqual(notices.first?.kind, .warning)
    XCTAssertEqual(reducer.active.count, 1); XCTAssertFalse(notices.first?.sound ?? true)
    XCTAssertEqual(reducer.active.first?.knownSeconds ?? -1, 3600, accuracy: 0.001)
  }
  func testCriticalEscalationReminderAndReviewing() {
    var settings = ControlPreferences(); settings.warningBanners = true
    var reducer = ProblemEpisodes(), notices: [EpisodeNotice] = []
    for i in 0...160 {
      notices += observe(
        &reducer, [signal(critical: i >= 20)], at: Double(i) * 5, preferences: settings)
    }
    XCTAssertEqual(notices.map(\.kind), [.warning, .critical, .reminder])
    XCTAssertEqual(reducer.active.count, 1)
    var reviewed = ProblemEpisodes(), reviewedNotices: [EpisodeNotice] = []
    for i in 0...100 {
      reviewedNotices += observe(
        &reviewed, [signal(critical: true, snoozed: true)], at: Double(i) * 5)
      if let id = reviewed.active.first?.id { reviewed.reviewing(id, value: true) }
    }
    XCTAssertEqual(reviewedNotices.map(\.kind), [.critical])
    XCTAssertEqual(reviewed.active.first?.status, .actionRequired)
  }
  func testRecoveryGapsAndNewEpisode() {
    var reducer = ProblemEpisodes()
    _ = observe(&reducer, [signal(critical: true)], at: 0)
    let id = reducer.active.first?.id
    for i in 1...30 { _ = observe(&reducer, [], at: Double(i) * 5, complete: false) }
    XCTAssertEqual(reducer.active.first?.status, .evidenceUnavailable)
    for i in 31...54 { _ = observe(&reducer, [], at: Double(i) * 5) }
    XCTAssertEqual(reducer.active.count, 1)
    _ = observe(&reducer, [], at: 275)
    XCTAssertEqual(reducer.active.count, 0)
    let notices = observe(&reducer, [signal(critical: true)], at: 280)
    XCTAssertEqual(notices.count, 1); XCTAssertTrue(reducer.active.first?.id != id)
    var bouncing = ProblemEpisodes(), settings = ControlPreferences();
    settings.warningBanners = true
    for i in 0...60 {
      let present = i % 10 < 6
      XCTAssertTrue(
        observe(&bouncing, present ? [signal()] : [], at: Double(i) * 5, preferences: settings)
          .isEmpty)
    }
  }
  func testCorrelationBudgetsAndClockChanges() throws {
    var reducer = ProblemEpisodes(), settings = ControlPreferences(); settings.warningBanners = true
    var app = signal(); app.correlatedTo = "system:memory"
    for i in 0...12 {
      _ = observe(
        &reducer, [app, signal(key: "system:memory")], at: Double(i) * 5, preferences: settings)
    }
    XCTAssertEqual(reducer.active.count, 2)
    XCTAssertEqual(reducer.ordinaryNotices.count, 1)
    XCTAssertFalse(reducer.active.first { $0.key == app.key }?.warningNoticeSent ?? true)
    reducer.ordinaryNotices = [origin, origin, origin]
    let critical = observe(
      &reducer, [signal(key: "system:memory", critical: true)], at: 65, preferences: settings)
    XCTAssertEqual(critical.first?.kind, .critical)
    var restored = try JSONDecoder().decode(
      ProblemEpisodes.self, from: JSONEncoder().encode(reducer))
    let jumped = restored.ingest(
      [signal(key: "system:memory", critical: true)], date: origin.addingTimeInterval(-100),
      uptime: 70,
      interval: 5, complete: true, preferences: settings, deliveryAllowed: true)
    XCTAssertTrue(jumped.isEmpty); XCTAssertEqual(restored.active.count, 2)
    var lots = (0..<500).map { signal(key: "app:\($0)") }
    lots.append(signal(key: "system:memory", critical: true))
    var bounded = ProblemEpisodes()
    let urgent = observe(&bounded, lots, at: 0)
    XCTAssertEqual(urgent.first?.kind, .critical);
    XCTAssertLessThanOrEqual(bounded.episodes.count, 128)
    XCTAssertTrue(bounded.active.contains { $0.key == "system:memory" })
    XCTAssertFalse(observe(&bounded, lots, at: 5).contains { $0.kind == .critical })
  }
  func testCancellationBudgetAndScopeCollisions() {
    var reducer = ProblemEpisodes(), preferences = ControlPreferences();
    preferences.warningBanners = true
    var sent: [EpisodeNotice] = []
    let signals = (0..<4).map { signal(key: "independent:\($0)") }
    for i in 0...12 {
      sent += observe(&reducer, signals, at: Double(i) * 5, preferences: preferences)
    }
    XCTAssertEqual(sent.count, 3); XCTAssertEqual(reducer.ordinaryNotices.count, 3)
    reducer.cancelReservation(sent[0])
    XCTAssertEqual(reducer.ordinaryNotices.count, 2)
    let retry = observe(&reducer, signals, at: 65, preferences: preferences)
    XCTAssertEqual(retry.count, 1); XCTAssertEqual(reducer.ordinaryNotices.count, 3)
    XCTAssertTrue(observe(&reducer, signals, at: 70, preferences: preferences).isEmpty)
    let prefix = String(repeating: "long-root/", count: 100)
    XCTAssertTrue(signal(key: prefix + "one").key != signal(key: prefix + "two").key)
  }
  func testControlStoreLabelsAndRecovery() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ControlStore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ControlStore(directory: dir)
    var state = try await store.load()
    XCTAssertEqual(state.revision, 0)
    let original = process(100)
    state.name(original, value: "My private task")
    state.revision += 1; try await store.save(state, durable: true)
    let saved = try Data(contentsOf: store.url)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let restored = try await ControlStore(directory: dir).load()
    XCTAssertEqual(restored.label(for: original), "My private task")
    var reused = original; reused.identity.seconds += 1
    XCTAssertNil(restored.label(for: reused))
    var stale = state; stale.revision = 0
    do { try await store.save(stale); XCTFail("Stale control state must fail") } catch {}
    XCTAssertEqual(try Data(contentsOf: store.url), saved)
    var oversized = state
    oversized.activity = (0...500).map { _ in
      ControlActivity(kind: .observation, title: "fixture", detail: "bounded")
    }
    oversized.revision += 1
    do { try await store.save(oversized); XCTFail("Oversized state must fail") } catch {}
    XCTAssertEqual(try Data(contentsOf: store.url), saved)
    let future = Data("{\"schemaVersion\":99}".utf8)
    try future.write(to: store.url, options: .atomic)
    let incompatible = ControlStore(directory: dir)
    do {
      _ = try await incompatible.load(); XCTFail("Unsupported version must remain unavailable")
    } catch {}
    do {
      try await incompatible.save(state); XCTFail("Unsupported state must not be overwritten")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: store.url), future)
    state.schemaVersion = 0
    let legacy = try JSONEncoder().encode(state); try legacy.write(to: store.url, options: .atomic)
    let migratedStore = ControlStore(directory: dir)
    var migrated = try await migratedStore.load()
    XCTAssertEqual(migrated.schemaVersion, 1)
    XCTAssertEqual(
      try Data(contentsOf: dir.appendingPathComponent("control-state.pre-v1.json")), legacy)
    migrated.revision += 1; try await migratedStore.save(migrated)
    let migratedAgain = try await ControlStore(directory: dir).load()
    XCTAssertEqual(migratedAgain.label(for: original), "My private task")
  }
  func testCoordinatorPersistenceAndDemoIsolation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ControlCoordinator-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ControlStore(directory: dir), coordinator = ControlCoordinator(store: store)
    var settings = Settings().validated(); settings.controlPreferences?.warningBanners = true
    var sample = ExperienceTests().sample(0)
    sample.processes[0].applicationMetadata = application(10, name: "Editor").applicationMetadata
    sample.processes[0].risk = .warning
    var notices: [EpisodeNotice] = []
    for i in 0...14 {
      sample.date = origin.addingTimeInterval(Double(i) * 5)
      let update = await coordinator.ingest(
        snapshot: sample, settings: settings, experience: ExperienceSummary(),
        uptime: Double(i) * 5, deliveryAllowed: true)
      notices += update.notices
    }
    XCTAssertEqual(notices.count, 1)
    await coordinator.name(sample.processes[0], value: "private-label")
    let before = try Data(contentsOf: store.url)
    let demo = ControlCoordinator(store: store, demo: true)
    sample.demo = true
    let demoUpdate = await demo.ingest(
      snapshot: sample, settings: settings, experience: ExperienceSummary(), uptime: 70,
      deliveryAllowed: true)
    XCTAssertTrue(demoUpdate.notices.isEmpty)
    await demo.name(sample.processes[0], value: "demo-only")
    XCTAssertEqual(try Data(contentsOf: store.url), before)
    let restarted = ControlCoordinator(store: ControlStore(directory: dir))
    await restarted.restore()
    sample.demo = false; sample.date = origin.addingTimeInterval(75)
    let next = await restarted.ingest(
      snapshot: sample, settings: settings, experience: ExperienceSummary(), uptime: 75,
      deliveryAllowed: true)
    XCTAssertTrue(next.notices.isEmpty)
    XCTAssertEqual(next.summary.taskName(sample.processes[0]), "private-label")
    XCTAssertEqual(next.summary.active.count, 1)
  }
  func process(_ pid: Int32, parent: Int32 = 1, name: String = "node", seconds: UInt64 = 100)
    -> ProcessRecord
  {
    ProcessRecord(
      identity: ProcessIdentity(pid: pid, seconds: seconds), ppid: parent,
      name: name, path: "/runtime/\(name)", footprint: GiB)
  }
  func application(_ pid: Int32, name: String) -> ProcessRecord {
    var p = process(pid, name: name)
    p.path = "/Apps/\(name).app/Contents/MacOS/\(name)"
    p.applicationMetadata = ApplicationDescriptor(
      name: name, bundleID: "test.\(name)",
      bundlePath: "/Apps/\(name).app", executablePath: p.path)
    return p
  }
  func testApplicationAndHistoricalOrigin() {
    var resolver = AppIdentityResolver()
    let editor = application(10, name: "Editor"), terminal = application(20, name: "Terminal")
    var python = process(30, parent: 10, name: "python", seconds: 101)
    let node = process(40, parent: 20, seconds: 102)
    let values = resolver.resolve([editor, terminal, python, node], at: origin)
    XCTAssertEqual(values[2].origin?.application?.name, "Editor")
    XCTAssertEqual(values[3].origin?.application?.name, "Terminal")
    XCTAssertEqual(values[2].origin?.applicationInstance, editor.identity)
    XCTAssertEqual(values[2].origin?.confidence, .ancestry)
    XCTAssertNil(values[2].group)
    python.ppid = 1
    let historical = resolver.resolve([python], at: origin.addingTimeInterval(5))[0]
    XCTAssertEqual(historical.origin?.confidence, .historical)
    XCTAssertEqual(historical.origin?.verifiedAt, origin)
    XCTAssertFalse(historical.origin?.isCurrent ?? true)
    python.path = "/different/python"
    XCTAssertEqual(
      resolver.resolve([python], at: origin.addingTimeInterval(10))[0].origin?.confidence,
      .unavailable)
    python.path = "/runtime/python"; python.identity.seconds += 1
    XCTAssertNil(
      resolver.resolve([python], at: origin.addingTimeInterval(15))[0].origin?.application)
    var bundled = application(50, name: "Python")
    bundled.ppid = editor.identity.pid; bundled.identity.seconds = 101
    var other = bundled; other.identity.pid = 60; other.ppid = terminal.identity.pid
    let separated = resolver.resolve(
      [editor, terminal, bundled, other], at: origin.addingTimeInterval(20))
    XCTAssertEqual(separated[2].applicationMetadata?.name, "Python")
    XCTAssertEqual(separated[2].origin?.application?.name, "Python")
    XCTAssertEqual(separated[2].origin?.launcher?.name, "Editor")
    XCTAssertEqual(separated[3].origin?.launcher?.name, "Terminal")
    XCTAssertEqual(separated[2].origin?.displayedApplication?.name, "Editor")
    XCTAssertEqual(separated[2].origin?.launcherInstance, editor.identity)
    bundled.ppid = 1
    XCTAssertNil(resolver.resolve([bundled], at: origin.addingTimeInterval(25))[0].origin?.launcher)
  }
  func testOriginGuardsAndBounds() {
    var resolver = AppIdentityResolver()
    var root = application(10, name: "Terminal")
    let child = process(20, parent: 10, seconds: 101)
    root.uid += 1
    XCTAssertNil(resolver.resolve([root, child], at: origin)[1].origin?.application)
    root.uid = child.uid; root.identity.seconds = 102
    XCTAssertNil(
      resolver.resolve([root, child], at: origin.addingTimeInterval(5))[1].origin?.application)
    root.identity.seconds = 100
    let children = (0..<5000).map { process(Int32(100 + $0), parent: 10, seconds: 101) }
    let all = resolver.resolve([root] + children, at: origin.addingTimeInterval(10))
    XCTAssertEqual(all.last?.origin?.application?.name, "Terminal")
    XCTAssertLessThanOrEqual(resolver.retainedIdentityCount, 4096)
    var reused = child; reused.identity.seconds += 10; reused.ppid = 1
    XCTAssertNil(
      resolver.resolve([reused], at: origin.addingTimeInterval(15))[0].origin?.application)
  }
}
