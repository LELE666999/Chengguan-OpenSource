import AppKit
import Combine
import CoreGraphics

struct DisplayModeMemory: Codable, Equatable, Sendable {
  var uuid: String
  var name: String
  var mode: DisplayModeChoice
  var enabled = true
  var updated: Date
}

@MainActor protocol DisplayModeMemorySystem {
  func read() -> [DisplayDevice]
  func usable(_ device: DisplayDevice) -> Bool
  func apply(_ mode: DisplayModeChoice, to device: DisplayDevice) -> Bool
}

struct MacDisplayModeMemorySystem: DisplayModeMemorySystem {
  func read() -> [DisplayDevice] { DisplayReader.read() }
  func usable(_ device: DisplayDevice) -> Bool {
    !device.virtual && device.mirror == 0 && CGDisplayIsActive(device.displayID) != 0 && CGDisplayIsAsleep(device.displayID) == 0
  }
  func apply(_ mode: DisplayModeChoice, to device: DisplayDevice) -> Bool {
    guard let current = DisplayReader.matching(device), usable(current),
          let cgMode = DisplayReader.cgMode(mode, display: current.displayID) else { return false }
    return CGDisplaySetDisplayMode(current.displayID, cgMode, nil) == .success
  }
}

/// Remembers confirmed modes, not the temporary modes reported while a link wakes.
/// Recovery is bounded to one short lifecycle window and two writes per display.
@MainActor final class DisplayModeMemoryController: ObservableObject {
  @Published private(set) var profiles: [String: DisplayModeMemory] = [:]
  @Published private(set) var status: [String: String] = [:]
  private let defaults: UserDefaults
  private let system: any DisplayModeMemorySystem
  private var task: Task<Void, Never>?
  private var learning: Task<Void, Never>?
  private var deadline: Date?
  private var samples: [String: String] = [:]
  private var attempts: [String: Int] = [:]
  private var lastWrite: [String: Date] = [:]
  private var manual = Set<String>()
  private var skipped = Set<String>()
  private var sleeping = false
  private var controlEnabled: Bool
  private var quietUntil = Date.distantPast
  private(set) var recovering = false
  static let storageKey = "displayRememberedModes.v1"

