import AppKit
import SentinelCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let icon = NSImage(contentsOf: url)
    {
      NSApp.applicationIconImage = icon
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(prepareMinimizedWindow(_:)),
      name: NSWindow.willMiniaturizeNotification, object: nil)
  }

  @objc private func prepareMinimizedWindow(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    window.miniwindowImage = NSApp.applicationIconImage
  }
}

@main enum MemorySentinelLauncher {
  @MainActor static func main() {
    // AppKit reads this opt-in while constructing NSApplication, before App.main().
    // It enables custom minimized-window icons instead of the default screenshot.
    UserDefaults.standard.register(defaults: ["AppleDockIconEnabled": true])
    MemorySentinelApp.main()
  }
}
struct MemorySentinelApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AppModel()
  var body: some Scene {
    Window("MemorySentinel", id: "dashboard") {
      DashboardContainer().environmentObject(model).preferredColorScheme(
        model.settings.theme == "dark" ? .dark : model.settings.theme == "light" ? .light : nil)
    }.defaultSize(width: 1180, height: 800).windowStyle(.hiddenTitleBar)
    Window("MemorySentinel · Fix", id: "fix") {
      FixView().environmentObject(model).preferredColorScheme(
        model.settings.theme == "dark" ? .dark : model.settings.theme == "light" ? .light : nil)
    }.defaultSize(width: 800, height: 760)
    MenuBarExtra {
      MenuPopover().environmentObject(model).preferredColorScheme(
        model.settings.theme == "light" ? .light : .dark)
    } label: {
      HStack(spacing: 4) {
        if model.settings.menuIcon {
          Image(
            systemName: model.paused ? "pause.circle" : (model.snapshot?.risk ?? .normal).symbol
          ).symbolRenderingMode(.palette).foregroundStyle((model.snapshot?.risk ?? .normal).color)
        }
        Text(model.demo ? "DEMO" : model.paused ? "Paused" : menuValue).monospacedDigit()
      }.accessibilityLabel("MemorySentinel \(model.snapshot?.risk.title ?? "Loading") \(menuValue)")
    }.menuBarExtraStyle(.window)
    SwiftUI.Settings {
      SettingsView().environmentObject(model).preferredColorScheme(
        model.settings.theme == "dark" ? .dark : model.settings.theme == "light" ? .light : nil)
    }
  }
  private var menuValue: String {
    guard let s = model.snapshot else { return "…" }
    return Format.bytes(
      model.settings.menuMetric == "system"
        ? s.system.used : model.settings.menuMetric == "swap" ? s.system.swap : s.monitoredBytes)
  }
}

// Release heavy dashboard views on close and rebuild them when its own window is visible.
struct DashboardContainer: View {
  @EnvironmentObject var model: AppModel
  @State private var presented = true
  @State private var dashboardWindow: NSWindow?
  var body: some View {
    ZStack {
      if presented { DashboardView() } else { Color.clear.frame(minWidth: 980, minHeight: 650) }
    }
    .onAppear { presented = true }
    .onChange(of: model.snapshot?.date) { _, _ in
      if dashboardWindow?.isVisible == true && !presented { presented = true }
    }
    .background(
      DashboardWindowProbe { window in
        if dashboardWindow !== window { dashboardWindow = window }
        if window?.isVisible == true && !presented { presented = true }
      }.frame(width: 0, height: 0)
    )
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
      if let window = event.object as? NSWindow, window === dashboardWindow {
        presented = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      event in
      if let window = event.object as? NSWindow, window === dashboardWindow { presented = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExposeNotification)) { event in
      if let window = event.object as? NSWindow, window === dashboardWindow { presented = true }
    }
  }
}

private struct DashboardWindowProbe: NSViewRepresentable {
  let report: @MainActor (NSWindow?) -> Void
  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView(); view.report = report; return view
  }
  func updateNSView(_ view: ProbeView, context: Context) {
    view.report = report
    view.reportWindow()
  }
  final class ProbeView: NSView {
    var report: (@MainActor (NSWindow?) -> Void)?
    private var pending: Task<Void, Never>?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reportWindow()
    }
    func reportWindow() {
      pending?.cancel()
      pending = Task { @MainActor [weak self] in
        guard !Task.isCancelled, let self else { return }
        report?(window)
        pending = nil
      }
    }
  }
}
