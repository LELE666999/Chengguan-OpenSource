import AppKit
import Combine
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable {
  let id: AudioObjectID, name: String
  var input: Bool, output: Bool
}
struct AudioClient: Identifiable {
  let id: AudioObjectID, pid: Int32
  let playing: Bool, recording: Bool
}
struct BluetoothInfo: Identifiable {
  let id: String, name: String
  let connected: Bool
  let rssi: Int?
  var kind = "设备", symbol = "dot.radiowaves.left.and.right"
  var batteries: [BluetoothBattery] = []
}

struct BluetoothBattery: Identifiable, Equatable {
  var id: String
  var title: String
  var percent: Int
}

final class Peripherals: ObservableObject {
  static let shared = Peripherals()
  @Published var devices: [AudioDeviceInfo] = []
  @Published var clients: [AudioClient] = []
  @Published var audioActivityAvailable = false
  @Published var output: AudioObjectID = 0
  @Published var input: AudioObjectID = 0
  @Published var outputVolume: Double = 0
  @Published var inputVolume: Double = 0
  @Published var outputWritable = false
  @Published var inputWritable = false
  @Published var bluetooth: [BluetoothInfo] = []
  @Published var error: String?
  private func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }
  private func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var a = address(selector)
    _ = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
    return value
  }
  private func ids(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [AudioObjectID] {
    var a = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }
  private func name(_ id: AudioObjectID) -> String {
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var a = address(kAudioObjectPropertyName)
    let result = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
    }
    guard result == noErr else { return "音频设备" }
    return value as String
  }
  func refreshAudio() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var processAddress = address(kAudioHardwarePropertyProcessObjectList)
    var processSize: UInt32 = 0
    audioActivityAvailable = AudioObjectGetPropertyDataSize(system, &processAddress, 0, nil, &processSize) == noErr
    devices = ids(system, kAudioHardwarePropertyDevices).map { id in
      AudioDeviceInfo(
        id: id, name: name(id),
        input: !ids(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput).isEmpty,
        output: !ids(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput).isEmpty)
    }
    output = uint(system, kAudioHardwarePropertyDefaultOutputDevice)
    input = uint(system, kAudioHardwarePropertyDefaultInputDevice)
    let o = volume(output, input: false)
    let i = volume(input, input: true)
    outputVolume = o.0
    outputWritable = o.1
    inputVolume = i.0
    inputWritable = i.1
    clients = ids(system, kAudioHardwarePropertyProcessObjectList).map { id in
      AudioClient(
        id: id, pid: Int32(bitPattern: uint(id, kAudioProcessPropertyPID)),
        playing: uint(id, kAudioProcessPropertyIsRunningOutput) > 0,
        recording: uint(id, kAudioProcessPropertyIsRunningInput) > 0)
    }
  }
  private func volume(_ id: AudioObjectID, input: Bool) -> (Double, Bool) {
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    for channel: UInt32 in [0, 1] {
      var a = address(kAudioDevicePropertyVolumeScalar, scope, channel)
      var value: Float32 = 0
      var size = UInt32(MemoryLayout<Float32>.size)
      var writable: DarwinBoolean = false
      if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr {
        AudioObjectIsPropertySettable(id, &a, &writable)
        return (Double(value) * 100, writable.boolValue)
      }
    }
    return (0, false)
  }
  func setVolume(_ value: Double, input: Bool) {
    let id = input ? self.input : output
    let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var succeeded = false
    for channel: UInt32 in [0, 1, 2] {
      var a = address(kAudioDevicePropertyVolumeScalar, scope, channel)
      var v = Float32(min(100, max(0, value)) / 100)
      var settable: DarwinBoolean = false
      if AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue {
        if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
          == noErr
        {
          succeeded = true
        }
      }
    }
    if !succeeded { error = "该设备不支持系统音量调节" }
    refreshAudio()
  }
  func selectDevice(_ id: AudioObjectID, input: Bool) {
    var a = address(
      input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    var v = id
    let result = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size),
      &v)
    if result != noErr { error = "无法切换设备（\(result)）" }
    refreshAudio()
  }
  @Published private(set) var bluetoothLoading = false
  @Published private(set) var bluetoothError: String?
  private let bluetoothQueue = DispatchQueue(label: "studio.lele.chengguan.bluetooth", qos: .utility)
  private var lastBluetooth = Date.distantPast
  @Published private(set) var bluetoothDuration: Double = 0
  func refreshBluetooth() {
    let minimum = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized } ? 30.0 : 90.0
    guard Date().timeIntervalSince(lastBluetooth) >= minimum else { return }
    guard !bluetoothLoading else { return }
    bluetoothLoading = true
    lastBluetooth = Date()
    let started = ProcessInfo.processInfo.systemUptime
    bluetoothQueue.async { [weak self] in
      // The legacy pairedDevices API omitted connected BLE devices on the validation Mac.
      // Query the system's own inventory off the main thread, with a bounded subprocess.
      let output = Command.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 6)
      var devices = output.status == 0 ? BluetoothInventory.parse(Data(output.text.utf8)) : nil
      if let parsed = devices { devices = BluetoothInventory.mergingHID(parsed,
        records: SystemValue.properties("AppleDeviceManagementHIDEventService") + SystemValue.properties("IOHIDDevice")) }
      DispatchQueue.main.async {
        if let devices { self?.bluetooth = devices }
        self?.bluetoothError = devices == nil ? "无法读取蓝牙设备，请稍后重试。" : nil
        self?.bluetoothLoading = false
        self?.bluetoothDuration = ProcessInfo.processInfo.systemUptime - started
      }
    }
  }
}

