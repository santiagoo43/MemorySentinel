import SentinelCore
import SwiftUI

extension RiskLevel {
  var color: Color {
    switch self {
    case .normal: .mint
    case .elevated: .yellow
    case .warning: .orange
    case .critical: .red
    }
  }
  var symbol: String {
    switch self {
    case .normal: "checkmark.shield.fill"
    case .elevated: "waveform.path"
    case .warning: "exclamationmark.triangle.fill"
    case .critical: "exclamationmark.octagon.fill"
    }
  }
}
struct Surface<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }.padding(20).frame(
      maxWidth: .infinity, alignment: .leading
    ).background(
      Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 18)
    ).overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07), lineWidth: 1))
  }
}
struct RiskBadge: View {
  var level: RiskLevel
  var body: some View {
    Label(level.title, systemImage: level.symbol).font(
      .system(size: 11, weight: .bold, design: .rounded)
    ).foregroundStyle(level.color).padding(.horizontal, 10).padding(.vertical, 6).background(
      level.color.opacity(0.12), in: Capsule()
    ).accessibilityLabel("Risk level \(level.title)")
  }
}
struct MetricCard: View {
  var title: String
  var value: String
  var subtitle: String
  var symbol: String
  var color: Color = .mint
  var body: some View {
    Surface {
      HStack {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
          .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: symbol).foregroundStyle(color)
      }
      Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.65).padding(.top, 9)
      Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(
        height: 28, alignment: .top
      ).padding(.top, 2)
    }.help(subtitle)
  }
}
struct SectionTitle: View {
  var title: String
  var subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 19, weight: .semibold))
      Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
}
struct EmptyState: View {
  var title: String
  var detail: String
  var symbol: String = "waveform.path"
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.mint)
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity, minHeight: 180).padding()
  }
}
