import SentinelCore
import SwiftUI

struct ProfilePicker: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Picker(
      "Profile",
      selection: Binding(
        get: { model.settings.activeProfile.id }, set: { model.activateProfile($0) })
    ) {
      ForEach(model.settings.profiles ?? []) { Text($0.name).tag($0.id) }
    }.labelsHidden().help("Active work profile").accessibilityLabel("Active work profile")
  }
}

struct SampleFreshness: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    TimelineView(.periodic(from: .now, by: 5)) { context in
      let age = model.snapshot.map { max(0, context.date.timeIntervalSince($0.date)) }
      let stale = age.map { $0 > Double(max(15, model.settings.interval * 3)) } ?? true
      Label(
        model.paused
          ? "Paused · last observation retained"
          : age.map {
            "Last sample \(Int($0))s ago\(stale ? " · stale" : "")"
          } ?? "Waiting for a sample",
        systemImage: stale || model.paused ? "clock.badge.exclamationmark" : "checkmark.circle"
      )
      .font(.caption2).foregroundStyle(stale || model.paused ? Color.orange : Color.secondary)
    }
  }
}

struct AppHealthCards: View {
  @EnvironmentObject var model: AppModel
  @State private var resetApp: AppHealth?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        SectionTitle(
          title: "Application health",
          subtitle:
            "\(model.settings.activeProfile.name) · Reference budgets are advisory accounting limits"
        )
        Spacer()
        Button("Profiles") { model.showSection("Profiles") }
      }
      if model.experience.apps.isEmpty {
        Text("Application cards appear when a matching app is measured in this profile.")
          .font(.callout).foregroundStyle(.secondary)
      }
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280), alignment: .top)], alignment: .leading,
        spacing: 14
      ) {
        ForEach(model.experience.apps) { health in
          Surface {
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Label(health.app.name, systemImage: "app.connected.to.app.below.fill").font(
                  .headline)
                Spacer()
                if health.overBudget || health.unusual {
                  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
              }
              Text(Format.bytes(health.app.footprint)).font(
                .system(size: 28, weight: .medium, design: .rounded)
              ).monospacedDigit()
              Text(
                "\(health.app.members) processes · \(health.app.version ?? "Version unavailable")"
              )
              .font(.caption2).foregroundStyle(.secondary)
              LabeledContent("Reference budget", value: Format.bytes(health.budget)).font(.caption)
              if let value = health.app.footprint, let budget = health.budget {
                ProgressView(value: min(value / budget, 1)).tint(
                  health.overBudget ? .orange : .mint
                )
                .accessibilityLabel("\(Int(value / budget * 100)) percent of reference budget")
              }
              Text(normalText(health)).font(.caption).foregroundStyle(.secondary)
              Text(Format.growth(health.forecast.growthPerMinute)).font(.caption).monospacedDigit()
              if let lower = health.forecast.lowerMinutes, let upper = health.forecast.upperMinutes
              {
                Label(
                  "At this rate: \(Int(floor(lower)))–\(Int(ceil(upper))) min to budget",
                  systemImage: "clock.arrow.circlepath"
                )
                .font(.caption.bold()).foregroundStyle(.orange)
              }
              Text(health.forecast.reason).font(.caption2).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
              Text(
                health.app.complete
                  ? "Complete application footprint at \(health.measuredAt.formatted(date: .omitted, time: .standard))"
                  : "Incomplete application readings · recovery cannot be established"
              )
              .font(.caption2).foregroundStyle(health.app.complete ? Color.secondary : Color.orange)
              HStack {
                FixButton(
                  origin: FixOrigin(
                    identity: health.app.root, issue: .selectedContributor, demoSource: model.demo),
                  title: "Review Fix…")
                Spacer()
                Menu {
                  ForEach([ExperienceEventKind.budget, .unusual, .footprint, .growth], id: \.self) {
                    kind in
                    Menu("Snooze \(kind.rawValue) warnings") {
                      ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                          model.snooze(app: health.id, kind: kind, minutes: minutes)
                        }
                      }
                    }
                  }
                  Button("Reset normal range…") { resetApp = health }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }.menuStyle(.borderlessButton).fixedSize()
                  .accessibilityLabel("Options for \(health.app.name)")
              }
            }
          }
        }
      }
    }.alert(
      "Reset this application's normal range?",
      isPresented: Binding(get: { resetApp != nil }, set: { if !$0 { resetApp = nil } })
    ) {
      Button("Cancel", role: .cancel) { resetApp = nil }
      Button("Reset range", role: .destructive) {
        model.resetNormalRange(appKey: resetApp?.id); resetApp = nil
      }
    } message: {
      Text(
        "The active profile will learn a new normal range from eligible future observations. History and settings stay available."
      )
    }
  }
  private func normalText(_ health: AppHealth) -> String {
    if health.normal.ready {
      return
        "Observed normal: \(Format.bytes(health.normal.lower))–\(Format.bytes(health.normal.upper))\(health.unusual ? " · unusual now" : "")"
    }
    return "Learning · \(Int(health.normal.coveredSeconds / 60))/60 eligible minutes"
  }
}

