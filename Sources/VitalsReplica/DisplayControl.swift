import AppKit
import ColorSync
import Combine
import CoreGraphics
import DisplayBridge

struct DisplayScene: Identifiable, Codable, Equatable {
  var id = UUID()
  var name: String, displayUUID: String
  var mode: DisplayModeChoice?
  var brightness: Double?, volume: Double?
  var color: DisplayColorAdjustment
  var audioOutputUID: String? = nil
}
struct DisplayColorAdjustment: Codable, Equatable {
  var brightness = 1.0, gamma = 1.0, red = 1.0, green = 1.0, blue = 1.0
  static let identity = DisplayColorAdjustment()
}
struct DisplayModeRecovery: Codable {
  var uuid: String
  var original: DisplayModeChoice
}
struct DisplayModeConfirmation {
  var recovery: DisplayModeRecovery
  var expires: Date
  var seconds: Int { max(0, Int(ceil(expires.timeIntervalSinceNow))) }
}
private struct DisplayGammaTable { var red: [Float], green: [Float], blue: [Float] }

/// A queued compatibility command must not start after the user turns control off.
final class DisplayAccessGate: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = true, revision = 0
  func setEnabled(_ value: Bool) { lock.lock(); defer { lock.unlock() }; enabled = value; revision += 1 }
  func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return revision }
  func permits(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return enabled && revision == ticket }
}

