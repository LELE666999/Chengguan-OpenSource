import AppKit

// Two flat colors and a filled signal mark, independent of the reference app.
let path = CommandLine.arguments[1]
let pixels = 1024
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
// Saturated cobalt and one solid white rhythm mark. No baked-in shadow.
NSColor(srgbRed: 0.025, green: 0.31, blue: 1, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
             xRadius: 202, yRadius: 202).fill()
NSColor.white.setFill()
for (x, height) in [(290.0, 220.0), (456.0, 420.0), (622.0, 310.0)] {
  NSBezierPath(roundedRect: NSRect(x: x, y: (1024-height)/2, width: 112, height: height),
               xRadius: 56, yRadius: 56).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
