import AppKit
import Foundation
import IOKit

/// One source of truth for the actual status item and its settings preview.
enum MenuBarMetric: String, CaseIterable, Identifiable {
  case gpu, battery, download, upload, disk, brightness, nasCPU, nasMemory, nasFree
  var id: String { rawValue }
  var title: String {
    switch self {
    case .gpu: "GPU"
    case .battery: "电池"
    case .download: "下载速度"
    case .upload: "上传速度"
    case .disk: "磁盘可用空间"
    case .brightness: "屏幕亮度"
    case .nasCPU: "NAS CPU"
    case .nasMemory: "NAS 内存"
    case .nasFree: "NAS 可用空间"
    }
  }
  var symbol: String {
    switch self {
    case .gpu: "square.3.layers.3d"
    case .battery: "battery.75percent"
    case .download: "arrow.down"
    case .upload: "arrow.up"
    case .disk: "internaldrive"
    case .brightness: "sun.max"
    case .nasCPU, .nasMemory, .nasFree: "server.rack"
    }
  }
}

enum MenuBarSelection {
  static func parse(_ raw: String) -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
  }
  static func encode(_ values: [String]) -> String {
    String(data: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
  }
  static func toggle(_ id: String, in raw: String) -> String {
    var values = parse(raw)
    if values.contains(id) { values.removeAll { $0 == id } } else { values.append(id) }
    return encode(values)
  }
  static func quotaID(provider: ProviderUsage, limit: UsageLimit, window: UsageWindow, index: Int) -> String {
    let parts = [provider.id, limit.name, String(window.minutes), window.label ?? "", String(index)]
    return Data(parts.joined(separator: "\u{1f}").utf8).base64EncodedString()
  }
  static func quotaName(_ window: UsageWindow) -> String {
    if let label = window.label { return label }
    if window.minutes >= 10080 { return "每周" }
    if window.minutes >= 1440 { return "每日" }
    return "\(max(1, window.minutes / 60))小时"
  }
}

/// IOKit may not expose brightness for a particular display; never invent a value.
@MainActor enum MenuBrightness {
  private static var lastRead = Date.distantPast
  private static var cached: Double?
  static func read() -> Double? {
    guard Date().timeIntervalSince(lastRead) >= 10 else { return cached }
    lastRead = Date(); cached = nil
    var iterator: io_iterator_t = 0
    guard let matching = IOServiceMatching("IODisplayConnect"),
          IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      var value: Float = 0
      if IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &value) == KERN_SUCCESS,
         value.isFinite, value >= 0, value <= 1 {
        cached = Double(value) * 100; break
      }
    }
    return cached
  }
}

struct MenuBarPresentation {
  var parts: [String]
  var symbol: String
  var color: NSColor
  var font: NSFont
  var accessibility: [String]
  var text: String { parts.joined(separator: "  ") }
  @MainActor var image: NSImage { MenuBarArtwork.image(text: text, font: font, symbol: symbol, iconColor: color) }
  var renderKey: MenuBarRenderKey {
    let rgb = color.usingColorSpace(.deviceRGB) ?? .white
    return MenuBarRenderKey(text: text, symbol: symbol, font: font.fontName, size: font.pointSize,
      red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
  }

  @MainActor static func make(snapshot s: MonitorSnapshot, providers: [ProviderUsage], nas: NASSnapshot?,
                              nasCurrent: Bool, activities: [DeviceActivity], defaults: UserDefaults = .standard) -> Self {
    let privacy = activities.filter { $0.active && ["microphone", "camera"].contains($0.id) }
    let symbol = privacy.contains { $0.id == "camera" } ? "camera.fill" : privacy.isEmpty ? "waveform.path.ecg" : "mic.fill"
    var parts: [String] = []
    if defaults.object(forKey: "showMenuCPU") as? Bool ?? true { parts.append(String(format: "%.0f%%", s.cpu)) }
    if defaults.object(forKey: "showMenuMemory") as? Bool ?? true { parts.append(Format.memory(s.usedMemory)) }
    let extra = MenuBarSelection.parse(defaults.string(forKey: "menuExtraMetrics") ?? "[]")
    for id in extra {
      guard let metric = MenuBarMetric(rawValue: id) else { continue }
      func percent(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }
      switch metric {
      case .gpu: parts.append("GPU " + percent(s.gpu))
      case .battery: parts.append("电池 " + percent(s.battery.percent))
      case .download: parts.append("↓ " + Format.networkRate(s.download))
      case .upload: parts.append("↑ " + Format.networkRate(s.upload))
      case .disk: parts.append("磁盘 " + (s.primaryVolume.map { Format.bytes($0.free) } ?? "—"))
      case .brightness: parts.append("亮度 " + percent(MenuBrightness.read()))
      case .nasCPU: parts.append("NAS CPU " + percent(nasCurrent ? nas?.cpu : nil))
      case .nasMemory: parts.append("NAS 内存 " + percent(nasCurrent ? nas?.memory : nil))
      case .nasFree: parts.append("NAS 可用 " + ((nasCurrent ? nas?.free.map { Format.bytes($0) } : nil) ?? "—"))
      }
    }
    let quotaIDs = MenuBarSelection.parse(defaults.string(forKey: "menuQuotaSelection") ?? "[]")
    for selected in quotaIDs {
      var match: String?
      for provider in providers {
        for limit in provider.limits {
          for (index, window) in limit.windows.enumerated() where MenuBarSelection.quotaID(provider: provider, limit: limit, window: window, index: index) == selected {
            let value = provider.stale() || !defaults.bool(forKey: "aiUsageEnabled") ? "—" : String(format: "%.0f%%", 100 - min(100, max(0, window.used)))
            match = "\(provider.id) \(MenuBarSelection.quotaName(window)) \(value)"
          }
        }
      }
      parts.append(match ?? "AI —")
    }
    let size: CGFloat = defaults.string(forKey: "menuSize") == "紧凑" ? 10 : defaults.string(forKey: "menuSize") == "大" ? 13 : 11
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: defaults.bool(forKey: "menuBold") ? .bold : .medium)
    let color: NSColor = !privacy.isEmpty ? (privacy.contains { $0.id == "camera" } ? .systemGreen : .systemOrange)
      : defaults.bool(forKey: "highLoadRed") && s.cpu > 85 ? .systemRed : defaults.bool(forKey: "menuColor") ? .systemBlue : .white
    return Self(parts: parts, symbol: symbol, color: color, font: font,
                accessibility: ["澄观"] + parts + privacy.map { $0.title + " · " + $0.detail })
  }
}

struct MenuBarRenderKey: Equatable {
  var text: String, symbol: String, font: String
  var size: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
}
