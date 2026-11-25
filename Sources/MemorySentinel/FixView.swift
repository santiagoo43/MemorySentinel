import AppKit
import SentinelCore
import SwiftUI

struct FixButton: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) var openWindow
  var origin = FixOrigin()
  var title = "Fix…"
  var body: some View {
    Button {
      openWindow(id: "fix"); NSApp.activate(ignoringOtherApps: true); model.beginFix(origin)
    } label: {
      Label(title, systemImage: "wrench.and.screwdriver")
    }
    .disabled(!model.fixReady || (origin.demoSource.map { $0 != model.demo } ?? false))
    .help(
      "Assess fresh evidence, review one concrete action, then verify the result. Nothing stops automatically."
    )
  }
}
struct FixView: View {
  private struct ForceApproval {
    let sessionID: UUID
    let planID: UUID
    let name: String
    let pid: Int32
  }
  @EnvironmentObject var model: AppModel
  @Environment(\.dismissWindow) var dismissWindow
  @State private var forceConfirmation = false
  @State private var forceApproval: ForceApproval?
  private var busy: Bool {
    model.fixSession.map { [.assessing, .executing, .verifying].contains($0.phase) } ?? false
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "wrench.and.screwdriver.fill").font(.title).foregroundStyle(.mint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Fix memory issue").font(.title2.bold());
          Text("Evidence → approval → action → verification").font(.caption).foregroundStyle(
            .secondary)
        }
        Spacer()
        if model.fixSession?.demo ?? model.demo {
          Text("SIMULATION ONLY").font(.caption.bold()).foregroundStyle(.yellow)
        }
        Button("Close") {
          if model.fixSession?.phase.active == true { model.cancelFix() }; dismissWindow(id: "fix")
        }
      }.padding(24)
      Divider()
      if let current = model.snapshot {
        HStack {
          RiskBadge(level: current.risk);
          Text(
            "Current \(current.demo ? "simulated" : "system") pressure: \(current.system.pressure.rawValue)"
          ).font(.caption); Spacer();
          if current.risk == .critical {
            Text("Save work now. Critical alerts remain active.").font(.caption.bold())
              .foregroundStyle(.red)
          }
        }.padding(.horizontal, 24).padding(.vertical, 10).background(
          current.risk.color.opacity(0.08))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let session = model.fixSession {
            steps(session.phase)
            Text(session.message).font(.callout).textSelection(.enabled)
            if let plan = session.plan {
              diagnosis(plan)
              if session.phase == .awaitingApproval { approval(plan, sessionID: session.id) }
              if session.phase == .executing {
                ProgressView("Waiting for the approved action…").controlSize(.small)
              }
              if session.phase == .verifying {
                Surface {
                  Text(
                    session.demo
                      ? "Verifying with simulated samples"
                      : "Verifying with live monitoring samples"
                  ).font(.headline);
                  ProgressView(value: Double(min(3, session.samples)), total: 3).padding(
                    .vertical, 12);
                  Text(
                    "\(session.samples) fresh samples · At least 3 comparable readings · Maximum 120 seconds"
                  ).font(.caption).foregroundStyle(.secondary)
                }
              }
              if let result = session.result { results(result, plan: plan) }
              if session.phase == .awaitingApproval || session.phase == .finished {
                candidates(plan)
              }
            } else if session.phase == .assessing {
              ProgressView("Requesting a fresh system sample…")
            } else if let result = session.result {
              Text(result.nextStep).foregroundStyle(.secondary)
              Button("Open Activity Monitor") { model.activityMonitor() }
                .disabled(session.demo || model.demo)
            }
            if session.phase.active {
              Button(
                session.phase == .awaitingApproval || session.phase == .assessing
                  ? "Cancel" : "Cancel remaining steps", role: .cancel
              ) { model.cancelFix() }
              if session.phase == .executing || session.phase == .verifying {
                Text(
                  "Cancellation stops remaining steps. A Quit or signal already sent cannot be undone. Monitoring and critical alerts continue."
                ).font(.caption).foregroundStyle(.secondary)
              }
            } else {
              Button("Assess current state again") {
                model.beginFix(session.demo == model.demo ? session.origin : FixOrigin())
              }.buttonStyle(
                .borderedProminent
              ).tint(.mint).foregroundStyle(.black)
            }
          } else {
            EmptyState(
              title: "Manual repair, measured results",
              detail:
                "Open Fix from a warning, process or incident to review fresh evidence. No action is automatic.",
              symbol: "wrench.and.screwdriver")
          }
        }.padding(24)
      }
    }.frame(minWidth: 740, minHeight: 640)
      .alert(
        "Force quit this exact process?", isPresented: $forceConfirmation, presenting: forceApproval
      ) { request in
        Button("Cancel", role: .cancel) { forceApproval = nil }
        Button("Force Quit · SIGKILL", role: .destructive) {
          model.approveFix(
            .forceQuit, sessionID: request.sessionID, planID: request.planID, forceConfirmed: true)
          forceApproval = nil
        }
      } message: { request in
        Text(
          "\(request.name), PID \(request.pid). Unsaved work will be lost and cleanup cannot run. This cannot be undone. Identity and ownership are checked again before sending SIGKILL."
        )
      }
      .onChange(of: model.fixSession?.plan?.id) { _, _ in
        forceConfirmation = false; forceApproval = nil
      }
      .onChange(of: model.fixSession?.phase) { _, phase in
        if phase != .awaitingApproval { forceConfirmation = false; forceApproval = nil }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
        event in
        if let window = event.object as? NSWindow,
          window.identifier?.rawValue == "fix" || window.title == "MemorySentinel · Fix"
        {
          if model.fixSession?.phase.active == true { model.cancelFix() }
        }
      }
  }
  private func steps(_ phase: FixPhase) -> some View {
    HStack(spacing: 10) {
      ForEach(
        Array(
          [FixPhase.assessing, .awaitingApproval, .executing, .verifying, .finished].enumerated()),
        id: \.offset
      ) { index, item in
        HStack(spacing: 5) {
          Image(systemName: phase == item ? "circle.inset.filled" : "circle");
          Text(["Assess", "Review", "Act", "Verify", "Result"][index])
        }.font(.system(size: 11, weight: phase == item ? .bold : .regular)).foregroundStyle(
          phase == item ? .mint : .secondary)
        if index < 4 {
          Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
      }
    }.accessibilityElement(children: .combine)
  }
  private func diagnosis(_ plan: FixPlan) -> some View {
    Surface {
      HStack {
        Text(plan.diagnosis.kind.title).font(.headline); Spacer();
        RiskBadge(level: plan.diagnosis.severity)
      }
      Text(plan.diagnosis.summary).padding(.top, 10)
      Text(plan.diagnosis.certainty).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
      ForEach(plan.diagnosis.evidence.keys.sorted(), id: \.self) { key in
        Text(evidence(key, value: plan.diagnosis.evidence[key]!))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let target = plan.target {
        Divider().padding(.vertical, 12)
        Text("Target: \(target.process.name) · PID \(target.process.identity.pid)").font(
          .subheadline.bold())
        Text(
          "Identity: \(target.process.identity.id)\nExecutable: \(target.process.path)\nOwner UID: \(target.process.uid)\nSource: \(target.source.name), PID \(target.source.identity.pid)"
        ).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.top, 7)
        Text(
          target.source.evidence
            ?? "Manually selected individual process; no Codex attribution inferred."
        ).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        if target.application != nil {
          Text(
            "The normal Quit request targets the owning application. Its workloads may stop. Helpers are not signalled individually."
          ).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        Text(
          "Source footprint at assessment: \(Format.bytes(target.source.footprint)). This is accounting, not a promise of that much unique RAM being released."
        ).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
      }
      if let source = plan.source, plan.origin.individualProcess != true,
        targetIsDifferent(plan, source: source)
      {
        Button("Review only \(source.name) · PID \(source.identity.pid)") {
          model.beginFix(
            FixOrigin(
              incidentID: plan.origin.incidentID, identity: source.identity,
              individualProcess: true, demoSource: plan.token.demo
            ))
        }.padding(.top, 10).disabled(busy || plan.token.demo != model.demo)
      }
      if !plan.explanation.isEmpty {
        Text(plan.explanation).font(.caption).foregroundStyle(.orange).padding(.top, 10)
      }
      if let incident = plan.origin.incidentID {
        Text("Linked incident: \(incident.uuidString). This plan uses current measurements.").font(
          .system(size: 9)
        ).foregroundStyle(.tertiary).padding(.top, 8)
      }
    }
  }
  private func evidence(_ key: String, value: Double) -> String {
    switch key {
    case "pid": return "Unverified PID: \(Int(value))"
    case "missingMonitoredFootprints": return "Unreadable monitored footprints: \(Int(value))"
    case "footprintBytes": return "Process footprint: \(Format.bytes(value))"
    case "physicalBytes": return "Physical memory: \(Format.bytes(value))"
    case "warningFraction": return "Warning threshold: \(Int(value * 100))% of physical memory"
    case "diskFreeBytes": return "Available storage: \(Format.bytes(value))"
    case "swapBytesPerMinute": return "Swap growth: \(Format.growth(value))"
    case "bytesPerMinute": return "Footprint growth: \(Format.growth(value))"
    case "pressureLevel": return "Kernel signal: \(value >= 2 ? "critical" : "warning")"
    default: return "Measured value: \(value.formatted())"
    }
  }
  private func targetIsDifferent(_ plan: FixPlan, source: ProcessRecord) -> Bool {
    plan.target?.process.identity != source.identity || plan.target == nil
  }
  private func approval(_ plan: FixPlan, sessionID: UUID) -> some View {
    Surface {
      Text("Choose one approved action").font(.headline)
      if plan.actions.contains(where: \.isProcessAction) {
        Label(
          "Save your work first. Closing or stopping an application can lose unsaved work. Reopening does not guarantee session restoration.",
          systemImage: "exclamationmark.triangle"
        ).font(.caption).foregroundStyle(.orange).padding(.vertical, 12)
      }
      if model.paused {
        Text("Monitoring is paused. Resume it before process actions so recovery can be measured.")
          .font(.caption).foregroundStyle(.orange);
        Button("Resume monitoring") { model.setPaused(false) }
      }
      ForEach(plan.actions) { action in
        Button(action.title(target: plan.target), role: action == .forceQuit ? .destructive : nil) {
          if action == .forceQuit, let target = plan.target {
            forceApproval = ForceApproval(
              sessionID: sessionID, planID: plan.id, name: target.process.name,
              pid: target.process.identity.pid)
            forceConfirmation = true
          } else {
            model.approveFix(action, sessionID: sessionID, planID: plan.id)
          }
        }.controlSize(.large).padding(.top, 8).disabled(model.paused && action.isProcessAction)
      }
      if plan.diagnosis.kind == .lowDisk {
        Text(
          "In System Settings, open General → Storage and review your files. Nothing is deleted by Fix."
        ).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
      }
      if plan.diagnosis.kind == .notifications {
        Text(
          "In System Settings, open Notifications → MemorySentinel and review permission/Focus. Opening Settings does not itself fix delivery."
        ).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
      }
      if plan.diagnosis.kind == .loginItem {
        Text(
          "The local ad-hoc build may not be recognized by ServiceManagement. A signing problem cannot be repaired by changing memory thresholds."
        ).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
      }
    }
  }
  private func candidates(_ plan: FixPlan) -> some View {
    DisclosureGroup("Review current large consumers · select one exact target") {
      VStack(spacing: 10) {
        Text(
          "These are measured consumers, not proven causes. Selection does not add a process to the Codex group. Protected targets will be refused."
        ).font(.caption).foregroundStyle(.secondary)
        ForEach(plan.candidates) { p in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(p.name).font(.system(size: 12, weight: .medium));
              Text(
                "PID \(p.identity.pid) · \(p.group ?? "Not attributed to Codex")\(p.uncertain ? " · unverified attribution" : "")"
              ).font(.system(size: 10)).foregroundStyle(.secondary)
            }; Spacer();
            Text(Format.bytes(p.footprint)).font(.system(size: 11, design: .monospaced));
            Button("Review") {
              model.beginFix(
                FixOrigin(
                  incidentID: plan.origin.incidentID, identity: p.identity,
                  demoSource: plan.token.demo))
            }.disabled(busy || plan.token.demo != model.demo)
          }
        }
      }.padding(.top, 12)
    }.padding(16).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
  }
  private func results(_ result: FixResult, plan: FixPlan) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Surface {
        Text(result.outcome.title).font(.title3.bold()).foregroundStyle(
          result.outcome == .solved ? .mint : .orange)
        Text(result.message).font(.callout).padding(.top, 10)
        if let replacement = model.fixSession?.replacement {
          Text("Reopened instance: \(replacement.id)").font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
          GridRow {
            Text("Action completed"); Text(answer(result.actionSucceeded))
          }
          GridRow {
            Text("Target problem resolved"); Text(answer(result.targetResolved))
          }
          GridRow {
            Text("System improved"); Text(answer(result.systemImproved))
          }
          GridRow {
            Text("Pressure");
            Text(
              "\(plan.before.system.pressure.rawValue) → \(result.after?.system.pressure.rawValue ?? "unavailable")"
            )
          }
          GridRow {
            Text("Estimated used");
            Text(
              "\(Format.bytes(plan.before.system.used)) → \(Format.bytes(result.after?.system.used))"
            )
          }
          GridRow {
            Text("Estimated available");
            Text(
              "\(Format.bytes(plan.before.system.available)) → \(Format.bytes(result.after?.system.available))"
            )
          }
          GridRow {
            Text("Swap");
            Text(
              "\(Format.bytes(plan.before.system.swap)) → \(Format.bytes(result.after?.system.swap))"
            )
          }
          GridRow {
            Text("Swap growth");
            Text(
              "\(Format.growth(plan.before.swapGrowth)) → \(Format.growth(result.after?.swapGrowth))"
            )
          }
          GridRow {
            Text("Risk");
            Text("\(plan.before.risk.title) → \(result.after?.risk.title ?? "Unavailable")")
          }
          GridRow {
            Text("Target growth");
            Text(
              "\(Format.growth(plan.before.targetGrowth)) → \(Format.growth(result.after?.targetGrowth))"
            )
          }
          GridRow {
            Text("Target footprint");
            Text(
              "\(Format.bytes(plan.before.targetFootprint)) → \(result.after?.targetFootprint == nil ? "Exited / unavailable" : Format.bytes(result.after?.targetFootprint))"
            )
          }
        }.font(.system(size: 11)).padding(.vertical, 16)
        Text(
          "\(result.samples) post-action samples. Swap need not fall immediately. Missing readings never prove recovery."
        ).font(.caption).foregroundStyle(.secondary)
        Text(result.nextStep).font(.callout).padding(.top, 12)
        if !result.remaining.isEmpty {
          Divider().padding(.vertical, 12); Text("Remaining related processes").font(.headline)
          ForEach(result.remaining) { p in
            HStack {
              Text("\(p.name) · PID \(p.identity.pid)").font(.caption); Spacer();
              Text(Format.bytes(p.footprint)).font(.caption);
              Button("Review Fix") {
                model.beginFix(FixOrigin(identity: p.identity, demoSource: plan.token.demo))
              }
            }
          }
        }
      }
      if let id = model.fixSession?.id {
        FixFollowupPanel(fixID: id)
        if let context = model.experience.followups.first(where: { $0.id == id }) {
          PastFixEvidenceView(context: context)
        }
      }
    }
  }
  private func answer(_ value: Bool?) -> String {
    value.map { $0 ? "Yes" : "No" } ?? "Not established"
  }
}