@MainActor final class DisplayControlStore: ObservableObject {
  static let shared = DisplayControlStore()
  @Published private(set) var displays: [DisplayDevice] = []
  @Published private(set) var hardware: [String: DisplayHardwareState] = [:]
  @Published private(set) var loading = false
  @Published private(set) var busy = false
  @Published var error: String?
  @Published var message: String?
  @Published private(set) var pendingMode: DisplayModeConfirmation?
  @Published private(set) var scenes: [DisplayScene] = []
  @Published private(set) var colors: [String: DisplayColorAdjustment] = [:]
  let modeMemory: DisplayModeMemoryController
  @Published var selected: String?
  @Published private(set) var enabled: Bool
  @Published var bridgeEnabled: Bool {
    didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "displayAdvancedBridge") }
  }
  private var timer: Timer?, confirmationTimer: Timer?
  private let queue = DispatchQueue(label: "studio.lele.Chengguan.displays", qos: .userInitiated)
  private var writes: [String: DispatchWorkItem] = [:]
  private var writeLedger = DisplayWriteLedger()
  private var refreshAgain = false
  private var gammaTables: [String: DisplayGammaTable] = [:]
  private var observers: [NSObjectProtocol] = []
  private var generation = 0
  private var controlRevision = 0
  private let access = DisplayAccessGate()
  private var monitoring = false
  private let defaults: UserDefaults
  var current: DisplayDevice? { displays.first { $0.id == selected } ?? displays.first }
  var bridgeAvailable: Bool { BetterDisplayIntegration.executable != nil }
  private init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.object(forKey: "displayControlEnabled") as? Bool ?? true
    modeMemory = DisplayModeMemoryController(defaults: defaults)
    bridgeEnabled = defaults.bool(forKey: "displayAdvancedBridge")
    access.setEnabled(enabled)
    if let data = defaults.data(forKey: "displayScenes"), let decoded = try? JSONDecoder().decode([DisplayScene].self, from: data) { scenes = decoded }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        self.restoreOwnedColors()
        if let recovery = self.pendingMode?.recovery { _ = self.restoreMode(recovery) }
      }
    })
    if enabled { startMonitoring() }
  }
  func setEnabled(_ value: Bool) {
    guard enabled != value else { return }
    controlRevision += 1
    access.setEnabled(value)
    enabled = value; defaults.set(value, forKey: "displayControlEnabled")
    modeMemory.setControlEnabled(value)
    if value { startMonitoring() }
    else {
      modeMemory.pause()
      for item in writes.values { item.cancel() }; writes = [:]
      generation += 1; refreshAgain = false; loading = false; busy = false
      timer?.invalidate(); timer = nil
      if monitoring { CGDisplayRemoveReconfigurationCallback(chengguanDisplayReconfigured, nil) }
      monitoring = false
      // Undo only unconfirmed display changes and color tables owned by this app.
      if pendingMode != nil { revertMode() }
      restoreOwnedColors()
      displays = []; hardware = [:]; error = nil; message = nil
    }
    DisplayAudioStore.shared.setEnabled(value)
  }
  private func startMonitoring() {
    guard enabled, !monitoring else { return }; monitoring = true
    CGDisplayRegisterReconfigurationCallback(chengguanDisplayReconfigured, nil)
    // Workspace observers are installed once; their callbacks honor the master switch.
    if observers.count == 1 {
    for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { _ in
        Task { @MainActor in guard self.enabled else { return }; self.modeMemory.resume(); self.refresh() }
      })
    }
    for notification in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { _ in
        Task { @MainActor in self.modeMemory.pause() }
      })
    }
    }
    recoverInterruptedMode()
    refresh()
    if let data = defaults.data(forKey: "displayPendingRecovery"), let recovery = try? JSONDecoder().decode(DisplayModeRecovery.self, from: data) {
      modeMemory.beginManualChange(recovery.uuid)
    }
    modeMemory.seed(displays)
    modeMemory.resume()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in self.refresh() } }
  }
  func reconfigured(_ flags: CGDisplayChangeSummaryFlags) {
    guard enabled else { return }
    refresh()
    let topology: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .unMirrorFlag]
    if !flags.intersection(topology).isEmpty { modeMemory.resume() }
    else if flags.contains(.setModeFlag) { modeMemory.learnStableSystemChange() }
  }
  func refresh() {
    guard enabled else { return }
    displays = DisplayReader.read()
    if selected == nil || !displays.contains(where: { $0.id == selected }) { selected = displays.first?.id }
    let connected = Set(displays.map(\.id))
    hardware = hardware.filter { connected.contains($0.key) }
    guard !loading else { refreshAgain = true; return }
    generation += 1; let ticket = generation
    loading = true
    let targets = displays
    let sentBeforeRead = writeLedger.sent
    queue.async {
      var result: [String: DisplayHardwareState] = [:]
      for d in targets where !d.virtual {
        var state = DisplayHardwareState(checked: true)
        var native: Float = 0
        if cd_native_brightness(d.displayID, &native) == 0 && native.isFinite && native >= 0 && native <= 1 { state.nativeBrightness = Double(native) * 100 }
        for code: UInt8 in [0x10, 0x62] where code != 0x10 || state.nativeBrightness == nil {
          var value: UInt16 = 0, maximum: UInt16 = 0
          if cd_ddc_read(d.displayID, d.id, code, &value, &maximum) == 0, maximum > 0, value <= maximum { state.values[code] = .init(value: value, maximum: maximum) }
        }
        result[d.id] = state
      }
      DispatchQueue.main.async {
        guard ticket == self.generation else { return }
        let active = Set(self.displays.map(\.id))
        for (id, var state) in result where active.contains(id) {
          let old = self.hardware[id]
          if !self.writeLedger.acceptSample(id + ":16", snapshot: sentBeforeRead) {
            state.nativeBrightness = old?.nativeBrightness
            state.values[0x10] = old?.values[0x10]
          }
          if !self.writeLedger.acceptSample(id + ":98", snapshot: sentBeforeRead) { state.values[0x62] = old?.values[0x62] }
          // Retain explicitly probed RGB/contrast values until the next detailed probe.
          for (code, value) in self.hardware[id]?.values ?? [:] where ![UInt8(0x10), 0x62].contains(code) { state.values[code] = value }
          self.hardware[id] = state
        }
        self.loading = false
        if self.refreshAgain { self.refreshAgain = false; self.refresh() }
      }
    }
  }
  func probeDetails(_ device: DisplayDevice) {
    guard enabled, !busy else { return }; busy = true
    let ticket = controlRevision
    let sentBeforeRead = writeLedger.sent
    queue.async {
      var values: [UInt8: DisplayVCPValue] = [:]
      for code: UInt8 in [0x12, 0x16, 0x18, 0x1a, 0x6c, 0x6e, 0x70, 0x60, 0xd6, 0x8d] {
        var value: UInt16 = 0, maximum: UInt16 = 0
        if cd_ddc_read(device.displayID, device.id, code, &value, &maximum) == 0 { values[code] = .init(value: value, maximum: maximum) }
      }
      DispatchQueue.main.async {
        guard self.enabled, self.controlRevision == ticket else { return }
        if self.displays.contains(where: { $0.id == device.id }) {
          var state = self.hardware[device.id] ?? .init(checked: true)
          for (key, value) in values where self.writeLedger.acceptSample(device.id + ":\(key)", snapshot: sentBeforeRead) { state.values[key] = value }
          self.hardware[device.id] = state
          self.message = values.isEmpty ? "显示器未返回额外的 DDC 控制能力" : "已读取 \(values.count) 项硬件控制"
        }
        self.busy = false
      }
    }
  }
  func setBrightness(_ value: Double, on device: DisplayDevice) {
    guard enabled, value.isFinite else { return }
    if hardware[device.id]?.nativeBrightness != nil {
      hardware[device.id]?.nativeBrightness = min(100, max(0, value))
      scheduleWrite(key: device.id + ":16", device: device) { current in cd_set_native_brightness(current.displayID, Float(min(100, max(0, value)) / 100)) }
    } else { setPercent(value, code: 0x10, on: device) }
  }
  func setPercent(_ value: Double, code: UInt8, on device: DisplayDevice) {
    guard let maximum = hardware[device.id]?.values[code]?.maximum, let raw = DisplayRules.rawValue(percent: value, maximum: maximum) else { return }
    setVCP(raw, code: code, on: device)
  }
  func setVCP(_ value: UInt16, code: UInt8, on device: DisplayDevice) {
    if let previous = hardware[device.id]?.values[code] { hardware[device.id]?.values[code] = .init(value: value, maximum: previous.maximum) }
    scheduleWrite(key: device.id + ":\(code)", device: device) { current in cd_ddc_write(current.displayID, current.id, code, value) }
  }
  private func scheduleWrite(key: String, device: DisplayDevice, operation: @escaping @Sendable (DisplayDevice) -> Int32) {
    guard enabled else { return }
    writes[key]?.cancel()
    let revision = writeLedger.begin(key)
    let ticket = controlRevision
    let permission = access.ticket(), gate = access
    // Sliders preview locally; only their settled value reaches the serial I2C queue.
    let item = DispatchWorkItem {
      guard gate.permits(permission) else { return }
      let uuid = CGDisplayCreateUUIDFromDisplayID(device.displayID)?.takeRetainedValue()
      let valid = CGDisplayIsOnline(device.displayID) != 0 && uuid.map { (CFUUIDCreateString(nil, $0) as String).caseInsensitiveCompare(device.id) == .orderedSame } == true
      let result = valid ? operation(device) : -3
      DispatchQueue.main.async {
        guard self.enabled, self.controlRevision == ticket else { return }
        if result != 0 {
          guard self.writeLedger.fail(key, revision: revision) else { return }
          self.error = "显示器未确认这次调整（\(result)）。请检查 DDC/CI 或线缆连接。"
        } else {
          guard self.writeLedger.didSend(key, revision: revision) else { return }
        }
        self.refresh()
      }
    }
    writes[key] = item
    queue.asyncAfter(deadline: .now() + 0.18, execute: item)
  }
  func changeMode(_ choice: DisplayModeChoice, on device: DisplayDevice) {
    guard enabled, pendingMode == nil, let current = DisplayReader.matching(device), let original = current.current,
          original.signature != choice.signature, let cgMode = DisplayReader.cgMode(choice, display: current.displayID) else { return }
    let recovery = DisplayModeRecovery(uuid: current.id, original: original)
    modeMemory.beginManualChange(current.id)
    defaults.set(try? JSONEncoder().encode(recovery), forKey: "displayPendingRecovery")
    let status = CGDisplaySetDisplayMode(current.displayID, cgMode, nil)
    guard status == .success else {
      modeMemory.endManualChange(nil, uuid: current.id, keep: false)
      defaults.removeObject(forKey: "displayPendingRecovery"); error = "无法切换显示模式（\(status.rawValue)）"; return
    }
    pendingMode = DisplayModeConfirmation(recovery: recovery, expires: Date().addingTimeInterval(15))
    confirmationTimer?.invalidate()
    confirmationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      Task { @MainActor in
        guard let pending = self.pendingMode else { return }
        if pending.seconds == 0 { self.revertMode() } else { self.objectWillChange.send() }
      }
    }
    refresh()
  }
  func keepMode() {
    guard let uuid = pendingMode?.recovery.uuid else { return }
    modeMemory.endManualChange(DisplayReader.read().first { $0.id == uuid }, uuid: uuid, keep: true)
    confirmationTimer?.invalidate(); confirmationTimer = nil; pendingMode = nil
    defaults.removeObject(forKey: "displayPendingRecovery"); message = "已保留显示模式"
  }
  func revertMode() {
    guard let recovery = pendingMode?.recovery else { return }
    confirmationTimer?.invalidate(); confirmationTimer = nil; pendingMode = nil
    if restoreMode(recovery) {
      defaults.removeObject(forKey: "displayPendingRecovery"); message = "已恢复先前的显示模式"
    }
    modeMemory.endManualChange(nil, uuid: recovery.uuid, keep: false)
    refresh()
  }
  @discardableResult private func restoreMode(_ recovery: DisplayModeRecovery) -> Bool {
    guard let current = DisplayReader.read().first(where: { $0.id == recovery.uuid }),
          let choice = DisplayRules.restoredMode(recovery.original, available: current.modes),
          let mode = DisplayReader.cgMode(choice, display: current.displayID) else {
      error = "原显示器暂不可用，重新连接后可恢复先前模式"
      return false
    }
    let status = CGDisplaySetDisplayMode(current.displayID, mode, nil)
    if status != .success { error = "无法恢复显示模式，请在系统显示器设置中恢复（\(status.rawValue)）" }
    return status == .success
  }
  private func recoverInterruptedMode() {
    if let data = defaults.data(forKey: "displayPendingRecovery"), let recovery = try? JSONDecoder().decode(DisplayModeRecovery.self, from: data) {
      if restoreMode(recovery) { defaults.removeObject(forKey: "displayPendingRecovery") }
      refresh()
    }
  }
  func arrange(_ device: DisplayDevice, relativeTo other: DisplayDevice, side: String) {
    guard pendingMode == nil, let current = DisplayReader.matching(device), let target = DisplayReader.matching(other), current.id != target.id else { return }
    let a = CGDisplayBounds(current.displayID), b = CGDisplayBounds(target.displayID)
    let point: CGPoint
    switch side {
    case "左侧": point = CGPoint(x: b.minX - a.width, y: b.minY)
    case "上方": point = CGPoint(x: b.minX, y: b.minY - a.height)
    case "下方": point = CGPoint(x: b.minX, y: b.maxY)
    default: point = CGPoint(x: b.maxX, y: b.minY)
    }
    configure { CGConfigureDisplayOrigin($0, current.displayID, Int32(point.x), Int32(point.y)) }
  }
  func makeMain(_ device: DisplayDevice) {
    guard let current = DisplayReader.matching(device), !current.main else { return }
    let bounds = CGDisplayBounds(current.displayID)
    configure { config in
      for d in self.displays {
        let b = CGDisplayBounds(d.displayID)
        let status = CGConfigureDisplayOrigin(config, d.displayID, Int32(b.minX - bounds.minX), Int32(b.minY - bounds.minY))
        if status != .success { return status }
      }
      return .success
    }
  }
  func mirror(_ device: DisplayDevice, to target: DisplayDevice?) {
    guard let current = DisplayReader.matching(device), target == nil || DisplayReader.matching(target!) != nil else { return }
    configure { CGConfigureDisplayMirrorOfDisplay($0, current.displayID, target?.displayID ?? kCGNullDirectDisplay) }
  }
  private func configure(_ operation: (CGDisplayConfigRef?) -> CGError) {
    guard enabled else { return }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { error = "无法开始显示配置"; return }
    let result = operation(config)
    guard result == .success else { CGCancelDisplayConfiguration(config); error = "显示配置未通过（\(result.rawValue)）"; return }
    let status = CGCompleteDisplayConfiguration(config, .forSession)
    if status != .success { error = "显示配置未完成（\(status.rawValue)）" } else { message = "显示布局已更新" }
    refresh()
  }
  func identify(_ device: DisplayDevice) {
    guard enabled else { return }
    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == device.displayID }) else { return }
    DisplayIdentification.show(device.name, on: screen)
  }
  func adjustColor(_ adjustment: DisplayColorAdjustment, on device: DisplayDevice) {
    guard enabled else { return }
    guard [adjustment.brightness, adjustment.gamma, adjustment.red, adjustment.green, adjustment.blue].allSatisfy({ $0.isFinite }) else { return }
    guard let current = DisplayReader.matching(device) else { return }
    if gammaTables[current.id] == nil {
      let capacity = Int(CGDisplayGammaTableCapacity(current.displayID))
      guard capacity > 0 && capacity <= 65536 else { error = "此显示模式不提供可调色表"; return }
      var r = [Float](repeating: 0, count: capacity), g = r, b = r, count: UInt32 = 0
      guard CGGetDisplayTransferByTable(current.displayID, UInt32(capacity), &r, &g, &b, &count) == .success, count > 0 else { error = "无法读取当前色表"; return }
      gammaTables[current.id] = .init(red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
    }
    guard let original = gammaTables[current.id] else { return }
    func apply(_ values: [Float], gain: Double) -> [Float] {
      values.map { Float(min(1, max(0, pow(Double($0), 1 / min(3, max(0.2, adjustment.gamma))) * gain * min(1, max(0.1, adjustment.brightness))))) }
    }
    let r = apply(original.red, gain: adjustment.red), g = apply(original.green, gain: adjustment.green), b = apply(original.blue, gain: adjustment.blue)
    let status = CGSetDisplayTransferByTable(current.displayID, UInt32(r.count), r, g, b)
    if status == .success { colors[current.id] = adjustment } else { error = "色表调整未生效（\(status.rawValue)）" }
  }
  func resetColor(_ device: DisplayDevice) {
    if let original = gammaTables[device.id], let d = DisplayReader.matching(device) {
      let status = CGSetDisplayTransferByTable(d.displayID, UInt32(original.red.count), original.red, original.green, original.blue)
      guard status == .success else { error = "无法恢复原色表"; return }
    }
    gammaTables.removeValue(forKey: device.id); colors.removeValue(forKey: device.id)
  }
  private func restoreOwnedColors() { for d in displays where gammaTables[d.id] != nil { resetColor(d) } }
  func setProfile(_ url: URL, on device: DisplayDevice) {
    guard enabled else { return }
    guard let current = DisplayReader.matching(device), let uuid = CGDisplayCreateUUIDFromDisplayID(current.displayID)?.takeRetainedValue() else { return }
    guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
          let profileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue() else { return }
    let ok = ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, [profileKey as String: url] as CFDictionary)
    if ok { message = "颜色描述文件已更新" } else { error = "无法应用颜色描述文件，请确认它是有效的显示器 ICC 配置" }
  }
  func saveScene(name: String, for device: DisplayDevice) {
    let state = hardware[device.id]
    var scene = DisplayScene(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)), displayUUID: device.id,
      mode: device.current, brightness: state?.brightness, volume: state?.volume, color: colors[device.id] ?? .identity)
    let audio = DisplayAudioStore.shared
    if state?.volume == nil || audio.associations[device.id] != nil, let output = audio.output(for: device), output.writable {
      scene.audioOutputUID = output.id; scene.volume = output.volume
    }
    guard !scene.name.isEmpty else { return }; scenes.append(scene); persistScenes(); message = "已保存场景"
  }
  func deleteScene(_ scene: DisplayScene) { scenes.removeAll { $0.id == scene.id }; persistScenes() }
  private func persistScenes() { defaults.set(try? JSONEncoder().encode(scenes), forKey: "displayScenes") }
  func applyScene(_ scene: DisplayScene, on device: DisplayDevice) {
    guard enabled, scene.displayUUID == device.id else { return }
    if let b = scene.brightness { setBrightness(b, on: device) }
    if let v = scene.volume {
      if let uid = scene.audioOutputUID {
        let audio = DisplayAudioStore.shared; audio.refresh()
        if let output = audio.outputs.first(where: { $0.id == uid }) { audio.setVolume(v, output: output) }
      } else { setPercent(v, code: 0x62, on: device) }
    }
    if scene.color != .identity || gammaTables[device.id] != nil { adjustColor(scene.color, on: device) }
    if let mode = scene.mode, let available = device.modes.first(where: { $0.signature == mode.signature }) { changeMode(available, on: device) }
    message = "已应用「\(scene.name)」"
  }
  func bridge(_ operation: String = "get", device: DisplayDevice?, arguments: [String], completion: ((String) -> Void)? = nil) {
    guard enabled else { return }
    guard bridgeEnabled, let executable = BetterDisplayIntegration.executable else { error = "请先在高级中启用 BetterDisplay 兼容引擎"; return }
    guard !busy else { return }
    if let device, DisplayReader.matching(device) == nil { error = "显示器已断开"; return }
    busy = true
    let args = [operation] + (device.map { ["-UUID=\($0.id)"] } ?? []) + arguments
    let gate = access, permission = access.ticket(), ticket = controlRevision
    queue.async {
      guard gate.permits(permission) else { return }
      let result = Command.run(executable, args, timeout: 12, includeError: true)
      DispatchQueue.main.async {
        guard self.enabled, self.controlRevision == ticket else { return }
        self.busy = false
        if result.status == 0 {
          self.message = operation == "get" ? "已读取显示信息" : "显示操作已发送"
          completion?(result.text); self.refresh()
        } else { self.error = String(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)).nilIfEmpty ?? "高级引擎未响应。请确认 BetterDisplay 正在运行且具有对应功能授权。" }
      }
    }
  }
  func readBridge(_ parameter: String, device: DisplayDevice, completion: @escaping (String?, String?) -> Void) {
    guard enabled, bridgeEnabled, let executable = BetterDisplayIntegration.executable else { completion(nil, "兼容引擎未启用"); return }
    let gate = access, permission = access.ticket(), ticket = controlRevision
    queue.async {
      guard gate.permits(permission) else { return }
      let result = Command.run(executable, ["get", "-UUID=\(device.id)", "-\(parameter)"], timeout: 8, includeError: true)
      DispatchQueue.main.async {
        guard self.enabled, self.controlRevision == ticket, self.displays.contains(where: { $0.id == device.id }) else { return }
        if result.status == 0 { completion(result.text.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        else { completion(nil, "此控制当前不可用") }
      }
    }
  }
  func openSystemSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private func chengguanDisplayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ user: UnsafeMutableRawPointer?) {
  guard !flags.contains(.beginConfigurationFlag) else { return }
  DispatchQueue.main.async { DisplayControlStore.shared.reconfigured(flags) }
}
enum BetterDisplayIntegration {
  static var executable: String? {
    let path = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }
}
@MainActor private enum DisplayIdentification {
  static var windows: [NSWindow] = []
  static func show(_ name: String, on screen: NSScreen) {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 105), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.ignoresMouseEvents = true
    let visual = NSVisualEffectView(frame: panel.contentView!.bounds); visual.material = .hudWindow; visual.state = .active; visual.wantsLayer = true; visual.layer?.cornerRadius = 22
    let label = NSTextField(labelWithString: name); label.font = .systemFont(ofSize: 23, weight: .semibold); label.alignment = .center; label.frame = NSRect(x: 15, y: 38, width: 310, height: 30)
    visual.addSubview(label); panel.contentView = visual
    panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 170, y: screen.frame.midY - 52)); panel.orderFrontRegardless(); windows.append(panel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { panel.orderOut(nil); windows.removeAll { $0 === panel } }
  }
}
