import Charts
import SentinelCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) var openWindow
  @Environment(\.openSettings) var openSettings
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var section = "Overview"
  @State private var onboarding = false
  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(spacing: 0) {
        header
        Divider().opacity(0.5)
        if let error = model.errorMessage ?? model.experience.error {
          HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(error).font(.caption)
            Spacer()
            FixButton(origin: FixOrigin(issue: model.errorKind))
            Button("Dismiss") { model.errorMessage = nil }
          }.padding(12).background(.orange.opacity(0.12))
        }
        if let message = model.experienceMessage {
          HStack {
            Text(message).font(.caption); Spacer();
            Button("Dismiss") { model.experienceMessage = nil }
          }
          .padding(12).background(.mint.opacity(0.08))
        }
        if model.demo || model.paused {
          HStack {
            Image(systemName: model.demo ? "testtube.2" : "pause.circle")
            Text(
              model.demo
                ? "SIMULATION MODE · Synthetic values · Process actions and native incident notifications disabled"
                : "MONITORING PAUSED · Values are from the last sample"
            ).font(.system(size: 11, weight: .semibold))
            Spacer()
            Button(model.demo ? "Return to live" : "Resume") {
              if model.demo { Task { await model.setDemo(false) } } else { model.setPaused(false) }
            }
          }.padding(12).background(.yellow.opacity(0.12))
        }
        Group {
          switch section {
          case "Processes": ProcessExplorer()
          case "Incidents": IncidentView()
          case "Profiles": ProfilesView()
          case "Recordings": RecordingsView()
          case "Sessions": SessionsView()
          case "Simulation": simulationView
          default: overview
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Color(nsColor: .windowBackgroundColor))
    }.frame(minWidth: 980, minHeight: 650)
      .disabled(model.maintenance)
      .overlay {
        if model.maintenance {
          ProgressView("Restoring local history…").padding(30).background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
      }
      .onAppear {
        if let requested = model.requestedSection {
          section = requested; model.requestedSection = nil
        }
        onboarding = !model.settings.onboardingComplete
        model.openFix = {
          openWindow(id: "fix"); NSApp.activate(ignoringOtherApps: true)
        }
        model.openDashboard = {
          openWindow(id: "dashboard")
          NSApp.activate(ignoringOtherApps: true)
        }
      }
      .sheet(isPresented: $onboarding) { onboardingView }
      .sheet(item: $model.reportRequest) { ReportPreview(request: $0).environmentObject(model) }
      .onChange(of: model.requestedSection) { _, requested in
        if let requested { section = requested; model.requestedSection = nil }
      }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "shield.lefthalf.filled").font(.system(size: 28, weight: .light))
          .foregroundStyle(.mint)
        VStack(alignment: .leading, spacing: 2) {
          Text("Memory").font(.system(size: 17, weight: .bold))
          Text("Sentinel").font(.system(size: 17, weight: .light)).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 25).padding(.horizontal, 14)
      Text("WORKSPACE").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.tertiary)
        .padding(.horizontal, 14).padding(.bottom, 8)
      nav("Overview", "square.grid.2x2")
      nav("Processes", "cpu")
      nav("Incidents", "clock.arrow.circlepath")
      nav("Recordings", "record.circle")
      nav("Sessions", "timer")
      nav("Profiles", "slider.horizontal.3")
      nav("Simulation", "testtube.2")
      Spacer()
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Circle().fill(model.paused ? .yellow : .mint).frame(width: 6, height: 6)
          Text(model.paused ? "Sampling paused" : "Watchdog active").font(
            .system(size: 11, weight: .medium))
        }
        Text("\(model.settings.interval)s interval · Local data only").font(.system(size: 10))
          .foregroundStyle(.secondary)
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
        .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      Button {
        openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }.buttonStyle(.plain).foregroundStyle(.secondary)
    }.padding(14).frame(width: 184).background(.ultraThinMaterial)
  }
  private func nav(_ title: String, _ symbol: String) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { section = title }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: symbol).frame(width: 18)
        Text(title).font(.system(size: 12, weight: section == title ? .semibold : .regular))
          .lineLimit(1).minimumScaleFactor(0.85)
        Spacer()
        if title == "Incidents" && !model.incidents.isEmpty {
          Text("\(model.incidents.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(
            .secondary)
        }
      }.padding(.horizontal, 13).padding(.vertical, 11).background(
        section == title ? Color.mint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9)
      ).foregroundStyle(section == title ? .mint : .secondary)
    }.buttonStyle(.plain)
  }
  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(section).font(.system(size: 23, weight: .semibold))
        Text("Your memory, under watch.").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
      if let s = model.snapshot {
        ProfilePicker().frame(width: 150)
        VStack(alignment: .trailing, spacing: 5) {
          RiskBadge(level: s.risk)
          SampleFreshness()
        }
      }
      Button {
        model.setPaused(!model.paused)
      } label: {
        Image(systemName: model.paused ? "play.fill" : "pause.fill")
      }.buttonStyle(.bordered).help(model.paused ? "Resume monitoring" : "Pause monitoring")
        .padding(.leading, 12)
    }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 20)
  }
  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let s = model.snapshot {
          let advisory = model.experience.alerts.max { $0.level < $1.level }
          let headlineRisk = max(s.risk, advisory?.level ?? .normal)
          let advisoryLeads = (advisory?.level ?? .normal) > s.risk
          HStack(spacing: 16) {
            Image(systemName: headlineRisk.symbol).font(.system(size: 28)).foregroundStyle(
              headlineRisk.color)
            VStack(alignment: .leading, spacing: 5) {
              Text(
                s.risk >= .warning
                  ? "Memory signals need your attention"
                  : s.hasUnavailableMemoryReadings
                    ? "Some memory signals are unavailable"
                    : advisoryLeads
                      ? advisory?.title ?? "An application needs attention"
                      : s.risk == .normal
                        ? "Memory is in a healthy range"
                        : s.risk == .elevated
                          ? "Memory activity needs a closer look"
                          : "Memory pressure needs your attention"
              ).font(.system(size: 18, weight: .medium))
              Text(
                advisoryLeads
                  ? advisory?.evidence ?? "Review the application cards below."
                  : s.reasons.first ?? "No warning signals detected in the available measurements."
              )
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            FixButton(
              origin: FixOrigin(
                identity: advisoryLeads ? advisory?.event.process : nil, demoSource: model.demo)
            )
            .buttonStyle(.borderedProminent).tint(headlineRisk.color).foregroundStyle(.black)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
            headlineRisk.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16)
          ).overlay(RoundedRectangle(cornerRadius: 16).stroke(headlineRisk.color.opacity(0.17)))
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 3), spacing: 13
          ) {
            MetricCard(
              title: "System used", value: Format.bytes(s.system.used),
              subtitle: "of \(Format.bytes(s.system.total)) physical · estimated",
              symbol: "memorychip")
            MetricCard(
              title: "Monitored footprint", value: Format.bytes(s.monitoredBytes),
              subtitle: "\(s.monitored.count) attributed processes · accounting sum",
              symbol: "square.stack.3d.up")
            MetricCard(
              title: "Memory pressure", value: s.system.pressure.rawValue.capitalized,
              subtitle: "macOS kernel / dispatch pressure signal", symbol: "waveform.path.ecg",
              color: s.risk.color)
            MetricCard(
              title: "Swap used", value: Format.bytes(s.system.swap),
              subtitle: Format.growth(s.swapGrowth), symbol: "arrow.left.arrow.right", color: .cyan)
            MetricCard(
              title: "Memory growth",
              value: Format.growth(s.groupGrowth.isEmpty ? nil : s.groupGrowth.values.reduce(0, +)),
              subtitle: "5 minute regression · attributed groups",
              symbol: "chart.line.uptrend.xyaxis", color: .cyan)
            MetricCard(
              title: "Available / compressed", value: Format.bytes(s.system.available),
              subtitle: "Compressor physical: \(Format.bytes(s.system.compressed))",
              symbol: "internaldrive", color: .purple)
          }
          AppHealthCards()
          SnoozeStatus()
          Surface { TimelineChart() }
          HStack(alignment: .top, spacing: 16) {
            insights(s)
            topProcesses(s)
          }
          Text(
            "Footprint totals describe process accounting and may overlap shared resources. System values are estimates; unavailable readings are omitted. No memory growth alone proves a leak."
          ).font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
          EmptyState(
            title: "Connecting to your system",
            detail:
              "Reading native memory counters and discovering processes. No administrator access is needed."
          )
        }
      }.padding(28)
    }
  }
  private func insights(_ s: Snapshot) -> some View {
    Surface {
      SectionTitle(title: "Insights", subtitle: "Deterministic analysis of measured data")
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(s.reasons.prefix(4).enumerated()), id: \.offset) { _, reason in
          Label {
            Text(reason).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "sparkle").foregroundStyle(.mint)
          }
        }
        if s.reasons.isEmpty {
          Label(
            "No sustained risk signals in the current windows.", systemImage: "checkmark.circle"
          ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(s.groupGrowth.keys.sorted().prefix(3), id: \.self) { group in
          Text("\(group): \(Format.growth(s.groupGrowth[group])) over the recent 5 minute window.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Text("Free storage: \(Format.bytes(s.system.diskFree))").font(.system(size: 11))
          .foregroundStyle(.secondary)
      }.padding(.top, 16)
    }
  }
  private func topProcesses(_ s: Snapshot) -> some View {
    Surface {
      HStack {
        SectionTitle(title: "Largest processes", subtitle: "Across the entire system")
        Spacer()
        Button("Explore") { section = "Processes" }.font(.caption)
      }
      VStack(spacing: 14) {
        ForEach(s.processes.prefix(5)) { p in
          HStack {
            Image(systemName: p.group == nil ? "app" : "app.connected.to.app.below.fill")
              .foregroundStyle(p.group == nil ? Color.secondary : Color.mint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
              Text(p.name).lineLimit(1).font(.system(size: 11, weight: .medium))
              Text(p.group ?? "Other process").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(p.footprint)).font(.system(size: 11, design: .monospaced))
          }
        }
      }.padding(.top, 16)
    }
  }
  private var simulationView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SectionTitle(
          title: "Exercise the watchdog safely",
          subtitle:
            "Synthetic scenarios use the production analyzer without allocating large amounts of memory."
        )
        Surface {
          Toggle(
            "Simulation Mode",
            isOn: Binding(
              get: { model.demo }, set: { value in Task { await model.setDemo(value) } }))
          Picker(
            "Scenario",
            selection: Binding(get: { model.scenario }, set: { model.changeScenario($0) })
          ) { ForEach(SimulationScenario.allCases, id: \.self) { Text($0.title).tag($0) } }
          .disabled(!model.demo)
          Text(
            "Each scenario seeds 15 minutes of synthetic history. Native incident notifications, persistence and process actions are disabled. Live monitoring resumes when Simulation Mode is switched off."
          ).font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }
        if model.demo {
          Surface { TimelineChart() }
          if let s = model.snapshot { insights(s) }
        }
      }.padding(28)
    }
  }
  private var onboardingView: some View {
    VStack(alignment: .leading, spacing: 22) {
      Image(systemName: "shield.lefthalf.filled").font(.system(size: 48)).foregroundStyle(.mint)
      Text("A quieter way to watch memory.").font(.system(size: 27, weight: .semibold))
      Text(
        "MemorySentinel watches ChatGPT, Codex and their verified child processes every five seconds. It also checks system pressure and swap, so you can act before memory becomes a problem."
      ).foregroundStyle(.secondary)
      Label("Local measurements. No telemetry or external servers.", systemImage: "lock.shield")
      Label(
        "Warnings explain the evidence. Nothing is stopped automatically.",
        systemImage: "hand.raised")
      Label(
        "Closing this window keeps the menu bar watchdog running.", systemImage: "menubar.rectangle"
      )
      HStack {
        Button("Enable notifications") { Task { await model.requestNotifications() } }
        Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
      }
      Button("Start watching") {
        model.settings.onboardingComplete = true
        onboarding = false
      }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black).controlSize(.large)
    }.padding(36).frame(width: 520).fixedSize(horizontal: false, vertical: true)
  }
}
