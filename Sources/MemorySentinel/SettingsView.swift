import SentinelCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @State private var label = ""
  @State private var value = ""
  @State private var kind: WatchRule.Kind = .executable
  @State private var clearConfirm = false
  var body: some View {
    TabView {
      Form {
        Section("Monitoring") {
          Picker("Sampling interval", selection: $model.settings.interval) {
            ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
          }
          Toggle(
            "Launch at login",
            isOn: Binding(get: { model.loginStatus == "Enabled" }, set: { model.setLogin($0) }))
          LabeledContent("Login item status", value: model.loginStatus)
          FixButton(origin: FixOrigin(issue: .loginItem), title: "Fix launch at login…")
          if model.loginStatus == "App service not found" {
            Text(
              "This local build is not recognized by ServiceManagement. Registration may require a Developer ID signed build in Applications."
            ).font(.caption).foregroundStyle(.secondary)
          }
          if model.loginStatus.contains("Approval") {
            Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
          }
        }
        Section("Appearance") {
          Picker("Theme", selection: $model.settings.theme) {
            Text("System").tag("system")
            Text("Dark").tag("dark")
            Text("Light").tag("light")
          }
          Picker("Menu bar metric", selection: $model.settings.menuMetric) {
            Text("Monitored footprint").tag("monitored")
            Text("System used estimate").tag("system")
            Text("Swap").tag("swap")
          }
          Toggle("Show status icon", isOn: $model.settings.menuIcon)
        }
        Text(
          "The menu bar watchdog keeps sampling after the dashboard closes. Quit from the menu bar to stop it."
        ).font(.caption).foregroundStyle(.secondary)
      }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
      Form {
        Section("Risk thresholds · scale with physical memory") {
          slider(
            "Warning process footprint", value: $model.settings.warningFraction, range: 0.05...0.80,
            percent: true)
          slider(
            "Critical process / group footprint", value: $model.settings.criticalFraction,
            range: 0.10...0.95, percent: true)
          Text(
            "Critical threshold must exceed warning. High footprint alone raises a warning; system pressure and growth provide additional evidence. Defaults on 18 GiB: 5.4 GiB warning, 8.1 GiB critical footprint."
          ).font(.caption).foregroundStyle(.secondary)
          slider("Sustained growth (MiB/min)", value: $model.settings.growthMiB, range: 10...1000)
          slider("Swap growth (MiB/min)", value: $model.settings.swapGrowthMiB, range: 10...1000)
        }
        Section("Notifications") {
          Toggle("Warning and critical notifications", isOn: $model.settings.notifications)
          slider("Cooldown (seconds)", value: $model.settings.cooldown, range: 60...1800)
          LabeledContent("System permission", value: model.notificationStatus)
          FixButton(origin: FixOrigin(issue: .notifications), title: "Fix notifications…")
          HStack {
            Button("Request permission") { Task { await model.requestNotifications() } }
            Button("Send test notification") { Task { await model.testNotification() } }.disabled(
              model.notificationStatus != "Allowed")
          }
          if let result = model.notificationTestResult {
            Text(result).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.formStyle(.grouped).tabItem { Label("Alerts", systemImage: "bell.badge") }
      Form {
        Section("Automatic targets") {
          Text(
            "ChatGPT and Codex bundle IDs; known Codex CLI distribution paths; verified descendants. Generic node, python and shell names are never sufficient evidence."
          ).font(.callout)
        }
        Section("Custom exact matches") {
          TextField("Group label", text: $label)
          Picker("Match", selection: $kind) {
            Text("Executable path").tag(WatchRule.Kind.executable)
            Text("Bundle ID").tag(WatchRule.Kind.bundle)
          }
          TextField(
            kind == .executable ? "/absolute/path/to/executable" : "com.example.app", text: $value)
          Button("Add watch rule") {
            model.settings.watchRules.append(
              .init(
                label: label.trimmingCharacters(in: .whitespaces),
                value: value.trimmingCharacters(in: .whitespaces), kind: kind))
            value = ""
            label = ""
          }.disabled(
            label.trimmingCharacters(in: .whitespaces).isEmpty
              || value.trimmingCharacters(in: .whitespaces).isEmpty
              || kind == .executable && !value.hasPrefix("/"))
          ForEach(model.settings.watchRules) { rule in
            HStack {
              VStack(alignment: .leading) {
                Text(rule.label)
                Text(rule.value).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Remove") { model.settings.watchRules.removeAll { $0.id == rule.id } }
            }
          }
        }
        if !model.settings.excludedPaths.isEmpty {
          Section("Excluded executable paths") {
            ForEach(model.settings.excludedPaths, id: \.self) { path in
              HStack {
                Text(path).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Restore") { model.settings.excludedPaths.removeAll { $0 == path } }
              }
            }
          }
        }
      }.formStyle(.grouped).tabItem { Label("Watchlist", systemImage: "list.bullet.rectangle") }
      Form {
        Section("Local retention") {
          Stepper(
            "Detailed samples: \(model.settings.detailHours) hours",
            value: $model.settings.detailHours, in: 1...24)
          Stepper(
            "Minute aggregates: \(model.settings.aggregateDays) days",
            value: $model.settings.aggregateDays, in: 1...7)
          Stepper(
            "Incidents: \(model.settings.incidentDays) days", value: $model.settings.incidentDays,
            in: 1...90)
          Text(
            "Hard limits: 48 MiB detailed payload, 20,000 detailed samples, 10,080 minute buckets and 2,000 incidents. The oldest records may expire earlier to stay within these limits."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Diagnostics") {
          HStack {
            Button("Export JSON") { model.export(csv: false) }
            Button("Export CSV") { model.export(csv: true) }
          }
          Button("Show local data folder") { NSWorkspace.shared.open(LocalPaths.directory) }
          Button("Delete all history…", role: .destructive) { clearConfirm = true }
          Text(
            "No command-line arguments or environment variables are collected. Diagnostic JSON includes process identities in incidents; CSV includes minute system and watched totals. All data stays on this Mac."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).tabItem { Label("Data", systemImage: "externaldrive") }
    }.padding(10).frame(width: 650, height: 620)
      .onAppear {
        Task { await model.refreshNotificationStatus() }; model.refreshLoginStatus()
      }
      .onDisappear {
        let valid = model.settings.validated()
        if valid != model.settings { model.settings = valid }
      }
      .onChange(of: model.settings.warningFraction) { _, new in
        if model.settings.criticalFraction < new + 0.05 {
          model.settings.criticalFraction = new + 0.05
        }
      }
      .onChange(of: model.settings.criticalFraction) { _, new in
        if new <= model.settings.warningFraction {
          model.settings.warningFraction = max(0.05, new - 0.05)
        }
      }
      .alert("Delete all recorded history?", isPresented: $clearConfirm) {
        Button("Cancel", role: .cancel) {}
        Button("Delete history", role: .destructive) { model.clearHistory() }
      } message: {
        Text(
          "This permanently removes local samples, aggregates and incidents. Monitoring continues and settings are preserved."
        )
      }
  }
  private func slider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false
  ) -> some View {
    VStack(alignment: .leading) {
      HStack {
        Text(title)
        Spacer()
        Text(percent ? "\(Int(value.wrappedValue*100))%" : "\(Int(value.wrappedValue))")
          .monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }.padding(.vertical, 3)
  }
}
