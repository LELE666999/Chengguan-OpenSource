import Foundation
import IOKit

struct PowerSample: Sendable {
  var system: Double?, adapter: Double?, battery: Double?, display: Double?
  var components: [PowerComponent] = []
}
struct PowerComponent: Sendable, Identifiable {
  var id: String
  var watts: Double
}

enum PowerMeasurement {
  static func valid(_ value: Double?, signed: Bool = false) -> Double? {
    guard let value, value.isFinite, abs(value) < 600, signed || value >= 0 else { return nil }
    return value
  }
  static func batteryWatts(voltage: Double?, current: NSNumber?) -> Double? {
    guard let voltage, voltage > 0, voltage < 100_000, let current else { return nil }
    var milliamps = current.int64Value
    if milliamps > 32767 && milliamps <= 65535 { milliamps -= 65536 }
    guard abs(Double(milliamps)) < 30_000 else { return nil }
    return valid(voltage * Double(milliamps) / 1_000_000, signed: true)
  }
  static func watts(energy: Double, unit: String, seconds: Double) -> Double? {
    guard seconds >= 0.1, seconds <= 60, energy >= 0 else { return nil }
    let factor: Double
    switch unit.lowercased() {
    case "nj": factor = 1e-9
    case "uj", "µj", "μj": factor = 1e-6
    case "mj": factor = 1e-3
    case "j": factor = 1
    default: return nil
    }
    return valid(energy * factor / seconds)
  }
  static func component(_ channel: String) -> String? {
    switch channel.lowercased() {
    case "cpu energy": "CPU"
    case "gpu energy": "GPU"
    case "dram energy": "内存"
    case "ane energy": "神经引擎"
    case "media engine energy", "media energy": "媒体引擎"
    default: nil // Parent/cluster counters must never be added to the same aggregate twice.
    }
  }
}

/// Optional runtime interface. A missing/changed energy interface leaves the readings unavailable.
/// Only energy-model channels are subscribed; no privileged helper or shell sampler is started.
final class ChipEnergyReader {
  private(set) var observedChannels: [[String: Any]] = []
  private var confirmed = Set<String>()
  private typealias Copy = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
  private typealias Subscribe = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
  private typealias Sample = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  private typealias StringValue = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
  private typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64
  private var handle: UnsafeMutableRawPointer?
  private var subscription: CFTypeRef?
  private var channels: CFMutableDictionary?
  private var previous: CFDictionary?
  private var previousTime: TimeInterval?
  private var sample: Sample?, delta: Delta?, channelName: StringValue?, channelUnit: StringValue?, integer: Integer?
  init() {
    guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return }
    handle = library
    func function<T>(_ name: String, as type: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: type) } }
    guard let copy = function("IOReportCopyChannelsInGroup", as: Copy.self),
      let subscribe = function("IOReportCreateSubscription", as: Subscribe.self) else { return }
    sample = function("IOReportCreateSamples", as: Sample.self)
    delta = function("IOReportCreateSamplesDelta", as: Delta.self)
    channelName = function("IOReportChannelGetChannelName", as: StringValue.self)
    channelUnit = function("IOReportChannelGetUnitLabel", as: StringValue.self)
    integer = function("IOReportSimpleGetIntegerValue", as: Integer.self)
    guard sample != nil, delta != nil, channelName != nil, channelUnit != nil, integer != nil,
      let requested = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
    var subscribed: Unmanaged<CFMutableDictionary>?
    subscription = subscribe(nil, requested, &subscribed, 0, nil)?.takeRetainedValue()
    channels = subscribed?.takeRetainedValue()
  }
  func read() -> [PowerComponent] {
    guard let subscription, let channels, let sample, let delta, let channelName, let channelUnit, let integer,
      let current = sample(subscription, channels, nil)?.takeRetainedValue() else { return [] }
    let time = ProcessInfo.processInfo.systemUptime
    defer { previous = current; previousTime = time }
    guard let previous, let previousTime,
      let change = delta(previous, current, nil)?.takeRetainedValue(),
      let list = (change as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
    var values: [String: Double] = [:]
    var clusterCPU: Double = 0
    var hasClusterCPU = false
    observedChannels.removeAll(keepingCapacity: true)
    for item in list {
      let channel = item as CFDictionary
      guard let name = channelName(channel)?.takeUnretainedValue() as String?,
        let unit = channelUnit(channel)?.takeUnretainedValue() as String?,
        let watts = PowerMeasurement.watts(energy: Double(integer(channel, 0)), unit: unit, seconds: time - previousTime) else { continue }
      observedChannels.append(["name": name, "unit": unit, "watts": watts])
      if ["ECPU Energy", "PCPU Energy"].contains(name) { clusterCPU += watts; hasClusterCPU = true }
      if let id = PowerMeasurement.component(name) { values[id] = watts }
    }
    // Some chips keep the aggregate channel at zero while reporting both cluster counters.
    if (values["CPU"] ?? 0) == 0 && hasClusterCPU { values["CPU"] = clusterCPU }
    for (id, value) in values where value > 0 { confirmed.insert(id) }
    // New chip/OS combinations expose placeholder channels that stay at zero forever.
    // Require a published nonzero sample before treating later zero samples as valid idle power.
    return ["CPU", "GPU", "内存", "神经引擎", "媒体引擎"].compactMap { id in
      guard confirmed.contains(id) else { return nil }
      return values[id].map { PowerComponent(id: id, watts: $0) }
    }
  }
  deinit {
    previous = nil; channels = nil; subscription = nil
    if let handle { dlclose(handle) }
  }
}
