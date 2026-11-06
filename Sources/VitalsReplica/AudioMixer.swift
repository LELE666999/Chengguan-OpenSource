import AppKit
import Combine
import CoreAudio
import MonitorBridge
import SwiftUI

enum AudioMixError: LocalizedError {
  case system(String, OSStatus), format, device, noProcesses
  var errorDescription: String? {
    switch self {
    case .system(let step, let code): return "\(step)失败（\(code)）。请在系统设置的“屏幕与系统音频录制”中允许澄观使用系统音频。"
    case .format: return "这个输出设备的音频格式暂不支持 App 混音。"
    case .device: return "找不到可用的输出设备。"
    case .noProcesses: return "这个 App 的音频进程已经退出。"
    }
  }
}
private enum AudioProperty {
  static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
  static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var a = address(selector), value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard status == noErr else { throw AudioMixError.system("读取音频设备", status) }
    return value as String
  }
  static func streams(_ id: AudioObjectID, input: Bool) -> [AudioStreamID] {
    var a = address(kAudioDevicePropertyStreams, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &values) == noErr else { return [] }
    return values
  }
  static func format(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
    var a = address(selector), value = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
    guard status == noErr else { throw AudioMixError.system("读取音频格式", status) }
    guard value.mFormatID == kAudioFormatLinearPCM, value.mBitsPerChannel == 32,
          value.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw AudioMixError.format }
    return value
  }
  static func inputBuffers(_ id: AudioObjectID) throws -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput), size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    guard status == noErr else { throw AudioMixError.system("读取输入配置", status) }
    guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let result = AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw)
    guard result == noErr else { throw AudioMixError.system("读取输入配置", result) }
    return Int(raw.load(as: AudioBufferList.self).mNumberBuffers)
  }
}

/// A private tap and aggregate route the chosen application's stereo mix back to the output.
/// Normal output resumes automatically whenever this reader stops (.mutedWhenTapped).
final class ProcessAudioGain {
  let objects: [AudioObjectID], output: AudioObjectID
  private var tap: AudioObjectID = 0, aggregate: AudioObjectID = 0
  private var proc: AudioDeviceIOProcID?
  private var gain: OpaquePointer?
  private let queue = DispatchQueue(label: "studio.lele.chengguan.audio-render", qos: .userInteractive)
  init(objects: [AudioObjectID], output: AudioObjectID, volume: Double) throws {
    guard !objects.isEmpty else { throw AudioMixError.noProcesses }
    guard output != 0 else { throw AudioMixError.device }
    self.objects = objects.sorted(); self.output = output
    do { try start(volume: volume) } catch { stop(); throw error }
  }
  private func check(_ result: OSStatus, _ step: String) throws { if result != noErr { throw AudioMixError.system(step, result) } }
  private func start(volume: Double) throws {
    let outputUID = try AudioProperty.string(output, kAudioDevicePropertyDeviceUID)
    let hardwareStreams = AudioProperty.streams(output, input: true).count
    let hardwareBuffers = try AudioProperty.inputBuffers(output)
    let description = CATapDescription(stereoMixdownOfProcesses: objects)
    description.uuid = UUID(); description.name = "澄观 App 混音"
    description.isPrivate = true
    description.muteBehavior = .mutedWhenTapped
    try check(AudioHardwareCreateProcessTap(description, &tap), "建立 App 音频流")
    let format = try AudioProperty.format(tap, kAudioTapPropertyFormat)
    guard format.mChannelsPerFrame == 2 else { throw AudioMixError.format }
    let specification: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Chengguan Private Mix",
      kAudioAggregateDeviceUIDKey: "studio.lele.chengguan.mix." + UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    try check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate), "建立 App 混音输出")
    let aggregateInputs = AudioProperty.streams(aggregate, input: true)
    guard aggregateInputs.count == hardwareStreams + 1 else { throw AudioMixError.format }
    for stream in AudioProperty.streams(aggregate, input: false) {
      let outputFormat = try AudioProperty.format(stream, kAudioStreamPropertyVirtualFormat)
      guard abs(outputFormat.mSampleRate - format.mSampleRate) < 1 else { throw AudioMixError.format }
    }
    guard let dsp = vr_gain_create(Float(min(100, max(0, volume)) / 100), format.mSampleRate) else { throw AudioMixError.format }
    gain = dsp
    try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, output, _ in
      vr_gain_render(dsp, input, output, UInt32(hardwareBuffers))
    }, "建立混音处理器")
    // Disable physical input streams before starting: mixing never opens the microphone.
    try check(vr_audio_disable_hardware_inputs(aggregate, proc, UInt32(hardwareStreams)), "设置混音输入")
    try check(AudioDeviceStart(aggregate, proc), "启动 App 混音")
  }
  func setVolume(_ value: Double) { if let gain { vr_gain_set(gain, Float(min(100, max(0, value)) / 100)) } }
  var diagnostics: [String: Any] {
    guard let gain else { return ["callbacks": 0, "input_rms": 0, "output_rms": 0] }
    return ["callbacks": vr_gain_callbacks(gain), "input_rms": vr_gain_input_rms(gain), "output_rms": vr_gain_output_rms(gain)]
  }
  func stop() {
    if aggregate != 0 {
      if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
      proc = nil
      AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0
    }
    if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    if let gain { vr_gain_destroy(gain); self.gain = nil }
  }
  deinit { stop() }
}

