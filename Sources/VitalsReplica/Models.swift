import AppKit
import Foundation
import SwiftUI

enum MonitorTab: String, CaseIterable, Identifiable {
  case overview, cpu, memory, disk, network, gpu, battery, sound, bluetooth, projects, agents, cables, nas, server, displays, defaultApps
  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "概览"
    case .cpu: "CPU"
    case .memory: "内存"
    case .disk: "磁盘"
    case .network: "网络"
    case .gpu: "GPU"
    case .battery: "电池"
    case .sound: "声效"
    case .bluetooth: "蓝牙"
    case .projects: "项目"
    case .agents: "代理"
    case .cables: "线缆"
    case .nas: "NAS"
    case .server: "服务器"
    case .displays: "显示器"
    case .defaultApps: "默认打开"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2.fill"
    case .cpu: "cpu.fill"
    case .memory: "memorychip.fill"
    case .disk: "internaldrive.fill"
    case .network: "network"
    case .gpu: "square.stack.3d.up.fill"
    case .battery: "battery.75percent"
    case .sound: "speaker.wave.2.fill"
    case .bluetooth: "dot.radiowaves.left.and.right"
    case .projects: "folder.fill"
    case .agents: "bot"
    case .cables: "cable.connector.horizontal"
    case .nas: "server.rack"
    case .server: "cloud"
    case .displays: "display"
    case .defaultApps: "app.badge.checkmark"
    }
  }
  var color: Color {
    let palette = UserDefaults.standard.string(forKey: "palette") ?? "Vitals"
    if palette == "单色" { return Color.primary.opacity(self == .memory ? 0.7 : 0.85) }
    if palette == "辅助功能" {
      return switch self {
      case .memory, .agents: .purple
      case .disk: .yellow
      case .network: .teal
      case .battery: .green
      case .gpu: .orange
      default: .blue
      }
    }
    let light: Color = switch self {
    case .overview: Color(.sRGB, red: 0, green: 122/255, blue: 1)
    case .memory: Color(.sRGB, red: 74/255, green: 58/255, blue: 167/255)
    case .disk: Color(.sRGB, red: 237/255, green: 161/255, blue: 0)
    case .network: Color(.sRGB, red: 28/255, green: 175/255, blue: 122/255)
    case .gpu, .sound: Color(.sRGB, red: 232/255, green: 123/255, blue: 164/255)
    case .projects: Color(red: 0.93, green: 0.39, blue: 0.20)
    case .battery: Color(.sRGB, red: 0, green: 131/255, blue: 0)
    case .agents: Color(.sRGB, red: 126/255, green: 58/255, blue: 214/255)
    default: Color(.sRGB, red: 43/255, green: 120/255, blue: 214/255)
    }
    let dark: NSColor = switch self {
    case .memory: NSColor(srgbRed: 181/255, green: 162/255, blue: 1, alpha: 1)
    case .disk: NSColor(srgbRed: 1, green: 192/255, blue: 65/255, alpha: 1)
    case .network: NSColor(srgbRed: 74/255, green: 216/255, blue: 164/255, alpha: 1)
    case .gpu, .sound: NSColor(srgbRed: 1, green: 155/255, blue: 192/255, alpha: 1)
    case .projects: NSColor(srgbRed: 1, green: 151/255, blue: 108/255, alpha: 1)
    case .battery: NSColor(srgbRed: 112/255, green: 219/255, blue: 107/255, alpha: 1)
    case .agents: NSColor(srgbRed: 191/255, green: 151/255, blue: 1, alpha: 1)
    default: NSColor(srgbRed: 118/255, green: 215/255, blue: 1, alpha: 1)
    }
    return Theme.adaptive(light: NSColor(light), dark: dark)
  }
  var shortcut: String? {
    let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    return Self.allCases.firstIndex(of: self).flatMap { $0 < keys.count ? keys[$0] : nil }
  }
  var isProcessTab: Bool { [.cpu, .memory, .disk, .network, .gpu, .battery].contains(self) }
  static func available(displayEnabled: Bool) -> [Self] { allCases.filter { displayEnabled || $0 != .displays } }
  static var visibleTabs: [Self] { available(displayEnabled: UserDefaults.standard.object(forKey: "displayControlEnabled") as? Bool ?? true) }
  static var menuTabs: [Self] { visibleTabs.filter { $0 != .defaultApps } }
}

