// Renders AppIcon.icns. Usage: swift icon.swift
import AppKit

func draw(_ ctx: CGContext, size: CGFloat) {
  let s = size / 1024
  ctx.scaleBy(x: s, y: s)

  // Apple's macOS icon grid: 824pt body inset 100pt, ~185pt corner radius.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
  ctx.addPath(shape)
  ctx.setFillColor(NSColor.black.cgColor)
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  let colors = [
    NSColor(red: 0.47, green: 0.36, blue: 1.00, alpha: 1).cgColor,
    NSColor(red: 0.16, green: 0.20, blue: 0.62, alpha: 1).cgColor,
  ] as CFArray
  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
  ctx.restoreGState()

  // Glyph drawn in a 100-unit box mapped onto the body.
  ctx.saveGState()
  ctx.translateBy(x: body.minX, y: body.minY)
  ctx.scaleBy(x: body.width / 100, y: body.height / 100)
  ctx.setStrokeColor(NSColor.white.cgColor)
  ctx.setLineWidth(5.5)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)

  let ring = { (x: CGFloat, y: CGFloat) in
    ctx.strokeEllipse(in: CGRect(x: x - 7, y: y - 7, width: 14, height: 14))
  }
  ring(32, 74)
  ring(32, 26)
  ring(68, 26)

  ctx.move(to: CGPoint(x: 32, y: 33))
  ctx.addLine(to: CGPoint(x: 32, y: 67))
  ctx.move(to: CGPoint(x: 68, y: 33))
  ctx.addLine(to: CGPoint(x: 68, y: 60))
  ctx.addQuadCurve(to: CGPoint(x: 58, y: 70), control: CGPoint(x: 68, y: 70))
  ctx.addLine(to: CGPoint(x: 46, y: 70))
  ctx.move(to: CGPoint(x: 53, y: 77))
  ctx.addLine(to: CGPoint(x: 46, y: 70))
  ctx.addLine(to: CGPoint(x: 53, y: 63))
  ctx.strokePath()

  // Green "ready" status dot.
  ctx.setFillColor(NSColor(red: 0.20, green: 0.84, blue: 0.45, alpha: 1).cgColor)
  ctx.fillEllipse(in: CGRect(x: 71, y: 71, width: 14, height: 14))
  ctx.setLineWidth(2)
  ctx.setStrokeColor(NSColor.white.cgColor)
  ctx.strokeEllipse(in: CGRect(x: 71, y: 71, width: 14, height: 14))
  ctx.restoreGState()
}

func png(size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw(NSGraphicsContext.current!.cgContext, size: CGFloat(size))
  NSGraphicsContext.current = nil
  return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

[16, 32, 128, 256, 512].forEach { base in
  try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: URL(fileURLWithPath: "build/icon-preview.png"))
