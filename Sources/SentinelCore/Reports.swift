import Foundation

public struct ReportOptions: Equatable, Sendable {
  public var includeDetails = false
  public var includeNotes = false
  public init(includeDetails: Bool = false, includeNotes: Bool = false) {
    self.includeDetails = includeDetails; self.includeNotes = includeNotes
  }
}
public struct ReportRow: Sendable, Identifiable {
  public var id = UUID()
  public var label: String
  public var value: String
}
public struct ReportSection: Sendable, Identifiable {
  public var id = UUID()
  public var title: String
  public var rows: [ReportRow]
}
public struct ReportDocument: Sendable, Identifiable {
  public var id = UUID()
  public var title: String
  public var caption: String
  public var sections: [ReportSection]
  public var points: [SessionPoint]
  public var options: ReportOptions
  public var markdown: String {
    var text =
      "# \(ReportBuilder.markdownText(title))\n\n\(ReportBuilder.markdownText(caption))\n\n"
    for section in sections {
      text +=
        "## \(ReportBuilder.markdownText(section.title))\n\n| Item | Observation |\n| --- | --- |\n"
      for row in section.rows {
        text +=
          "| \(ReportBuilder.markdownText(row.label)) | \(ReportBuilder.markdownText(row.value)) |\n"
      }
      text += "\n"
    }
    if !points.isEmpty {
      text +=
        "## Measured timeline\n\n| Elapsed seconds | Footprint bytes | Swap bytes | Risk | Gap before sample |\n| --- | --- | --- | --- | --- |\n"
      for p in SessionSeries.reduce(points, limit: 240) {
        text +=
          "| \(String(format: "%.1f", p.elapsed)) | \(p.monitored.map { String(format: "%.0f", $0) } ?? "Unavailable") | \(p.swap.map { String(format: "%.0f", $0) } ?? "Unavailable") | \(p.risk.title) | \(p.gap ? "Yes" : "No") |\n"
      }
    }
    return text
  }
  public var html: String {
    var body = "<h1>\(ReportBuilder.htmlText(title))</h1><p>\(ReportBuilder.htmlText(caption))</p>"
    if !points.isEmpty { body += ReportBuilder.svg(points) }
    for section in sections {
      body +=
        "<h2>\(ReportBuilder.htmlText(section.title))</h2><table><thead><tr><th>Item</th><th>Observation</th></tr></thead><tbody>"
      for row in section.rows {
        body +=
          "<tr><th scope=\"row\">\(ReportBuilder.htmlText(row.label))</th><td>\(ReportBuilder.htmlText(row.value))</td></tr>"
      }
      body += "</tbody></table>"
    }
    return """
      <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"><title>\(ReportBuilder.htmlText(title))</title><style>body{font:15px system-ui,sans-serif;line-height:1.55;max-width:960px;margin:40px auto;padding:0 24px;color:#18252b;background:#fafcfb}h1{font-size:30px}h2{margin-top:32px}p{color:#45565c}table{border-collapse:collapse;width:100%;margin:16px 0}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dce4e2;padding:10px;overflow-wrap:anywhere}thead{background:#eaf3f0}svg{width:100%;height:auto;background:#edf4f2;border-radius:12px}svg text{font:12px system-ui,sans-serif;fill:#243c38}@media(prefers-color-scheme:dark){body{background:#14211f;color:#e3eeea}p{color:#b5c9c2}thead,svg{background:#1d332d}th,td{border-color:#365048}svg text{fill:#dfefe8}}</style></head><body>\(body)</body></html>
      """
  }
}

