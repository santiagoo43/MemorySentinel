import Charts
import SentinelCore
import SwiftUI

struct MemoryDatum: Identifiable {
  var id: Int
  var elapsed: Double
  var value: Double?
  var segment: Int
}
struct MemorySeries: Identifiable {
  var id: String
  var points: [MemoryDatum]
  static func session(_ session: WorkSession, label: String) -> Self {
    var segment = 0
    let points = SessionSeries.reduce(session.points).enumerated().map { i, p in
      if p.gap || p.monitored == nil { segment += 1 }
      return MemoryDatum(id: i, elapsed: p.elapsed, value: p.monitored, segment: segment)
    }
    return Self(id: label, points: points)
  }
}
struct MemoryMarker: Identifiable {
  var id: UUID
  var elapsed: Double
  var label: String
}
struct ObservedMemoryChart: View {
  var title: String
  var series: [MemorySeries]
  var duration: Double
  var markers: [MemoryMarker] = []
  @Binding var selection: Double?
  private var maximum: Double {
    max(GiB, series.flatMap(\.points).compactMap(\.value).filter(\.isFinite).max() ?? GiB) * 1.05
  }
  private var minutesSelection: Binding<Double?> {
    Binding<Double?>(
      get: { selection.map { $0 / 60.0 } }, set: { value in selection = value.map { $0 * 60.0 } })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      plot
      if duration > 0 {
        Slider(
          value: Binding<Double>(
            get: { min(duration, max(0, selection ?? 0)) }, set: { selection = $0 }),
          in: 0...max(1, duration)
        )
        .accessibilityLabel("Selected observed time in seconds")
      }
    }
  }
  @ChartContentBuilder private var marks: some ChartContent {
    ForEach(series) { line in
      ForEach(line.points) { point in
        if let value = point.value, value.isFinite {
          LineMark(
            x: .value("Elapsed minutes", point.elapsed / 60), y: .value("GiB", value / GiB),
            series: .value("Continuous segment", "\(line.id)-\(point.segment)")
          )
          .foregroundStyle(by: .value("Observation", line.id))
          .accessibilityLabel("\(line.id), \(String(format: "%.1f", point.elapsed / 60)) minutes")
          .accessibilityValue(Format.bytes(value))
        }
      }
    }
  }
  private var plot: some View {
    Chart {
      marks
      ForEach(markers.prefix(80)) { marker in
        RuleMark(x: .value("Event minutes", marker.elapsed / 60.0))
          .foregroundStyle(.orange.opacity(0.35)).lineStyle(
            StrokeStyle(lineWidth: 1, dash: [2, 4])
          )
          .accessibilityLabel(marker.label)
      }
      if let selection {
        RuleMark(x: .value("Selected minutes", selection / 60.0)).foregroundStyle(.secondary)
          .lineStyle(StrokeStyle(dash: [3, 3]))
      }
    }.chartXScale(domain: 0.0...max(1.0, duration / 60.0)).chartYScale(
      domain: 0.0...(maximum / GiB)
    )
    .chartXSelection(value: minutesSelection)
    .chartForegroundStyleScale(range: [Color.mint, Color.orange, Color.blue])
    .chartXAxisLabel("Minutes since start").chartYAxisLabel("GiB")
    .frame(height: 175).accessibilityLabel(
      "\(title). Measured values with breaks at gaps. Peak \(Format.bytes(series.flatMap(\.points).compactMap(\.value).max()))."
    )
  }
}

