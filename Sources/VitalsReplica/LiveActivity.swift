import AppKit
import AVFoundation
import Combine
import IOKit.pwr_mgt
import SwiftUI

struct DeviceActivity: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let active: Bool
}

@MainActor final class LiveActivity: ObservableObject {
  static let shared = LiveActivity()
  @Published private(set) var activities: [DeviceActivity] = []
  @Published private(set) var changes: [AIQuickMessage] = []
  @Published private(set) var awakeUntil: Date?
  @Published private(set) var error: String?
  var onChange: (() -> Void)?
  private var assertion: IOPMAssertionID = 0
  private var timer: AnyCancellable?
  private var cameras: [String] = []
  private var checkedCamera = false
  private var cameraCount = 0
  private var cameraChecking = false
  private var lastCamera = Date.distantPast
  private var initialized = false
  private var screenWindows: [NSWindow] = []
  private weak var model: MonitorModel?
  func start(model: MonitorModel) {
    self.model = model
    guard timer == nil else { return }
    timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    refresh()
  }
  func refresh() {
    if let until = awakeUntil, Date() >= until { stopAwake() }
    Peripherals.shared.refreshAudio()
    if !cameraChecking && Date().timeIntervalSince(lastCamera) >= 9 {
      cameraChecking = true; lastCamera = Date()
      Task {
        let result = await Task.detached(priority: .utility) {
          let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
          return (devices.filter(\.isInUseByAnotherApplication).map(\.localizedName), devices.count)
        }.value
        cameras = result.0; cameraCount = result.1; checkedCamera = true; cameraChecking = false
        updateActivities()
      }
    }
    updateActivities()
  }
  private func updateActivities() {
    let audio = Peripherals.shared
    let own = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications
    func names(_ clients: [AudioClient]) -> String {
      let labels: [String] = clients.map { client in
        if let name = apps.first(where: { $0.processIdentifier == client.pid })?.localizedName { return name }
        if let group = model?.snapshot.groups.first(where: { group in group.processes.contains { $0.pid == client.pid } }) { return group.name }
        if let name = NSRunningApplication(processIdentifier: client.pid)?.localizedName { return name }
        return model?.snapshot.processes.first(where: { $0.pid == client.pid })?.name ?? "进程 \(client.pid)"
      }
      return Array(Set(labels)).sorted().joined(separator: "、")
    }
    let recording = audio.clients.filter { $0.recording && $0.pid != own }
    let playing = audio.clients.filter { $0.playing && $0.pid != own }
    let next = [
      DeviceActivity(id: "microphone", title: recording.isEmpty ? "麦克风" : "麦克风使用中", detail: audio.audioActivityAvailable ? recording.isEmpty ? "未检测到录音" : names(recording) : "状态暂不可读", symbol: "mic.fill", active: !recording.isEmpty),
      DeviceActivity(id: "camera", title: cameras.isEmpty ? "摄像头" : "摄像头使用中", detail: checkedCamera ? cameraCount == 0 ? "未发现可读取的设备" : cameras.isEmpty ? "未检测到占用" : cameras.joined(separator: "、") : "正在检查", symbol: "camera.fill", active: !cameras.isEmpty),
      DeviceActivity(id: "audio", title: playing.isEmpty ? "音频" : "音频输出使用中", detail: audio.audioActivityAvailable ? playing.isEmpty ? "未检测到音频输出" : names(playing) : "状态暂不可读", symbol: "speaker.wave.2.fill", active: !playing.isEmpty)
    ]
    if initialized {
      for item in next {
        guard let old = activities.first(where: { $0.id == item.id }), old.active != item.active || (item.active && old.detail != item.detail) else { continue }
        changes.insert(AIQuickMessage(id: UUID().uuidString, time: Date(), title: item.active ? item.title : item.id == "microphone" ? "录音已停止" : item.id == "camera" ? "摄像头占用已结束" : "音频播放已停止", detail: item.active ? item.detail : old.detail, symbol: item.symbol), at: 0)
      }
      changes = Array(changes.prefix(20))
    }
    activities = next; initialized = initialized || checkedCamera
    onChange?()
  }
  func keepAwake(minutes: Int) {
    stopAwake()
    error = nil
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), "澄观 · 临时保持常亮" as CFString, &id)
    guard result == kIOReturnSuccess else { error = "无法开启常亮（\(result)）"; return }
    assertion = id; awakeUntil = Date().addingTimeInterval(Double(max(1, min(240, minutes))) * 60)
  }
  func stopAwake() {
    if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    awakeUntil = nil
  }
  func end() { stopAwake(); closeScreen(); timer?.cancel(); timer = nil }
  func cleanScreen() {
    guard screenWindows.isEmpty else { return }
    for screen in NSScreen.screens {
      let window = ScreenCleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.level = .screenSaver; window.backgroundColor = .black; window.isReleasedWhenClosed = false
      let view = ScreenCleaningView(frame: CGRect(origin: .zero, size: screen.frame.size))
      view.finish = { [weak self] in self?.closeScreen() }; window.contentView = view
      window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); screenWindows.append(window)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.closeScreen() }
  }
  private func closeScreen() { for window in screenWindows { window.close() }; screenWindows.removeAll() }
}
private final class ScreenCleaningWindow: NSWindow { override var canBecomeKey: Bool { true } }
private final class ScreenCleaningView: NSView {
  var finish: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) { if event.keyCode == 53 { finish?() } }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.setFill(); bounds.fill()
    let text = "清洁屏幕 · 按 Esc 退出 · 30 秒后自动结束"
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.gray]
    let width = text.size(withAttributes: attributes).width
    text.draw(at: NSPoint(x: (bounds.width - width) / 2, y: 50), withAttributes: attributes)
  }
}

