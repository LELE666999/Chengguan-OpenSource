import AppKit

guard CommandLine.arguments.count == 2 else {
  fatalError("Usage: swift scripts/DrawDMGBackground.swift OUTPUT.png")
}

let size = NSSize(width: 640, height: 380)
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 760,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  (text as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: size + 12), withAttributes: [
    .font: NSFont.systemFont(ofSize: size, weight: weight),
    .foregroundColor: color,
    .paragraphStyle: paragraph
  ])
}

centered("澄观", y: 291, size: 28, weight: .semibold, color: NSColor(calibratedWhite: 0.12, alpha: 1))
centered("拖动澄观到「应用程序」即可安装", y: 258, size: 15, weight: .regular,
         color: NSColor(calibratedWhite: 0.45, alpha: 1))

let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 296, y: 170))
arrow.line(to: NSPoint(x: 344, y: 170))
arrow.move(to: NSPoint(x: 335, y: 179))
arrow.line(to: NSPoint(x: 344, y: 170))
arrow.line(to: NSPoint(x: 335, y: 161))
NSColor(calibratedWhite: 0.68, alpha: 1).setStroke()
arrow.stroke()

centered("macOS 15 及以上 · Apple 芯片", y: 35, size: 12, weight: .regular,
         color: NSColor(calibratedWhite: 0.55, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
  to: URL(fileURLWithPath: CommandLine.arguments[1])
)
