import AppKit
import SentinelCore
import SwiftUI
import UniformTypeIdentifiers

enum ReportRequest: Identifiable, Sendable {
  case recording(FlightRecording), session(WorkSession), fix(FixSession)
  var id: String {
    switch self {
    case .recording(let value): "recording-\(value.id)"
    case .session(let value): "session-\(value.id)"
    case .fix(let value): "fix-\(value.id)"
    }
  }
}
private struct ReportFile: FileDocument {
  static var markdownType: UTType { UTType(filenameExtension: "md") ?? .plainText }
  static var readableContentTypes: [UTType] { [.html, markdownType] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    guard let value = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = value
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let wrapper = FileWrapper(regularFileWithContents: data)
    wrapper.fileAttributes[FileAttributeKey.posixPermissions.rawValue] = 0o600
    return wrapper
  }
}
struct ReportPreview: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var request: ReportRequest
  @State private var options = ReportOptions()
  @State private var document: ReportDocument?
  @State private var error: String?
  @State private var refresh = 0
  @State private var format = "html"
  @State private var exporting = false
  @State private var choosingDestination = false
  @State private var exportFile: ReportFile?
  @State private var exportType: UTType = .html
  @State private var exportName = "MemorySentinel-report.html"
  @State private var cursor: Double?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Report preview").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }
      }
      HStack {
        Toggle("Include private details", isOn: $options.includeDetails)
        Toggle("Include private notes", isOn: $options.includeNotes)
        Spacer(); Button("Refresh") { refresh += 1 }
      }.font(.caption)
      Text(
        options.includeDetails || options.includeNotes
          ? "Selected private data is included. Review the full preview before sharing."
          : "Personal paths, user-defined names, process identities and notes are omitted by default."
      )
      .font(.caption).foregroundStyle(
        options.includeDetails || options.includeNotes ? Color.orange : Color.secondary)
      if let document {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text(document.title).font(.title2)
            Text(document.caption).font(.caption).foregroundStyle(.secondary)
            if !document.points.isEmpty {
              ObservedMemoryChart(
                title: "Measured timeline",
                series: [
                  MemorySeries(id: "Attributed footprint", points: reportPoints(document.points))
                ], duration: document.points.last?.elapsed ?? 0, selection: $cursor)
            }
            ForEach(document.sections) { section in
              VStack(alignment: .leading, spacing: 9) {
                Text(section.title).font(.headline)
                ForEach(section.rows) { row in
                  HStack(alignment: .top) {
                    Text(row.label).frame(width: 190, alignment: .leading).foregroundStyle(
                      .secondary);
                    Text(row.value).frame(maxWidth: .infinity, alignment: .leading).textSelection(
                      .enabled)
                  }.font(.caption)
                }
              }
              Divider()
            }
          }.padding(8)
        }
        HStack {
          Picker("Format", selection: $format) {
            Text("Standalone HTML").tag("html"); Text("Markdown").tag("md")
          }.frame(width: 270)
          Spacer()
          Button(exporting ? "Saving…" : "Save report…") { save(document) }.buttonStyle(
            .borderedProminent
          ).disabled(exporting || choosingDestination)
        }
      } else {
        ProgressView("Preparing a local report…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
    }.padding(26).frame(width: 850, height: 700)
      .fileExporter(
        isPresented: $choosingDestination, document: exportFile,
        contentTypes: [exportType], defaultFilename: exportName,
        onCompletion: { result in
          exportFile = nil
          switch result {
          case .success(let url):
            do {
              try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
              error = nil
            } catch { self.error = error.localizedDescription }
          case .failure(let issue): error = issue.localizedDescription
          }
        }, onCancellation: { exportFile = nil }
      )
      .task(id: "\(options.includeDetails)-\(options.includeNotes)-\(refresh)") { await load() }
      .onChange(of: model.demo) { _, _ in dismiss() }
  }
  private func reportPoints(_ input: [SessionPoint]) -> [MemoryDatum] {
    var segment = 0
    return input.enumerated().map { i, point in
      if point.gap || point.monitored == nil { segment += 1 }
      return MemoryDatum(id: i, elapsed: point.elapsed, value: point.monitored, segment: segment)
    }
  }
  @MainActor private func load() async {
    let selectedOptions = options, tracker = model.analytics
    let request = request, followups = model.experience.followups
    document = nil; error = nil
    do {
      let value: ReportDocument
      switch request {
      case .recording(let recording):
        let frames = try await tracker.frames(for: recording)
        value = await Task.detached {
          ReportBuilder.recording(recording, frames: frames, options: selectedOptions)
        }.value
      case .session(let session):
        let current = try await tracker.sessionDetails(id: session.id) ?? session
        value = await Task.detached { ReportBuilder.session(current, options: selectedOptions) }
          .value
      case .fix(let fix):
        value = await Task.detached {
          ReportBuilder.fix(
            fix, followup: followups.first { $0.id == fix.id }, options: selectedOptions)
        }.value
      }
      if !Task.isCancelled { document = value }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
  private func save(_ document: ReportDocument) {
    let isHTML = format == "html", selectedFormat = format
    exporting = true
    Task { @MainActor in
      let data = await Task.detached { Data((isHTML ? document.html : document.markdown).utf8) }
        .value
      exportFile = ReportFile(data: data)
      exportName = "MemorySentinel-report.\(selectedFormat)"
      exportType = isHTML ? .html : ReportFile.markdownType
      exporting = false; choosingDestination = true
    }
  }
}
