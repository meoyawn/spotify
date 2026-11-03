// Code-native icon masters. Regenerate with: swift tools/generate_app_icons.swift
// Spotify 1.3.6.1921's installed AppIcon.icns supplied the visual reference only;
// these curves and the debug treatment are drawn here, not extracted pixels.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("macos/Runner/Assets.xcassets")
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func color(_ hex: UInt32) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
    green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func stroke(_ start: NSPoint, _ end: NSPoint, _ control1: NSPoint, _ control2: NSPoint, width: CGFloat) {
  let path = NSBezierPath()
  path.move(to: start)
  path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
  path.lineWidth = width
  path.lineCapStyle = .round
  path.stroke()
}

func drawIcon(debug: Bool) {
  // A 1024-point canvas with macOS's usual transparent inset.
  let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
    xRadius: 184, yRadius: 184)
  NSGradient(starting: color(0x202521), ending: color(0x101311))!.draw(in: tile, angle: 90)
  let disc = NSBezierPath(ovalIn: NSRect(x: 182, y: 182, width: 660, height: 660))
  NSGradient(starting: color(debug ? 0xFFD36A : 0x3DED86),
    ending: color(debug ? 0xF0A72B : 0x19C968))!.draw(in: disc, angle: -70)
  color(0x101811).setStroke()
  stroke(NSPoint(x: 315, y: 609), NSPoint(x: 718, y: 550),
    NSPoint(x: 453, y: 642), NSPoint(x: 586, y: 617), width: 62)
  stroke(NSPoint(x: 333, y: 499), NSPoint(x: 673, y: 450),
    NSPoint(x: 452, y: 528), NSPoint(x: 565, y: 509), width: 49)
  stroke(NSPoint(x: 350, y: 400), NSPoint(x: 632, y: 361),
    NSPoint(x: 450, y: 424), NSPoint(x: 547, y: 408), width: 38)
  if debug {
    // A contrasting code badge also distinguishes debug without relying on hue.
    let badge = NSBezierPath(roundedRect: NSRect(x: 626, y: 174, width: 238, height: 174),
      xRadius: 55, yRadius: 55)
    color(0x141A16).setFill()
    badge.fill()
    color(0xFFD36A).setStroke()
    for (tip, edge) in [(CGFloat(677), CGFloat(713)), (CGFloat(813), CGFloat(777))] {
      let bracket = NSBezierPath()
      bracket.move(to: NSPoint(x: edge, y: 300))
      bracket.line(to: NSPoint(x: tip, y: 261))
      bracket.line(to: NSPoint(x: edge, y: 222))
      bracket.lineWidth = 16
      bracket.lineCapStyle = .round
      bracket.lineJoinStyle = .round
      bracket.stroke()
    }
  }
}

for debug in [false, true] {
  let name = debug ? "DebugAppIcon" : "AppIcon"
  let directory = assets.appendingPathComponent("\(name).appiconset")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for size in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(debug: debug)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: directory.appendingPathComponent("app_icon_\(size).png"))
  }
  let images: [[String: String]] = [16, 32, 128, 256, 512].flatMap { size in
    [1, 2].map { scale in
      ["size": "\(size)x\(size)", "idiom": "mac", "scale": "\(scale)x",
        "filename": "app_icon_\(size * scale).png"]
    }
  }
  let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
  try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(
    to: directory.appendingPathComponent("Contents.json"))
  print("Generated \(name): \(directory.path)")
}
