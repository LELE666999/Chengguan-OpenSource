import AppKit
import SwiftUI
import Combine

@MainActor final class StorageFormatStore: ObservableObject {
  enum Phase { case checking, ready, blocked, formatting, complete, failed }
  static let shared = StorageFormatStore()
  @Published private(set) var volume: ExternalVolume?
  @Published private(set) var proof: StorageEraseProof?
  @Published private(set) var phase: Phase = .checking
  @Published private(set) var message = "正在检查存储…"
  private var generation = UUID()
  private let inspector: @Sendable (ExternalVolume) throws -> StorageEraseProof
  private let eraser: @Sendable (StorageEraseRequest) throws -> Void
  var running: Bool { phase == .formatting }
  init(inspector: @escaping @Sendable (ExternalVolume) throws -> StorageEraseProof = { try StorageEraseEngine.inspect($0) },
       eraser: @escaping @Sendable (StorageEraseRequest) throws -> Void = { try StorageEraseEngine.erase($0) }) {
    self.inspector = inspector; self.eraser = eraser
  }
  func prepare(_ volume: ExternalVolume) async {
    guard !running else { return }
    let token = UUID(); generation = token; self.volume = volume; proof = nil; phase = .checking; message = "正在检查存储…"
    let inspect = inspector
    do {
      let value = try await Task.detached(priority: .userInitiated) { try inspect(volume) }.value
      guard generation == token else { return }
      proof = value; phase = .ready; message = "只格式化当前卷，保留其他分区。"
    } catch {
      guard generation == token else { return }
      phase = .blocked; message = error.localizedDescription
    }
  }
  func request(format: StorageEraseFormat, name: String) throws -> StorageEraseRequest {
    guard phase == .ready, let proof else { throw StorageEraseError.message("请先完成设备检查。") }
    let request = StorageEraseRequest(proof: proof, format: format, name: name)
    try StorageErasePolicy.validate(request)
    return request
  }
  func checkConnection(_ volumes: [ExternalVolume]) {
    guard phase == .ready, let volume, !volumes.contains(where: { $0.id == volume.id && $0.path == volume.path }) else { return }
    proof = nil; phase = .blocked; message = "存储已移除或连接已变化。请重新连接后打开格式化。"
  }
  func erase(_ request: StorageEraseRequest) async {
    guard phase == .ready, let proof, proof.matches(request.proof) else { return }
    guard !StorageSpeedStore.shared.running, !ExternalStorageMonitor.shared.busy.contains(request.proof.volume.id) else {
      message = "请先停止测速或等待当前存储操作完成。"; return
    }
    do { try StorageErasePolicy.validate(request) } catch { message = error.localizedDescription; return }
    // Set synchronously before leaving the main actor, so eject and benchmark cannot race this operation.
    phase = .formatting; message = "正在格式化，请保持连接。完成前无法关闭此窗口。"
    let erase = eraser
    ExternalStorageMonitor.shared.formatMessage(request.proof.volume, title: "正在格式化 " + request.proof.volume.name, detail: request.format.title)
    do {
      try await Task.detached(priority: .userInitiated) { try erase(request) }.value
      phase = .complete; message = "「" + request.name + "」已格式化为 " + request.format.title + "。"
      ExternalStorageMonitor.shared.formatMessage(request.proof.volume, title: request.name + " 格式化完成", detail: request.format.title + " · 正在刷新存储")
    } catch {
      phase = .failed; message = error.localizedDescription
      ExternalStorageMonitor.shared.formatMessage(request.proof.volume, title: request.proof.volume.name + " 格式化未完成", detail: "请查看格式化窗口")
    }
    ExternalStorageMonitor.shared.refresh(urgent: true)
  }
}

/// Opens a persistent window from both the menu popover and the main app.
@MainActor enum StorageFormatWindow {
  private static var window: NSWindow?
  private static let delegate = StorageFormatWindowDelegate()
  static func show(_ volume: ExternalVolume) {
    if StorageFormatStore.shared.running { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    if window == nil {
      let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      value.title = "格式化"; value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
      value.isReleasedWhenClosed = false; value.delegate = delegate; value.center(); window = value
    }
    window?.contentViewController = NSHostingController(rootView: StorageFormatView(volume: volume))
    window?.contentMinSize = NSSize(width: 520, height: 600); window?.setContentSize(NSSize(width: 520, height: 600))
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  static func close() { window?.performClose(nil) }
}
private final class StorageFormatWindowDelegate: NSObject, NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if StorageFormatStore.shared.running { NSSound.beep(); return false }
    return true
  }
}

struct StorageFormatButton: View {
  let volume: ExternalVolume
  @ObservedObject private var format = StorageFormatStore.shared
  @ObservedObject private var speed = StorageSpeedStore.shared
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  var body: some View {
    Button { StorageFormatWindow.show(volume) } label: {
      Label("格式化", systemImage: "externaldrive.badge.xmark")
        .padding(.horizontal, 11).frame(height: 32)
    }.buttonStyle(StorageActionButtonStyle()).font(.system(size: 11, weight: .medium))
      .disabled(speed.running || format.running || storage.busy.contains(volume.id))
      .accessibilityLabel("格式化存储 " + volume.name)
  }
}

