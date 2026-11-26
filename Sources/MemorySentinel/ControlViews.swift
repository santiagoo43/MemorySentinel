import SentinelCore
import SwiftUI

extension AppModel {
  func nameTask(_ process: ProcessRecord, value: String) {
    let tracker = controller, expectedDemo = demo
    Task {
      await tracker.name(process, value: value)
      if demo == expectedDemo { control = await tracker.summary() }
    }
  }
  func reviewEpisode(_ id: UUID, value: Bool) {
    let tracker = controller, expectedDemo = demo
    Task {
      await tracker.reviewing(id, value: value)
      if demo == expectedDemo { control = await tracker.summary() }
    }
  }
  func controlBinding(_ path: WritableKeyPath<ControlPreferences, Bool>) -> Binding<Bool> {
    Binding<Bool>(
      get: { self.settings.controls[keyPath: path] },
      set: { value in
        var preferences = self.settings.controls
        preferences[keyPath: path] = value; self.settings.controlPreferences = preferences
      })
  }
}

struct CurrentIssuesSummary: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "bell.badge").foregroundStyle(.mint)
      VStack(alignment: .leading, spacing: 4) {
        Text("Smart alerts · \(model.control.active.count) current issue(s)").font(.callout.bold())
        Text(
          model.control.active.contains { $0.status == .actionRequired }
            ? "A current issue needs review. Open Activity for evidence and available steps."
            : "Warnings stay visible. Unchanged readings do not trigger periodic banners."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("View activity") { model.showSection("Activity") }
    }.padding(14).background(.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct EpisodeCard: View {
  @EnvironmentObject var model: AppModel
  var episode: ProblemEpisode
  private var origin: FixOrigin {
    let issue: ProblemKind =
      [.systemPressure, .lowDisk, .unavailableMetrics, .monitoringFailure].contains(episode.kind)
      ? episode.kind : .selectedContributor
    return FixOrigin(
      identity: episode.identities.first, issue: issue, demoSource: model.demo,
      episodeID: episode.id)
  }
  var body: some View {
    Surface {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(episode.label).font(.headline)
          Spacer()
          Text(episode.status.title).font(.caption.bold()).foregroundStyle(
            episode.status == .actionRequired
              ? Color.orange : episode.status == .resolved ? .mint : .secondary)
        }
        Text(episode.evidence).font(.callout).textSelection(.enabled)
        if let reason = episode.humanReason {
          Label(reason, systemImage: "person.crop.circle.badge.exclamationmark").font(.caption)
            .foregroundStyle(.orange)
        }
        if let failed = episode.automaticFailure {
          Text("Automatic attempt: \(failed)").font(.caption).foregroundStyle(.orange)
        }
        Text(episode.noticeDecision ?? "Review current evidence before deciding on an action.")
          .font(.caption).foregroundStyle(.secondary)
        if let failure = episode.noticeFailure {
          Text("Notification delivery: \(failure)").font(.caption).foregroundStyle(.orange)
        }
        HStack {
          Text("Since \(episode.started.formatted(date: .abbreviated, time: .shortened))").font(
            .caption2
          )
          .foregroundStyle(.secondary)
          Spacer()
          Toggle(
            "Reviewing",
            isOn: Binding<Bool>(
              get: { episode.reviewing }, set: { model.reviewEpisode(episode.id, value: $0) })
          )
          .toggleStyle(.checkbox).font(.caption)
          FixButton(origin: origin, title: "Review Fix…")
        }
        if let correlation = episode.correlatedTo {
          Text(
            "Related to \(model.control.episodes.first { $0.key == correlation }?.label ?? "a system issue"). Signals remain separate evidence."
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct ControlActivityView: View {
  @EnvironmentObject var model: AppModel
  @State private var filter = "All"
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        SectionTitle(
          title: "Current issues", subtitle: "Measurements, decisions and outcomes are separate")
        if let error = model.control.error {
          Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
            .orange)
        }
        if model.control.active.isEmpty {
          Text("No active problem episodes in the available evidence.").foregroundStyle(.secondary)
        }
        ForEach(model.control.active) { EpisodeCard(episode: $0) }
        Divider()
        HStack {
          SectionTitle(title: "Activity", subtitle: "Local audit · latest 500 entries")
          Spacer()
          Picker("Activity type", selection: $filter) {
            Text("All").tag("All")
            Text("Notifications").tag("notification")
            Text("Suppressed alerts").tag("suppressed")
            Text("Self repair").tag("selfRepair")
            Text("Automatic actions").tag("automatic")
            Text("Manual actions").tag("manual")
            Text("Permissions").tag("permission")
          }.frame(width: 220)
        }
        ForEach(model.control.activity.filter { filter == "All" || $0.kind.rawValue == filter }) {
          item in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(item.title).font(.callout.bold()); Spacer()
              Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                .foregroundStyle(.secondary)
            }
            Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let id = item.fixSessionID, let fix = model.fixHistory.first(where: { $0.id == id })
            {
              Button("Preview recorded Fix report…") { model.reportRequest = .fix(fix) }.font(
                .caption)
            }
            Divider()
          }
        }
      }.padding(28)
    }
  }
}