struct SnoozeStatus: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    let snoozes = model.experience.snoozes.filter {
      $0.profileID == model.settings.activeProfile.id && $0.until > Date()
    }
    if !snoozes.isEmpty {
      Surface {
        VStack(alignment: .leading, spacing: 9) {
          Label("Warning snoozes · critical system alerts stay active", systemImage: "bell.slash")
            .font(.caption.bold())
          ForEach(snoozes) { item in
            HStack {
              Text(
                "\(model.experience.apps.first { $0.id == item.appKey }?.app.name ?? (item.appKey == "system" ? "System" : "Saved application")) · \(item.kind.rawValue) until \(item.until.formatted(date: .omitted, time: .shortened))"
              )
              .font(.caption)
              Spacer(); Button("Resume alerts") { model.cancelSnooze(item.id) }
            }
          }
        }
      }
    }
  }
}

struct ProfilesView: View {
  @EnvironmentObject var model: AppModel
  @State private var editing: WorkProfile?
  @State private var reset = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          SectionTitle(
            title: "Work profiles",
            subtitle: "Exact watch rules, advisory budgets and local normal ranges")
          Spacer()
          Button("New profile") {
            editing = WorkProfile(
              name: "New profile", budgets: model.settings.activeProfile.budgets)
          }
          .disabled((model.settings.profiles?.count ?? 0) >= 12)
        }
        ForEach(model.settings.profiles ?? []) { profile in
          Surface {
            HStack {
              VStack(alignment: .leading, spacing: 6) {
                Text(profile.name).font(.headline)
                Text(
                  "\(profile.watchRules.count) exact rules · \(profile.budgets.count) budgets · Notifications \(profile.notifications ? "on" : "off")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if profile.id == model.settings.activeProfile.id {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.mint)
              } else {
                Button("Activate") { model.activateProfile(profile.id) }
              }
              Button("Edit…") { editing = profile }
            }
          }
        }
        SnoozeStatus()
        Button("Reset active profile's normal ranges…") { reset = true }
        Text(
          "Normal ranges need at least 60 minutes of eligible stable observations. Warnings, incomplete readings, Simulation Mode and interventions are excluded. Application versions and monitoring configurations are kept separate."
        )
        .font(.caption).foregroundStyle(.secondary)
        RecoveryControls()
      }.padding(28)
    }.sheet(item: $editing) { profile in
      ProfileEditor(draft: profile) {
        model.saveProfile($0); editing = nil
      }.environmentObject(model)
    }.alert("Reset normal ranges for the active profile?", isPresented: $reset) {
      Button("Cancel", role: .cancel) {}
      Button("Reset ranges", role: .destructive) { model.resetNormalRange() }
    } message: {
      Text(
        "Previously learned ranges for this profile will be discarded. Other profiles, recorded history and settings remain available."
      )
    }
  }
}