struct FixHistoryDetail: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  let session: FixSession
  @State private var report = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          SectionTitle(
            title: "Recorded Fix evidence",
            subtitle: session.started.formatted(date: .complete, time: .standard));
          Spacer(); Button("Done") { dismiss() }
        }
        if session.demo {
          Text("SIMULATION EVIDENCE · No native action").font(.caption.bold()).foregroundStyle(
            .orange)
        }
        Text(session.result?.outcome.title ?? session.phase.rawValue.capitalized).font(
          .title3.bold())
        Button("Report preview…") { report = true }
        FixFollowupPanel(fixID: session.id)
        Text("Session \(session.id.uuidString)").font(.system(size: 10, design: .monospaced))
        if let incident = session.origin.incidentID {
          Text("Original incident: \(incident.uuidString)").font(.caption)
        }
        if let plan = session.plan {
          Text(plan.diagnosis.kind.title).font(.headline)
          Text(plan.diagnosis.summary)
          Text(plan.diagnosis.certainty).font(.caption).foregroundStyle(.secondary)
          if let target = plan.target {
            Text(
              "Target: \(target.process.name)\nIdentity: \(target.process.identity.id)\nExecutable: \(target.process.path)\nUID: \(target.process.uid)\nSource: \(target.source.name) · \(target.source.identity.id)"
            ).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          }
          Text(
            "Approved: \(session.approvedAction?.title(target:plan.target) ?? "No action")\nApproval: \(session.approvedAt?.formatted(date:.abbreviated,time:.standard) ?? "Not approved")\nRequest accepted: \(session.actionSentAt?.formatted(date:.abbreviated,time:.standard) ?? "Not recorded")\nExplicit Force Quit confirmation: \(session.forceConfirmed ? "Yes" : "No")"
          ).font(.caption)
          if let replacement = session.replacement {
            Text("Reopened instance: \(replacement.id)").font(
              .system(size: 11, design: .monospaced)
            ).textSelection(.enabled)
          }
          if let result = session.result {
            Divider(); Text(result.message)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
              GridRow {
                Text("Metric").bold(); Text("Before").bold(); Text("After").bold()
              }
              GridRow {
                Text("Pressure"); Text(plan.before.system.pressure.rawValue);
                Text(result.after?.system.pressure.rawValue ?? "Unavailable")
              }
              GridRow {
                Text("Estimated used"); Text(Format.bytes(plan.before.system.used));
                Text(Format.bytes(result.after?.system.used))
              }
              GridRow {
                Text("Estimated available"); Text(Format.bytes(plan.before.system.available));
                Text(Format.bytes(result.after?.system.available))
              }
              GridRow {
                Text("Swap"); Text(Format.bytes(plan.before.system.swap));
                Text(Format.bytes(result.after?.system.swap))
              }
              GridRow {
                Text("Swap growth"); Text(Format.growth(plan.before.swapGrowth));
                Text(Format.growth(result.after?.swapGrowth))
              }
              GridRow {
                Text("Target footprint"); Text(Format.bytes(plan.before.targetFootprint));
                Text(Format.bytes(result.after?.targetFootprint))
              }
              GridRow {
                Text("Target growth"); Text(Format.growth(plan.before.targetGrowth));
                Text(Format.growth(result.after?.targetGrowth))
              }
              GridRow {
                Text("Risk"); Text(plan.before.risk.title);
                Text(result.after?.risk.title ?? "Unavailable")
              }
            }.font(.system(size: 11))
            Text(
              "Action: \(result.actionSucceeded.map { $0 ? "completed" : "failed" } ?? "unknown") · Target: \(result.targetResolved.map { $0 ? "resolved" : "unresolved" } ?? "not established") · System: \(result.systemImproved.map { $0 ? "improved" : "unchanged" } ?? "not established")"
            ).font(.caption)
            Text(
              "Post-action samples: \(result.samples). Footprint is accounting, not unique physical RAM. Exited targets have no current footprint."
            ).font(.caption).foregroundStyle(.secondary)
            Text(result.nextStep)
            ForEach(result.remaining) { process in
              Text(
                "Remaining: \(process.name) · \(process.identity.id) · \(Format.bytes(process.footprint))"
              ).font(.caption)
            }
          }
        } else {
          Text(session.message)
        }
        FixButton(
          origin: session.demo == model.demo ? session.origin : FixOrigin(),
          title: "Assess current state…")
      }.padding(28)
    }.frame(width: 760, height: 640)
      .sheet(isPresented: $report) {
        ReportPreview(request: .fix(session)).environmentObject(model)
      }
  }
}
