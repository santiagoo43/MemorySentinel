import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum SaveDestination {
  static func choose(name: String, type: UTType, window origin: NSWindow? = nil) async throws
    -> URL?
  {
    guard
      let window = origin ?? NSApp.keyWindow ?? NSApp.mainWindow
        ?? NSApp.orderedWindows.first(where: { $0.isVisible && !($0 is NSSavePanel) })
    else {
      throw NSError(
        domain: "MemorySentinel.Export", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Open an application window before exporting."])
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    // Keep the export attached to its originating window, including report-preview sheets.
    let response = await panel.beginSheetModal(for: window)
    panel.orderOut(nil)
    window.makeKeyAndOrderFront(nil)
    return response == .OK ? panel.url : nil
  }
}

struct SaveWindowProbe: NSViewRepresentable {
  let report: @MainActor (NSWindow?) -> Void
  func makeNSView(context: Context) -> Probe {
    let view = Probe(); view.report = report; return view
  }
  func updateNSView(_ view: Probe, context: Context) { view.report = report }
  final class Probe: NSView {
    var report: (@MainActor (NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      Task { @MainActor [weak self, weak window = window] in self?.report?(window) }
    }
  }
}
