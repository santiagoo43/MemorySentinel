import Charts
import SentinelCore
import SwiftUI

struct TimelineChart: View {
  @EnvironmentObject var model: AppModel
  @State private var range: Double = 900
  @State private var series = "Monitored"
  @State private var selection: Date?
  private var points: [TimelinePoint] {
    model.timeline.filter { $0.date >= (model.snapshot?.date ?? Date()).addingTimeInterval(-range) }
  }
  private func value(_ p: TimelinePoint) -> Double? {
    series == "System" ? p.systemUsed : series == "Monitored" ? p.monitored : p.groups[series]
  }
  private func peakValue(_ p: TimelinePoint) -> Double? {
    series == "Monitored" ? p.peak ?? p.monitored : value(p)
  }
  private var nearest: TimelinePoint? {
    guard let selection else { return nil }
    return points.min {
      abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection))
    }
  }
  private var peak: TimelinePoint? {
    points.filter { peakValue($0) != nil }.max { (peakValue($0) ?? 0) < (peakValue($1) ?? 0) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        SectionTitle(
          title: "Memory timeline",
          subtitle:
            "GiB · \(series == "System" ? "estimated system used" : "attributed footprint accounting")"
        )
        Spacer()
        Picker("Series", selection: $series) {
          Text("Monitored").tag("Monitored")
          Text("System").tag("System")
          ForEach((model.snapshot?.point.groups.keys.sorted() ?? []), id: \.self) {
            Text($0).tag($0)
          }
        }.labelsHidden().frame(width: 140)
      }
      Picker("Time window", selection: $range) {
        Text("5 min").tag(300.0)
        Text("15 min").tag(900.0)
        Text("1 hour").tag(3600.0)
        Text("6 hours").tag(21600.0)
        Text("24 hours").tag(86400.0)
      }.pickerStyle(.segmented).frame(maxWidth: 430)
      if points.compactMap({ value($0) }).isEmpty {
        EmptyState(
          title: "Building the timeline",
          detail:
            "Measured values appear as samples arrive. Historical group data may be unavailable.")
      } else {
        Chart {
          ForEach(points) { p in
            if let bytes = value(p) {
              AreaMark(x: .value("Time", p.date), y: .value("Memory GiB", bytes / GiB))
                .foregroundStyle(
                  LinearGradient(
                    colors: [.mint.opacity(0.20), .mint.opacity(0.005)], startPoint: .top,
                    endPoint: .bottom))
              LineMark(x: .value("Time", p.date), y: .value("Memory GiB", bytes / GiB))
                .foregroundStyle(.mint).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(
                  .linear)
            }
          }
          if let peak, let bytes = peakValue(peak) {
            PointMark(
              x: .value(
                "Peak time", series == "Monitored" ? peak.peakDate ?? peak.date : peak.date),
              y: .value("Peak", bytes / GiB)
            )
            .foregroundStyle(.mint).symbolSize(24)
          }
          ForEach(model.incidents.filter { $0.date >= (points.first?.date ?? Date()) }.prefix(20)) {
            event in
            RuleMark(x: .value("Incident", event.date)).foregroundStyle(
              event.level.color.opacity(0.4)
            ).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
          }
          if let nearest, let bytes = value(nearest) {
            RuleMark(x: .value("Selected time", nearest.date)).foregroundStyle(
              .secondary.opacity(0.4)
            ).annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) {
              VStack(spacing: 3) {
                Text(Format.bytes(bytes)).font(
                  .system(size: 11, weight: .semibold, design: .monospaced))
                Text(nearest.date.formatted(date: .omitted, time: .standard)).font(.system(size: 9))
                  .foregroundStyle(.secondary)
              }.padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }.chartXSelection(value: $selection).chartYScale(
          domain: 0...max(1, (points.compactMap { peakValue($0) }.max() ?? GiB) / GiB * 1.18)
        ).chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisGridLine().foregroundStyle(.primary.opacity(0.04))
            AxisValueLabel(format: .dateTime.hour().minute())
          }
        }.chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(.primary.opacity(0.05))
            AxisValueLabel()
          }
        }.frame(height: 220).accessibilityLabel(
          "\(series) memory chart in GiB. Peak \(Format.bytes(peak.flatMap { peakValue($0) }))")
      }
      HStack {
        Label("Measured memory", systemImage: "circle.fill").foregroundStyle(.mint)
        Spacer()
        Text("Peak \(Format.bytes(peak.flatMap { peakValue($0) })) · Drag for values")
          .foregroundStyle(
            .secondary)
      }.font(.system(size: 10))
    }.onChange(of: range) { _, value in Task { await model.refreshTimeline(range: value) } }
  }
}