struct ProcessSample: Identifiable, Sendable {
  let pid: Int32, ppid: Int32
  let uid: UInt32
  let start: UInt64
  let name: String, path: String
  var cpu: Double = 0
  let memory: UInt64
  var readRate: Double = 0, writeRate: Double = 0
  var networkIn: Double? = nil, networkOut: Double? = nil
  var wakeups: Double = 0
  let measured: Bool
  var measurementError: Int32 = 0
  var powerWatts: Double? = nil
  var id: Int32 { pid }
  var identity: String { "\(pid):\(start)" }
}

struct AppGroup: Identifiable, Sendable {
  let id: String, name: String
  let bundlePath: String?
  var processes: [ProcessSample]
  var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
  var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
  var readRate: Double { processes.reduce(0) { $0 + $1.readRate } }
  var writeRate: Double { processes.reduce(0) { $0 + $1.writeRate } }
  var networkIn: Double? {
    let v = processes.compactMap(\.networkIn)
    return v.isEmpty ? nil : v.reduce(0, +)
  }
  var networkOut: Double? {
    let v = processes.compactMap(\.networkOut)
    return v.isEmpty ? nil : v.reduce(0, +)
  }
  var measuredCount: Int { processes.filter(\.measured).count }
  var powerWatts: Double? {
    let values = processes.compactMap(\.powerWatts)
    return values.isEmpty ? nil : values.reduce(0, +)
  }
}

enum CounterMath {
  static func rate(current: UInt64, previous: UInt64?, elapsed: Double) -> Double {
    guard let previous, current >= previous, elapsed > 0, elapsed.isFinite else { return 0 }
    return Double(current - previous) / elapsed
  }
}

enum AppGrouping {
  static func bundleRoot(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
    return String(path[..<r.lowerBound]) + ".app"
  }
  static func groups(
    _ processes: [ProcessSample], names: [String: String] = [:], systemBundles: Set<String> = []
  ) -> [AppGroup] {
    let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    var result: [String: AppGroup] = [:]
    for p in processes {
      var bundle = bundleRoot(p.path)
      var ancestor = p
      var visited: Set<Int32> = [p.pid]
      for _ in 0..<24 {
        guard bundle == nil, let parent = byPID[ancestor.ppid], parent.uid == p.uid,
          !visited.contains(parent.pid)
        else { break }
        visited.insert(parent.pid)
        bundle = bundleRoot(parent.path)
        ancestor = parent
      }
      let systemOwner = bundle.map { systemBundles.contains($0) } ?? false
      if systemOwner { bundle = nil }
      let system =
        systemOwner
        || (bundle == nil
          && (p.uid == 0 || p.uid == UInt32.max || p.path.hasPrefix("/System/")
            || p.path.hasPrefix("/usr/libexec/") || p.path.hasPrefix("/usr/sbin/")))
      let key = bundle ?? (system ? "system.macos" : "process." + p.name)
      let name =
        bundle.map {
          names[$0] ?? URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        } ?? (system ? "macOS" : p.name)
      if result[key] == nil {
        result[key] = AppGroup(id: key, name: name, bundlePath: bundle, processes: [])
      }
      result[key]!.processes.append(p)
    }
    return result.values.map {
      var g = $0
      g.processes.sort { $0.memory > $1.memory }
      return g
    }.sorted { $0.cpu > $1.cpu }
  }
}

