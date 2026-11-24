import Charts
import SentinelCore
import SwiftUI

extension ProcessRecord {
  var sortRisk: Int { uncertain ? -1 : risk.rawValue }
  var sortMemory: Double { footprint ?? -1 }
  var sortGrowth: Double { growth ?? -.infinity }
  var sortUptime: Double { identity.startDate.timeIntervalSince1970 }
}
private struct ProcessSelection: Identifiable {
  let process: ProcessRecord
  let demo: Bool
  var id: ProcessIdentity { process.identity }
}
struct ProcessExplorer: View {
  @EnvironmentObject var model: AppModel
  @State private var search = ""
  @State private var filter = "Monitored"
  @State private var selection: ProcessIdentity?
  @State private var detail: ProcessSelection?
  @State private var sortOrder = [KeyPathComparator(\ProcessRecord.sortMemory, order: .reverse)]
  private var filtered: [ProcessRecord] {
    (model.snapshot?.processes ?? []).filter { p in
      (filter == "All processes" || filter == "Unverified" && p.uncertain
        || filter == "Monitored" && p.group != nil)
        && (search.isEmpty
          || "\(p.name) \(p.identity.pid) \(p.group ?? "") \(p.path)"
            .localizedCaseInsensitiveContains(search))
    }.sorted(using: sortOrder)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        TextField("Search name, PID or path", text: $search).textFieldStyle(.roundedBorder).frame(
          maxWidth: 360)
        Spacer()
        Picker("Scope", selection: $filter) {
          Text("Monitored").tag("Monitored")
          Text("All processes").tag("All processes")
          Text("Unverified").tag("Unverified")
        }.labelsHidden().frame(width: 160)
      }
      Text(
        "\(filtered.count) processes · Footprint and RSS are different accounting measures · Select a row for details"
      ).font(.system(size: 11)).foregroundStyle(.secondary)
      if filtered.isEmpty {
        EmptyState(
          title: "No matching processes",
          detail: filter == "Monitored"
            ? "Open ChatGPT or Codex, or add an exact executable or bundle rule in Settings."
            : "Try a different search or scope.")
      } else {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
          TableColumn("Process", value: \.name) { p in
            HStack(spacing: 8) {
              Image(
                systemName: p.uncertain
                  ? "questionmark.app" : p.group != nil ? "app.connected.to.app.below.fill" : "app"
              ).foregroundStyle(
                p.uncertain ? Color.yellow : p.group != nil ? Color.mint : Color.secondary)
              VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(p.group ?? (p.uncertain ? "Unverified attribution" : "Other process")).font(
                  .system(size: 9)
                ).foregroundStyle(.secondary).lineLimit(1)
              }
            }.padding(.vertical, 5).help(p.evidence ?? p.path)
          }.width(min: 180, ideal: 230)
          TableColumn("PID", value: \.identity.pid) { p in
            Text("\(p.identity.pid)").font(.system(size: 10, design: .monospaced))
          }.width(55)
          TableColumn("Footprint", value: \.sortMemory) { p in
            Text(Format.bytes(p.footprint)).font(.system(size: 11, design: .monospaced)).help(
              "RSS: \(Format.bytes(p.rss)). Footprint is Darwin physical-footprint accounting.")
          }.width(min: 95, ideal: 110)
          TableColumn("Growth / min", value: \.sortGrowth) { p in
            Text(Format.growth(p.growth)).font(.system(size: 10, design: .monospaced))
              .foregroundStyle((p.growth ?? 0) > 100 * MiB ? .orange : .secondary)
          }.width(min: 105, ideal: 130)
          TableColumn("Peak", value: \.peak) { p in
            Text(p.footprint == nil ? "Unavailable" : Format.bytes(p.peak)).font(
              .system(size: 10, design: .monospaced))
          }.width(min: 85, ideal: 95)
          TableColumn("Uptime", value: \.sortUptime) { p in
            Text(p.identity.startDate, style: .relative).font(.system(size: 10)).foregroundStyle(
              .secondary)
          }.width(min: 65, ideal: 80)
          TableColumn("Status", value: \.sortRisk) { p in
            if p.uncertain {
              Text("UNVERIFIED").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow)
            } else {
              Text(p.risk.title).font(.system(size: 9, weight: .semibold)).foregroundStyle(
                p.risk.color)
            }
          }.width(min: 70, ideal: 85)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
      }
    }.padding(28).onChange(of: selection) { _, value in
      if let value, let process = model.snapshot?.processes.first(where: { $0.identity == value }) {
        detail = ProcessSelection(process: process, demo: model.demo)
      }
    }.sheet(item: $detail, onDismiss: { selection = nil }) { selected in
      ProcessDetail(process: selected.process, sourceDemo: selected.demo).environmentObject(model)
    }
  }
}
struct ProcessDetail: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  let process: ProcessRecord
  var sourceDemo = false
  private var current: ProcessRecord {
    model.snapshot?.processes.first { $0.identity == process.identity } ?? process
  }
  private var alive: Bool {
    model.snapshot?.processes.contains { $0.identity == process.identity } ?? false
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text(current.name).font(.title2.bold())
            Text("PID \(current.identity.pid) · PPID \(current.ppid) · PGID \(current.pgid)").font(
              .system(.caption, design: .monospaced)
            ).foregroundStyle(.secondary)
          }
          Spacer()
          RiskBadge(level: current.risk)
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        if !alive {
          Label(
            "This process has exited or changed identity. Actions are disabled.",
            systemImage: "info.circle"
          ).foregroundStyle(.orange)
        }
        HStack {
          MetricCard(
            title: "Footprint", value: Format.bytes(current.footprint),
            subtitle: "Darwin physical-footprint accounting", symbol: "memorychip")
          MetricCard(
            title: "Resident set", value: Format.bytes(current.rss),
            subtitle: "Resident pages; shared mappings may overlap", symbol: "square.stack")
          MetricCard(
            title: "Peak observed", value: Format.bytes(current.peak),
            subtitle: Format.growth(current.growth), symbol: "chart.line.uptrend.xyaxis")
        }
        Surface {
          Text("Process memory").font(.headline)
          Chart(model.timeline) { p in
            if let bytes = p.processes[current.identity.id] {
              LineMark(x: .value("Time", p.date), y: .value("GiB", bytes / GiB)).foregroundStyle(
                .mint)
            }
          }.frame(height: 150).chartYScale(domain: .automatic(includesZero: true))
          Text("Only this PID + start-time identity. Missing samples are not estimated.").font(
            .caption
          ).foregroundStyle(.secondary)
        }
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 11) {
          row("Attribution", current.group ?? "Not attributed")
          row("Evidence", current.evidence ?? "No verified relationship to monitored applications")
          row("Executable", current.path.isEmpty ? "Unavailable" : current.path)
          row("Bundle ID", current.bundleID ?? "Unavailable")
          row(
            "Started",
            current.identity.startDate.formatted(date: .complete, time: .standard)
              + " · \(current.identity.microseconds) µs")
          row(
            "First observed", current.observedSince.formatted(date: .abbreviated, time: .standard))
        }.textSelection(.enabled)
        Text("Related child processes").font(.headline)
        let children =
          model.snapshot?.processes.filter {
            $0.ppid == current.identity.pid && $0.identity.startDate >= current.identity.startDate
          } ?? []
        if children.isEmpty {
          Text("No current direct children.").foregroundStyle(.secondary).font(.caption)
        }
        ForEach(children.prefix(30)) { child in
          HStack {
            Text(child.name)
            Text("PID \(child.identity.pid)").foregroundStyle(.secondary)
            Spacer()
            Text(Format.bytes(child.footprint))
          }.font(.caption)
        }
        Divider()
        HStack {
          Button("Activity Monitor") { model.activityMonitor() }
            .disabled(model.demo || sourceDemo != model.demo)
          Button("Exclude executable") {
            model.exclude(current)
            dismiss()
          }.disabled(model.demo || sourceDemo != model.demo || current.path.isEmpty)
          Spacer()
          FixButton(origin: FixOrigin(identity: current.identity, demoSource: sourceDemo)).disabled(
            !alive)
        }
        Text(
          "No automatic termination. Every signal rechecks PID, start time and executable. System processes, other users and the watchdog's ancestors are protected. Growth is not proof of a leak."
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(28)
    }.frame(width: 820, height: 710)
  }
  private func row(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).frame(maxWidth: .infinity, alignment: .leading)
    }.font(.system(size: 11))
  }
}
