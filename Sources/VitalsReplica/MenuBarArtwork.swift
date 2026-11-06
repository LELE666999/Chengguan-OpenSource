import AppKit

/// NSStatusBarButton may override attributed-title colors to match the menu bar.
/// A non-template bitmap keeps metric text white in every menu-bar appearance.
enum MenuBarArtwork {
  @MainActor static func image(text: String, font: NSFont, symbol: String, iconColor: NSColor) -> NSImage {
    let title = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    let textSize = title.size()
    let iconWidth: CGFloat = 16
    let gap: CGFloat = text.isEmpty ? 0 : 6
    let size = NSSize(width: ceil(iconWidth + gap + textSize.width), height: 22)
    let image = NSImage(size: size)
    let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(paletteColors: [iconColor]))
    icon?.isTemplate = false

    // Explicit backing scales keep small glyphs sharp on Retina and external screens.
    for scale in [1, 2, 3] {
      guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
      bitmap.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
      context.cgContext.clear(NSRect(origin: .zero, size: size))
      if let icon, icon.size.width > 0, icon.size.height > 0 {
        let ratio = min(iconWidth / icon.size.width, iconWidth / icon.size.height)
        let iconSize = NSSize(width: icon.size.width * ratio, height: icon.size.height * ratio)
        icon.draw(in: NSRect(x: (iconWidth - iconSize.width) / 2, y: (size.height - iconSize.height) / 2,
                            width: iconSize.width, height: iconSize.height))
      }
      title.draw(at: NSPoint(x: iconWidth + gap, y: floor((size.height - textSize.height) / 2)))
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(bitmap)
    }
    image.isTemplate = false
    image.accessibilityDescription = text.isEmpty ? "澄观" : "澄观 · " + text
    return image
  }
}
