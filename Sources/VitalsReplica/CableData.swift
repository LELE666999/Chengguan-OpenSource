import Foundation
import IOKit

/// Only SOP' identifies a cable. SOP describes the partner, never the cable brand.
/// VDO layout cross-checked against WhatCable (MIT); see Resources/WhatCable-LICENSE.txt.
struct CableIdentity: Equatable, Codable, Sendable {
  let active: Bool
  let vendorID: Int
  let productID: Int
  let certificationID: UInt32?
  let speedCode: Int
  let currentAmps: Int?
  let ratedVolts: Int?
  let ratedWatts: Int?
  let epr: Bool
  let warning: String?
  var vendor: String { vendorID == 0 ? "未提供" : String(format: "VID 0x%04X", vendorID) }
  var power: String { ratedWatts.map { "\($0) W" } ?? "功率未知" }
  var speed: String {
    switch speedCode {
    case 0: return "480 Mbps"
    case 1: return "5 Gbps"
    case 2: return "10 Gbps"
    case 3: return "USB4 · 20–40 Gbps"
    case 4: return "80 Gbps"
    default: return "数据能力未知"
    }
  }
  static func decode(_ words: [UInt32], revision: Int) -> CableIdentity? {
    guard words.count >= 4 else { return nil }
    let type = Int((words[0] >> 27) & 7)
    guard type == 3 || type == 4 else { return nil }
    let v = words[3], active = type == 4
    let version = Int((v >> 21) & 7)
    // Unknown layouts must not become plausible-looking 60 W / USB 2.0 defaults.
    let supported = revision == 2 || revision == 3
    let layout = supported && (active ? [0, 2, 3].contains(version) : version == 0)
    let amps: Int? = layout ? [1: 3, 2: 5][Int((v >> 5) & 3)] : nil
    let voltageCode = Int((v >> 9) & 3)
    let epr = layout && !active && revision >= 3 && (v & (1 << 17)) != 0 && voltageCode == 3
    let volts: Int? = layout ? (revision >= 3 && voltageCode == 3 ? 50 : 20) : nil
    let vbus = !active || (v & (1 << 4)) != 0
    let watts = vbus ? amps.map { (epr ? 48 : 20) * $0 } : nil
    var speed = layout ? Int(v & 7) : -1
    // PD 2.0 only defines speed codes 0...2. Active VDO2 protocol flags are inverted.
    if revision == 2 && speed > 2 { speed = -1 }
    if active {
      if words.count < 5 || version != 3 { speed = -1 }
      else {
        let flag: UInt32 = speed >= 3 ? 1 << 8 : speed == 0 ? 1 << 5 : 1 << 4
        if words[4] & flag != 0 { speed = -1 }
      }
    }
    let warning: String?
    if !layout { warning = "芯片格式暂不支持，能力未推断" }
    else if (v & (1 << 17)) != 0 && voltageCode != 3 && !active && revision >= 3 { warning = "芯片的 EPR 与电压字段不一致" }
    else if active && voltageCode == 3 { warning = "主动线缆的 EPR 能力暂未确认" }
    else if amps == nil || !(0...4).contains(speed) { warning = "芯片部分规格未提供或暂不可解码" }
    else { warning = nil }
    return CableIdentity(active: active, vendorID: Int(words[0] & 0xffff), productID: Int(words[2] >> 16),
      certificationID: words[1] == 0 ? nil : words[1], speedCode: speed, currentAmps: amps,
      ratedVolts: volts, ratedWatts: watts, epr: epr, warning: warning)
  }
}

struct CablePowerProfile: Equatable, Codable, Sendable {
  let volts: Double
  let amps: Double
  let watts: Int
  var label: String { String(format: "%g V · %g A", volts, amps) }
}