@MainActor struct LiveActivityPanel: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var activity = LiveActivity.shared
  var compact = false
  var showActivities = true
  var showTools = true
  var body: some View {
    VStack(spacing: compact ? 7 : 12) {
      if showActivities {
      ForEach(activity.activities.filter { !compact || $0.active }) { item in
        Button {
          if item.id == "camera" {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
          } else { model.select(.sound); model.onShowMain?() }
        } label: {
          HStack(spacing: 9) {
            Image(systemName: item.symbol).foregroundStyle(item.active ? (item.id == "microphone" ? Color.orange : Theme.accent) : .secondary).frame(width: 16)
            Text(item.title).fontWeight(.medium)
            Spacer(minLength: 8)
            Text(item.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }.font(.system(size: compact ? 11 : 12)).padding(compact ? 6 : 10).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(CareRowStyle())
      }
      }
      if showTools {
      HStack(spacing: 8) {
        if let until = activity.awakeUntil {
          Button { activity.stopAwake() } label: { Label("常亮至 " + until.formatted(date: .omitted, time: .shortened), systemImage: "sun.max.fill") }
        } else {
          Menu { ForEach([15, 30, 60, 120], id: \.self) { value in Button("\(value) 分钟") { activity.keepAwake(minutes: value) } } }
            label: { Label("常亮", systemImage: "sun.max") }.menuStyle(.borderlessButton).fixedSize()
        }
        Button { activity.cleanScreen() } label: { Label("清洁屏幕", systemImage: "display") }
        Spacer(minLength: 0)
        if compact { Button { model.presentCare(.clean) } label: { Label("整理", systemImage: "sparkles.rectangle.stack") } }
      }.font(.system(size: 11)).buttonStyle(AIControlButtonStyle(compact: true))
      }
      if let error = activity.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
    }
  }
}

/// Apply to a whole label, including its padding; never nest controls inside the label.
struct CareRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { CareRowSurface(label: configuration.label, pressed: configuration.isPressed) }
}
private struct CareRowSurface<L: View>: View {
  let label: L
  let pressed: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    label.background(Color.primary.opacity(pressed ? 0.10 : hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
      .contentShape(RoundedRectangle(cornerRadius: 12)).opacity(enabled ? 1 : 0.45)
      .scaleEffect(pressed ? 0.995 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
      .onHover { hovered = $0 }
  }
}
