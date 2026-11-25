import CSystem
import Foundation
import SentinelCore

private actor SampleSinkBarrier {
  private var entered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var blocked: CheckedContinuation<Void, Never>?
  private(set) var finished = false
  func block() async {
    entered = true
    let waiting = entryWaiters; entryWaiters = []
    for waiter in waiting { waiter.resume() }
    await withCheckedContinuation { blocked = $0 }
  }
  func waitForEntry() async {
    if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
  }
  func release() { blocked?.resume(); blocked = nil }
  func maintenanceFinished() { finished = true }
}

@MainActor final class ExperienceTests {
  let origin = Date(timeIntervalSince1970: 1_800_000_000)
  func sample(
    _ step: Int, value: Double = GiB, risk: RiskLevel = .normal,
    version: String? = "1.0", demo: Bool = false
  ) -> Snapshot {
    var analyzer = Analyzer()
    var result = analyzer.evaluate(
      Simulator().sample(step: step, scenario: .stable, origin: origin), settings: Settings()
    ).snapshot
    result.processes[0].footprint = value; result.processes[0].rss = value * 0.8
    result.processes[0].appVersion = version; result.risk = risk; result.demo = demo
    return result
  }
  func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "SentinelExperience-\(UUID().uuidString)")
  }
  func testLegacySettingsAndProfiles() throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var legacy = Settings(); legacy.interval = 15; legacy.notifications = false
    legacy.watchRules = [WatchRule(label: "Worker", value: "/example/worker", kind: .executable)]
    let encoder = JSONEncoder()
    try encoder.encode(legacy).write(to: dir.appendingPathComponent("settings.json"))
    let store = SettingsStore(directory: dir), loaded = store.load()
    XCTAssertEqual(loaded.interval, 15); XCTAssertFalse(loaded.notifications)
    XCTAssertEqual(loaded.activeProfile.watchRules, legacy.watchRules)
    XCTAssertEqual(loaded.profiles?.count, 3)
    var renamed = loaded
    renamed.profiles![0].name = "Renamed"; renamed.profiles![0].notifications = true;
    renamed.notifications = true
    XCTAssertEqual(renamed.analysisSignature, loaded.analysisSignature)
    try store.save(loaded)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("settings.pre-v2.json").path))
    var changed = loaded; changed.interval = 2; try store.save(changed)
    let restored = try store.restorePreV2Backup()
    XCTAssertEqual(restored.interval, 15); XCTAssertEqual(restored.watchRules, legacy.watchRules)
    var profile = WorkProfile(name: "Custom", disabledBuiltIns: ["Codex"])
    let custom = profile.applying(to: loaded)
    let raw = Simulator().sample(step: 0, scenario: .stable, origin: origin).processes
    XCTAssertNil(Classifier.classify(raw, settings: custom)[0].group)
    profile.watchRules = [
      WatchRule(label: "Exact", value: sample(0).processes[0].path, kind: .executable)
    ]
    XCTAssertEqual(
      Classifier.classify(sample(0).processes, settings: profile.applying(to: loaded))[0].group,
      "Exact")
  }
  func testAttributionVersionAndIncompleteAccounting() {
    var s = sample(0)
    let root = s.processes[0]
    var helper = root;
    helper.identity = ProcessIdentity(pid: 4201, seconds: root.identity.seconds + 1)
    helper.ppid = root.identity.pid; helper.name = "node"; helper.path = "/example/node";
    helper.appVersion = nil
    s.processes.append(helper)
    let f = AppAttribution.frame(snapshot: s, settings: Settings(), uptime: 100)
    XCTAssertEqual(f.apps.count, 1); XCTAssertEqual(f.apps[0].members, 2)
    XCTAssertEqual(f.apps[0].version, "1.0"); XCTAssertEqual(f.apps[0].footprint, 2 * GiB)
    s.processes[1].footprint = nil
    let missing = AppAttribution.frame(snapshot: s, settings: Settings(), uptime: 105)
    XCTAssertNil(missing.apps[0].footprint); XCTAssertNil(missing.monitored)
    XCTAssertFalse(missing.apps[0].complete)
    s.processes[1].uid += 1
    XCTAssertEqual(
      AppAttribution.frame(snapshot: s, settings: Settings(), uptime: 110).apps.count, 2)
  }
  func testBaselineAndForecastQuality() {
    var bucket = BaselineBucket()
    for i in 0..<720 {
      bucket.observe(value: GiB, at: origin.addingTimeInterval(Double(i) * 5), seconds: 5)
    }
    XCTAssertTrue(bucket.range.ready); XCTAssertEqual(bucket.range.lower, GiB)
    XCTAssertEqual(bucket.range.upper, GiB)
    let covered = bucket.range.coveredSeconds
    bucket.observe(value: .nan, at: origin, seconds: 5)
    XCTAssertEqual(bucket.range.coveredSeconds, covered)
    func series(_ count: Int) -> [GrowthReading] {
      (0..<count).map { i in
        GrowthReading(
          date: origin.addingTimeInterval(Double(i) * 5), uptime: Double(i) * 5,
          value: GiB + Double(i) * 5 * MiB, generation: "original")
      }
    }
    let valid = BudgetPredictor.predict(readings: series(181), budget: 3 * GiB, interval: 5)
    XCTAssertTrue(valid.available); XCTAssertEqual(valid.growthPerMinute!, 60 * MiB, accuracy: 1)
    XCTAssertGreaterThan(valid.lowerMinutes!, 10); XCTAssertLessThanOrEqual(valid.upperMinutes!, 30)
    XCTAssertFalse(
      BudgetPredictor.predict(readings: series(30), budget: 3 * GiB, interval: 5).available)
    var changed = series(181); changed[90].value = nil
    XCTAssertFalse(
      BudgetPredictor.predict(readings: changed, budget: 3 * GiB, interval: 5).available)
    changed = series(181); changed[90].generation = "new instance"
    XCTAssertFalse(
      BudgetPredictor.predict(readings: changed, budget: 3 * GiB, interval: 5).available)
    changed = series(181); changed.removeSubrange(70...80)
    XCTAssertFalse(
      BudgetPredictor.predict(readings: changed, budget: 3 * GiB, interval: 5).available)
    changed = series(181); changed[90].uptime += 300
    XCTAssertFalse(
      BudgetPredictor.predict(readings: changed, budget: 3 * GiB, interval: 5).available)
    changed = series(181)
    for i in changed.indices { changed[i].value = GiB + (i.isMultiple(of: 2) ? 200 * MiB : 0) }
    XCTAssertFalse(
      BudgetPredictor.predict(readings: changed, budget: 3 * GiB, interval: 5).available)
  }
  func testRecordingWindowsMergeAndInterruption() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), engine = ExperienceCoordinator(history: store)
    var settings = Settings().validated(); settings.cooldown = 60
    for i in 0...120 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let id = try await engine.recordNow(now: origin.addingTimeInterval(600))
    let initial = await engine.summary()
    XCTAssertEqual(initial.recordings.count, 1);
    XCTAssertEqual(initial.recordings[0].references.count, 121)
    let merged = try await engine.recordNow(now: origin.addingTimeInterval(600))
    XCTAssertEqual(id, merged)
    for i in 121...240 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let result = await engine.summary(), frames = try await engine.frames(recordingID: id)
    XCTAssertEqual(result.recordings[0].status, .complete); XCTAssertEqual(frames.count, 241)
    XCTAssertEqual(frames.first?.date, origin);
    XCTAssertEqual(frames.last?.date, origin.addingTimeInterval(1200))
    _ = try await engine.recordNow(now: origin.addingTimeInterval(1200))
    await engine.interrupt(reason: "Monitoring paused", now: origin.addingTimeInterval(1201))
    let interrupted = await engine.summary()
    XCTAssertEqual(interrupted.recordings.first?.status, .partial)
    XCTAssertTrue(interrupted.recordings[0].partialReason!.contains("paused"))
  }
  func testSessionCoverageComparisonAndRestart() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), engine = ExperienceCoordinator(history: store)
    let settings = Settings().validated()
    let id = try await engine.startSession(
      name: "Coding", note: "Private note", profile: settings.activeProfile, now: origin, uptime: 0)
    for i in 0...12 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let first = try await engine.sessionDetails(id: id)!
    XCTAssertEqual(first.observedSeconds, 60, accuracy: 0.001)
    XCTAssertEqual(first.mean!, GiB, accuracy: 1);
    XCTAssertEqual(first.coverage, 1, accuracy: 0.001)
    _ = await engine.ingest(snapshot: sample(36), incidents: [], settings: settings, uptime: 180)
    let gap = try await engine.sessionDetails(id: id)!
    XCTAssertEqual(gap.observedSeconds, 60, accuracy: 0.001);
    XCTAssertEqual(gap.coverage, 1.0 / 3, accuracy: 0.001)
    XCTAssertTrue(gap.points.last!.gap)
    let restarted = ExperienceCoordinator(history: store)
    await restarted.restore(now: origin.addingTimeInterval(200))
    let recovered = try await restarted.sessionDetails(id: id)!
    XCTAssertEqual(recovered.status, .interrupted); XCTAssertEqual(recovered.note, "Private note")
    XCTAssertEqual(recovered.points.count, gap.points.count)
    XCTAssertTrue(SessionComparison.cautions(first, recovered).contains { $0.contains("coverage") })
    XCTAssertTrue(
      SessionComparison.cautions(first, recovered).contains { $0.contains("interrupted") })
  }
  func testRecordingDeadlineAndIncompleteEvidence() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), tracker = ExperienceCoordinator(history: store)
    let settings = Settings().validated()
    _ = await tracker.ingest(snapshot: sample(0), incidents: [], settings: settings, uptime: 0)
    let firstID = try await tracker.recordNow(now: origin)
    for i in 1...119 {
      _ = await tracker.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    var analyzer = Analyzer()
    let event = analyzer.evaluate(
      Simulator().sample(step: 121, scenario: .critical, origin: origin), settings: settings)
    _ = await tracker.ingest(
      snapshot: event.snapshot, incidents: event.incidents, settings: settings, uptime: 605)
    let next = await tracker.summary()
    XCTAssertEqual(next.recordings.count, 2)
    XCTAssertEqual(next.recordings.first(where: { $0.id == firstID })?.status, .complete)
    let firstFrames = try await tracker.frames(recordingID: firstID)
    XCTAssertEqual(firstFrames.last?.date, origin.addingTimeInterval(595))
    XCTAssertEqual(next.recordings.first?.trigger, origin.addingTimeInterval(605))
    for i in 130...241 {
      _ = await tracker.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let gapped = await tracker.summary().recordings.first!
    XCTAssertEqual(gapped.status, .partial); XCTAssertNotNil(gapped.partialReason)
    var missing = sample(242); missing.processes[0].footprint = nil
    _ = await tracker.ingest(snapshot: missing, incidents: [], settings: settings, uptime: 1210)
    _ = try await tracker.recordNow(now: origin.addingTimeInterval(1210))
    for i in 243...362 {
      _ = await tracker.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let incomplete = await tracker.summary().recordings.first!
    XCTAssertEqual(incomplete.status, .partial); XCTAssertNotNil(incomplete.partialReason)
  }
  func testPretriggerMarkersSurviveRestartAndFrozenReport() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), tracker = ExperienceCoordinator(history: store)
    let settings = Settings().validated(), base = Date().addingTimeInterval(-20)
    let uptime = ProcessInfo.processInfo.systemUptime - 20
    let rootID = ProcessIdentity(pid: 4200, seconds: UInt64(base.timeIntervalSince1970 - 100))
    let helperID = ProcessIdentity(pid: 4201, seconds: UInt64(base.timeIntervalSince1970 + 5))
    func reading(_ i: Int) -> Snapshot {
      var value = sample(i)
      value.date = base.addingTimeInterval(Double(i) * 5)
      value.processes[0].identity = rootID
      value.processesAvailable = true
      if i == 1 || i == 2 {
        var helper = value.processes[0]
        helper.identity = helperID; helper.ppid = rootID.pid
        helper.path = "/example/worker"; helper.name = "worker"; helper.appVersion = nil
        value.processes.append(helper)
      }
      return value
    }
    for i in 0...4 {
      _ = await tracker.ingest(
        snapshot: reading(i), incidents: [], settings: settings, uptime: uptime + Double(i) * 5)
    }
    guard var fix = try await completedFix(store: store) else { XCTFail("No Fix fixture"); return }
    fix.updated = base.addingTimeInterval(7)
    await tracker.observeFix(fix)
    let id = try await tracker.recordNow(now: base.addingTimeInterval(20))
    let frozen = await tracker.summary().recordings.first!
    XCTAssertEqual(Set(frozen.events.map(\.id)).count, frozen.events.count)
    XCTAssertEqual(frozen.events.map(\.date), frozen.events.map(\.date).sorted())
    XCTAssertTrue(frozen.events.contains { $0.kind == .fix })
    XCTAssertTrue(frozen.events.contains { $0.kind == .processStarted && $0.process == helperID })
    XCTAssertTrue(frozen.events.contains { $0.kind == .processExited && $0.process == helperID })
    _ = await tracker.ingest(
      snapshot: reading(5), incidents: [], settings: settings, uptime: uptime + 25)
    let frozenFrames = try await tracker.frames(for: frozen)
    XCTAssertEqual(frozenFrames.count, frozen.references.count)
    XCTAssertEqual(frozenFrames.last?.date, base.addingTimeInterval(20))
    let recovered = ExperienceCoordinator(history: store)
    await recovered.restore(now: base.addingTimeInterval(25))
    let interrupted = await recovered.summary()
    XCTAssertEqual(interrupted.recordings.first { $0.id == id }?.status, .partial)
    _ = await recovered.ingest(
      snapshot: reading(6), incidents: [], settings: settings, uptime: uptime + 30)
    _ = try await recovered.recordNow(now: base.addingTimeInterval(30))
    let next = await recovered.summary().recordings.first!
    XCTAssertTrue(next.events.contains { $0.kind == .processStarted && $0.process == helperID })
    XCTAssertTrue(next.events.contains { $0.kind == .processExited && $0.process == helperID })
    XCTAssertTrue(
      next.events.contains {
        $0.kind == .note && $0.text == "Record now was requested."
          && $0.date == base.addingTimeInterval(20)
      })
    XCTAssertEqual(Set(next.events.map(\.id)).count, next.events.count)
    XCTAssertGreaterThan(next.references.count, 1)
  }
  func testSessionUnknownAndReplacementPeaks() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), tracker = ExperienceCoordinator(history: store)
    let settings = Settings().validated()
    _ = await tracker.ingest(snapshot: sample(0), incidents: [], settings: settings, uptime: 0)
    let id = try await tracker.startSession(
      name: "Peak evidence", note: "", profile: settings.activeProfile,
      now: origin.addingTimeInterval(3), uptime: 3)
    var missing = sample(1); missing.processes[0].footprint = nil
    _ = await tracker.ingest(snapshot: missing, incidents: [], settings: settings, uptime: 5)
    let unknown = try await tracker.sessionDetails(id: id)!
    XCTAssertNil(unknown.consumers.first?.peak)
    XCTAssertEqual(unknown.observedSeconds, 0)
    XCTAssertTrue(ReportBuilder.session(unknown).markdown.contains("Peak Unavailable"))
    _ = await tracker.ingest(snapshot: sample(2), incidents: [], settings: settings, uptime: 10)
    var replacement = sample(3, value: 10 * GiB)
    replacement.processes[0].identity.seconds += 1
    _ = await tracker.ingest(snapshot: replacement, incidents: [], settings: settings, uptime: 15)
    let peaked = try await tracker.sessionDetails(id: id)!
    XCTAssertEqual(peaked.consumers.first?.peak, 10 * GiB)
    XCTAssertEqual(peaked.peak, 10 * GiB)
    XCTAssertEqual(peaked.observedSeconds, 5)
    XCTAssertEqual(peaked.elapsedSeconds, 12)
  }
  func testMaintenanceDrainsAnInflightSample() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), barrier = SampleSinkBarrier()
    let engine = MonitoringEngine(settings: Settings(), history: store) { _ in
      await barrier.block()
    }
    let sampling = Task { await engine.sample(force: true) }
    await barrier.waitForEntry()
    let maintenance = Task {
      await engine.suspendForMaintenance()
      await barrier.maintenanceFinished()
    }
    for _ in 0..<100 {
      if await engine.isPaused { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let paused = await engine.isPaused, finishedEarly = await barrier.finished
    XCTAssertTrue(paused); XCTAssertFalse(finishedEarly)
    do {
      _ = try await engine.freshSnapshot(); XCTFail("Maintenance must reject a fresh snapshot")
    } catch {}
    await barrier.release()
    await sampling.value; await maintenance.value
    let finished = await barrier.finished; XCTAssertTrue(finished)
    let before = try await store.counts()
    await engine.sample(force: true)
    let after = try await store.counts(); XCTAssertEqual(before, after)
    await engine.finishMaintenance(); await engine.stop()
  }
  func testSnoozeAndLearningExclusions() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), engine = ExperienceCoordinator(history: store)
    var settings = Settings().validated()
    var profile = settings.activeProfile
    profile.budgets = [MemoryBudget(target: "Codex", bytes: GiB / 2)]
    settings.profiles = [profile]
    let first = await engine.ingest(
      snapshot: sample(0), incidents: [], settings: settings, uptime: 0)
    let appKey = first.apps[0].id
    try await engine.snooze(
      profile: profile.id, app: appKey, kind: .budget, minutes: 15, now: origin)
    _ = await engine.ingest(snapshot: sample(1), incidents: [], settings: settings, uptime: 5)
    let warning = await engine.ingest(
      snapshot: sample(2), incidents: [], settings: settings, uptime: 10)
    XCTAssertEqual(warning.newAlerts.count, 1); XCTAssertTrue(warning.newAlerts[0].snoozed)
    XCTAssertFalse(
      ScopedSnooze(
        profileID: profile.id, appKey: appKey, kind: .budget, until: origin.addingTimeInterval(900)
      )
      .suppresses(profile: profile.id, app: appKey, kind: .budget, level: .critical, now: origin))
    for i in 3...30 {
      _ = await engine.ingest(
        snapshot: sample(i, risk: .warning), incidents: [], settings: settings,
        uptime: Double(i) * 5)
    }
    let excluded = await engine.summary()
    XCTAssertEqual(excluded.apps[0].normal.coveredSeconds, 0, accuracy: 0.001)
    let demoEngine = ExperienceCoordinator(history: store, demo: true)
    for i in 0...30 {
      _ = await demoEngine.ingest(
        snapshot: sample(i, demo: true), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let demoState = await demoEngine.summary()
    XCTAssertEqual(demoState.apps[0].normal.coveredSeconds, 0, accuracy: 0.001)
    try await engine.resetNormalRange(profile: profile.id)
    let reset = await engine.summary(); XCTAssertEqual(reset.apps[0].normal.coveredSeconds, 0)
  }
  func testMigrationAndRestore() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var raw: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &raw), SQLITE_OK)
    let legacy =
      "CREATE TABLE samples(t REAL PRIMARY KEY,point TEXT NOT NULL,detail TEXT NOT NULL); CREATE TABLE minutes(t REAL PRIMARY KEY,point TEXT NOT NULL); CREATE TABLE incidents(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE fix_sessions(id TEXT PRIMARY KEY,t REAL NOT NULL,payload TEXT NOT NULL); INSERT INTO minutes VALUES(1,'legacy sentinel'); PRAGMA user_version=0;"
    XCTAssertEqual(sqlite3_exec(raw, legacy, nil, nil, nil), SQLITE_OK); sqlite3_close(raw)
    let history = try HistoryStore(directory: dir)
    let version = try await history.schemaVersion(); XCTAssertEqual(version, 2)
    let before = try await history.counts(); XCTAssertEqual(before[1], 1)
    let snapshot = sample(0)
    try await history.append(snapshot, incidents: [], settings: Settings())
    let mutated = try await history.counts(); XCTAssertEqual(mutated[0], 1)
    try await history.restorePreV2Backup()
    let restored = try await history.counts(); XCTAssertEqual(restored, [0, 1, 0])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("history.before-restore.sqlite").path))
    let reopened = try HistoryStore(directory: dir)
    let again = try await reopened.counts(); XCTAssertEqual(again, restored)
  }
  func testExperienceWriteRollbackAndRevisionOrdering() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), tracker = ExperienceCoordinator(history: store)
    let settings = Settings().validated()
    _ = await tracker.ingest(snapshot: sample(0), incidents: [], settings: settings, uptime: 0)
    let id = try await tracker.recordNow(now: origin)
    let original = await tracker.summary().recordings.first!
    let beforeBytes = try await store.experiencePayloadBytes()
    let frame = AppAttribution.frame(snapshot: sample(1), settings: settings, uptime: 5)
    var replacement = original
    replacement.revision += 1; replacement.title = "Must roll back"
    var failed = ExperienceWrite(frame: frame)
    failed.recordings = [replacement]
    failed.state = Data(repeating: 65, count: 8 * 1024 * 1024 + 1)
    do {
      try await store.persistExperience(failed)
      XCTFail("An invalid state must abort the entire write batch")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("8 MiB"))
    }
    let absent = try await store.experienceFrames(ids: [frame.id])
    XCTAssertTrue(absent.isEmpty)
    let unchanged = try await store.experienceValue(FlightRecording.self, kind: "recording", id: id)
    XCTAssertEqual(unchanged?.revision, original.revision)
    XCTAssertEqual(unchanged?.title, original.title)
    let afterBytes = try await store.experiencePayloadBytes()
    XCTAssertEqual(afterBytes, beforeBytes)
    replacement.title = "New revision"
    var accepted = ExperienceWrite(frame: frame); accepted.recordings = [replacement]
    try await store.persistExperience(accepted)
    var stale = ExperienceWrite(); stale.recordings = [original]
    try await store.persistExperience(stale)
    let latest = try await store.experienceValue(FlightRecording.self, kind: "recording", id: id)
    XCTAssertEqual(latest?.revision, replacement.revision)
    XCTAssertEqual(latest?.title, replacement.title)
    let frames = try await store.experienceFrames(ids: [frame.id])
    XCTAssertEqual(frames.count, 1)
    let reopened = try HistoryStore(directory: dir)
    let persisted = try await reopened.experienceValue(
      FlightRecording.self, kind: "recording", id: id)
    XCTAssertEqual(persisted?.title, replacement.title)
  }
  func testUnapprovedFixRevisionCacheIsBounded() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    guard let completed = try await completedFix(store: store) else {
      XCTFail("No completed Fix fixture"); return
    }
    let tracker = ExperienceCoordinator(history: store)
    _ = await tracker.ingest(snapshot: sample(0), incidents: [], settings: Settings(), uptime: 0)
    await tracker.observeFix(completed)
    let before = await tracker.summary()
    for _ in 0..<700 {
      var cancelled = completed
      cancelled.id = UUID(); cancelled.approvedAction = nil; cancelled.phase = .finished
      cancelled.actionSentAt = nil; cancelled.result?.outcome = .cancelled
      await tracker.observeFix(cancelled)
    }
    let count = await tracker.trackedFixRevisionCount
    XCTAssertLessThanOrEqual(count, 512)
    await tracker.observeFix(completed)
    let after = await tracker.summary()
    XCTAssertEqual(after.followups.count, before.followups.count)
    XCTAssertEqual(after.recordings.first?.events.count, before.recordings.first?.events.count)
    XCTAssertEqual(after.followups.first?.id, completed.id)
  }
  func testMigrationFailurePreservesLegacyData() throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("history.sqlite")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    let schema = """
      CREATE TABLE minutes(t REAL PRIMARY KEY,point TEXT NOT NULL);
      INSERT INTO minutes VALUES(1,'preserve this row');
      CREATE TABLE experience_frames(id TEXT PRIMARY KEY,t REAL NOT NULL);
      PRAGMA user_version=0;
      """
    XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    do {
      _ = try HistoryStore(directory: dir)
      XCTFail("An incompatible experience table must fail migration")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("migration failed"))
    }
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    func scalar(_ sql: String) -> String? {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
      else { return nil }
      return String(cString: text)
    }
    XCTAssertEqual(scalar("PRAGMA user_version"), "0")
    XCTAssertEqual(scalar("SELECT point FROM minutes WHERE t=1"), "preserve this row")
    XCTAssertEqual(
      scalar("SELECT count(*) FROM sqlite_master WHERE name='experience_frame_time'"), "0")
    XCTAssertEqual(
      scalar("SELECT count(*) FROM sqlite_master WHERE name='experience_items'"), "0")
    XCTAssertEqual(scalar("PRAGMA quick_check"), "ok")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("history.pre-v2.sqlite").path))
  }
  func testStorageQuotaAndSeriesPeaks() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    let engine = ExperienceCoordinator(history: store, maximumPayloadBytes: 1024 * 1024)
    for i in 0..<40 {
      var s = sample(i)
      s.processes[0].name = String(repeating: "fixture", count: 500)
      for p in 1..<32 {
        var other = s.processes[0]; other.identity.pid += Int32(p);
        other.ppid = s.processes[0].identity.pid
        other.identity.seconds += UInt64(p); s.processes.append(other)
      }
      _ = await engine.ingest(
        snapshot: s, incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    let bytes = try await store.experiencePayloadBytes();
    XCTAssertLessThanOrEqual(bytes, 1024 * 1024)
    XCTAssertGreaterThan(bytes, 200_000)
    let state = await engine.summary(); XCTAssertNil(state.error)
    var points: [SessionPoint] = []
    // Obtain points through the public session API, then exercise long-series reduction.
    let id = try await engine.startSession(
      name: "Series", note: "", profile: Settings().activeProfile,
      now: origin.addingTimeInterval(195), uptime: 195)
    for i in 40...50 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    let session = try await engine.sessionDetails(id: id)!
    guard var point = session.points.first else { XCTFail("No session points"); return }
    for i in 0..<5000 {
      point.id = UUID(); point.elapsed = Double(i); point.monitored = i == 2345 ? 100 * GiB : GiB
      point.gap = i == 3456; points.append(point)
    }
    let reduced = SessionSeries.reduce(points)
    XCTAssertLessThanOrEqual(reduced.count, 600)
    XCTAssertTrue(reduced.contains { $0.monitored == 100 * GiB })
    XCTAssertTrue(reduced.contains { $0.gap }); XCTAssertEqual(reduced.first?.id, points.first?.id)
    XCTAssertEqual(reduced.last?.id, points.last?.id)
    for i in points.indices {
      points[i].gap = i.isMultiple(of: 7)
      if i.isMultiple(of: 11) { points[i].monitored = nil }
    }
    let sparse = SessionSeries.reduce(points, limit: 60)
    XCTAssertLessThanOrEqual(sparse.count, 60)
    XCTAssertTrue(
      zip(sparse, sparse.dropFirst()).allSatisfy { before, after in
        let between = points[(Int(before.elapsed) + 1)...Int(after.elapsed)]
        return !between.contains { $0.gap || $0.monitored == nil } || after.gap
      })
  }
  func completedFix(store: HistoryStore) async throws -> FixSession? {
    let fixture = FixTests()
    let (coordinator, runtime, _) = fixture.setup(verify: 5, save: { try await store.saveFix($0) })
    await runtime.metricsMissing()
    await coordinator.prepare(origin: FixOrigin(issue: .monitoringFailure), settings: Settings())
    await fixture.approve(coordinator, .restartMonitoring)
    _ = await fixture.waitPhase(coordinator, .verifying)
    try await fixture.post(coordinator, runtime, count: 3)
    let session = await fixture.waitPhase(coordinator, .finished)
    return session
  }
  func testFiveMinuteFollowupAndImmutableResult() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    guard var fix = try await completedFix(store: store) else {
      XCTFail("No completed fixture Fix"); return
    }
    let original = try await store.fixSessions().first
    let engine = ExperienceCoordinator(history: store)
    _ = await engine.ingest(snapshot: sample(0), incidents: [], settings: Settings(), uptime: 0)
    fix.updated = origin
    await engine.observeFix(fix)
    for i in 1...60 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    let stable = await engine.summary()
    XCTAssertEqual(stable.followups.first?.status, .stable)
    XCTAssertEqual(stable.followups.first?.samples, 60)
    XCTAssertGreaterThanOrEqual(stable.followups.first?.coveredSeconds ?? 0, 270)
    XCTAssertLessThanOrEqual(stable.followups.first?.coveredSeconds ?? 0, 300)
    let persisted = try await store.fixSessions().first
    XCTAssertEqual(persisted?.result?.outcome, original?.result?.outcome)
    XCTAssertEqual(persisted?.result?.systemImproved, original?.result?.systemImproved)
    let again = ExperienceCoordinator(history: store)
    _ = await again.ingest(snapshot: sample(0), incidents: [], settings: Settings(), uptime: 0)
    fix.id = UUID(); fix.revision = 100; fix.plan?.diagnosis.kind = .systemPressure
    await again.observeFix(fix)
    for i in 1...60 {
      var s = sample(i); if i == 30 { s.system.pressure = .warning }
      _ = await again.ingest(
        snapshot: s, incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    let returned = await again.summary();
    XCTAssertEqual(returned.followups.first?.status, .returned)
    let partial = ExperienceCoordinator(history: store)
    _ = await partial.ingest(snapshot: sample(0), incidents: [], settings: Settings(), uptime: 0)
    fix.id = UUID(); fix.revision = 200; await partial.observeFix(fix)
    var missing = sample(1); missing.processes[0].footprint = nil
    _ = await partial.ingest(snapshot: missing, incidents: [], settings: Settings(), uptime: 5)
    let unknown = await partial.summary(); XCTAssertEqual(unknown.followups.first?.status, .partial)
    let bounded = ExperienceCoordinator(history: store)
    _ = await bounded.ingest(snapshot: sample(0), incidents: [], settings: Settings(), uptime: 0)
    fix.id = UUID(); fix.revision = 300; await bounded.observeFix(fix)
    for i in 1...59 {
      _ = await bounded.ingest(
        snapshot: sample(i), incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    var afterWindow = sample(61); afterWindow.system.pressure = .warning
    _ = await bounded.ingest(
      snapshot: afterWindow, incidents: [], settings: Settings(), uptime: 305)
    let ended = await bounded.summary().followups.first!
    XCTAssertEqual(ended.status, .stable); XCTAssertFalse(ended.warningReturned)
    XCTAssertEqual(ended.samples, 59); XCTAssertEqual(ended.coveredSeconds, 295)
    XCTAssertEqual(ended.last?.date, origin.addingTimeInterval(295))
  }
  func testSharedReportsAndEscaping() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), engine = ExperienceCoordinator(history: store)
    let secret = "fixture-private-user"
    var profile = Settings().activeProfile; profile.name = secret
    var settings = Settings().validated(); settings.profiles = [profile]
    let sessionID = try await engine.startSession(
      name: secret, note: "<script>alert('private')</script> \(secret)", profile: profile,
      now: origin, uptime: 0)
    for i in 0...3 {
      var s = sample(i)
      s.processes[0].group = secret; s.processes[0].path = "/Users/\(secret)/project/worker"
      s.processes[0].appVersion = "1.0 /Users/\(secret)"
      _ = await engine.ingest(snapshot: s, incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let session = try await engine.sessionDetails(id: sessionID)!
    let report = ReportBuilder.session(session)
    XCTAssertFalse(report.html.contains(secret)); XCTAssertFalse(report.markdown.contains(secret))
    XCTAssertFalse(report.html.contains("/Users/")); XCTAssertFalse(report.html.contains("<script"))
    XCTAssertTrue(report.html.contains("default-src 'none'"))
    let detailed = ReportBuilder.session(
      session, options: ReportOptions(includeDetails: true, includeNotes: true))
    XCTAssertTrue(detailed.html.contains(secret));
    XCTAssertTrue(detailed.html.contains("&lt;script&gt;"))
    XCTAssertFalse(detailed.html.contains("<script>"));
    XCTAssertTrue(detailed.markdown.contains("&lt;script&gt;"))
    let id = try await engine.recordNow(now: origin.addingTimeInterval(15))
    var recording = await engine.summary().recordings.first!
    recording.partialReason = "/Users/\(secret)/private"; recording.status = .partial
    recording.events.append(ExperienceEvent(date: origin, kind: .note, text: secret))
    let frames = try await engine.frames(recordingID: id)
    let clipReport = ReportBuilder.recording(recording, frames: frames)
    XCTAssertFalse(clipReport.html.contains(secret));
    XCTAssertFalse(clipReport.markdown.contains("/Users/"))
    XCTAssertTrue(clipReport.html.contains("Capture is incomplete"))
  }
  func testDemoSeedAndMaintenanceBarrier() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir), live = ExperienceCoordinator(history: store)
    let demo = ExperienceCoordinator(history: nil, demo: true), updates = UpdateRecorder()
    let engine = MonitoringEngine(
      settings: Settings().validated(), history: store, experience: live, demoExperience: demo
    ) { await updates.add($0) }
    await engine.mode(demo: true, scenario: .budgetApproach)
    let seeded = await updates.last()
    XCTAssertEqual(seeded?.snapshot.demo, true)
    XCTAssertEqual(seeded?.experience?.apps.first?.forecast.available, true)
    XCTAssertEqual(seeded?.experience?.apps.first?.normal.coveredSeconds, 0)
    let bytes = try await store.experiencePayloadBytes(); XCTAssertEqual(bytes, 0)
    await engine.mode(demo: false, scenario: .stable)
    await engine.suspendForMaintenance()
    let loops = await engine.samplingLoopCount; XCTAssertEqual(loops, 0)
    let counts = try await store.counts()
    await engine.sample(force: true)
    let after = try await store.counts(); XCTAssertEqual(counts, after)
    do {
      _ = try await engine.freshSnapshot(); XCTFail("Maintenance must reject a fresh Fix snapshot")
    } catch {}
    await engine.finishMaintenance()
    let paused = await engine.isPaused; XCTAssertTrue(paused)
    await engine.stop()
  }
  func testLearnedRangeProfileAndVersionIsolation() async {
    let engine = ExperienceCoordinator(history: nil)
    let settings = Settings().validated()
    for i in 0...720 {
      _ = await engine.ingest(
        snapshot: sample(i), incidents: [], settings: settings, uptime: Double(i) * 5)
    }
    let learned = await engine.summary()
    XCTAssertTrue(learned.apps[0].normal.ready)
    let covered = learned.apps[0].normal.coveredSeconds
    var warning = sample(721); warning.system.pressure = .warning
    _ = await engine.ingest(snapshot: warning, incidents: [], settings: settings, uptime: 3605)
    let excluded = await engine.summary();
    XCTAssertEqual(excluded.apps[0].normal.coveredSeconds, covered)
    _ = await engine.ingest(
      snapshot: sample(722, version: "2.0"), incidents: [], settings: settings, uptime: 3610)
    let newVersion = await engine.summary(); XCTAssertFalse(newVersion.apps[0].normal.ready)
    let coding = settings.profiles![1].applying(to: settings)
    _ = await engine.ingest(snapshot: sample(723), incidents: [], settings: coding, uptime: 3615)
    let otherProfile = await engine.summary();
    XCTAssertEqual(otherProfile.apps[0].normal.coveredSeconds, 0)
    _ = await engine.ingest(snapshot: sample(724), incidents: [], settings: settings, uptime: 3620)
    let original = await engine.summary(); XCTAssertTrue(original.apps[0].normal.ready)
    try? await engine.resetNormalRange(profile: settings.activeProfile.id)
    let reset = await engine.summary(); XCTAssertFalse(reset.apps[0].normal.ready)
  }
  func testFollowupKeepsProcessAndGroupAccountingSeparate() async throws {
    let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HistoryStore(directory: dir)
    guard var fix = try await completedFix(store: store) else { XCTFail("No fixture Fix"); return }
    var s = sample(0)
    let root = s.processes[0]
    var helper = root; helper.identity.pid += 1; helper.identity.seconds += 1
    helper.ppid = root.identity.pid; helper.footprint = 2 * GiB; helper.risk = .warning
    s.processes.append(helper)
    fix.id = UUID(); fix.updated = origin; fix.approvedAction = .quitApplication
    fix.plan?.target = FixTarget(process: root, source: root, related: [helper.identity])
    fix.plan?.diagnosis.kind = .highFootprint
    fix.plan?.before = FixMeasurement(snapshot: s, target: root.identity)
    let engine = ExperienceCoordinator(history: store)
    _ = await engine.ingest(snapshot: s, incidents: [], settings: Settings(), uptime: 0)
    await engine.observeFix(fix)
    for i in 1...60 {
      s.date = origin.addingTimeInterval(Double(i) * 5)
      _ = await engine.ingest(
        snapshot: s, incidents: [], settings: Settings(), uptime: Double(i) * 5)
    }
    let observed = await engine.summary()
    XCTAssertEqual(observed.apps[0].app.footprint, 3 * GiB)
    XCTAssertEqual(observed.followups[0].last?.targetFootprint, GiB)
    XCTAssertEqual(observed.followups[0].status, .returned)
    let unreadable = ExperienceCoordinator(history: store)
    s.date = origin
    _ = await unreadable.ingest(snapshot: s, incidents: [], settings: Settings(), uptime: 0)
    fix.id = UUID(); await unreadable.observeFix(fix)
    s.processes.removeAll { $0.identity == root.identity }; s.unreadablePIDs = [root.identity.pid]
    s.date = origin.addingTimeInterval(5)
    _ = await unreadable.ingest(snapshot: s, incidents: [], settings: Settings(), uptime: 5)
    let partial = await unreadable.summary(); XCTAssertEqual(partial.followups[0].status, .partial)
  }
}