struct CablePort: Identifiable, Equatable, Codable, Sendable {
  let id: String
  let number: Int
  let identity: CableIdentity?
  let devices: [String]
  let link: String?
  let display: String?
  let supplyWatts: Int?
  let supplyVolts: Double?
  let supplyAmps: Double?
  let liquidDetected: Bool
  var displayLanes: Int? = nil
  var displayRate: String? = nil
  var powerProfiles: [CablePowerProfile] = []
  var activeTransports: [String] = []
  var pdRevision: Int? = nil
  var identityWords: [UInt32] = []
  var title: String { "USB-C \(number)" }
  var subtitle: String { devices.isEmpty ? "已连接 · 设备名称未提供" : devices.joined(separator: " · ") }
  var summary: String {
    var parts = [identity?.power ?? "芯片未读到"]
    if let link { parts.append(link) }
    if display != nil { parts.append("视频输出中") }
    return parts.joined(separator: " · ")
  }
  // Registry IDs and physical-port numbers stay local. No serial number is read.
  var connectionSignature: String { "\(identity?.vendorID ?? -1):\(identity?.productID ?? -1):\(identity?.ratedWatts ?? -1):\(devices.joined(separator: ","))" }
  var cableName: String { identity?.ratedWatts.map { "\($0) W USB-C 线缆" } ?? "USB-C 线缆" }
  var videoDetail: String {
    guard display != nil else { return "未检测到输出" }
    return [displayLanes.map { "\($0) 通道" }, displayRate.map { $0 + " / 通道" }].compactMap { $0 }.joined(separator: " · ")
  }
}

struct CableSnapshot: Equatable, Codable, Sendable {
  var ports: [CablePort] = []
  var portCount = 0
  var readable = false
  var identified: Int { ports.filter { $0.identity != nil }.count }
  var summary: String {
    !readable ? "当前 Mac 未提供线缆数据" : ports.isEmpty ? "未连接 USB-C 线缆" : "\(ports.count) 个连接 · \(identified) 个芯片已识别"
  }
}