enum BluetoothInventory {
  static func percentage(_ value: Any?) -> Int? {
    let number: Double?
    if let text = value as? String { number = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
    else { number = UsageNumeric.value(value) }
    guard let number, (0...100).contains(number), number.rounded() == number else { return nil }
    return Int(number)
  }
  static func batteries(_ details: [String: Any]) -> [BluetoothBattery] {
    [("main", "电量", "device_batteryLevelMain"), ("left", "左耳", "device_batteryLevelLeft"),
     ("right", "右耳", "device_batteryLevelRight"), ("case", "充电盒", "device_batteryLevelCase")].compactMap { id, title, key in
      percentage(details[key]).map { BluetoothBattery(id: id, title: title, percent: $0) }
    }
  }
  static func mergingHID(_ devices: [BluetoothInfo], records: [[String: Any]]) -> [BluetoothInfo] {
    func address(_ text: String) -> String { text.lowercased().filter { $0.isHexDigit } }
    return devices.map { device in
      var device = device
      guard device.connected, device.batteries.isEmpty, address(device.id).count == 12 else { return device }
      for record in records {
        let raw = record["DeviceAddress"] as? String ?? record["BluetoothDeviceAddress"] as? String ?? ""
        guard address(raw) == address(device.id), let value = percentage(record["BatteryPercent"]) else { continue }
        device.batteries = [BluetoothBattery(id: "main", title: "电量", percent: value)]; break
      }
      return device
    }
  }
  static func parse(_ data: Data) -> [BluetoothInfo]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
    var result: [BluetoothInfo] = []
    for controller in controllers {
      for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
        for entry in controller[key] as? [[String: Any]] ?? [] {
          for (name, raw) in entry {
            guard let details = raw as? [String: Any] else { continue }
            let minor = (details["device_minorType"] as? String ?? "").lowercased()
            let hint = minor + " " + name.lowercased()
            let type: (String, String)
            if hint.contains("headphone") || hint.contains("airpods") || hint.contains("beats") {
              type = ("耳机", "headphones")
            } else if hint.contains("keyboard") {
              type = ("键盘", "keyboard")
            } else if hint.contains("trackpad") {
              type = ("触控板", "computermouse")
            } else if hint.contains("mouse") {
              type = ("鼠标", "computermouse")
            } else if hint.contains("iphone") || hint.contains("phone") {
              type = ("电话", "iphone")
            } else if hint.contains("mac") || hint.contains("computer") {
              type = ("电脑", "laptopcomputer")
            } else { type = ("设备", "dot.radiowaves.left.and.right") }
            let rawRSSI = (details["device_rssi"] as? NSNumber)?.intValue
              ?? Int(details["device_rssi"] as? String ?? "")
            result.append(BluetoothInfo(
              id: details["device_address"] as? String ?? name, name: name,
              connected: connected,
              rssi: connected ? rawRSSI.flatMap { $0 > -127 && $0 < 0 ? $0 : nil } : nil,
              kind: type.0, symbol: type.1, batteries: connected ? batteries(details) : []))
          }
        }
      }
    }
    return result.sorted { $0.connected != $1.connected ? $0.connected : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
