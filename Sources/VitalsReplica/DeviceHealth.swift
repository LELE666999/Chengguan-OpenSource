import Combine
import Foundation

struct DeviceHealthCheck: Identifiable, Sendable {
  enum State: String, Sendable { case good, attention, unknown }
  let id: String, title: String, detail: String
  let state: State
}
struct DiskHealthReading: Identifiable, Sendable {
  let id: String, name: String, transport: String
  let smart: String?
  let internalDisk: Bool
  let size: UInt64?
  var temperature: Double?, wear: Double?, spare: Double?, readBytes: Double?, writtenBytes: Double?, powerHours: Double?, mediaErrors: Double?
  var state: DeviceHealthCheck.State {
    guard let smart else { return .unknown }
    return smart.lowercased() == "verified" && (wear ?? 0) < 100 && (mediaErrors ?? 0) == 0 ? .good : .attention
  }
  var statusText: String { smart == nil ? "设备未提供 SMART" : state == .good ? "SMART 已通过" : "健康指标需关注" }
}
struct DeviceHealthReport: Sendable {
  var time: Date?
  var checks: [DeviceHealthCheck] = []
  var disks: [DiskHealthReading] = []
}
/// Infrequent read-only checks, isolated from the two-second sampling queue.
final class DeviceHealthStore: ObservableObject {
  static let shared = DeviceHealthStore()
  @Published private(set) var report = DeviceHealthReport()
  @Published private(set) var loading = false
  func refresh(force: Bool = false) {
    guard !loading, force || report.time.map({ Date().timeIntervalSince($0) > 120 }) != false else { return }
    loading = true
    DispatchQueue.global(qos: .utility).async {
      let report = DeviceHealthReader.read()
      DispatchQueue.main.async { self.report = report; self.loading = false }
    }
  }
}
enum DeviceHealthReader {
  static func securityCheck(id: String, title: String, output: Command.Output, enabled: [String], disabled: [String]) -> DeviceHealthCheck {
    let text = output.text.lowercased()
    let state: DeviceHealthCheck.State
    if output.status != 0 { state = .unknown }
    else if disabled.contains(where: text.contains) { state = .attention }
    else if enabled.contains(where: text.contains) { state = .good }
    else { state = .unknown }
    return DeviceHealthCheck(id: id, title: title,
      detail: state == .good ? "已开启" : state == .attention ? "未开启" : "暂时无法确认", state: state)
  }
  static func disk(_ info: [String: Any]) -> DiskHealthReading? {
    guard let id = info["DeviceIdentifier"] as? String, (info["WholeDisk"] as? Bool ?? info["Whole"] as? Bool) == true,
          info["VirtualOrPhysical"] as? String != "Virtual" else { return nil }
    let raw = info["SMARTStatus"] as? String
    let smart = raw.flatMap { ["verified", "failing", "failed"].contains($0.lowercased()) ? $0 : nil }
    let attributes = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
    func number(_ key: String) -> Double? { (attributes[key] as? NSNumber)?.doubleValue }
    func counter(_ key: String, scale: Double = 1) -> Double? {
      guard let low = number(key + "_0") else { return nil }
      return ((number(key + "_1") ?? 0) * 18_446_744_073_709_551_616 + low) * scale
    }
    let kelvin = number("TEMPERATURE")
    return DiskHealthReading(id: id, name: info["MediaName"] as? String ?? id,
      transport: info["BusProtocol"] as? String ?? "—", smart: smart,
      internalDisk: info["Internal"] as? Bool ?? false, size: (info["TotalSize"] as? NSNumber)?.uint64Value,
      temperature: kelvin.flatMap { (200...500).contains($0) ? $0 - 273.15 : nil }, wear: number("PERCENTAGE_USED"),
      spare: number("AVAILABLE_SPARE"), readBytes: counter("DATA_UNITS_READ", scale: 512_000).flatMap { $0 > 0 ? $0 : nil },
      writtenBytes: counter("DATA_UNITS_WRITTEN", scale: 512_000).flatMap { $0 > 0 ? $0 : nil },
      powerHours: counter("POWER_ON_HOURS"), mediaErrors: counter("MEDIA_ERRORS"))
  }
  static func read() -> DeviceHealthReport {
    var report = DeviceHealthReport(time: Date())
    report.checks = [
      securityCheck(id: "sip", title: "系统完整性保护", output: Command.run("/usr/bin/csrutil", ["status"]), enabled: ["enabled"], disabled: ["disabled", "unknown (custom configuration)"]),
      securityCheck(id: "filevault", title: "FileVault 磁盘加密", output: Command.run("/usr/bin/fdesetup", ["status"]), enabled: ["filevault is on"], disabled: ["filevault is off"]),
      securityCheck(id: "gatekeeper", title: "应用来源检查", output: Command.run("/usr/sbin/spctl", ["--status"]), enabled: ["assessments enabled"], disabled: ["assessments disabled"]),
      securityCheck(id: "firewall", title: "应用防火墙", output: Command.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]), enabled: ["enabled", "state = 1", "state = 2"], disabled: ["disabled", "state = 0"]),
    ]
    let output = Command.run("/usr/sbin/diskutil", ["list", "-plist", "physical"])
    if let data = output.text.data(using: .utf8),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
      let ids = plist["WholeDisks"] as? [String] ?? []
      for id in ids.prefix(16) where id.range(of: "^disk[0-9]+$", options: .regularExpression) != nil {
        let info = Command.run("/usr/sbin/diskutil", ["info", "-plist", id])
        guard info.status == 0, let data = info.text.data(using: .utf8),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disk = disk(dictionary) else { continue }
        report.disks.append(disk)
      }
    }
    return report
  }
}
