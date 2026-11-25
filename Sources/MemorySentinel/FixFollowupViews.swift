import SentinelCore
import SwiftUI

struct FixFollowupPanel: View {
  @EnvironmentObject var model: AppModel
  var fixID: UUID? = nil
  private var values: [FollowupObservation] {
    Array(model.experience.followups.filter { fixID == nil || $0.id == fixID }.prefix(20))
  }
  var body: some View {
    ForEach(values) { value in
      Surface {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Five-minute follow-up · \(value.appName)").font(.headline); Spacer()
            Text(title(value.status)).font(.caption.bold()).foregroundStyle(
              value.status == .stable ? Color.mint : Color.orange)
          }
          Text(
            "Immediate result: \(value.immediate.outcome.title). Follow-up is a separate observation."
          ).font(.caption).foregroundStyle(.secondary)
          Text(
            "Footprint: \(Format.bytes(value.before.targetFootprint)) → \(Format.bytes(value.immediate.after?.targetFootprint)) → \(Format.bytes(value.last?.targetFootprint))"
          ).font(.caption)
          Text(
            "Pressure: \(value.before.system.pressure.rawValue) → \(value.immediate.after?.system.pressure.rawValue ?? "unavailable") → \(value.last?.system.pressure.rawValue ?? "unavailable")"
          ).font(.caption)
          if value.status == .observing {
            ProgressView(value: min(1, value.coveredSeconds / 300)).tint(.mint)
          }
          Text(
            "\(Int(value.coveredSeconds))/300 covered seconds · \(value.samples) samples · Related warning \(value.warningReturned ? "observed" : "not observed in available samples")"
          )
          .font(.caption2).foregroundStyle(.secondary)
          Text(
            value.issue ?? "Observing existing monitoring samples. No further action will be sent."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func title(_ state: FollowupObservation.Status) -> String {
    switch state {
    case .observing: "Observing"
    case .stable: "No related warning observed"
    case .returned: "Related warning observed"
    case .partial: "Partial observation"
    case .unavailable: "Cannot evaluate"
    }
  }
}

struct PastFixEvidenceView: View {
  @EnvironmentObject var model: AppModel
  var context: FollowupObservation? = nil
  private var cohorts: [[FollowupObservation]] {
    let values = model.experience.followups.filter {
      $0.profileID == model.settings.activeProfile.id
        && (context == nil
          || ($0.appKey == context?.appKey && $0.version == context?.version
            && $0.problem == context?.problem))
    }
    return Dictionary(grouping: values) {
      [$0.appKey ?? "system", $0.version ?? "unknown", $0.problem.rawValue, $0.action.rawValue]
        .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
    }.values.sorted { ($0.first?.started ?? .distantPast) > ($1.first?.started ?? .distantPast) }
  }
  var body: some View {
    if !cohorts.isEmpty {
      Surface {
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle(
            title: "What helped before",
            subtitle:
              "Comparable observations in this profile · Past outcomes do not predict success")
          ForEach(Array(cohorts.prefix(12).enumerated()), id: \.offset) { _, values in
            if let first = values.first {
              let complete = values.filter { $0.status == .stable || $0.status == .returned }
              let stable = complete.filter { $0.status == .stable }.count
              VStack(alignment: .leading, spacing: 5) {
                Text(
                  "\(first.appName) · \(first.version ?? "Version unavailable") · \(first.problem.title)"
                ).font(.caption.bold())
                Text(
                  "\(first.action.rawValue): \(stable)/\(complete.count) complete observations without a related warning; \(values.filter { $0.status == .partial || $0.status == .unavailable }.count) partial/unavailable; \(values.filter { $0.status == .observing }.count) observing."
                ).font(.caption)
                if values.count < 3 {
                  Text("Few comparable cases; the evidence is limited.").font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if first.version == nil {
                  Text(
                    "Application versions are unknown; version equivalence cannot be established."
                  ).font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
    }
  }
}
