import AppKit
import SentinelCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
  @Published var control = ControlSummary()
  @Published var experience = ExperienceSummary()
  @Published var experienceMessage: String?
  @Published var requestedSection: String?
  @Published var showSessionComposer = false
  @Published var reportRequest: ReportRequest?
  @Published var maintenance = false
  @Published var exportingDiagnostics = false
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
      var normalized = settings.validated()
      if normalized.activeProfileID == oldValue.activeProfileID,
        normalized.watchRules != oldValue.watchRules
          || normalized.excludedPaths != oldValue.excludedPaths
          || normalized.disabledBuiltIns != oldValue.disabledBuiltIns
          || normalized.notifications != oldValue.notifications,
        let i = normalized.profiles?.firstIndex(where: { $0.id == normalized.activeProfileID })
      {
        normalized.profiles![i].watchRules = normalized.watchRules
        normalized.profiles![i].excludedPaths = normalized.excludedPaths
        normalized.profiles![i].disabledBuiltIns = normalized.disabledBuiltIns ?? []
        normalized.profiles![i].notifications = normalized.notifications
      }
      if normalized != settings { settings = normalized }
      do { try settingsStore.save(settings) } catch { errorMessage = error.localizedDescription }
      if settings.analysisSignature != oldValue.analysisSignature {
        invalidateFix("Relevant settings changed. Assess a new plan.")
        experience.apps = []; experience.alerts = []
      }
      if settings.controls.externalActionsEnabled != oldValue.controls.externalActionsEnabled {
        automationGate.invalidate()
        if !settings.controls.externalActionsEnabled, fixSession?.authority == .policy {
          invalidateFix("External automation was stopped. No further steps will be sent.")
        }
      }
      configureAutomation()
      configurationRevision &+= 1
      let revision = configurationRevision, value = settings
      Task { await engine?.configure(value, revision: revision) }
    }
  }
  let history: HistoryStore?
  let liveExperience: ExperienceCoordinator
  let demoExperience: ExperienceCoordinator
  let liveControl: ControlCoordinator
  let demoControl: ControlCoordinator
  var controller: ControlCoordinator { demo ? demoControl : liveControl }
  var analytics: ExperienceCoordinator { demo ? demoExperience : liveExperience }
  private var configurationRevision: UInt64 = 0
  private let settingsStore = SettingsStore()
  var engine: MonitoringEngine?
  private var liveFixHistory: [FixSession] = []
  private var demoFixHistory: [FixSession] = []
  var fixCoordinator: FixCoordinator?
  let interventionGate = InterventionGate()
  lazy var automationGate = AutomationGate(intervention: interventionGate)
  var nativeRuntime: NativeFixRuntime?
  var automationTask: Task<Void, Never>?
  var automationWarmup: Double?
  var lastAutomationSample: (Date, Double)?
  var manualRequestPending = false
  var selfCareTask: Task<Void, Never>?
  var selfCareBudget = SelfRepairBudget()
  var sampleHeartbeat = ProcessInfo.processInfo.systemUptime
  @Published var selfCareStatus = "Waiting for monitoring"
  @Published var automationReasons: [UUID: String] = [:]
  @Published var automationMessage: String?
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
    let loaded = settingsStore.load()
    settings = loaded.activeProfile.applying(to: loaded).validated()
    do { history = try HistoryStore() } catch {
      history = nil
      errorKind = .historyFailure
      errorMessage =
        "History unavailable: \(error.localizedDescription). Live monitoring continues."
    }
    liveExperience = ExperienceCoordinator(history: history)
    demoExperience = ExperienceCoordinator(history: nil, demo: true)
    liveControl = ControlCoordinator(store: ControlStore())
    demoControl = ControlCoordinator(store: nil, demo: true)
    engine = MonitoringEngine(
      settings: settings, history: history,
      experience: liveExperience, demoExperience: demoExperience
    ) { [weak self] update in
      await self?.receive(update)
    }
    if let engine {
      let runtime = NativeFixRuntime(
        engine: engine, gate: interventionGate, automationGate: automationGate,
        repairObservers: { [weak self] in
          self?.resetPressureObserver(); ApplicationIconCache.shared.clear()
        })
      nativeRuntime = runtime
      let store = history
      fixCoordinator = FixCoordinator(
        runtime: runtime, gate: interventionGate,
        save: { value in
          guard let store else {
            throw HistoryError.database(
              "Fix requires an available audit history. Monitoring continues; no action was sent.")
          }
          try await store.saveFix(value)
        }, publish: { [weak self] value in await self?.receiveFix(value) },
        automationGate: automationGate)
    }
    resetPressureObserver()
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.invalidateFix("The Mac woke from sleep. Assess a new plan.")
        await self.analytics.interrupt(
          reason: "The Mac slept or woke; observation continuity changed.")
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
        await self?.analytics.interrupt(reason: "System sleep interrupted observation.")
        await self?.engine?.pause(true)
      }
    }
    let delegate = NotificationDelegate()
    delegate.onOpen = { [weak self] episodeID in
      if episodeID != nil { self?.requestedSection = "Activity" }
      self?.openDashboard?()
    }
    notificationDelegate = delegate
    UNUserNotificationCenter.current().delegate = delegate
    let action = UNNotificationAction(
      identifier: "dashboard", title: "Open dashboard", options: .foreground)
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(identifier: "MEMORY_RISK", actions: [action], intentIdentifiers: [])
    ])
    refreshLoginStatus()
    Task {
      await liveExperience.restore()
      await liveControl.restore()
      control = await liveControl.summary()
      configureAutomation()
      experience = await liveExperience.summary()
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
      startSelfCare()
    }
  }
  private func resetPressureObserver() {
    pressureSource?.cancel()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    pressureSource = source
    source.setEventHandler { [weak self] in Task { @MainActor in self?.pressureChanged() } }
    source.activate()
  }
  private func pressureChanged() {
    guard let data = pressureSource?.data else { return }
    let value: Pressure =
      data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
    Task { await engine?.pressureEvent(value) }
  }
  private func receive(_ update: EngineUpdate) async {
    guard update.snapshot.demo == demo else { return }
    if let signature = update.configuration, signature != settings.analysisSignature { return }
    if let state = update.experience { experience = state }
    if update.snapshot.system.pressure == .critical && snapshot?.system.pressure != .critical {
      ApplicationIconCache.shared.clear()
    }
    snapshot = update.snapshot
    sampleHeartbeat = ProcessInfo.processInfo.systemUptime
    if let seed = update.seed {
      timeline = seed
      incidents = []
    } else {
      timeline.append(update.snapshot.point)
    }
    timeline.removeAll { update.snapshot.date.timeIntervalSince($0.date) > selectedRange }
    let visualLimit = update.snapshot.system.pressure == .critical ? 240 : 800
    if timeline.count > visualLimit { timeline.removeFirst(timeline.count - visualLimit) }
    fixObservation?.cancel()
    fixObservation = Task { await fixCoordinator?.observe(update.snapshot) }
    if let error = update.error {
      errorMessage = "History write failed: \(error)"; errorKind = .historyFailure
    }
    if !update.incidents.isEmpty {
      incidents.insert(contentsOf: update.incidents, at: 0)
      incidents.sort { $0.date > $1.date }
      if incidents.count > 300 { incidents.removeLast(incidents.count - 300) }
    }
    let controlUpdate = await controller.ingest(
      snapshot: update.snapshot, settings: settings,
      experience: experience, uptime: ProcessInfo.processInfo.systemUptime,
      deliveryAllowed: settings.notifications && notificationStatus == "Allowed")
    guard update.snapshot.demo == demo else { return }
    control = controlUpdate.summary
    configureAutomation()
    scheduleAutomation(update.snapshot)
    for notice in controlUpdate.notices { await notifyEpisode(notice) }
    if !demo && Date().timeIntervalSince(historyRefresh) > 30 { await refreshTimeline() }
  }
  func refreshTimeline(range: TimeInterval? = nil) async {
    if let range { selectedRange = range }
    guard !demo, let history else { return }
    historyRefresh = Date()
    do {
      let points = try await history.timeline(since: Date().addingTimeInterval(-selectedRange))
      guard !demo else { return }
      timeline = Array(points.suffix(snapshot?.system.pressure == .critical ? 240 : 800))
    } catch { errorMessage = error.localizedDescription }
  }
  func setPaused(_ value: Bool) {
    guard !maintenance else { return }
    invalidateFix("Monitoring pause state changed. Assess a new plan.")
    paused = value
    let tracker = analytics
    Task {
      if value { await tracker.interrupt(reason: "Monitoring paused by you.") }
      await engine?.pause(value)
      if !value { await engine?.sample() }
    }
  }
  func setDemo(_ value: Bool) async {
    guard !maintenance else { return }
    interventionGate.invalidate(demo: value)
    await fixCoordinator?.cancel(
      message: "Monitoring mode changed. No further native actions will be sent.")
    demo = value
    automationWarmup = nil; lastAutomationSample = nil
    automationGate.invalidate(); configureAutomation()
    if value { await demoControl.resetDemo() }
    await controller.restore()
    control = await controller.summary()
    experience = await analytics.summary()
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
    Task {
      await demoControl.resetDemo()
      await engine?.mode(demo: true, scenario: value)
    }
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
  private func notifyEpisode(_ notice: EpisodeNotice) async {
    guard !demo, settings.notifications, notificationStatus == "Allowed" else {
      await liveControl.cancelReservation(notice); return
    }
    let content = UNMutableNotificationContent()
    content.title = "MemorySentinel · \(notice.title)"
    content.body = String(notice.body.prefix(1000))
    content.sound = notice.sound ? .default : nil
    content.categoryIdentifier = "MEMORY_RISK"
    content.userInfo = ["episodeID": notice.episodeID.uuidString]
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    } catch {
      await liveControl.deliveryFailed(notice, message: error.localizedDescription)
      control = await controller.summary()
    }
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
  func export(csv: Bool, window: NSWindow? = nil) {
    guard !demo else { errorMessage = "Return to live mode to export recorded history."; return }
    guard !exportingDiagnostics else { return }
    exportingDiagnostics = true
    Task { @MainActor in
      defer { exportingDiagnostics = false }
      do {
        guard
          let url = try await SaveDestination.choose(
            name: "MemorySentinel-\(Int(Date().timeIntervalSince1970)).\(csv ? "csv" : "json")",
            type: csv ? .commaSeparatedText : .json, window: window
          ), !demo
        else { return }
        guard let history = self.history else {
          throw HistoryError.database("History is unavailable")
        }
        try await history.export(to: url, csv: csv)
      } catch { self.errorMessage = error.localizedDescription }
    }
  }
  func clearHistory() {
    if demo { demoFixHistory = []; fixHistory = []; timeline = []; incidents = []; return }
    guard !maintenance else { return }
    Task {
      guard !maintenance else { return }
      await beginHistoryMaintenance()
      do {
        try await history?.clear()
        await liveExperience.reload()
        await liveControl.clearHistory()
        control = await liveControl.summary()
        experience = await liveExperience.summary()
        timeline = []
        incidents = []
        fixHistory = []; liveFixHistory = []; fixSession = nil
        experienceMessage = "History cleared. Monitoring is paused; resume when ready."
      } catch { errorMessage = error.localizedDescription }
      await finishHistoryMaintenance()
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
  private func receiveFix(_ value: FixSession) async {
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
    await (value.demo ? demoExperience : liveExperience).observeFix(value)
    await (value.demo ? demoControl : liveControl).observeFix(value)
    if value.demo == demo { control = await controller.summary() }
    configureAutomation()
    if value.demo == demo { experience = await analytics.summary() }
  }
  func beginFix(_ origin: FixOrigin = FixOrigin()) {
    guard fixReady && !maintenance else { return }
    if let fixSession, (fixSession.authority ?? .manual) == .manual,
      [.assessing, .executing, .verifying].contains(fixSession.phase)
    {
      return
    }
    manualRequestPending = true
    automationGate.invalidate(); automationTask?.cancel()
    interventionGate.invalidate(); configureAutomation()
    Task {
      if fixSession?.authority != .manual && fixSession?.phase.active == true {
        await fixCoordinator?.cancel(message: "A manual Fix has priority over automation.")
      }
      await synchronizeEngineConfiguration()
      await fixCoordinator?.prepare(origin: origin, settings: settings)
      manualRequestPending = false; configureAutomation()
    }
  }
  func approveFix(
    _ action: FixAction, sessionID: UUID, planID: UUID, forceConfirmed: Bool = false
  ) {
    guard let session = fixSession, session.id == sessionID,
      !maintenance,
      session.phase == .awaitingApproval, session.plan?.id == planID
    else { return }
    Task {
      await fixCoordinator?.approve(
        sessionID: sessionID, planID: planID, action: action, forceConfirmed: forceConfirmed)
    }
  }
  func cancelFix() { invalidateFix("Cancelled by you. A request already sent cannot be undone.") }
  func invalidateFix(_ message: String) {
    selfCareBudget.resetContinuity(); sampleHeartbeat = ProcessInfo.processInfo.systemUptime
    automationWarmup = nil; lastAutomationSample = nil
    automationGate.invalidate(); automationTask?.cancel()
    interventionGate.invalidate()
    Task { await fixCoordinator?.cancel(message: message) }
  }
  func synchronizeEngineConfiguration() async {
    await engine?.configure(settings, revision: configurationRevision)
  }
  func beginHistoryMaintenance() async {
    maintenance = true; paused = true
    invalidateFix("History maintenance invalidated pending approvals.")
    await fixCoordinator?.cancel(message: "History maintenance cancelled remaining steps.")
    await engine?.suspendForMaintenance()
  }
  func finishHistoryMaintenance() async {
    await engine?.finishMaintenance(); paused = true; maintenance = false
  }
  func refreshRestoredHistory() async throws {
    try await history?.recoverInterruptedFixes()
    incidents = try await history?.incidents() ?? []
    liveFixHistory = try await history?.fixSessions() ?? []
    fixHistory = liveFixHistory; fixSession = nil; timeline = []
  }

}
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  @MainActor var onOpen: ((UUID?) -> Void)?
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) { completionHandler([.banner, .sound, .list]) }
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let episode = (response.notification.request.content.userInfo["episodeID"] as? String).flatMap(
      UUID.init(uuidString:))
    Task { @MainActor in onOpen?(episode) }
    completionHandler()
  }
}