final class AppAudioMixer: ObservableObject {
  static let shared = AppAudioMixer()
  @Published private(set) var volumes: [String: Double] = [:]
  @Published private(set) var pending: Set<String> = []
  @Published var error: String?
  private final class Worker { var sessions: [String: ProcessAudioGain] = [:] }
  private let worker = Worker()
  private let workQueue = DispatchQueue(label: "studio.lele.chengguan.audio-control", qos: .userInitiated)
  private var latestSnapshot: MonitorSnapshot?
  private var listener: AudioObjectPropertyListenerBlock?
  private var targets: [String: ([AudioObjectID], AudioObjectID)] = [:]
  private var revisions: [String: UInt64] = [:]
  private var nextRevision: UInt64 = 0
  private var beforeMute: [String: Double] = [:]
  private init() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, !self.targets.isEmpty, let snapshot = self.latestSnapshot else { return }
      self.reconcile(snapshot: snapshot)
    }
    listener = block
    for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
      var address = AudioProperty.address(selector)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
  }
  func reconcile(snapshot: MonitorSnapshot) {
    latestSnapshot = snapshot
    guard !targets.isEmpty else { return }
    let audio = Peripherals.shared
    audio.refreshAudio()
    reconcile(AudioAppRow.collect(audio.clients, snapshot: snapshot), output: audio.output)
  }
  func volume(_ id: String) -> Double { volumes[id] ?? 100 }
  func toggleMute(id: String, objects: [AudioObjectID], output: AudioObjectID) {
    let current = volume(id)
    if current > 0 { beforeMute[id] = current }
    setVolume(current == 0 ? beforeMute[id] ?? 100 : 0, id: id, objects: objects, output: output)
  }
  func setVolume(_ value: Double, id: String, objects: [AudioObjectID], output: AudioObjectID) {
    let value = min(100, max(0, value))
    nextRevision &+= 1
    let revision = nextRevision
    revisions[id] = revision
    volumes[id] = value
    if value >= 99.95 { targets.removeValue(forKey: id) }
    else { targets[id] = (objects.sorted(), output) }
    pending.insert(id); error = nil
    // HAL may wait on system authorization. Never block SwiftUI's main thread.
    workQueue.async { [weak self, worker] in
      var failure: String?
      do {
        if value >= 99.95 { worker.sessions.removeValue(forKey: id)?.stop() }
        else if let session = worker.sessions[id], session.objects == objects.sorted(), session.output == output { session.setVolume(value) }
        else {
          worker.sessions.removeValue(forKey: id)?.stop()
          worker.sessions[id] = try ProcessAudioGain(objects: objects, output: output, volume: value)
        }
      } catch { worker.sessions.removeValue(forKey: id)?.stop(); failure = error.localizedDescription }
      DispatchQueue.main.async {
        guard let self, self.revisions[id] == revision else { return }
        self.pending.remove(id)
        if let failure { self.volumes[id] = 100; self.targets.removeValue(forKey: id); self.error = failure }
      }
    }
  }
  func reconcile(_ rows: [AudioAppRow], output: AudioObjectID) {
    for id in Array(targets.keys) {
      guard let row = rows.first(where: { $0.id == id }) else { setVolume(100, id: id, objects: [], output: output); continue }
      if row.objects.sorted() != targets[id]?.0 || output != targets[id]?.1 {
        setVolume(volume(id), id: id, objects: row.objects, output: output)
      }
    }
  }
  func reset() {
    for id in Set(volumes.keys).union(targets.keys) { setVolume(100, id: id, objects: [], output: 0) }
    beforeMute.removeAll()
  }
}

struct AppVolumeControl: View {
  let row: AudioAppRow
  let output: AudioObjectID
  @ObservedObject private var mixer = AppAudioMixer.shared
  @State private var value: Double = 100
  @State private var editing = false
  var body: some View {
    HStack(spacing: 10) {
      Button {
        mixer.toggleMute(id: row.id, objects: row.objects, output: output)
        value = mixer.volume(row.id)
      } label: {
        Image(systemName: mixer.volume(row.id) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundStyle(.secondary)
      }.buttonStyle(.plain).help(mixer.volume(row.id) == 0 ? "取消静音" : "静音")
      Slider(value: $value, in: 0...100, onEditingChanged: { active in
        editing = active
        if !active { mixer.setVolume(value, id: row.id, objects: row.objects, output: output); value = mixer.volume(row.id) }
      }).tint(MonitorTab.sound.color).onChange(of: value) { _, v in
        // Once the route exists, adjust its DSP target continuously during dragging.
        if editing, mixer.volume(row.id) < 100 { mixer.setVolume(v, id: row.id, objects: row.objects, output: output) }
      }
      Group {
        if mixer.pending.contains(row.id) { ProgressView().controlSize(.mini).help("正在建立 App 混音，可能需要系统音频授权") }
        else { Text(String(format: "%.0f%%", value)).font(Theme.number(12)) }
      }.frame(width: 44, alignment: .trailing)
    }.onAppear { value = mixer.volume(row.id) }.onChange(of: mixer.volume(row.id)) { _, v in if !editing { value = v } }
  }
}
