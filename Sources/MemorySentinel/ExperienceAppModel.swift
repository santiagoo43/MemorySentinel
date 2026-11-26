import AppKit
import Foundation
import SentinelCore

extension AppModel {
  func activateProfile(_ id: UUID) {
    guard let profile = settings.profiles?.first(where: { $0.id == id }),
      settings.activeProfileID != id
    else { return }
    invalidateFix("The work profile changed. Assess a new plan.")
    settings = profile.applying(to: settings)
    experience.apps = []; experience.alerts = []
    let tracker = analytics
    Task { await tracker.interrupt(reason: "The active work profile changed.", kind: .profile) }
  }
  func saveProfile(_ profile: WorkProfile) {
    let valid = profile.validated()
    var value = settings
    if let i = value.profiles?.firstIndex(where: { $0.id == valid.id }) {
      value.profiles![i] = valid
    } else if (value.profiles?.count ?? 0) < 12 {
      value.profiles?.append(valid)
    } else {
      errorMessage = "Up to 12 work profiles can be stored."; return
    }
    if value.activeProfileID == valid.id { value = valid.applying(to: value) }
    settings = value
  }
  func showSection(_ title: String) {
    requestedSection = title; openDashboard?()
  }
  func recordNow(showDetails: Bool = true) {
    guard !maintenance else { return }
    guard !paused else { errorMessage = "Resume monitoring before starting a recording."; return }
    let tracker = analytics, expectedDemo = demo
    Task {
      do {
        _ = try await tracker.recordNow()
        guard expectedDemo == demo else { return }
        experience = await tracker.summary()
        experienceMessage =
          "Recording the available lead-in and the next 10 minutes. Capture limits apply."
        if showDetails { showSection("Recordings") }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func startSession(name: String, note: String, profileID: UUID) async throws {
    guard !maintenance else {
      throw HistoryError.database("Wait for history maintenance to finish.")
    }
    guard let profile = settings.profiles?.first(where: { $0.id == profileID }) else {
      throw HistoryError.database("Choose an available profile.")
    }
    activateProfile(profileID)
    let expectedDemo = demo, tracker = analytics
    await synchronizeEngineConfiguration()
    guard expectedDemo == demo, settings.activeProfileID == profileID else {
      throw HistoryError.database(
        "The monitoring context changed. Review the session profile again.")
    }
    _ = try await tracker.startSession(name: name, note: note, profile: profile)
    experience = await tracker.summary(); showSessionComposer = false
  }
  func endSession() {
    let tracker = analytics, expectedDemo = demo
    Task {
      do {
        try await tracker.endSession()
        if expectedDemo == demo { experience = await tracker.summary() }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func snooze(app: String, kind: ExperienceEventKind, minutes: Int) {
    let tracker = analytics, profileID = settings.activeProfile.id, expectedDemo = demo
    Task {
      do {
        try await tracker.snooze(profile: profileID, app: app, kind: kind, minutes: minutes)
        if expectedDemo == demo { experience = await tracker.summary() }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func cancelSnooze(_ id: UUID) {
    let tracker = analytics, expectedDemo = demo
    Task {
      do {
        try await tracker.cancelSnooze(id: id)
        if expectedDemo == demo { experience = await tracker.summary() }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func resetNormalRange(appKey: String? = nil) {
    let tracker = analytics, expectedDemo = demo, profile = settings.activeProfile.id
    Task {
      do {
        try await tracker.resetNormalRange(profile: profile, appKey: appKey)
        if expectedDemo == demo { experience = await tracker.summary() }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func createRecoverySnapshot() {
    guard !demo else {
      experienceMessage = "Simulation data stays separate from live recovery snapshots."; return
    }
    Task {
      do {
        guard let history else { throw HistoryError.database("History is unavailable.") }
        let url = try await history.createRecoverySnapshot()
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func restorePreMigrationHistory() {
    guard !demo && !maintenance else { return }
    Task {
      await beginHistoryMaintenance()
      do {
        guard let history else { throw HistoryError.database("History is unavailable.") }
        try await history.restorePreV2Backup()
        await liveExperience.reload()
        experience = await liveExperience.summary()
        try await refreshRestoredHistory()
        experienceMessage =
          "Pre-migration history restored. The replaced database is preserved as history.before-restore.sqlite. Resume monitoring when ready."
      } catch { errorMessage = error.localizedDescription }
      await finishHistoryMaintenance()
    }
  }
  func restorePreMigrationSettings() {
    guard !demo && !maintenance else { return }
    do {
      let restored = try SettingsStore().restorePreV2Backup()
      settings = restored.activeProfile.applying(to: restored)
      experienceMessage =
        "Pre-migration settings restored. The replaced settings remain in settings.before-restore.json."
    } catch { errorMessage = error.localizedDescription }
  }
}