/// Bounded native registry reads, no processes, drivers, USB commands or elevated access.
enum CableReader {
  static func read() -> CableSnapshot {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleHPMInterface"), &iterator) == KERN_SUCCESS else { return CableSnapshot() }
    defer { IOObjectRelease(iterator) }
    var roots: [[String: Any]] = []
    while roots.count < 32 {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      defer { IOObjectRelease(service) }
      if let node = node(service, depth: 0) { roots.append(node) }
    }
    return parse(roots)
  }
  private static func node(_ service: io_registry_entry_t, depth: Int) -> [String: Any]? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          var result = properties?.takeRetainedValue() as? [String: Any] else { return nil }
    var entry: UInt64 = 0
    if IORegistryEntryGetRegistryEntryID(service, &entry) == KERN_SUCCESS { result["RegistryID"] = entry }
    var name = [CChar](repeating: 0, count: 128)
    if IORegistryEntryGetName(service, &name) == KERN_SUCCESS { result["RegistryName"] = String(cString: name) }
    guard depth < 4 else { return result }
    var iterator: io_iterator_t = 0
    if IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS {
      defer { IOObjectRelease(iterator) }
      var children: [[String: Any]] = []
      for _ in 0..<64 {
        let child = IOIteratorNext(iterator)
        guard child != 0 else { break }
        defer { IOObjectRelease(child) }
        if let value = node(child, depth: depth + 1) { children.append(value) }
      }
      result["Children"] = children
    }
    return result
  }
  static func words(_ value: Any?) -> [UInt32] {
    guard let values = value as? [Data], values.count <= 7 else { return [] }
    // IOKit returns little-endian byte strings, not host-endian integer arrays.
    var result: [UInt32] = []
    for data in values {
      guard data.count == 4 else { return [] }
      result.append(data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) })
    }
    return result
  }
  static func parse(_ roots: [[String: Any]]) -> CableSnapshot {
    var result = CableSnapshot()
    for root in roots {
      let kind = root["PortTypeDescription"] as? String ?? ""
      guard kind == "USB-C" else { continue }
      result.readable = true; result.portCount += 1
      // Re-read current trees every time. Never retain an old PDO/identity after unplug.
      guard root["ConnectionActive"] as? Bool == true,
        let number = root["PortNumber"] as? Int else { continue }
      var nodes: [[String: Any]] = []
      func visit(_ node: [String: Any], depth: Int) {
        guard depth < 5 else { return }
        for child in (node["Children"] ?? node["IORegistryEntryChildren"]) as? [[String: Any]] ?? [] {
          nodes.append(child); visit(child, depth: depth + 1)
        }
      }
      visit(root, depth: 0)
      func name(_ n: [String: Any]) -> String { (n["RegistryName"] ?? n["IORegistryEntryName"]) as? String ?? "" }
      let cable = nodes.first { name($0) == "SOP'" }
      let metadata = cable?["Metadata"] as? [String: Any] ?? [:]
      let identity = CableIdentity.decode(words(metadata["VDOs"] ?? cable?["VDOs"]), revision: cable?["Specification Revision"] as? Int ?? 0)
      let active = nodes.filter { $0["Active"] as? Bool == true }
      let usb = active.first { name($0) == "USB3" } ?? active.first { name($0) == "USB2" }
      let display = active.first { name($0) == "DisplayPort" }
      let products = [display?["ProductName"] as? String, usb?["Product"] as? String].compactMap { clean($0) }
      let source = nodes.first { name($0).hasPrefix("USB-PD") && name($0).contains("[*]") }
      let option = source?["WinningPowerSourceOption"] as? [String: Any] ?? [:]
      let milliwatts = option["Max Power (mW)"] as? Int
      let mv = (option["Voltage (mV)"] as? NSNumber)?.doubleValue
      let ma = (option["Max Current (mA)"] as? NSNumber)?.doubleValue
      // Native IOKit uses a CFSet here; ioreg's plist export turns it into an array.
      let options = source?["PowerSourceOptions"]
      let profileRows = (options as? NSSet)?.allObjects ?? (options as? [Any]) ?? []
      let profiles = profileRows.compactMap { value -> CablePowerProfile? in
        guard let item = value as? [String: Any] else { return nil }
        guard item["Class"] as? String == "IOPortFeaturePowerSourceOptionFixed",
          let v = (item["Voltage (mV)"] as? NSNumber)?.doubleValue, v > 0, v <= 50000,
          let a = (item["Max Current (mA)"] as? NSNumber)?.doubleValue, a > 0, a <= 5000,
          let w = item["Max Power (mW)"] as? Int, w > 0, w <= 240000 else { return nil }
        return CablePowerProfile(volts: v / 1000, amps: a / 1000, watts: w / 1000)
      }.sorted { $0.volts < $1.volts }
      result.ports.append(CablePort(id: String(describing: root["RegistryID"] ?? root["IORegistryEntryID"] ?? number), number: number,
        identity: identity, devices: Array(NSOrderedSet(array: products)) as? [String] ?? products,
        link: clean(usb?["DataRateDescription"] as? String), display: display.map { clean($0["ProductName"] as? String) ?? "DisplayPort" },
        supplyWatts: milliwatts.flatMap { $0 > 0 && $0 <= 240_000 ? $0 / 1000 : nil },
        supplyVolts: mv.flatMap { $0 > 0 && $0 <= 50_000 ? $0 / 1000 : nil },
        supplyAmps: ma.flatMap { $0 > 0 && $0 <= 5_000 ? $0 / 1000 : nil },
        liquidDetected: root["LDCM_LiquidDetected"] as? Bool == true,
        displayLanes: (display?["LaneCount"] as? Int).flatMap { (1...4).contains($0) ? $0 : nil },
        displayRate: clean(display?["LinkRateDescription"] as? String), powerProfiles: Array(profiles.prefix(16)),
        activeTransports: (root["TransportsActive"] as? [String] ?? []).compactMap { clean($0) },
        pdRevision: cable?["Specification Revision"] as? Int,
        identityWords: words(metadata["VDOs"] ?? cable?["VDOs"])))
    }
    result.ports.sort { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number }
    return result
  }
  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
    return text.isEmpty ? nil : text
  }
}