  init(defaults: UserDefaults = .standard, system: (any DisplayModeMemorySystem)? = nil) {
    self.defaults = defaults; self.system = system ?? MacDisplayModeMemorySystem()
    controlEnabled = defaults.object(forKey: "displayControlEnabled") as? Bool ?? true
    if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode([String: DisplayModeMemory].self, from: data) {
      profiles = saved.filter { $0.key == $0.value.uuid && Self.valid($0.value.mode) }
    }
  }
  private static func valid(_ mode: DisplayModeChoice) -> Bool {
    mode.width >= 640 && mode.height >= 480 && mode.pixelWidth >= mode.width && mode.pixelHeight >= mode.height && mode.pixelWidth <= 65536 && mode.pixelHeight <= 65536 && mode.refresh.isFinite && (0...1000).contains(mode.refresh)
  }
  func seed(_ devices: [DisplayDevice]) {
    for device in devices where profiles[device.id] == nil && !manual.contains(device.id) {
      remember(device)
    }
  }
  func remember(_ device: DisplayDevice) {
    guard controlEnabled, !manual.contains(device.id), system.usable(device), let mode = device.current, Self.valid(mode) else { return }
    let enabled = profiles[device.id]?.enabled ?? true
    profiles[device.id] = .init(uuid: device.id, name: device.name, mode: mode, enabled: enabled, updated: Date())
    status.removeValue(forKey: device.id); persist()
  }
  func setEnabled(_ enabled: Bool, on device: DisplayDevice) {
    if enabled { remember(device) }
    guard profiles[device.id] != nil else { return }
    profiles[device.id]?.enabled = enabled; status.removeValue(forKey: device.id)
    skipped.insert(device.id); persist()
  }
  func beginManualChange(_ uuid: String) {
    manual.insert(uuid); skipped.insert(uuid); learning?.cancel()
  }
  func endManualChange(_ device: DisplayDevice?, uuid: String, keep: Bool) {
    manual.remove(uuid)
    if keep, let device { remember(device) }
    quietUntil = Date().addingTimeInterval(3)
  }
  func pause() {
    sleeping = true; task?.cancel(); task = nil; learning?.cancel(); deadline = nil; recovering = false
  }
  func setControlEnabled(_ value: Bool) { controlEnabled = value; if !value { pause() } }
  func resume(schedule: Bool = true, now: Date = Date()) {
    guard controlEnabled else { return }
    sleeping = false; learning?.cancel()
    // Several notifications describe one wake. Do not reset the retry budget.
    if deadline == nil || now >= deadline! {
      task?.cancel(); task = nil
      deadline = now.addingTimeInterval(18); samples = [:]; attempts = [:]; lastWrite = [:]; skipped = manual
    }
    recovering = true
    guard schedule, task == nil else { return }
    task = Task { @MainActor [weak self] in
      for _ in 0..<18 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        self.tick()
        if !self.recovering { break }
      }
      guard !Task.isCancelled else { return }
      self?.finishRecovery()
    }
  }
  /// Wait for two matching snapshots and for the exact saved timing to reappear.
  /// A mode ID or a nearby resolution is never a substitute for the saved mode.
  func tick(now: Date = Date()) {
    guard controlEnabled, !sleeping, let deadline else { return }
    guard now < deadline else { finishRecovery(); return }
    let devices = system.read()
    for device in devices where system.usable(device) && !manual.contains(device.id) && !skipped.contains(device.id) {
      guard let current = device.current else { continue }
      let previous = samples.updateValue(current.signature, forKey: device.id)
      guard previous == current.signature else { continue }
      guard let profile = profiles[device.id] else { remember(device); continue }
      guard profile.enabled else { continue }
      if current.signature == profile.mode.signature {
        if attempts[device.id, default: 0] > 0 { status[device.id] = "已自动恢复" }
        continue
      }
      guard attempts[device.id, default: 0] < 2,
            now.timeIntervalSince(lastWrite[device.id] ?? .distantPast) >= 2 else { continue }
      guard let target = DisplayRules.restoredMode(profile.mode, available: device.modes) else {
        status[device.id] = "等待已记住的模式"; continue
      }
      attempts[device.id, default: 0] += 1; lastWrite[device.id] = now
      status[device.id] = system.apply(target, to: device) ? "正在恢复" : "恢复未完成"
      samples.removeValue(forKey: device.id)
    }
  }
  func finishRecovery() {
    let devices = system.read()
    for device in devices where profiles[device.id]?.enabled == true && !skipped.contains(device.id) && system.usable(device) {
      if let saved = profiles[device.id], device.current?.signature != saved.mode.signature {
        status[device.id] = "模式暂不可用 · 可重试"
      }
    }
    deadline = nil; recovering = false; task = nil; quietUntil = Date().addingTimeInterval(2)
  }
  func restoreNow(_ device: DisplayDevice) {
    guard controlEnabled, !manual.contains(device.id), system.usable(device), let profile = profiles[device.id], profile.enabled else { return }
    if device.current?.signature == profile.mode.signature { status[device.id] = "已是记住的模式"; return }
    guard let target = DisplayRules.restoredMode(profile.mode, available: device.modes) else { status[device.id] = "已记住的模式暂不可用"; return }
    status[device.id] = system.apply(target, to: device) ? "正在恢复" : "恢复未完成"
    resume()
  }
  /// An explicit mode change in System Settings becomes the new preference only
  /// outside sleep/reconnect recovery and after it has stopped changing.
  func learnStableSystemChange() {
    guard !sleeping, !recovering, Date() >= quietUntil else { return }
    learning?.cancel()
    let before = system.read()
    learning = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self, !self.sleeping, !self.recovering, Date() >= self.quietUntil else { return }
      for device in self.system.read() where !self.manual.contains(device.id) {
        guard before.first(where: { $0.id == device.id })?.current?.signature == device.current?.signature else { continue }
        self.remember(device)
      }
    }
  }
  private func persist() { defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.storageKey) }
}
