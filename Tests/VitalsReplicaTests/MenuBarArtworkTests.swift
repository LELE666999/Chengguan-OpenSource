import AppKit
import XCTest

@testable import VitalsReplica

final class MenuBarArtworkTests: XCTestCase {
  @MainActor func testMetricPixelsStayWhiteAtAllBackingScalesAndAppearances() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        let image = MenuBarArtwork.image(text: "25%  38.20 GB", font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                                         symbol: "waveform.path.ecg", iconColor: .systemBlue)
        XCTAssertFalse(image.isTemplate)
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertEqual(bitmaps.count, 3)
        for bitmap in bitmaps {
          let scale = bitmap.pixelsHigh / 22
          var opaqueTextPixels = 0
          var blueIconPixels = 0
          for x in 0..<(16 * scale) {
            for y in 0..<bitmap.pixelsHigh {
              guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
              if color.blueComponent > color.redComponent + 0.2 { blueIconPixels += 1 }
            }
          }
          XCTAssertGreaterThan(blueIconPixels, 5 * scale)
          for x in (22 * scale)..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
              guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
              opaqueTextPixels += 1
              XCTAssertGreaterThan(color.redComponent, 0.98)
              XCTAssertGreaterThan(color.greenComponent, 0.98)
              XCTAssertGreaterThan(color.blueComponent, 0.98)
            }
          }
          XCTAssertGreaterThan(opaqueTextPixels, 80 * scale)
        }
        XCTAssertEqual(image.accessibilityDescription, "澄观 · 25%  38.20 GB")
      }
    }
  }

  @MainActor func testIconOnlyAndFontPreferencesKeepTheirWidths() {
    let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    let large = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    let icon = MenuBarArtwork.image(text: "", font: small, symbol: "mic.fill", iconColor: .systemOrange)
    let compact = MenuBarArtwork.image(text: "100%  48.00 GB", font: small, symbol: "mic.fill", iconColor: .systemOrange)
    let roomy = MenuBarArtwork.image(text: "100%  48.00 GB", font: large, symbol: "mic.fill", iconColor: .systemOrange)
    XCTAssertEqual(icon.size.width, 16)
    XCTAssertGreaterThan(compact.size.width, icon.size.width)
    XCTAssertGreaterThan(roomy.size.width, compact.size.width)
    XCTAssertEqual(icon.accessibilityDescription, "澄观")
  }
}