struct RecordingsView: View {
  @EnvironmentObject var model: AppModel
  @State private var selectedID: UUID?
  @State private var frames: [ExperienceFrame] = []
  @State private var cursor: Double? = 0
  @State private var loading = false
  @State private var error: String?
  @State private var frozenRecording: FlightRecording?
  @State private var expandedProcesses = false
  @State private var expandedEvents = false
  private var recording: FlightRecording? {
    frozenRecording ?? model.experience.recordings.first { $0.id == selectedID }
  }
  private var duration: Double { max(1, (frames.last?.uptime ?? 0) - (frames.first?.uptime ?? 0)) }
  private var selectedFrame: ExperienceFrame? {
    guard let first = frames.first else { return nil }
    return frames.min {
      abs(($0.uptime - first.uptime) - (cursor ?? 0))
        < abs(($1.uptime - first.uptime) - (cursor ?? 0))
    }
  }
  private var markers: [MemoryMarker] {
    guard let first = frames.first else { return [] }
    var grouped: [UUID: (frame: ExperienceFrame, events: [ExperienceEvent])] = [:]
    for event in recording?.events ?? [] {
      guard
        let nearest = frames.min(by: {
          abs($0.date.timeIntervalSince(event.date)) < abs($1.date.timeIntervalSince(event.date))
        })
      else { continue }
      if grouped[nearest.id] == nil { grouped[nearest.id] = (nearest, []) }
      grouped[nearest.id]?.events.append(event)
    }
    return grouped.values.sorted { $0.frame.uptime < $1.frame.uptime }.map { group in
      let kinds = Array(Set(group.events.map { $0.kind.title })).sorted().joined(separator: ", ")
      return MemoryMarker(
        id: group.frame.id, elapsed: max(0, group.frame.uptime - first.uptime),
        label: "\(group.events.count) event(s): \(kinds)")
    }
  }
  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Flight Recorder").font(.headline); Spacer();
          Button("Record now") { model.recordNow() }.disabled(
            model.paused || !model.experience.historyAvailable)
        }
        Text("20 captures · 64 MiB shared experience quota · Old captures expire automatically")
          .font(.caption2).foregroundStyle(.secondary)
        List(selection: $selectedID) {
          ForEach(model.experience.recordings) { item in
            VStack(alignment: .leading, spacing: 5) {
              Text(item.title).font(.headline)
              Text(item.trigger.formatted(date: .abbreviated, time: .shortened)).font(.caption)
              Label(
                item.status.rawValue.capitalized,
                systemImage: item.status == .recording
                  ? "record.circle" : item.status == .expired ? "archivebox" : "waveform.path"
              )
              .font(.caption2).foregroundStyle(
                item.status == .recording ? Color.orange : Color.secondary)
            }.padding(.vertical, 5).tag(item.id)
          }
        }.listStyle(.sidebar)
      }.padding(16).frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let recording {
            HStack {
              SectionTitle(
                title: recording.title,
                subtitle:
                  "HISTORICAL OBSERVATIONS\(recording.demo ? " · SIMULATED DATA" : "") · \(recording.status.rawValue.capitalized)"
              )
              Spacer()
              Button("Report…") {
                frozenRecording = recording
                model.reportRequest = .recording(recording)
              }
              Button("Refresh") { refresh() }
            }
            Text(
              "\(frames.count) available samples · \(recording.start.formatted(date: .abbreviated, time: .standard)) — \(recording.end.formatted(date: .omitted, time: .standard))"
            )
            .font(.caption).foregroundStyle(.secondary)
            if let reason = recording.partialReason {
              Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            if loading { ProgressView("Loading recorded observations…") }
            if let error { Text(error).foregroundStyle(.orange) }
            if !frames.isEmpty {
              Surface {
                ObservedMemoryChart(
                  title: "Attributed footprint and system used estimate",
                  series: [
                    line("Attributed footprint", value: { $0.monitored }),
                    line("System used estimate", value: { $0.system.used }),
                  ], duration: duration, markers: markers, selection: $cursor)
                if markers.count > 80 {
                  Text(
                    "Showing 80 of \(markers.count) event positions. Recent retained events are listed below."
                  )
                  .font(.caption2).foregroundStyle(.secondary)
                }
              }
              Surface {
                ObservedMemoryChart(
                  title: "Swap", series: [line("Swap", value: { $0.system.swap })],
                  duration: duration, markers: markers, selection: $cursor)
              }
              if let frame = selectedFrame {
                Surface {
                  VStack(alignment: .leading, spacing: 10) {
                    Text(
                      "Nearest measured sample · \(frame.date.formatted(date: .abbreviated, time: .standard))"
                    ).font(.headline)
                    Text(
                      "Profile \(frame.profileName) · \(frame.system.pressure.rawValue.capitalized) pressure · Footprint \(Format.bytes(frame.monitored)) · Swap \(Format.bytes(frame.system.swap))"
                    ).font(.caption)
                    Text(
                      "Before → after capture: \(Format.bytes(frames.first?.monitored)) → \(Format.bytes(frames.last?.monitored)). These are accounting measurements, not proof of released unique RAM."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    let processes = frame.processes.sorted {
                      ($0.footprint ?? -1) > ($1.footprint ?? -1)
                    }
                    ForEach(processes.prefix(8)) { process in
                      HStack {
                        Text(process.name).lineLimit(1); Spacer();
                        Text("PID \(process.id.pid)").foregroundStyle(.secondary);
                        Text(Format.bytes(process.footprint)).monospacedDigit()
                      }.font(.caption)
                    }
                    if processes.count > 8 {
                      DisclosureGroup(
                        "\(processes.count - 8) more captured processes",
                        isExpanded: $expandedProcesses
                      ) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                          ForEach(processes.dropFirst(8)) { process in
                            HStack {
                              Text(process.name).lineLimit(1); Spacer()
                              Text("PID \(process.id.pid)").foregroundStyle(.secondary)
                              Text(Format.bytes(process.footprint)).monospacedDigit()
                            }.font(.caption)
                          }
                        }
                      }.font(.caption)
                    }
                    Text(
                      "\(frame.omittedProcesses) monitored processes omitted by the per-frame limit. This historical list cannot authorize process actions."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                  }
                }
              }
            } else if !loading {
              EmptyState(
                title: recording.status == .expired
                  ? "Recording expired" : "No stored frames available",
                detail:
                  "Count and payload quotas preserve bounded storage. Unavailable past data is never reconstructed."
              )
            }
            Surface {
              DisclosureGroup(
                "Event markers (\(recording.events.count))", isExpanded: $expandedEvents
              ) {
                LazyVStack(alignment: .leading, spacing: 9) {
                  if recording.omittedEvents > 0 {
                    Text("\(recording.omittedEvents) earlier markers omitted under capture limits.")
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  ForEach(recording.events.suffix(100)) { event in
                    HStack(alignment: .top) {
                      Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                        .foregroundStyle(.secondary)
                      Text(event.text)
                    }.font(.caption)
                  }
                  if recording.events.count > 100 {
                    Text("Showing the latest 100 retained markers.").font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          } else {
            EmptyState(
              title: "Record a memory event",
              detail:
                "Confirmed warnings capture available lead-in and subsequent samples. Record now starts a manual capture.",
              symbol: "record.circle")
          }
        }.padding(24)
      }.frame(minWidth: 420)
    }.onAppear { if selectedID == nil { selectedID = model.experience.recordings.first?.id } }
      .onChange(of: model.experience.recordings.first?.id) { _, id in
        if selectedID == nil { selectedID = id }
      }
      .onChange(of: model.demo) { _, _ in
        frozenRecording = nil; selectedID = nil; frames = []
      }
      .onChange(of: model.reportRequest == nil) { _, closed in
        if closed { frozenRecording = nil }
      }
      .task(id: "\(selectedID?.uuidString ?? "none")-\(recording?.revision ?? 0)-\(model.demo)") {
        await load()
      }
  }
  private func line(_ title: String, value: (ExperienceFrame) -> Double?) -> MemorySeries {
    var segment = 0, previous: ExperienceFrame?
    let points = frames.enumerated().map { i, frame in
      if previous != nil && ObservationContinuity.interval(previous, frame) == nil
        || value(frame) == nil
      {
        segment += 1
      }
      previous = frame
      return MemoryDatum(
        id: i, elapsed: max(0, frame.uptime - (frames.first?.uptime ?? frame.uptime)),
        value: value(frame), segment: segment)
    }
    return MemorySeries(id: title, points: points)
  }
  private func refresh() { Task { await load() } }
  @MainActor private func load() async {
    guard let recording else { frames = []; return }
    loading = true; error = nil
    let tracker = model.analytics, expectedDemo = model.demo, id = recording.id
    do {
      let values = try await tracker.frames(for: recording)
      guard !Task.isCancelled, selectedID == id, model.demo == expectedDemo else { return }
      frames = values; loading = false
      if values.count < recording.references.count {
        error = "Some referenced frames are unavailable. The displayed capture is incomplete."
      }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
  }
}

struct SessionsView: View {
  @EnvironmentObject var model: AppModel
  @State private var selectedID: UUID?
  @State private var comparisonID: UUID?
  @State private var detail: WorkSession?
  @State private var comparison: WorkSession?
  @State private var cursor: Double?
  @State private var error: String?
  private var header: WorkSession? { model.experience.sessions.first { $0.id == selectedID } }
  private var comparisonHeader: WorkSession? {
    model.experience.sessions.first { $0.id == comparisonID }
  }
  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Work sessions").font(.headline); Spacer();
          Button("Start…") { model.showSessionComposer = true }.disabled(
            model.experience.sessions.contains { $0.status == .active }
              || !model.experience.historyAvailable)
        }
        if model.experience.sessions.contains(where: { $0.status == .active }) {
          Button("End active session") { model.endSession() }
        }
        List(selection: $selectedID) {
          ForEach(model.experience.sessions) { session in
            VStack(alignment: .leading, spacing: 5) {
              Text(session.name).font(.headline)
              Text("\(session.profileName) · \(session.status.rawValue.capitalized)").font(.caption)
                .foregroundStyle(.secondary)
              Text(session.started.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
            }.padding(.vertical, 5).tag(session.id)
          }
        }.listStyle(.sidebar)
      }.padding(16).frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let detail {
            HStack {
              SectionTitle(
                title: detail.name,
                subtitle: "\(detail.profileName) · \(detail.status.rawValue.capitalized)");
              Spacer(); Button("Report…") { model.reportRequest = .session(detail) }
            }
            sessionMetrics(detail)
            Surface {
              VStack(alignment: .leading, spacing: 9) {
                Text("Session observations").font(.headline)
                Text(
                  "Swap change: \(detail.swapChange.map { String(format: "%+.1f MiB", $0 / MiB) } ?? "Unavailable")"
                )
                Text("Measured pressure time").font(.caption.bold())
                ForEach(detail.pressureSeconds.keys.sorted(), id: \.self) { state in
                  HStack {
                    Text(state.capitalized); Spacer()
                    Text(String(format: "%.1f min", detail.pressureSeconds[state, default: 0] / 60))
                  }
                }
                if detail.pressureSeconds.isEmpty {
                  Text("No complete pressure intervals available.")
                }
                Text(
                  "\(detail.profileIDs.count) observed profile(s) · \(detail.configurations.count) configuration(s). Pressure intervals can have different coverage from complete memory observations."
                )
                .foregroundStyle(.secondary)
              }.font(.caption)
            }
            if !detail.note.isEmpty { Text(detail.note).font(.callout).textSelection(.enabled) }
            Picker("Compare with", selection: $comparisonID) {
              Text("No comparison").tag(UUID?.none)
              ForEach(model.experience.sessions.filter { $0.id != detail.id }) {
                Text("\($0.name) · \($0.started.formatted(date: .abbreviated, time: .shortened))")
                  .tag(Optional($0.id))
              }
            }
            Surface {
              ObservedMemoryChart(
                title: comparison == nil
                  ? "Measured attributed footprint" : "Sessions aligned at their own start",
                series: [MemorySeries.session(detail, label: "Selected session")]
                  + (comparison.map { [MemorySeries.session($0, label: "Comparison session")] }
                    ?? []),
                duration: max(detail.elapsedSeconds, comparison?.elapsedSeconds ?? 0),
                selection: $cursor)
              if let cursor {
                Text(
                  "Selected elapsed time: \(String(format: "%.1f", cursor / 60)) min · Values are measured; gaps remain visible."
                ).font(.caption).foregroundStyle(.secondary)
              }
            }
            if let comparison {
              Surface {
                VStack(alignment: .leading, spacing: 10) {
                  Text("Selected → comparison").font(.headline)
                  Text("Mean: \(Format.bytes(detail.mean)) → \(Format.bytes(comparison.mean))")
                  Text("Peak: \(Format.bytes(detail.peak)) → \(Format.bytes(comparison.peak))")
                  Text(
                    "Warnings per observed hour: \(rate(detail.warningsPerHour)) → \(rate(comparison.warningsPerHour))"
                  )
                  Text(
                    "Coverage: \(Int(detail.coverage * 100))% → \(Int(comparison.coverage * 100))%")
                  ForEach(SessionComparison.cautions(detail, comparison), id: \.self) {
                    Text($0).foregroundStyle(.secondary)
                  }
                }.font(.caption)
              }
            }
            Surface {
              VStack(alignment: .leading, spacing: 9) {
                Text("Largest measured consumers").font(.headline)
                ForEach(detail.consumers.sorted { ($0.peak ?? -1) > ($1.peak ?? -1) }) { app in
                  HStack {
                    Text("\(app.name) · \(app.version ?? "Version unavailable")"); Spacer();
                    Text("Peak \(Format.bytes(app.peak))")
                  }.font(.caption)
                }
              }
            }
          } else {
            EmptyState(
              title: "Measure a work session",
              detail:
                "Name a task, choose its profile, then compare measured memory and warning rates across sessions.",
              symbol: "timer")
          }
          if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(24)
      }.frame(minWidth: 420)
    }.onAppear { if selectedID == nil { selectedID = model.experience.sessions.first?.id } }
      .onChange(of: model.experience.sessions.first?.id) { _, id in
        if selectedID == nil { selectedID = id }
      }
      .onChange(of: model.demo) { _, _ in
        selectedID = nil; detail = nil; comparisonID = nil; comparison = nil
      }
      .task(
        id:
          "\(selectedID?.uuidString ?? "none")-\(header?.revision ?? 0)-\(comparisonID?.uuidString ?? "none")-\(comparisonHeader?.revision ?? 0)-\(model.demo)"
      ) { await load() }
      .sheet(isPresented: $model.showSessionComposer) { SessionComposer().environmentObject(model) }
  }
  private func rate(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0) } ?? "Unavailable"
  }
  private func sessionMetrics(_ session: WorkSession) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
      MetricCard(
        title: "Mean footprint", value: Format.bytes(session.mean),
        subtitle: "Time-weighted available measurements", symbol: "memorychip")
      MetricCard(
        title: "Peak footprint", value: Format.bytes(session.peak),
        subtitle: "Observed attributed accounting peak", symbol: "chart.line.uptrend.xyaxis")
      MetricCard(
        title: "Coverage", value: "\(Int(session.coverage * 100))%",
        subtitle:
          "\(Int(session.observedSeconds / 60)) observed / \(Int(session.elapsedSeconds / 60)) elapsed min",
        symbol: "clock")
      MetricCard(
        title: "Warnings / hour", value: rate(session.warningsPerHour),
        subtitle:
          "\(session.warningCount) warning events · \(session.fixIDs.count) approved Fix sessions",
        symbol: "bell")
    }
  }
  @MainActor private func load() async {
    guard let id = selectedID else { detail = nil; return }
    let tracker = model.analytics, expectedDemo = model.demo, compareID = comparisonID
    do {
      let value = try await tracker.sessionDetails(id: id)
      var other: WorkSession?
      if let compareID { other = try await tracker.sessionDetails(id: compareID) }
      guard !Task.isCancelled, selectedID == id, model.demo == expectedDemo,
        comparisonID == compareID
      else { return }
      detail = value; comparison = other; error = nil
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}

struct SessionComposer: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  @State private var name = ""
  @State private var note = ""
  @State private var profileID: UUID?
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Start work session").font(.title2.bold())
      TextField("Session name", text: $name)
      Picker("Profile", selection: $profileID) {
        ForEach(model.settings.profiles ?? []) { Text($0.name).tag(Optional($0.id)) }
      }
      Text("Private note · omitted from shared reports by default").font(.caption).foregroundStyle(
        .secondary)
      TextEditor(text: $note).frame(height: 100).border(.secondary.opacity(0.3))
      Text(
        "Only existing monitoring measurements are recorded. Missing periods reduce coverage; no project files or terminal commands are inspected."
      ).font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.orange).font(.caption) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start session") {
          guard let profileID else { return }; busy = true
          Task {
            do { try await model.startSession(name: name, note: note, profileID: profileID) } catch
            { self.error = error.localizedDescription; busy = false }
          }
        }.buttonStyle(.borderedProminent).disabled(busy || profileID == nil)
      }
    }.padding(26).frame(width: 520).onAppear { profileID = model.settings.activeProfile.id }
  }
}
