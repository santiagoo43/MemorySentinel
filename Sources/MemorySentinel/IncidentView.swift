import AppKit
import SentinelCore
import SwiftUI

struct IncidentView: View {
  @EnvironmentObject var model: AppModel
  @State private var selectedFix: FixSession?
  @State private var selected: Incident?
  @State private var context: [Snapshot] = []
  @State private var exportWindow: NSWindow?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          SectionTitle(
            title: "Incident timeline",
            subtitle: "Warnings and critical events · Local evidence with process identity")
          Spacer()
          Menu("Export") {
            Button("JSON diagnostics") { model.export(csv: false, window: exportWindow) }
            Button("CSV minute timeline") { model.export(csv: true, window: exportWindow) }
          }.disabled(model.demo || model.exportingDiagnostics)
        }
        FixFollowupPanel()
        PastFixEvidenceView()
        if !model.fixHistory.isEmpty {
          SectionTitle(
            title: "Fix activity",
            subtitle: "Approved actions, before/after evidence and recovery outcomes")
          ForEach(model.fixHistory.prefix(30)) { fix in
            Surface {
              HStack {
                Text(fix.result?.outcome.title ?? fix.phase.rawValue.capitalized).font(.headline);
                Spacer();
                Text(fix.updated.formatted(date: .abbreviated, time: .standard)).font(.caption)
                  .foregroundStyle(.secondary)
              }
              Text(fix.plan?.diagnosis.summary ?? fix.message).font(.caption).padding(.top, 8)
              Text(fix.approvedAction?.title(target: fix.plan?.target) ?? "No action approved")
                .font(.caption).foregroundStyle(.secondary)
              if let result = fix.result {
                Text(
                  "Action: \(result.actionSucceeded.map { $0 ? "completed" : "failed" } ?? "unknown") · Target: \(result.targetResolved.map { $0 ? "resolved" : "unresolved" } ?? "not established") · System: \(result.systemImproved.map { $0 ? "improved" : "unchanged" } ?? "not established")"
                ).font(.caption).padding(.top, 6)
              }
              HStack {
                Button("Recorded evidence") { selectedFix = fix }; Spacer();
                FixButton(origin: fix.origin, title: "Review current state…")
              }.padding(.top, 10)
            }
          }
          Divider()
        }
        if model.incidents.isEmpty {
          EmptyState(
            title: "No incidents recorded",
            detail:
              "Confirmed WARNING and CRITICAL events appear here. You can exercise the analyzer in Simulation Mode.",
            symbol: "checkmark.shield")
        }
        ForEach(model.incidents) { event in
          Button {
            selected = event
            context = []
            if !model.demo {
              Task { context = (try? await model.history?.context(around: event.date)) ?? [] }
            }
          } label: {
            Surface {
              HStack(alignment: .top, spacing: 16) {
                Image(systemName: event.level.symbol).foregroundStyle(event.level.color).font(
                  .title2)
                VStack(alignment: .leading, spacing: 7) {
                  HStack {
                    Text(event.processName ?? "System memory").font(
                      .system(size: 14, weight: .semibold))
                    if let id = event.identity {
                      Text("PID \(id.pid)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack {
                      RiskBadge(level: event.level); Spacer();
                      FixButton(
                        origin: FixOrigin(
                          incidentID: event.id, identity: event.identity,
                          demoSource: event.demo ?? false))
                    }
                  }
                  Text(event.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                  HStack {
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                    Spacer()
                    Text(
                      "Footprint \(Format.bytes(event.footprint)) · Swap \(Format.bytes(event.system.swap))"
                    )
                  }.font(.system(size: 10)).foregroundStyle(.tertiary)
                }
              }
            }
          }.buttonStyle(.plain)
        }
      }.padding(28)
    }.background(
      SaveWindowProbe { exportWindow = $0 }.frame(width: 0, height: 0).accessibilityHidden(true)
    )
    .sheet(item: $selectedFix) { session in
      FixHistoryDetail(session: session).environmentObject(model)
    }
    .sheet(item: $selected) { event in
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          SectionTitle(
            title: "Incident evidence",
            subtitle: event.date.formatted(date: .complete, time: .standard))
          Spacer()
          Button("Done") { selected = nil }
        }
        HStack {
          RiskBadge(level: event.level); Spacer();
          FixButton(
            origin: FixOrigin(
              incidentID: event.id, identity: event.identity, demoSource: event.demo ?? false))
        }
        Text(event.reason).font(.callout)
        Text(
          "Pressure: \(event.system.pressure.rawValue) · Estimated used: \(Format.bytes(event.system.used)) · Swap: \(Format.bytes(event.system.swap))"
        ).font(.caption).foregroundStyle(.secondary)
        if let identity = event.identity {
          Text(
            "Identity: \(identity.id) · \(event.processName ?? "")\nFootprint: \(Format.bytes(event.footprint)) · \(Format.growth(event.growth))"
          ).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        Divider()
        Text("Measured context · 60 seconds before and after").font(.headline)
        if context.isEmpty {
          Text(
            "Detailed context has expired, is not recorded in Simulation Mode, or is not yet available."
          ).font(.caption).foregroundStyle(.secondary)
        }
        ScrollView {
          VStack(spacing: 8) {
            ForEach(Array(context.enumerated()), id: \.offset) { _, s in
              HStack {
                Text(s.date.formatted(date: .omitted, time: .standard))
                Spacer()
                Text(
                  "Used \(Format.bytes(s.system.used)) · Watched \(Format.bytes(s.monitoredBytes)) · Swap \(Format.bytes(s.system.swap))"
                )
              }.font(.system(size: 10, design: .monospaced))
            }
          }
        }
        Text(
          "Future samples appear after they are collected. Minute rollups preserve trends after detailed retention expires; process context is then unavailable."
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(28).frame(width: 720, height: 510)
    }
  }
}
