import Combine
import CoreAudio
import Foundation

struct DisplayAudioOutput: Identifiable, Equatable {
  var id: String // Stable Core Audio UID, not the transient object ID.
  var object: AudioObjectID
  var name: String
  var volume: Double?
  var writable: Bool
}
enum DisplayAudioRules {
  static func match(_ name: String, outputs: [DisplayAudioOutput]) -> DisplayAudioOutput? {
    func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    let matches = outputs.filter { normalized($0.name) == normalized(name) }
    return matches.count == 1 ? matches.first : nil
  }
}
/// Controls the explicitly named output without changing the Mac's output route.
@MainActor final class DisplayAudioStore: ObservableObject {
  static let shared = DisplayAudioStore()
  @Published private(set) var outputs: [DisplayAudioOutput] = []
  @Published private(set) var defaultOutput: String?
  @Published private(set) var associations: [String: String]
  @Published var error: String?
  private var timer: Timer?
  private var enabled = UserDefaults.standard.object(forKey: "displayControlEnabled") as? Bool ?? true
  private init() {
    associations = UserDefaults.standard.dictionary(forKey: "displayAudioOutputs") as? [String: String] ?? [:]
    if enabled { setEnabled(true) }
  }
  func setEnabled(_ value: Bool) {
    enabled = value; timer?.invalidate(); timer = nil
    if value {
      refresh()
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    } else { outputs = []; defaultOutput = nil }
  }
  func associate(_ uid: String?, with display: String) {
    associations[display] = uid
    UserDefaults.standard.set(associations, forKey: "displayAudioOutputs")
    refresh()
  }
  func output(for display: DisplayDevice) -> DisplayAudioOutput? {
    if let uid = associations[display.id] { return outputs.first { $0.id == uid } }
    if let matched = DisplayAudioRules.match(display.name, outputs: outputs), matched.writable { return matched }
    return outputs.first { $0.id == defaultOutput }
  }
  func isSystemFallback(_ display: DisplayDevice) -> Bool {
    associations[display.id] == nil && DisplayAudioRules.match(display.name, outputs: outputs)?.writable != true
  }
  func refresh() {
    guard enabled else { return }
    let system = AudioObjectID(kAudioObjectSystemObject)
    let current: UInt32? = read(system, kAudioHardwarePropertyDefaultOutputDevice)
    outputs = ids(system, kAudioHardwarePropertyDevices).compactMap { object in
      var address = Self.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0,
            let uid = string(object, kAudioDevicePropertyDeviceUID), let name = string(object, kAudioObjectPropertyName) else { return nil }
      let controls = volumeControls(object)
      return DisplayAudioOutput(id: uid, object: object, name: name,
        volume: controls.isEmpty ? nil : controls.map { Double($0.value) * 100 }.reduce(0, +) / Double(controls.count),
        writable: !controls.isEmpty && controls.allSatisfy(\.writable))
    }
    defaultOutput = outputs.first { $0.object == current }?.id
  }
  func setVolume(_ value: Double, output: DisplayAudioOutput) {
    guard enabled, value.isFinite, let actual = outputs.first(where: { $0.id == output.id }), actual.writable else { return }
    // Re-resolve by UID immediately before writing, in case of a hot-unplug.
    guard string(actual.object, kAudioDevicePropertyDeviceUID) == actual.id else { refresh(); return }
    let controls = volumeControls(actual.object)
    guard !controls.isEmpty, controls.allSatisfy(\.writable) else { refresh(); return }
    var scalar = Float(min(100, max(0, value)) / 100)
    var succeeded = true
    for control in controls {
      var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, control.channel)
      if AudioObjectSetPropertyData(actual.object, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar) != noErr { succeeded = false }
    }
    if succeeded {
      var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
      var writable: DarwinBoolean = false
      if AudioObjectIsPropertySettable(actual.object, &address, &writable) == noErr, writable.boolValue {
        var mute: UInt32 = scalar == 0 ? 1 : 0
        _ = AudioObjectSetPropertyData(actual.object, &address, 0, nil, 4, &mute)
      }
    } else { error = "音频设备未接受音量调整，请重新选择输出设备。" }
    refresh()
  }
  private struct Control { var channel: UInt32, value: Float, writable: Bool }
  private func volumeControls(_ object: AudioObjectID) -> [Control] {
    var result: [Control] = []
    for channel: UInt32 in [0, 1, 2] {
      var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, channel)
      var value: Float = 0, size: UInt32 = 4, writable: DarwinBoolean = false
      if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, value.isFinite, (0...1).contains(value) {
        _ = AudioObjectIsPropertySettable(object, &address, &writable)
        result.append(Control(channel: channel, value: value, writable: writable.boolValue))
        if channel == 0 { break } // A master control takes precedence over channels.
      }
    }
    return result
  }
  private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }
  private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? where T: FixedWidthInteger {
    var result: T = 0, size = UInt32(MemoryLayout<T>.size), address = Self.address(selector)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
  }
  private func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = Self.address(selector), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var result = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : []
  }
  private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var value: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size), address = Self.address(selector)
    let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return result == noErr ? value as String : nil
  }
}