struct HistoryPoint: Identifiable, Codable, Sendable {
  var time: Date
  var cpu: Double, memory: Double, gpu: Double?, download: Double, upload: Double, read: Double,
    write: Double
  var temperature: Double?, battery: Double?
  var id: Date { time }
  func value(_ tab: MonitorTab) -> Double? {
    switch tab {
    case .memory: memory
    case .gpu: gpu
    case .network: download
    case .disk: write
    case .battery: battery
    default: cpu
    }
  }
}
struct BatterySample: Sendable {
  var percent: Double?, health: Double?, cycles: Int?, temperature: Double?, watts: Double?,
    minutes: Int?
  var charging = false, plugged = false
}
struct SensorSample: Identifiable, Sendable {
  let key: String, name: String, value: Double, unit: String
  var id: String { key }
}
struct VolumeSample: Identifiable, Sendable {
  let path: String, name: String
  let total: UInt64, free: UInt64
  let removable: Bool
  var id: String { path }
}
struct ProjectSample: Identifiable, Sendable {
  let path: String, name: String
  var processes: [ProcessSample]
  var ports: [Int]
  var id: String { path }
  var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
  var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
}
struct AgentSample: Identifiable, Sendable {
  let process: ProcessSample, name: String
  let directory: String?
  var id: String { process.identity }
}
struct MonitorSnapshot: Sendable {
  var time = Date(), cpu = 0.0, user = 0.0, system = 0.0, load = 0.0
  var coreUsage: [Double] = [], coreLabels: [String] = [], clusterDescription = ""
  var totalMemory: UInt64 = 0, appMemory: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
    cached: UInt64 = 0, swap: UInt64 = 0
  var pressureLevel = 1
  var gpu: Double?, gpuMemory: UInt64?, temperature: Double?, fan: Double?
  var download = 0.0, upload = 0.0, read = 0.0, write = 0.0
  var received: Double = 0, sent: Double = 0, written: Double = 0
  var battery = BatterySample(), sensors: [SensorSample] = [], volumes: [VolumeSample] = []
  var power = PowerSample()
  var groups: [AppGroup] = [], processes: [ProcessSample] = [], projects: [ProjectSample] = [],
    agents: [AgentSample] = []
  var isWarmup = false
  var listeningPorts: [Int] = []
  var projectScanTime: Date?
  var moduleDurations: [String: Double] = [:]
  var collectionMode = "标准"
  var networkSampleInterval = 5.0
  var unmeasured = 0, samplingDuration = 0.0, error: String?
  var localNetwork = LocalNetworkSnapshot()
  var usedMemory: UInt64 { min(totalMemory, appMemory + wired + compressed) }
  var availableMemory: UInt64 { totalMemory > usedMemory ? totalMemory - usedMemory : 0 }
  var primaryVolume: VolumeSample? { volumes.first { !$0.removable } ?? volumes.first }
  var point: HistoryPoint {
    HistoryPoint(
      time: time, cpu: cpu, memory: Double(usedMemory), gpu: gpu, download: download,
      upload: upload, read: read, write: write, temperature: temperature, battery: battery.percent)
  }
}

enum Format {
  static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }
  static func bytes(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    let units = ["B", "kB", "MB", "GB", "TB"]
    var n = value
    var i = 0
    while n >= 1000 && i < 4 {
      n /= 1000
      i += 1
    }
    return String(format: i >= 3 ? "%.2f %@" : (i >= 2 ? "%.1f %@" : "%.0f %@"), n, units[i])
  }
  static func memory(_ value: UInt64) -> String { memory(Double(value)) }
  static func memory(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var n = value
    var i = 0
    while n >= 1024 && i < 4 {
      n /= 1024
      i += 1
    }
    return String(format: i >= 3 ? "%.2f %@" : (i >= 2 ? "%.1f %@" : "%.0f %@"), n, units[i])
  }
  static func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "—" }
  static func networkRate(_ value: Double?) -> String {
    value.map {
      UserDefaults.standard.bool(forKey: "networkBits")
        ? bytes($0 * 8).replacingOccurrences(of: "B", with: "b") + "/s" : bytes($0) + "/s"
    } ?? "—"
  }
  static func appCPU(_ value: Double) -> String {
    String(
      format: "%.1f%%",
      value
        / (UserDefaults.standard.bool(forKey: "wholeMachineCPU")
          ? Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) : 1))
  }
  static func temperature(_ value: Double) -> String {
    UserDefaults.standard.string(forKey: "temperatureUnit") == "f"
      ? String(format: "%.0f °F", value * 9 / 5 + 32) : String(format: "%.0f °C", value)
  }
  static func percent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.0f%%", value)
  }
  static func duration(_ seconds: Double) -> String {
    let n = max(0, Int(seconds))
    if n >= 86400 { return "\(n/86400)天 \(n%86400/3600)小时" }
    if n >= 3600 { return "\(n/3600)小时 \(n%3600/60)分钟" }
    return "\(n/60)分钟"
  }
  static func split(_ text: String) -> (String, String) {
    let s = text.split(separator: " ", maxSplits: 1)
    return (s.first.map(String.init) ?? "—", s.count > 1 ? String(s[1]) : "")
  }
}