public enum ReportBuilder {
  private static let semantics =
    "MemorySentinel 1.2.0 · Local observations. Footprint sums are attributed accounting, not unique physical RAM. Missing data remains unavailable. Differences do not establish causation."
  private static func row(_ label: String, _ value: String) -> ReportRow {
    ReportRow(label: label, value: value)
  }
  private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
  private static func privacy(_ options: ReportOptions) -> String {
    options.includeDetails || options.includeNotes
      ? "Includes selected private details. Review the complete preview before sharing."
      : "Shared version: personal paths, user-defined names, process identities and private notes omitted."
  }
  private static func name(_ app: String, index: Int, options: ReportOptions) -> String {
    options.includeDetails
      ? app : ["ChatGPT", "Codex", "Codex CLI"].contains(app) ? app : "Application \(index + 1)"
  }
  private static func version(_ value: String?, options: ReportOptions) -> String {
    guard let value else { return "Unavailable" }
    if options.includeDetails { return value }
    return value.range(
      of: #"^[0-9]+(?:\.[0-9]+){0,4}(?:[a-zA-Z][0-9]+)?(?: \([0-9]+\))?$"#,
      options: .regularExpression) == nil
      ? "Unavailable in shared report" : value
  }
  private static func profile(_ value: String, options: ReportOptions) -> String {
    options.includeDetails || ["General", "Coding", "Heavy workload"].contains(value)
      ? value : "Custom profile"
  }
  public static func recording(
    _ recording: FlightRecording, frames: [ExperienceFrame],
    options: ReportOptions = ReportOptions()
  ) -> ReportDocument {
    var sections = [
      ReportSection(
        title: "Capture",
        rows: [
          row("State", recording.status.rawValue.capitalized),
          row("Trigger", date(recording.trigger)),
          row(
            "Available window",
            "\(date(frames.first?.date ?? recording.start)) — \(date(frames.last?.date ?? recording.end))"
          ),
          row("Samples", "\(frames.count) available of \(recording.references.count) referenced"),
          row(
            "Frame availability",
            frames.count < recording.references.count
              ? "Some referenced frames are unavailable; this report contains incomplete evidence."
              : frames.isEmpty
                ? "No retained frames are available." : "All referenced frames are available."
          ),
          row(
            "Event markers",
            "\(recording.events.count) retained; \(recording.omittedEvents) omitted under capture limits"
          ),
          row(
            "Timeline rows",
            "Latest \(min(100, recording.events.count)) retained markers shown below"),
          row(
            "Capture limits",
            options.includeDetails
              ? recording.partialReason ?? "Bounded capture and retention apply."
              : recording.status == .partial
                ? "Capture is incomplete; interruptions or capture limits left missing observations."
                : recording.status == .expired
                  ? "Expired by automatic retention or storage quota."
                  : "Up to 10 minutes of available lead-in and 10 minutes after the latest trigger; bounded capture and retention apply."
          ),
        ])
    ]
    if let first = frames.first, let last = frames.last {
      sections.append(
        ReportSection(
          title: "Before and after",
          rows: [
            row(
              "Attributed footprint",
              "\(Format.bytes(first.monitored)) → \(Format.bytes(last.monitored))"),
            row(
              "System used estimate",
              "\(Format.bytes(first.system.used)) → \(Format.bytes(last.system.used))"),
            row("Swap", "\(Format.bytes(first.system.swap)) → \(Format.bytes(last.system.swap))"),
            row("Pressure", "\(first.system.pressure.rawValue) → \(last.system.pressure.rawValue)"),
            row("Risk", "\(first.risk.title) → \(last.risk.title)"),
            row(
              "Process capture",
              "Up to 96 monitored processes and 12 other consumers per frame. Maximum omitted monitored count: \(frames.map(\.omittedProcesses).max() ?? 0)."
            ),
          ]))
      sections.append(
        ReportSection(
          title: "Applications at the last available sample",
          rows: last.apps.enumerated().prefix(32).map { i, app in
            row(
              name(app.name, index: i, options: options),
              "\(Format.bytes(app.footprint)); version \(version(app.version, options: options)); \(app.members) members"
                + (options.includeDetails ? "; \(app.sourcePath)" : ""))
          }))
    }
    sections.append(
      ReportSection(
        title: "Event timeline",
        rows: recording.events.suffix(100).map {
          row(date($0.date), options.includeDetails ? $0.text : $0.kind.title)
        }))
    var previous: ExperienceFrame?
    let points = frames.map { frame -> SessionPoint in
      let point = SessionPoint(
        date: frame.date, elapsed: max(0, frame.uptime - (frames.first?.uptime ?? frame.uptime)),
        monitored: frame.monitored, swap: frame.system.swap, risk: frame.risk,
        gap: previous != nil && ObservationContinuity.interval(previous, frame) == nil)
      previous = frame; return point
    }
    return ReportDocument(
      title: options.includeDetails ? recording.title : "Memory flight recording",
      caption: semantics + " " + privacy(options) + (recording.demo ? " SIMULATED DATA." : ""),
      sections: sections, points: SessionSeries.reduce(points), options: options)
  }
  public static func session(_ session: WorkSession, options: ReportOptions = ReportOptions())
    -> ReportDocument
  {
    var rows = [
      row("State", session.status.rawValue.capitalized), row("Started", date(session.started)),
      row("Profile", profile(session.profileName, options: options)),
      row("Session time", String(format: "%.1f min", session.elapsedSeconds / 60)),
      row("Complete observation time", String(format: "%.1f min", session.observedSeconds / 60)),
      row("Coverage", String(format: "%.1f%%", session.coverage * 100)),
      row("Time-weighted mean footprint", Format.bytes(session.mean)),
      row("Peak footprint", Format.bytes(session.peak)),
      row(
        "Swap change",
        session.swapChange.map { String(format: "%+.1f MiB", $0 / MiB) } ?? "Unavailable"),
      row("Warning events", "\(session.warningCount)"),
      row(
        "Warnings per observed hour",
        session.warningsPerHour.map { String(format: "%.2f", $0) } ?? "Unavailable"),
      row("Approved Fix sessions", "\(session.fixIDs.count)"),
      row(
        "Context changes",
        "\(session.profileIDs.count) profiles; \(session.configurations.count) configurations"),
    ]
    if options.includeNotes { rows.append(row("Private note", session.note)) }
    let pressure = session.pressureSeconds.keys.sorted().map {
      row($0.capitalized, String(format: "%.1f min", session.pressureSeconds[$0, default: 0] / 60))
    }
    let consumers = session.consumers.sorted { ($0.peak ?? -1) > ($1.peak ?? -1) }.enumerated()
      .prefix(32).map {
        i, app in
        row(
          name(app.name, index: i, options: options),
          "Peak \(Format.bytes(app.peak)); version \(version(app.version, options: options))"
            + (options.includeDetails ? "; \(app.sourcePath ?? "Source unavailable")" : ""))
      }
    return ReportDocument(
      title: options.includeDetails ? session.name : "Memory work session",
      caption: semantics + " " + privacy(options) + (session.demo ? " SIMULATED DATA." : ""),
      sections: [
        ReportSection(title: "Summary", rows: rows),
        ReportSection(title: "Measured pressure time", rows: pressure),
        ReportSection(title: "Largest consumers", rows: consumers),
      ], points: SessionSeries.reduce(session.points), options: options)
  }
  public static func fix(
    _ fix: FixSession, followup: FollowupObservation?, options: ReportOptions = ReportOptions()
  ) -> ReportDocument {
    func outcome(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unavailable" }
    var rows = [
      row("Recorded at", date(fix.updated)),
      row("Problem", fix.plan?.diagnosis.kind.title ?? "Unavailable"),
      row("Approved at", fix.approvedAt.map(date) ?? "Not approved"),
      row("Request recorded at", fix.actionSentAt.map(date) ?? "No request recorded"),
      row("Immediate result sample", fix.result?.after.map { date($0.date) } ?? "Unavailable"),
      row("Approved action", fix.approvedAction?.rawValue ?? "None"),
      row("Immediate outcome", fix.result?.outcome.title ?? fix.phase.rawValue),
      row("Action completed", outcome(fix.result?.actionSucceeded)),
      row("Target resolved", outcome(fix.result?.targetResolved)),
      row("System improved", outcome(fix.result?.systemImproved)),
      row(
        "Target footprint",
        "\(Format.bytes(fix.plan?.before.targetFootprint)) → \(Format.bytes(fix.result?.after?.targetFootprint))"
      ),
      row(
        "System used estimate",
        "\(Format.bytes(fix.plan?.before.system.used)) → \(Format.bytes(fix.result?.after?.system.used))"
      ),
      row(
        "Swap",
        "\(Format.bytes(fix.plan?.before.system.swap)) → \(Format.bytes(fix.result?.after?.system.swap))"
      ),
      row("Application version", version(fix.plan?.target?.source.appVersion, options: options)),
    ]
    if options.includeDetails {
      rows.append(row("Target", fix.plan?.target?.process.path ?? "No process target"))
      rows.append(row("Process identity", fix.plan?.target?.process.identity.id ?? "Unavailable"))
      rows.append(row("Recorded result", fix.result?.message ?? fix.message))
    }
    var sections = [ReportSection(title: "Approved intervention", rows: rows)]
    if let followup {
      sections.append(
        ReportSection(
          title: "Five-minute observation",
          rows: [
            row("State", followup.status.rawValue.capitalized),
            row("Covered time", String(format: "%.1f s", followup.coveredSeconds)),
            row("Samples", "\(followup.samples)"),
            row(
              "Related warning observed",
              followup.warningReturned ? "Yes" : "No in available samples"),
            row(
              "Observation limit",
              options.includeDetails
                ? followup.issue ?? "Observation is still in progress."
                : followup.status == .partial || followup.status == .unavailable
                  ? "Observation was interrupted or had insufficient reliable data."
                  : followup.status == .observing
                    ? "Observation is still in progress."
                    : "Applies only to the available samples; events between samples may be missed."
            ),
          ]))
    }
    return ReportDocument(
      title: "Memory Fix report",
      caption: semantics + " " + privacy(options) + (fix.demo ? " SIMULATED DATA." : ""),
      sections: sections, points: [], options: options)
  }
  static func htmlText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
  static func markdownText(_ text: String) -> String {
    var value = htmlText(text).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
      of: "\r", with: " ")
    for char in ["\\", "|", "[", "]", "(", ")", "*", "_", "`", "#", "!"] {
      value = value.replacingOccurrences(of: char, with: "\\" + char)
    }
    return value
  }
  static func svg(_ input: [SessionPoint]) -> String {
    let points = SessionSeries.reduce(input, limit: 240)
    let maximum = max(GiB, points.compactMap(\.monitored).max() ?? GiB)
    let duration = max(1, points.last?.elapsed ?? 1)
    var path = "", connected = false
    for point in points {
      guard let value = point.monitored, value.isFinite, point.elapsed.isFinite else {
        connected = false; continue
      }
      let x = 45 + max(0, min(1, point.elapsed / duration)) * 805
      let y = 170 - max(0, min(1, value / maximum)) * 135
      path += String(format: "%@%.2f %.2f ", connected && !point.gap ? "L" : "M", x, y)
      connected = true
    }
    return
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 900 215\" role=\"img\" aria-label=\"Measured attributed footprint over session time. Lines break at missing observations.\"><text x=\"45\" y=\"24\">Footprint · scale 0–\(htmlText(Format.bytes(maximum)))</text><path d=\"\(path)\" fill=\"none\" stroke=\"#219f82\" stroke-width=\"2\"/><text x=\"45\" y=\"199\">0 min</text><text x=\"780\" y=\"199\">\(String(format: "%.1f min", duration / 60))</text></svg>"
  }
}
