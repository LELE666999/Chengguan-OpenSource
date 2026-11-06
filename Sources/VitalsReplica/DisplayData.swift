import AppKit
import CoreGraphics
import DisplayBridge
import Foundation

struct DisplayModeChoice: Identifiable, Codable, Equatable, Sendable {
  var id: Int32
  var width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
  var refresh: Double
  var hiDPI: Bool { pixelWidth > width || pixelHeight > height }
  var dimensions: String { "\(width) × \(height)" }
  var rateLabel: String {
    guard refresh.isFinite, refresh > 0 else { return "可变 / 系统" }
    return String(format: abs(refresh.rounded() - refresh) < 0.005 ? "%.0f Hz" : "%.2f Hz", refresh)
  }
  var title: String { dimensions + (hiDPI ? " · HiDPI" : "") + " · " + rateLabel }
  var signature: String { "\(width):\(height):\(pixelWidth):\(pixelHeight):\(Int((refresh * 100).rounded()))" }
  init(_ mode: CGDisplayMode) {
    id = mode.ioDisplayModeID; width = mode.width; height = mode.height
    pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight; refresh = mode.refreshRate
  }
  init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refresh: Double) {
    self.id = id; self.width = width; self.height = height; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refresh = refresh
  }
}
struct DisplayDevice: Identifiable, Codable, Equatable, Sendable {
  var id: String // System UUID, never a transient display-list index.
  var displayID: UInt32, name: String
  var builtin: Bool, main: Bool, virtual: Bool
  var width: Int, height: Int
  var millimetersWidth: Double, millimetersHeight: Double
  var rotation: Double
  var originX: Double, originY: Double
  var mirror: UInt32
  var vendor: UInt32, model: UInt32, serial: UInt32
  var manufactured: String?
  var hdrPotential: Bool, edr: Double
  var current: DisplayModeChoice?
  var modes: [DisplayModeChoice]
  var output: String { width > 0 && height > 0 ? "\(width) × \(height)" : "—" }
  var inches: Double? {
    let diagonal = hypot(millimetersWidth, millimetersHeight) / 25.4
    return diagonal > 1 ? diagonal : nil
  }
  var resolutionName: String {
    if width >= 7680 { return "8K" }; if width >= 5120 { return "5K" }; if width >= 3840 { return "4K" }
    return width > 0 ? "\(width)" : "显示器"
  }
  var shortName: String { builtin ? "内建显示屏" : name }
  var connectionLabel: String { builtin ? "内建" : virtual ? "虚拟" : "外接" }
}
struct DisplayVCPValue: Codable, Equatable, Sendable {
  var value: UInt16, maximum: UInt16
  var percent: Double? { maximum > 0 && value <= maximum ? Double(value) / Double(maximum) * 100 : nil }
}
struct DisplayHardwareState: Equatable, Sendable {
  var nativeBrightness: Double?
  var values: [UInt8: DisplayVCPValue] = [:]
  var checked = false
  var brightness: Double? { nativeBrightness ?? values[0x10]?.percent }
  var volume: Double? { values[0x62]?.percent }
}
enum DisplayRules {
  static func switchValue(_ text: String) -> Bool? {
    switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "on", "true", "yes", "1", "1.0": return true
    case "off", "false", "no", "0", "0.0": return false
    default: return nil
    }
  }
  /// One stop per desktop size; preserve the active timing and HiDPI family.
  static func scalingModes(_ available: [DisplayModeChoice], current: DisplayModeChoice?) -> [DisplayModeChoice] {
    guard let current else { return [] }
    var seen = Set<String>()
    let candidates = [current] + available.filter { $0.hiDPI == current.hiDPI }.sorted {
      let a = abs($0.refresh - current.refresh), b = abs($1.refresh - current.refresh)
      return a == b ? $0.id < $1.id : a < b
    }
    return candidates.filter { seen.insert($0.dimensions).inserted }.sorted {
      $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width
    }
  }
  static func scalingIndex(_ value: Double, count: Int) -> Int? {
    guard value.isFinite, count > 0 else { return nil }
    return min(count - 1, max(0, Int(min(Double(count - 1), max(0, value)).rounded())))
  }
  static func uniqueModes(_ modes: [DisplayModeChoice], current: DisplayModeChoice?) -> [DisplayModeChoice] {
    var seen = Set<String>()
    var result = [DisplayModeChoice]()
    // Prefer the active mode's ID where identical timing records coexist.
    for mode in ([current].compactMap { $0 } + modes) where mode.width >= 640 && mode.height >= 480 {
      if seen.insert(mode.signature).inserted { result.append(mode) }
    }
    return result.sorted {
      if $0.width != $1.width { return $0.width < $1.width }
      if $0.height != $1.height { return $0.height < $1.height }
      if $0.hiDPI != $1.hiDPI { return $0.hiDPI }
      return $0.refresh < $1.refresh
    }
  }
  static func restoredMode(_ original: DisplayModeChoice, available: [DisplayModeChoice]) -> DisplayModeChoice? {
    // IDs may be reused after reconnect, so match the complete mode signature.
    available.first { $0.signature == original.signature }
  }
  static func rawValue(percent: Double, maximum: UInt16) -> UInt16? {
    guard percent.isFinite, maximum > 0 else { return nil }
    return UInt16((min(100, max(0, percent)) * Double(maximum) / 100).rounded())
  }
}
/// A poll that began before a slider write must never replace its optimistic value.
struct DisplayWriteLedger {
  private(set) var pending: [String: Int] = [:]
  private(set) var sent: [String: Int] = [:]
  private var next = 0
  mutating func begin(_ key: String) -> Int {
    next += 1; pending[key] = next; sent.removeValue(forKey: key); return next
  }
  mutating func didSend(_ key: String, revision: Int) -> Bool {
    guard pending[key] == revision else { return false }
    sent[key] = revision; return true
  }
  mutating func acceptSample(_ key: String, snapshot: [String: Int]) -> Bool {
    guard let revision = pending[key] else { return true }
    guard snapshot[key] == revision else { return false }
    pending.removeValue(forKey: key); sent.removeValue(forKey: key); return true
  }
  mutating func fail(_ key: String, revision: Int) -> Bool {
    guard pending[key] == revision else { return false }
    pending.removeValue(forKey: key); sent.removeValue(forKey: key); return true
  }
}
@MainActor enum DisplayReader {
  static func read() -> [DisplayDevice] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [UInt32](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).compactMap { display in
      guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
      let uuid = CFUUIDCreateString(nil, cfUUID) as String
      let info = cd_copy_display_info(display) as? [String: Any] ?? [:]
      let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
      let names = info["DisplayProductName"] as? [String: String] ?? [:]
      let name = screen?.localizedName ?? names["zh_CN"] ?? names["en_US"] ?? names.values.sorted().first ?? "显示器 \(display)"
      let current = CGDisplayCopyDisplayMode(display).map(DisplayModeChoice.init)
      let allModes = CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
      let mm = CGDisplayScreenSize(display), bounds = CGDisplayBounds(display)
      let year = (info["DisplayYearManufacture"] as? NSNumber)?.intValue
      let week = (info["DisplayWeekManufacture"] as? NSNumber)?.intValue
      return DisplayDevice(id: uuid, displayID: display, name: name, builtin: CGDisplayIsBuiltin(display) != 0, main: CGDisplayIsMain(display) != 0,
        virtual: (info["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue ?? false,
        width: (info["kCGDisplayPixelWidth"] as? NSNumber)?.intValue ?? current?.pixelWidth ?? 0,
        height: (info["kCGDisplayPixelHeight"] as? NSNumber)?.intValue ?? current?.pixelHeight ?? 0,
        millimetersWidth: mm.width, millimetersHeight: mm.height, rotation: CGDisplayRotation(display), originX: bounds.minX, originY: bounds.minY,
        mirror: CGDisplayMirrorsDisplay(display), vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display), serial: CGDisplaySerialNumber(display),
        manufactured: year.map { "\($0) 年" + (week.map { " · 第 \($0) 周" } ?? "") },
        hdrPotential: (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1,
        edr: Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
        current: current, modes: DisplayRules.uniqueModes(allModes.map(DisplayModeChoice.init), current: current))
    }.sorted { $0.main != $1.main ? $0.main : $0.displayID < $1.displayID }
  }
  static func matching(_ device: DisplayDevice) -> DisplayDevice? { read().first { $0.id == device.id } }
  static func cgMode(_ choice: DisplayModeChoice, display: UInt32) -> CGDisplayMode? {
    let modes = CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
    return modes.first { DisplayModeChoice($0).signature == choice.signature }
  }
}
