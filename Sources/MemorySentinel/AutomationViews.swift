import SentinelCore
import SwiftUI

struct AutomationSettings: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Form {
      Section("Automatic control") {
        Toggle("Repair MemorySentinel's own monitoring", isOn: model.controlBinding(\.selfRepair))
        Text(model.selfCareStatus).font(.caption).foregroundStyle(.secondary)
        Toggle(
          "Allow registered external actions", isOn: model.controlBinding(\.externalActionsEnabled)
        )
        .disabled(model.demo || !model.control.persistent || model.control.error != nil)
        Button("Stop automation", role: .destructive) { model.stopAutomation() }
        Text(
          "External actions start off. Register an exact process in Processes before enabling them. No root, Full Disk Access, Accessibility or general Apple Events permission is requested."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if let message = model.automationMessage {
        Section {
          Text(message).font(.callout); Button("Dismiss") { model.automationMessage = nil }
        }
      }
      Section("External limits") {
        Text(
          "One intervention at a time · one attempt per issue · one per target per hour · three per rolling 24 hours. Two failed attempts pause the rule until review. Manual Fix takes priority."
        )
        Text(
          "Force Quit always requires a separate manual confirmation. Stop automation prevents later steps; a request already sent cannot be undone."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Registered permissions · \(model.control.rules.count)/64") {
        if model.control.rules.isEmpty {
          Text("No external permissions. Open a process and choose Register managed task…")
            .foregroundStyle(.secondary)
        }
        ForEach(model.control.rules) { rule in
          VStack(alignment: .leading, spacing: 6) {
            Text(rule.label).font(.headline)
            Text(rule.operation.title).font(.callout)
            Text(
              "\(rule.trigger.title) · \(Int(rule.holdSeconds))s observed hold · expires \(rule.expires.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption)
            Text(rule.executable.path).font(.caption.monospaced()).textSelection(.enabled)
            Text("Executable SHA-256: \(rule.executable.sha256)").font(.caption2.monospaced())
              .textSelection(.enabled)
            Text(
              rule.reviewReason ?? model.automationReasons[rule.id]
                ?? "Waiting for fresh evaluation"
            ).font(.caption).foregroundStyle(.secondary)
            if let last = model.control.attempts.first(where: { $0.ruleID == rule.id }) {
              Text(
                "Last used \(last.created.formatted(date: .abbreviated, time: .shortened)): \(last.status.rawValue). \(last.message)"
              )
              .font(.caption)
              Text(
                "Earliest target retry: \(last.created.addingTimeInterval(3600).formatted(date: .abbreviated, time: .shortened)); episode, daily limit, review and fresh evidence may delay it further."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
              if rule.enabled && rule.reviewReason != nil {
                Button("Review unchanged permission") { model.reviewAutomation(rule) }
              }
              Button(rule.enabled ? "Revoke permission" : "Revoked", role: .destructive) {
                model.revokeAutomation(rule.id)
              }.disabled(!rule.enabled)
            }
          }.padding(.vertical, 8)
        }
      }
    }.formStyle(.grouped)
  }
}

struct ManagedTaskRegistration: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var process: ProcessRecord
  @State private var label = ""
  @State private var application = false
  @State private var restart = false
  @State private var trigger = AutomaticTrigger.sustainedPressure
  @State private var limitMiB = 1024.0
  @State private var hold = 60.0
  @State private var days = 7
  @State private var endpoint = ""
  @State private var arguments = "[]"
  @State private var directory = ""
  @State private var acknowledge = false
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Register an exact permission").font(.title2.bold())
      Text(
        "\(process.name) · PID \(process.identity.pid) · owner \(process.uid)\nStarted \(process.identity.startDate.formatted())\n\(process.path)"
      )
      .font(.caption.monospaced()).textSelection(.enabled)
      Text(
        process.origin?.evidence
          ?? "Application origin unavailable. This grants no authority over a launcher or its children."
      )
      .font(.caption).foregroundStyle(.secondary)
      Form {
        TextField("Task / permission name", text: $label)
        if process.applicationMetadata?.executablePath == process.path {
          Toggle("Advanced: restart this cooperative application", isOn: $application)
        }
        if application {
          TextField("Private readiness socket path", text: $endpoint)
          Text(
            "Requires an application-specific integration that holds a verified idle/no-unsaved-work lease. Unsupported applications need a manual decision. A save prompt, refusal or timeout stops the sequence."
          ).font(.caption)
        } else {
          Toggle("Separately authorize restart after SIGTERM", isOn: $restart)
          if restart {
            TextField("Explicit arguments (JSON string array)", text: $arguments)
            TextField("Working directory (optional absolute path)", text: $directory)
            Text(
              "The same pinned executable is launched directly with these arguments and a minimal environment. Existing arguments and environment variables are never inferred."
            ).font(.caption)
          }
        }
        Picker("Trigger", selection: $trigger) {
          Text("Sustained system pressure").tag(AutomaticTrigger.sustainedPressure)
          Text("Critical system pressure").tag(AutomaticTrigger.criticalPressure)
          if !application {
            Text("Explicit task stop threshold").tag(AutomaticTrigger.taskFootprint)
          }
        }
        if trigger == .taskFootprint {
          TextField("Stop threshold (MiB)", value: $limitMiB, format: .number)
          Text("This is an explicit stop rule. Existing advisory budgets grant no action.").font(
            .caption)
        }
        Slider(value: $hold, in: 60...600, step: 15) { Text("Observed hold: \(Int(hold))s") }
        Stepper("Permission expires in \(days) days", value: $days, in: 1...30)
        Text(
          "Bound to profile \(model.settings.activeProfile.name). Task permission applies only to this PID + start time, owner and exact executable. Children receive no permission. A changed binary requires a new review."
        )
        .font(.caption)
      }.formStyle(.grouped)
      Toggle(
        "I authorize this interruption. SIGTERM or normal Quit can interrupt work; this task is disposable or the app supports the required readiness integration.",
        isOn: $acknowledge
      )
      .font(.caption)
      if let error { Text(error).foregroundStyle(.orange).font(.caption) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(saving ? "Saving…" : "Register permission") {
          saving = true
          Task {
            do {
              try await model.registerAutomation(
                process: process, label: label, application: application,
                restart: restart, trigger: trigger, limit: limitMiB * MiB, hold: hold,
                endpoint: endpoint, argumentsJSON: arguments, directory: directory, days: days)
              dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
          }
        }.disabled(
          !acknowledge || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
      }
    }.padding(24).frame(width: 660, height: 760)
      .onChange(of: application) { _, value in
        if value && trigger == .taskFootprint { trigger = .sustainedPressure }
      }
  }
}
