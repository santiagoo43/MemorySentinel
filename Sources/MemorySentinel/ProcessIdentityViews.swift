import AppKit
import SentinelCore
import SwiftUI

@MainActor final class ApplicationIconCache {
  static let shared = ApplicationIconCache()
  private let images = NSCache<NSString, NSImage>()
  private init() { images.countLimit = 128; images.totalCostLimit = 4 * 1024 * 1024 }
  func image(_ path: String) -> NSImage? {
    if let cached = images.object(forKey: path as NSString) { return cached }
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    NSGraphicsContext.restoreGraphicsState()
    let icon = NSImage(size: NSSize(width: 64, height: 64)); icon.addRepresentation(bitmap)
    images.setObject(icon, forKey: path as NSString, cost: 64 * 64 * 4)
    return icon
  }
  func clear() { images.removeAllObjects() }
}

struct ProcessIdentityCell: View {
  @EnvironmentObject var model: AppModel
  var process: ProcessRecord
  private var secondaryLabel: String {
    var result = (model.control.taskName(process).map { $0 + " · " } ?? "") + process.name
    if let direct = process.applicationMetadata,
      direct.bundlePath != process.origin?.displayedApplication?.bundlePath
    {
      result += " · bundle: \(direct.name)"
    }
    return result
  }
  var body: some View {
    HStack(spacing: 9) {
      if let path = process.origin?.displayedApplication?.bundlePath,
        let icon = ApplicationIconCache.shared.image(path)
      {
        Image(nsImage: icon).resizable().frame(width: 25, height: 25).accessibilityHidden(true)
      } else {
        Image(systemName: "questionmark.app").frame(width: 25).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(process.origin?.displayedApplication?.name ?? "Unknown application").font(
          .system(size: 11, weight: .medium)
        ).lineLimit(1)
        Text(secondaryLabel)
          .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        Text(process.origin?.confidence.title ?? "Origin unavailable").font(.system(size: 9))
          .foregroundStyle(process.origin?.isCurrent == true ? Color.secondary : .orange).lineLimit(
            1)
        Text(model.automationStatus(process)).font(.system(size: 9)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }.padding(.vertical, 4).help(process.origin?.evidence ?? "No verified application origin.")
  }
}

struct ProcessApplicationGroup: Identifiable {
  var id: String
  var name: String
  var processes: [ProcessRecord]
  static func groups(_ processes: [ProcessRecord]) -> [Self] {
    Dictionary(grouping: processes) {
      "\($0.uid):" + ($0.origin?.displayedApplication?.bundlePath ?? "unknown")
    }
    .map { key, values in
      Self(
        id: key, name: values.first?.origin?.displayedApplication?.name ?? "Unknown application",
        processes: values)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
