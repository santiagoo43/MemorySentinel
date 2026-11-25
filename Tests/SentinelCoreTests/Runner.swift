import Foundation

@MainActor private var failures = 0
@MainActor private var assertions = 0
@MainActor func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
  failures += 1
  print("FAIL \(file):\(line) \(message)")
}
@MainActor func XCTAssertTrue(
  _ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
) {
  assertions += 1
  if !value() { XCTFail("Expected true", file: file, line: line) }
}
@MainActor func XCTAssertFalse(
  _ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(!value(), file: file, line: line) }
@MainActor func XCTAssertEqual<T: Equatable>(
  _ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line
) {
  assertions += 1
  if a != b { XCTFail("\(a) != \(b)", file: file, line: line) }
}
@MainActor func XCTAssertEqual(
  _ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(abs(a - b) <= accuracy, file: file, line: line) }
@MainActor func XCTAssertGreaterThan<T: Comparable>(
  _ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(a > b, file: file, line: line) }
@MainActor func XCTAssertGreaterThanOrEqual<T: Comparable>(
  _ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(a >= b, file: file, line: line) }
@MainActor func XCTAssertLessThanOrEqual<T: Comparable>(
  _ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line
) { XCTAssertTrue(a <= b, file: file, line: line) }
@MainActor func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertTrue(value == nil, file: file, line: line)
}
@MainActor func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line)
{ XCTAssertTrue(value != nil, file: file, line: line) }
@MainActor func XCTAssertThrowsError<T>(
  _ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line
) {
  assertions += 1
  do {
    _ = try value()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
@main struct TestRunner {
  @MainActor static func main() async {
    if NativeFixTests.runFixtureIfRequested() { return }
    let t = CoreTests()
    let f = FixTests()
    let native = NativeFixTests()
    let experience = ExperienceTests()
    let tests: [(String, () async throws -> Void)] = [
      (
        "Experience legacy settings and profiles",
        { try experience.testLegacySettingsAndProfiles() }
      ),
      (
        "Experience application attribution and accounting",
        { experience.testAttributionVersionAndIncompleteAccounting() }
      ),
      ("Experience baseline and forecast quality", { experience.testBaselineAndForecastQuality() }),
      (
        "Experience recording windows and interruption",
        { try await experience.testRecordingWindowsMergeAndInterruption() }
      ),
      (
        "Experience recording deadlines and incomplete evidence",
        { try await experience.testRecordingDeadlineAndIncompleteEvidence() }
      ),
      (
        "Experience pretrigger markers and frozen reports",
        { try await experience.testPretriggerMarkersSurviveRestartAndFrozenReport() }
      ),
      (
        "Experience unknown and replacement peaks",
        { try await experience.testSessionUnknownAndReplacementPeaks() }
      ),
      (
        "Experience maintenance drains inflight sample",
        { try await experience.testMaintenanceDrainsAnInflightSample() }
      ),
      (
        "Experience sessions coverage and restart",
        { try await experience.testSessionCoverageComparisonAndRestart() }
      ),
      (
        "Experience snooze and learning exclusions",
        { try await experience.testSnoozeAndLearningExclusions() }
      ),
      ("Experience migration and restore", { try await experience.testMigrationAndRestore() }),
      (
        "Experience atomic writes and revision ordering",
        { try await experience.testExperienceWriteRollbackAndRevisionOrdering() }
      ),
      (
        "Experience failed migration preserves data",
        { try experience.testMigrationFailurePreservesLegacyData() }
      ),
      (
        "Experience unapproved Fix cache stays bounded",
        { try await experience.testUnapprovedFixRevisionCacheIsBounded() }
      ),
      (
        "Experience quotas and series peaks",
        { try await experience.testStorageQuotaAndSeriesPeaks() }
      ),
      (
        "Experience five-minute followup",
        { try await experience.testFiveMinuteFollowupAndImmutableResult() }
      ),
      (
        "Experience shared reports and escaping",
        { try await experience.testSharedReportsAndEscaping() }
      ),
      (
        "Experience demo and maintenance",
        { try await experience.testDemoSeedAndMaintenanceBarrier() }
      ),
      (
        "Experience learned profile and version isolation",
        { await experience.testLearnedRangeProfileAndVersionIsolation() }
      ),
      (
        "Experience followup accounting and unreadable identity",
        { try await experience.testFollowupKeepsProcessAndGroupAccountingSeparate() }
      ),
      ("generic runtime evidence", { t.testGenericRuntimeRequiresEvidence() }),
      ("bundle ancestry and exclusions", { t.testBundleAndAncestryAndExcludedProcess() }),
      ("parent start time and PGID", { t.testNewerParentAndGroupDoNotEstablishAncestry() }),
      ("custom exact rules", { t.testCustomExactPath() }),
      ("bounded regression windows", { t.testRegressionWindowsAndBound() }),
      ("risk hysteresis", { t.testHysteresisAndCriticalBypass() }),
      ("per-identity cooldown", { t.testCooldownPerIdentityAndEscalation() }),
      ("all simulation scenarios", { t.testAllScenariosAndPIDReuse() }),
      ("live Darwin metrics", { t.testLiveMetrics() }),
      ("settings persistence", { try t.testSettingsPersistenceAndValidation() }),
      (
        "history persistence retention exports",
        { try await t.testHistoryPersistenceRetentionExportAndDemoIsolation() }
      ),
      ("corrupt history recovery", { try await t.testCorruptHistoryRecovery() }),
      ("protected process signaling", { t.testProtectedSignal() }),
      ("orphan attribution continuity", { t.testOrphanAttribution() }),
      ("long run and bounded identities", { t.testLongRunAndBoundedIdentityHistory() }),
      (
        "engine pressure pause and demo isolation", { try await t.testEnginePressurePauseAndDemo() }
      ),
      ("storage payload budget", { try await t.testStorageBudget() }),
      ("provisional pressure warning", { t.testPressureWarningIsVisibleWhileConfirming() }),
      ("missing metrics retain risk", { t.testMissingMetricsDoNotImplyRecoveryOrInventRAM() }),
      ("controlled fixture signals", { try t.testControlledChildTermination() }),
      ("minute peak timestamp", { try await t.testMinutePeakPreservesExactTimestamp() }),
      (
        "Fix unreadable process and worker data",
        { try await f.testUnreadablePIDsNeverProveRecovery() }
      ),
      (
        "Fix selected source outside related limit",
        { try await f.testSelectedSourceSurvivesRelationLimit() }
      ),
      (
        "Fix replacement metadata comparability",
        { try await f.testReplacementMetadataMustRemainComparable() }
      ),
      ("Fix planning and explicit selection", { try await f.testPlanningAndManualSelection() }),
      ("Fix old incidents and PID reuse", { try await f.testOldIncidentAndPIDReuse() }),
      ("Fix protected and invalidated plans", { try await f.testProtectedAndInvalidatedPlans() }),
      (
        "Fix duplicate and cancelled approvals",
        { try await f.testDuplicateApprovalAndCancellation() }
      ),
      (
        "Fix refusal timeout and Force confirmation",
        { try await f.testRefusalTimeoutAndSeparateForceConfirmation() }
      ),
      ("Fix before/after and unchanged swap", { try await f.testVerificationAndUnchangedSwap() }),
      (
        "Fix replacement identity and helpers",
        { try await f.testRestartReplacementAndRemainingHelpers() }
      ),
      ("Fix missing data and guidance", { try await f.testMissingMetricsDeadlineAndGuidance() }),
      ("Fix monitoring restart and demo", { try await f.testMonitoringRestartAndDemo() }),
      (
        "Fix system comparison needs measured improvement",
        { try await f.testSystemComparisonRequiresMeasuredImprovement() }
      ),
      (
        "Fix incomplete monitoring repair cannot succeed",
        { try await f.testIncompleteMonitoringRepairCannotSucceed() }
      ),
      (
        "Fix missing worker trend cannot prove recovery",
        { try await f.testMissingWorkerTrendNeverProvesRecovery() }
      ),
      ("Fix history recovery and exports", { try await f.testFixHistoryRecoveryAndExport() }),
      (
        "Fix mode provenance and stale audit writes",
        { try await f.testModeProvenanceAndAuditOrdering() }
      ),
      (
        "Fix expiry, individual target and unique samples",
        { try await f.testExpiryIndividualSelectionAndFreshSamples() }
      ),
      (
        "Fix swap and replacement worker verification",
        { try await f.testRapidSwapAndNewWorkersPreventFalseSuccess() }
      ),
      (
        "Native Fix fixture quit/relaunch/guards",
        { try await native.testNativeQuitRelaunchAndBackendGuards() }
      ),
    ]
    let filter = CommandLine.arguments.firstIndex(of: "--filter").flatMap {
      $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
    }
    let selected = tests.filter { filter == nil || $0.0.localizedCaseInsensitiveContains(filter!) }
    for (name, test) in selected {
      let before = failures
      do { try await test() } catch { XCTFail("\(name): \(error)") }
      print("\(before==failures ? "PASS" : "FAIL") \(name)")
    }
    print("\(selected.count) suites, \(assertions) assertions, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
}
