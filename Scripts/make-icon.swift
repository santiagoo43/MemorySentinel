import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
  // Use explicit pixel dimensions; lockFocus() otherwise doubles pixels on Retina displays.
  let representation = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)!
  let scale = CGFloat(size) / 1024
  // Match the 824/1024 optical footprint of macOS app tiles. Keep the whole
  // design centered and proportional, leaving room for the app switcher selection.
  let artworkScale: CGFloat = 824 / 944
  let translation = 512 * (1 - artworkScale)
  let transform = NSAffineTransform()
  transform.transformStruct = NSAffineTransformStruct(
    m11: scale * artworkScale, m12: 0, m21: 0, m22: scale * artworkScale,
    tX: scale * translation, tY: scale * translation)
  transform.concat()
  let rect = NSRect(x: 40, y: 40, width: 944, height: 944)
  let background = NSBezierPath(roundedRect: rect, xRadius: 214, yRadius: 214)
  NSGradient(
    starting: NSColor(red: 0.055, green: 0.12, blue: 0.16, alpha: 1),
    ending: NSColor(red: 0.02, green: 0.045, blue: 0.08, alpha: 1))!.draw(in: background, angle: 60)
  let shield = NSBezierPath()
  shield.move(to: NSPoint(x: 512, y: 837))
  shield.line(to: NSPoint(x: 764, y: 742))
  shield.line(to: NSPoint(x: 743, y: 439))
  shield.curve(
    to: NSPoint(x: 512, y: 207), controlPoint1: NSPoint(x: 725, y: 325),
    controlPoint2: NSPoint(x: 604, y: 239))
  shield.curve(
    to: NSPoint(x: 281, y: 439), controlPoint1: NSPoint(x: 420, y: 239),
    controlPoint2: NSPoint(x: 299, y: 325))
  shield.line(to: NSPoint(x: 260, y: 742))
  shield.close()
  NSColor(red: 0.25, green: 0.90, blue: 0.74, alpha: 0.12).setFill()
  shield.fill()
  NSColor(red: 0.32, green: 0.95, blue: 0.79, alpha: 1).setStroke()
  shield.lineWidth = 28
  shield.stroke()
  let pulse = NSBezierPath()
  pulse.move(to: NSPoint(x: 348, y: 508))
  pulse.line(to: NSPoint(x: 424, y: 508))
  pulse.line(to: NSPoint(x: 470, y: 634))
  pulse.line(to: NSPoint(x: 542, y: 385))
  pulse.line(to: NSPoint(x: 597, y: 508))
  pulse.line(to: NSPoint(x: 679, y: 508))
  pulse.lineWidth = 28
  pulse.lineCapStyle = .round
  pulse.lineJoinStyle = .round
  pulse.stroke()
  NSGraphicsContext.restoreGraphicsState()
  let data = representation.representation(using: .png, properties: [:])!
  let names: [String]
  switch size {
  case 16: names = ["icon_16x16.png"]
  case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
  case 64: names = ["icon_32x32@2x.png"]
  case 128: names = ["icon_128x128.png"]
  case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
  case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
  default: names = ["icon_512x512@2x.png"]
  }
  for name in names {
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
  }
}
