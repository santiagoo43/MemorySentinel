import Charts
import SentinelCore
import SwiftUI

struct MenuPopover: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) var openWindow
  @Environment(\.openSettings) var openSettings
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(.mint)
        VStack(alignment: .leading) {
          Text("MemorySentinel").font(.headline)
          Text(model.demo ? "SIMULATED DATA" : "MEMORY WATCHDOG").font(
            .system(size: 9, weight: .bold)
          ).tracking(2).foregroundStyle(.secondary)
        }
        Spacer()
        RiskBadge(level: model.snapshot?.risk ?? .normal)
      }
      if let s = model.snapshot {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(Format.bytes(s.monitoredBytes)).font(
            .system(size: 37, weight: .medium, design: .rounded)
          ).monospacedDigit()
          Text("attributed footprint").font(.caption).foregroundStyle(.secondary)
        }
        Chart(model.timeline.suffix(80)) { p in
          if let value = p.monitored {
            AreaMark(x: .value("Time", p.date), y: .value("GiB", value / GiB)).foregroundStyle(
              LinearGradient(
                colors: [.mint.opacity(0.25), .mint.opacity(0.01)], startPoint: .top,
                endPoint: .bottom))
            LineMark(x: .value("Time", p.date), y: .value("GiB", value / GiB)).foregroundStyle(
              .mint
            ).lineStyle(StrokeStyle(lineWidth: 2))
          }
        }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 65).accessibilityLabel(
          "Recent monitored memory timeline")
        HStack {
          mini("Pressure", s.system.pressure.rawValue.capitalized)
          Spacer()
          mini("Swap", Format.bytes(s.system.swap))
          Spacer()
          mini(
            "Growth", Format.growth(s.groupGrowth.isEmpty ? nil : s.groupGrowth.values.reduce(0, +))
          )
        }
        Text(s.reasons.first ?? "No warning signals in the current measured data.").font(.caption)
          .foregroundStyle(s.risk >= .warning ? .orange : .secondary).lineLimit(3)
      } else {
        ProgressView("Reading system memory…").frame(height: 160)
      }
      FixButton().frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      Button {
        showDashboard()
      } label: {
        Label("Open dashboard", systemImage: "rectangle.grid.2x2").frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black).keyboardShortcut("o")
      HStack {
        Button {
          model.setPaused(!model.paused)
        } label: {
          Label(
            model.paused ? "Resume" : "Pause",
            systemImage: model.paused ? "play.fill" : "pause.fill")
        }
        Spacer()
        Button {
          openSettings()
          NSApp.activate(ignoringOtherApps: true)
        } label: {
          Image(systemName: "gearshape")
        }.help("Settings")
        Button {
          NSApp.terminate(nil)
        } label: {
          Image(systemName: "power")
        }.help("Quit MemorySentinel")
      }.buttonStyle(.borderless).foregroundStyle(.secondary)
    }.padding(22).frame(width: 400).onAppear { model.openDashboard = { showDashboard() } }
  }
  private func mini(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
    }
  }
  private func showDashboard() {
    openWindow(id: "dashboard")
    NSApp.activate(ignoringOtherApps: true)
  }
}