@MainActor struct StorageFormatView: View {
  let volume: ExternalVolume
  @ObservedObject var store = StorageFormatStore.shared
  @AppStorage("appearance") private var appearance = "auto"
  @State private var name = "Untitled"
  @State private var selected: StorageEraseFormat = .exfat
  @State private var confirmation: StorageEraseRequest?
  @State private var validation: String?
  init(volume: ExternalVolume, store: StorageFormatStore? = nil) {
    self.volume = volume; self.store = store ?? .shared
    _name = State(initialValue: (try? StorageEraseFormat.exfat.validate(name: volume.name)) != nil ? volume.name : "Untitled")
  }
  private var locked: Bool { store.phase != .ready }
  var body: some View {
    content.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
      .task { await store.prepare(volume) }
      .onReceive(ExternalStorageMonitor.shared.$volumes) { store.checkConnection($0) }
      .onChange(of: name) { _, _ in validation = nil }
      .alert("格式化「" + volume.name + "」？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
        Button("取消", role: .cancel) { confirmation = nil }
        Button("抹掉并格式化", role: .destructive) {
          confirmation = nil
          Task { await store.erase(request) }
        }
      } message: { request in
        Text("「\(volume.name)」当前卷中的所有文件都将被清除，无法撤销。请确认已备份。\n\n新名称：\(request.name)\n新格式：\(request.format.title)\n设备：\(volume.bsdName)\n\n只处理当前卷，不重新分区。")
      }
  }
  var content: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("格式化").font(.system(size: 23, weight: .semibold))
        Spacer()
        if store.running { ProgressView().controlSize(.small) }
      }.frame(height: 32)
      HStack(spacing: 12) {
        Image(systemName: volume.symbol).font(.system(size: 24)).foregroundStyle(Theme.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text(volume.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          Text([volume.total.map(Format.bytes), volume.format.title, volume.bsdName].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17))
      VStack(alignment: .leading, spacing: 8) {
        Text("新名称").font(.system(size: 12, weight: .medium))
        TextField("Untitled", text: $name).textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 38)
          .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11)).disabled(locked)
          .accessibilityLabel("格式化后的名称")
      }
      VStack(alignment: .leading, spacing: 9) {
        Text("格式").font(.system(size: 12, weight: .medium))
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
          ForEach(StorageEraseFormat.allCases) { format in
            let chosen = selected == format
            let available = format != .fat32 || (volume.total ?? UInt64.max) <= 32_000_000_000
            Button { selected = format; validation = nil } label: {
              VStack(alignment: .leading, spacing: 6) {
                HStack { Text(format.title).font(.system(size: 13, weight: .semibold)); Spacer(); if chosen { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) } }
                Text(format.detail).font(.system(size: 10)).foregroundStyle(Color.secondary).lineLimit(1)
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 62)
            }.buttonStyle(StorageActionButtonStyle(tint: chosen ? Theme.accent : .primary, selected: chosen))
              .disabled(locked || !available).accessibilityLabel("格式 " + format.title)
              .accessibilityAddTraits(chosen ? .isSelected : [])
          }
        }
      }
      VStack(alignment: .leading, spacing: 7) {
        if store.phase == .complete {
          Label("格式化完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
        } else {
          Label("会清除当前卷的所有文件", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
        }
        Text(validation ?? store.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          .lineLimit(5).help(validation ?? store.message)
      }.padding(.top, 2)
      Spacer(minLength: 0)
      HStack(spacing: 9) {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) } label: {
          Label("磁盘工具", systemImage: "arrow.up.right").padding(.horizontal, 12).frame(height: 36)
        }.buttonStyle(StorageActionButtonStyle()).disabled(store.running)
        Spacer(minLength: 0)
        if store.phase == .complete {
          Button("完成") { StorageFormatWindow.close() }.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
          Button { StorageFormatWindow.close() } label: { Text("取消").padding(.horizontal, 12).frame(height: 36) }
            .buttonStyle(StorageActionButtonStyle(tint: .primary)).disabled(store.running)
          Button {
            do { confirmation = try store.request(format: selected, name: name); validation = nil }
            catch { validation = error.localizedDescription }
          } label: {
            Text(store.running ? "正在格式化" : "格式化…").fontWeight(.semibold).padding(.horizontal, 17).frame(height: 36)
          }.buttonStyle(StorageActionButtonStyle(tint: .red, selected: true)).disabled(locked)
        }
      }.font(.system(size: 12))
    }.padding(24).frame(minWidth: 520, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
  }
}

struct StorageActionButtonStyle: ButtonStyle {
  var tint: Color = Theme.accent
  var selected = false
  func makeBody(configuration: Configuration) -> some View {
    StorageActionSurface(label: configuration.label, tint: tint, selected: selected, pressed: configuration.isPressed)
  }
}
private struct StorageActionSurface<L: View>: View {
  let label: L
  let tint: Color
  let selected: Bool
  let pressed: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    label.foregroundStyle(tint).background(tint.opacity(pressed ? 0.24 : hovered ? 0.17 : selected ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10))
      .contentShape(RoundedRectangle(cornerRadius: 10)).opacity(enabled ? 1 : 0.42)
      .scaleEffect(pressed ? 0.98 : 1).onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
  }
}
