import AppKit
import SentinelCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
  @Published var fixSession: FixSession?
  @Published var fixHistory: [FixSession] = []
  @Published var fixReady = false
  @Published var errorKind: ProblemKind = .monitoringFailure
  @Published var snapshot: Snapshot?
  @Published var timeline: [TimelinePoint] = []
  @Published var incidents: [Incident] = []
  @Published var errorMessage: String?
  @Published var paused = false
  @Published var demo = false
  @Published var scenario: SimulationScenario = .stable
  @Published var notificationStatus = "Not requested"
  @Published var loginStatus = "Disabled"
  @Published var notificationTestResult: String?
  @Published var settings: SentinelCore.Settings {
    didSet {
      do { try settingsStore.save(settings) } catch { errorMessage = error.localizedDescription }
      if settings.warningFraction != oldValue.warningFraction
        || settings.criticalFraction != oldValue.criticalFraction
        || settings.growthMiB != oldValue.growthMiB
        || settings.swapGrowthMiB != oldValue.swapGrowthMiB
        || settings.watchRules != oldValue.watchRules
        || settings.excludedPaths != oldValue.excludedPaths
      {
        invalidateFix("Relevant settings changed. Assess a new plan.")
      }
      Task { await engine?.configure(settings) }
    }
  }
  let history: HistoryStore?
  private let settingsStore = SettingsStore()
  private var engine: MonitoringEngine?
  private var liveFixHistory: [FixSession] = []
  private var demoFixHistory: [FixSession] = []
  private var fixCoordinator: FixCoordinator?
  private let interventionGate = InterventionGate()
  private var fixObservation: Task<Void, Never>?
  private var pressureSource: (any DispatchSourceMemoryPressure)?
  private var wakeObserver: NSObjectProtocol?
  private var sleepingObserver: NSObjectProtocol?
  private var notificationDelegate: NotificationDelegate?
  var openDashboard: (() -> Void)?
  var openFix: (() -> Void)?
  private var historyRefresh: Date = .distantPast
  var selectedRange: TimeInterval = 900
  init() {
    settings = settingsStore.load()
    do { history = try HistoryStore() } catch {
      history = nil
      errorKind = .historyFailure
      errorMessage =
        "History unavailable: \(error.localizedDescription). Live monitoring continues."
    }
    engine = MonitoringEngine(settings: settings, history: history) { [weak self] update in
      await self?.receive(update)
    }
    if let engine {
      let runtime = NativeFixRuntime(engine: engine, gate: interventionGate)
      let store = history
      fixCoordinator = FixCoordinator(
        runtime: runtime, gate: interventionGate,
        save: { value in
          guard let store else {
            throw HistoryError.database(
              "Fix requires an available audit history. Monitoring continues; no action was sent.")
          }
          try await store.saveFix(value)
        }, publish: { [weak self] value in await self?.receiveFix(value) })
    }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    pressureSource = source
    source.setEventHandler { [weak self] in Task { @MainActor in self?.pressureChanged() } }
    source.activate()
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.invalidateFix("The Mac woke from sleep. Assess a new plan.")
        await self.engine?.resetAfterWake()
        await self.engine?.pause(self.paused)
        await self.engine?.sample()
      }
    }
    sleepingObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.invalidateFix("The Mac is sleeping; remaining Fix steps were cancelled.");
        await self?.engine?.pause(true)
      }
    }
    let delegate = NotificationDelegate()
    delegate.onOpen = { [weak self] in self?.openDashboard?() }
    notificationDelegate = delegate
    UNUserNotificationCenter.current().delegate = delegate
    let action = UNNotificationAction(
      identifier: "dashboard", title: "Open dashboard", options: .foreground)
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(identifier: "MEMORY_RISK", actions: [action], intentIdentifiers: [])
    ])
    refreshLoginStatus()
    Task {
      if let history {
        if let recovered = await history.recoveryMessage { errorMessage = recovered }
        do {
          try await history.recoverInterruptedFixes(); fixHistory = try await history.fixSessions();
          liveFixHistory = fixHistory
        } catch {
          errorMessage = "Fix history: \(error.localizedDescription)"; errorKind = .historyFailure
        }
        incidents = (try? await history.incidents()) ?? []
      }
      fixReady = true
      await refreshNotificationStatus()
      if CommandLine.arguments.contains("--demo") { await setDemo(true) }
      await engine?.start()
    }
  }
  private func pressureChanged() {
    guard let data = pressureSource?.data else { return }
    let value: Pressure =
      data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
    Task { await engine?.pressureEvent(value) }
  }
  private func receive(_ update: EngineUpdate) async {
    guard update.snapshot.demo == demo else { return }
    snapshot = update.snapshot
    if let seed = update.seed {
      timeline = seed
      incidents = []
    } else {
      timeline.append(update.snapshot.point)
    }
    timeline.removeAll { update.snapshot.date.timeIntervalSince($0.date) > selectedRange }
    if timeline.count > 800 { timeline.removeFirst(timeline.count - 800) }
    fixObservation?.cancel()
    fixObservation = Task { await fixCoordinator?.observe(update.snapshot) }
    if let error = update.error {
      errorMessage = "History write failed: \(error)"; errorKind = .historyFailure
    }
    if !update.incidents.isEmpty {
      incidents.insert(contentsOf: update.incidents, at: 0)
      incidents.sort { $0.date > $1.date }
      if incidents.count > 300 { incidents.removeLast(incidents.count - 300) }
      if !demo && settings.notifications && notificationStatus == "Allowed" {
        await notify(update.incidents)
      }
    }
    if !demo && Date().timeIntervalSince(historyRefresh) > 30 { await refreshTimeline() }
  }
  func refreshTimeline(range: TimeInterval? = nil) async {
    if let range { selectedRange = range }
    guard !demo, let history else { return }
    historyRefresh = Date()
    do {
      let points = try await history.timeline(since: Date().addingTimeInterval(-selectedRange))
      guard !demo else { return }
      timeline = points
    } catch { errorMessage = error.localizedDescription }
  }
  func setPaused(_ value: Bool) {
    invalidateFix("Monitoring pause state changed. Assess a new plan.")
    paused = value
    Task {
      await engine?.pause(value)
      if !value { await engine?.sample() }
    }
  }
  func setDemo(_ value: Bool) async {
    interventionGate.invalidate(demo: value)
    await fixCoordinator?.cancel(
      message: "Monitoring mode changed. No further native actions will be sent.")
    demo = value
    demoFixHistory = []
    fixHistory = value ? [] : liveFixHistory
    snapshot = nil
    timeline = []
    incidents = []
    await engine?.mode(demo: value, scenario: scenario)
    if !value {
      incidents = (try? await history?.incidents()) ?? []
      await refreshTimeline()
    }
  }
  func changeScenario(_ value: SimulationScenario) {
    invalidateFix("The simulation scenario changed. Assess a new plan.")
    scenario = value
    demoFixHistory = []; fixHistory = []
    Task { await engine?.mode(demo: true, scenario: value) }
  }
  func requestNotifications() async {
    do {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    } catch {
      errorMessage = "Notification permission: \(error.localizedDescription)";
      errorKind = .notifications
    }
    await refreshNotificationStatus()
  }
  func refreshNotificationStatus() async {
    let status: Int = await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { @Sendable state in
        continuation.resume(returning: state.authorizationStatus.rawValue)
      }
    }
    notificationStatus =
      status == UNAuthorizationStatus.authorized.rawValue
      ? "Allowed"
      : status == UNAuthorizationStatus.denied.rawValue
        ? "Denied in System Settings" : "Not requested"
  }
  private func notify(_ events: [Incident]) async {
    // A batch produces one concise notification, even when many related workers trigger together.
    guard let event = events.max(by: { $0.level < $1.level }) else { return }
    let content = UNMutableNotificationContent()
    content.title = "MemorySentinel · \(event.level.title)"
    content.subtitle =
      event.identity.map {
        "\(event.processName ?? "Process") · PID \($0.pid) · \(Format.bytes(event.footprint))"
      } ?? "System memory requires attention"
    content.body =
      "\(event.reason.prefix(350))\nSave work, review the dashboard, and close unneeded workloads."
    content.sound = .default
    content.categoryIdentifier = "MEMORY_RISK"
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    } catch { errorMessage = "Notification delivery failed: \(error.localizedDescription)" }
  }
  func testNotification() async {
    let identifier = UUID().uuidString
    let content = UNMutableNotificationContent()
    content.title = "MemorySentinel test"
    content.body = "Native notifications are working. No real incident was created."
    content.categoryIdentifier = "MEMORY_RISK"
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      let delivered: Bool = await withCheckedContinuation { continuation in
        UNUserNotificationCenter.current().getDeliveredNotifications { @Sendable notifications in
          continuation.resume(
            returning: notifications.contains { $0.request.identifier == identifier })
        }
      }
      notificationTestResult =
        delivered
        ? "Test confirmed in Notification Center"
        : "Submitted to macOS; banner display follows system settings"
    } catch {
      errorMessage = error.localizedDescription
      notificationTestResult = "Delivery failed: \(error.localizedDescription)"
    }
  }
  func refreshLoginStatus() {
    switch SMAppService.mainApp.status {
    case .enabled: loginStatus = "Enabled"
    case .requiresApproval: loginStatus = "Approval required in System Settings"
    case .notRegistered: loginStatus = "Disabled"
    case .notFound: loginStatus = "App service not found"
    @unknown default: loginStatus = "Unavailable"
    }
  }
  func setLogin(_ value: Bool) {
    do {
      if value {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLoginStatus()
    } catch {
      errorMessage = "Launch at login: \(error.localizedDescription)"; errorKind = .loginItem
      refreshLoginStatus()
    }
  }
  func export(csv: Bool) {
    guard !demo else { errorMessage = "Return to live mode to export recorded history."; return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      "MemorySentinel-\(Int(Date().timeIntervalSince1970)).\(csv ? "csv" : "json")"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        guard let history else { throw HistoryError.database("History is unavailable") }
        try await history.export(to: url, csv: csv)
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func clearHistory() {
    if demo { demoFixHistory = []; fixHistory = []; timeline = []; incidents = []; return }
    interventionGate.invalidate()
    Task {
      await fixCoordinator?.cancel(
        message: "History was explicitly cleared; remaining Fix steps were cancelled.")
      do {
        try await history?.clear()
        timeline = []
        incidents = []
        fixHistory = []; liveFixHistory = []
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func activityMonitor() {
    let token = interventionGate.current()
    guard !demo && !token.demo else { return }
    do {
      _ = try interventionGate.liveEffect(token: token) {
        NSWorkspace.shared.open(
          URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func exclude(_ process: ProcessRecord) {
    guard !process.path.isEmpty else { return }
    if !settings.excludedPaths.contains(process.path) {
      settings.excludedPaths.append(process.path)
    }
  }
  private func receiveFix(_ value: FixSession) {
    if let current = fixSession, (current.revision ?? 0) > (value.revision ?? 0) { return }
    fixSession = value
    if value.demo {
      demoFixHistory.removeAll { $0.id == value.id }; demoFixHistory.insert(value, at: 0);
      demoFixHistory = Array(demoFixHistory.prefix(50))
      if demo { fixHistory = demoFixHistory }
    } else {
      liveFixHistory.removeAll { $0.id == value.id }; liveFixHistory.insert(value, at: 0);
      liveFixHistory = Array(liveFixHistory.prefix(100))
      if !demo { fixHistory = liveFixHistory }
    }
    if value.approvedAction == .restartMonitoring && value.phase == .verifying { paused = false }
  }
  func beginFix(_ origin: FixOrigin = FixOrigin()) {
    guard fixReady else { return }
    Task { await fixCoordinator?.prepare(origin: origin, settings: settings) }
  }
  func approveFix(
    _ action: FixAction, sessionID: UUID, planID: UUID, forceConfirmed: Bool = false
  ) {
    guard let session = fixSession, session.id == sessionID,
      session.phase == .awaitingApproval, session.plan?.id == planID
    else { return }
    Task {
      await fixCoordinator?.approve(
        sessionID: sessionID, planID: planID, action: action, forceConfirmed: forceConfirmed)
    }
  }
  func cancelFix() { invalidateFix("Cancelled by you. A request already sent cannot be undone.") }
  private func invalidateFix(_ message: String) {
    interventionGate.invalidate()
    Task { await fixCoordinator?.cancel(message: message) }
  }

}
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  @MainActor var onOpen: (() -> Void)?
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) { completionHandler([.banner, .sound, .list]) }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in onOpen?() }
    completionHandler()
  }
}