struct ProfileEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  @State var draft: WorkProfile
  var save: (WorkProfile) -> Void
  private var canSave: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.watchRules.allSatisfy {
        !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.isEmpty
          && ($0.kind != .executable || $0.value.hasPrefix("/"))
      }
      && draft.budgets.allSatisfy { !$0.target.isEmpty && $0.bytes.isFinite && $0.bytes >= MiB }
  }
  private var groups: [String] {
    Array(
      Set(
        ["ChatGPT", "Codex", "Codex CLI"] + draft.watchRules.map(\.label)
          + draft.budgets.filter { $0.scope == .group }.map(\.target))
    ).sorted()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Edit work profile").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() };
        Button("Save") { save(draft) }.buttonStyle(.borderedProminent).disabled(!canSave)
      }
      Form {
        Section("Profile") {
          TextField("Name", text: $draft.name)
          Toggle("Warning and critical notifications", isOn: $draft.notifications)
          ForEach(["ChatGPT", "Codex", "Codex CLI"], id: \.self) { group in
            Toggle(
              "Watch \(group)",
              isOn: Binding(
                get: { !draft.disabledBuiltIns.contains(group) },
                set: { enabled in
                  draft.disabledBuiltIns.removeAll { $0 == group };
                  if !enabled { draft.disabledBuiltIns.append(group) }
                }))
          }
        }
        Section("Exact watch rules") {
          ForEach($draft.watchRules) { $rule in
            HStack {
              TextField("Label", text: $rule.label)
              Picker("Match", selection: $rule.kind) {
                ForEach(WatchRule.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
              }.frame(width: 140)
              TextField("Exact bundle ID or executable path", text: $rule.value)
              Button {
                draft.watchRules.removeAll { $0.id == rule.id }
              } label: {
                Image(systemName: "minus.circle")
              }.accessibilityLabel("Remove rule")
            }
          }
          Button("Add exact rule") {
            draft.watchRules.append(WatchRule(label: "My app", value: "", kind: .bundle))
          }.disabled(draft.watchRules.count >= 64)
        }
        Section("Reference budgets · attributed footprint, not reserved RAM") {
          ForEach($draft.budgets) { $budget in
            HStack {
              Picker("Scope", selection: $budget.scope) {
                ForEach(MemoryBudget.Scope.allCases, id: \.self) {
                  Text($0.rawValue.capitalized).tag($0)
                }
              }.frame(width: 150)
              if budget.scope == .group {
                Picker("Group", selection: $budget.target) {
                  ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
              } else {
                Picker("Application", selection: $budget.target) {
                  if !model.experience.apps.contains(where: { $0.id == budget.target }) {
                    Text(budget.label ?? "Choose a measured application").tag(budget.target)
                  }
                  ForEach(model.experience.apps) {
                    Text("\($0.app.name) · \($0.app.version ?? "Version unavailable")").tag($0.id)
                      .help($0.app.sourcePath)
                  }
                }
              }
              TextField(
                "GiB",
                value: Binding(
                  get: { budget.bytes / GiB }, set: { budget.bytes = max(1.0 / 1024, $0) * GiB }),
                format: .number.precision(.fractionLength(0...2))
              ).frame(width: 75)
              Text("GiB").foregroundStyle(.secondary)
              Button {
                draft.budgets.removeAll { $0.id == budget.id }
              } label: {
                Image(systemName: "minus.circle")
              }.accessibilityLabel("Remove budget")
            }.onChange(of: budget.scope) { _, scope in
              budget.target =
                scope == .group ? groups.first ?? "Codex" : model.experience.apps.first?.id ?? ""
            }.onChange(of: budget.target) { _, target in
              if let app = model.experience.apps.first(where: { $0.id == target }) {
                budget.label = app.app.name + " · " + (app.app.version ?? "Version unavailable")
              }
            }
          }
          Button("Add budget") {
            draft.budgets.append(MemoryBudget(target: groups.first ?? "Codex", bytes: 4 * GiB))
          }.disabled(draft.budgets.count >= 64)
          Text(
            "Each target has one budget. A later duplicate replaces the earlier entry when saved. Application targets can be chosen from currently measured apps."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Excluded executable paths · one exact path per line") {
          TextEditor(
            text: Binding(
              get: { draft.excludedPaths.joined(separator: "\n") },
              set: { draft.excludedPaths = $0.split(separator: "\n").map(String.init) })
          ).font(.system(.caption, design: .monospaced)).frame(height: 80)
        }
      }.formStyle(.grouped)
      Text(
        "Applying an active profile change invalidates pending Fix approvals. System pressure protection remains independent of advisory budgets."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(width: 850, height: 650)
  }
}

struct RecoveryControls: View {
  @EnvironmentObject var model: AppModel
  @State private var restoreHistory = false
  @State private var restoreSettings = false
  var body: some View {
    Surface {
      VStack(alignment: .leading, spacing: 12) {
        Text("Storage and recovery").font(.headline)
        Text(
          "Experience data: \(Format.bytes(Double(model.experience.storageBytes))) logical payload · 64 MiB quota. Up to 20 recordings plus expiry notices, 100 sessions and 200 follow-ups; oldest data can expire earlier under the quota. SQLite files and recovery snapshots can use additional disk space."
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Create recovery snapshot") { model.createRecoverySnapshot() }
          Button("Restore pre-1.2 history…") { restoreHistory = true }
          Button("Restore pre-1.2 settings…") { restoreSettings = true }
        }.disabled(model.demo)
      }
    }.alert("Restore pre-migration history?", isPresented: $restoreHistory) {
      Button("Cancel", role: .cancel) {}
      Button("Restore history") { model.restorePreMigrationHistory() }
    } message: {
      Text(
        "Monitoring will pause. The database captured before migration will replace current history. A consistent copy of the current database is preserved as history.before-restore.sqlite. Resume monitoring after reviewing the result."
      )
    }
    .alert("Restore pre-migration settings?", isPresented: $restoreSettings) {
      Button("Cancel", role: .cancel) {}
      Button("Restore settings") { model.restorePreMigrationSettings() }
    } message: {
      Text(
        "The original settings will be restored. Current settings are preserved as settings.before-restore.json. Pending Fix approvals will be invalidated."
      )
    }
  }
}
