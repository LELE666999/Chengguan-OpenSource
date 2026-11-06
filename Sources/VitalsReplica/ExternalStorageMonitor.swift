import AppKit
import Combine

@MainActor final class ExternalStorageMonitor: ObservableObject {
  static let shared = ExternalStorageMonitor()
  @Published private(set) var volumes: [ExternalVolume] = []
  @Published private(set) var changes: [AIQuickMessage] = []
  @Published private(set) var readable = true
  @Published private(set) var busy: Set<String> = []
  @Published private(set) var ejecting: Set<String> = []
  @Published private(set) var notice: AIQuickMessage?
  @Published var error: String?
  private let ejector: @Sendable (ExternalVolume) async -> StorageEjectResult
  private let diskEvents = StorageDiskEvents()
  private var observers: [NSObjectProtocol] = []
  private var timer: AnyCancellable?
  private var reading: Task<Void, Never>?
  private var probing: Task<Void, Never>?
  private var mountCheck: Task<Void, Never>?
  private var eventRefresh: Task<Void, Never>?
  private var noticeExpiry: Task<Void, Never>?
  private var knownPaths: Set<String>?
  private var suppressed: [String: ExternalVolume] = [:]
  private var lastCapacityRead = Date.distantPast
  private var epoch = 0
  private var pending = false
  private var checked = false
  private struct Hint { let path: String; let folder: String?; let checkedAt: Date }
  private var hints: [String: Hint] = [:]
  var revision: Int { epoch }
  init(ejector: @escaping @Sendable (ExternalVolume) async -> StorageEjectResult = { await StorageEjector.eject($0) }) {
    self.ejector = ejector
  }

  func start() {
    guard timer == nil else { return }
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                 NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let path = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
          ?? notification.userInfo?["NSDevicePath"] as? String
        Task { @MainActor in self?.workspaceEvent(name, path: path) }
      })
    }
    diskEvents.onEvent = { [weak self] in self?.diskEvent($0) }; diskEvents.start()
    timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
      self?.checkMounts()
      if let self, Date().timeIntervalSince(lastCapacityRead) >= 30 { refresh() }
    }
    checkMounts()
    refresh()
  }
  func stop() {
    diskEvents.stop(); diskEvents.onEvent = nil
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
    timer?.cancel(); timer = nil; epoch += 1
    reading?.cancel(); reading = nil; probing?.cancel(); probing = nil; pending = false
    mountCheck?.cancel(); mountCheck = nil; eventRefresh?.cancel(); eventRefresh = nil
    noticeExpiry?.cancel(); noticeExpiry = nil
  }
  func refresh(urgent: Bool = false) {
    if urgent { epoch += 1; reading?.cancel(); reading = nil; pending = false }
    guard reading == nil else { pending = true; return }
    lastCapacityRead = Date()
    let token = epoch
    reading = Task { [weak self] in
      let result = await Task.detached(priority: .utility) { ExternalStorageReader.read() }.value
      guard let self, !Task.isCancelled else { return }
      apply(result, revision: token)
      reading = nil
      if pending || token != epoch { pending = false; refresh() }
    }
  }
  func apply(_ result: StorageReadResult, now: Date = Date(), revision: Int? = nil) {
    guard revision == nil || revision == epoch else { return }
    readable = result.readable
    // A failed read must not generate a false unplug or erase a visible device.
    guard result.readable else { return }
    var next = result.volumes.filter { suppressed[$0.id] == nil }
    let retained = volumes.filter { old in result.unavailablePaths.contains(old.path) && !next.contains { $0.id == old.id } }
    next.append(contentsOf: retained)
    if !retained.isEmpty { readable = false }
    next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    hints = hints.filter { key, hint in now.timeIntervalSince(hint.checkedAt) < 120 && next.contains { $0.id == key && $0.path == hint.path } }
    for i in next.indices {
      if let hint = hints[next[i].id] { next[i].cameraFolder = hint.folder; next[i].contentChecked = true }
    }
    let events = Self.diff(checked ? volumes : [], next, now: now)
    if !events.isEmpty { changes = Array((events + changes).prefix(30)); showNotice(events[0]) }
    volumes = next; checked = true
    probeContent()
  }
  func workspaceEvent(_ name: Notification.Name, path: String?) {
    if name == NSWorkspace.didUnmountNotification {
      remove(path: path)
    } else if name == NSWorkspace.didMountNotification {
      restore(path: path)
    }
    scheduleEventRefresh()
  }
  func diskEvent(_ signal: StorageDiskSignal) {
    if signal.kind == .removed {
      guard volumes.contains(where: { Self.matches($0, signal) }) else { return }
      remove(matching: { Self.matches($0, signal) })
    } else {
      guard signal.path?.hasPrefix("/Volumes/") == true || volumes.contains(where: { $0.bsdName == signal.bsdName }) else { return }
      restore(path: signal.path, bsdName: signal.bsdName)
    }
    scheduleEventRefresh()
  }
  private static func matches(_ volume: ExternalVolume, _ signal: StorageDiskSignal) -> Bool {
    signal.path == volume.path || (!signal.bsdName.isEmpty && (volume.bsdName == signal.bsdName
      || (signal.whole && volume.bsdName.hasPrefix(signal.bsdName + "s"))))
  }
  private func restore(path: String?, bsdName: String? = nil) {
    suppressed = suppressed.filter { _, v in !(path == v.path || (bsdName != nil && bsdName == v.bsdName)) }
  }
  private func remove(path: String?) {
    guard let path else { return }
    remove(matching: { $0.path == path })
  }
  private func remove(matching predicate: (ExternalVolume) -> Bool) {
    let removed = volumes.filter(predicate)
    guard !removed.isEmpty else { return }
    epoch += 1
    for v in removed { suppressed[v.id] = v; hints.removeValue(forKey: v.id) }
    volumes.removeAll(where: predicate)
    let events = Self.diff(removed, [], now: Date())
    changes = Array((events + changes).prefix(30)); if let event = events.first { showNotice(event) }
  }
  private func scheduleEventRefresh() {
    epoch += 1; eventRefresh?.cancel()
    eventRefresh = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled, let self else { return }
      eventRefresh = nil; refresh(urgent: true)
    }
  }
  private func checkMounts() {
    guard mountCheck == nil else { return }
    mountCheck = Task { [weak self] in
      let paths = await Task.detached(priority: .userInitiated) { ExternalStorageReader.mountedPaths() }.value
      guard let self, !Task.isCancelled else { return }
      if let paths { reconcileMountedPaths(paths) }
      mountCheck = nil
    }
  }
  /// Fast fallback reads only the mount table, never per-volume capacity or media contents.
  func reconcileMountedPaths(_ paths: Set<String>) {
    let removed = volumes.contains { !paths.contains($0.path) }
    if removed { remove(matching: { !paths.contains($0.path) }) }
    let added = paths.subtracting(knownPaths ?? paths).filter { $0.hasPrefix("/Volumes/") }
    knownPaths = paths
    for path in added { restore(path: path) }
    if removed || !added.isEmpty { scheduleEventRefresh() }
  }
  private func showNotice(_ event: AIQuickMessage) {
    notice = event; noticeExpiry?.cancel()
    noticeExpiry = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }
  private func record(_ volume: ExternalVolume, title: String, detail: String, priority: Int = 0) {
    let event = AIQuickMessage(id: UUID().uuidString, time: Date(), title: title, detail: detail,
      symbol: volume.symbol, priority: priority, storage: true)
    changes = Array(([event] + changes).prefix(30)); showNotice(event)
  }
  func speedMessage(_ target: StorageSpeedTarget, title: String, detail: String) {
    let event = AIQuickMessage(id: UUID().uuidString, time: Date(), title: title, detail: detail,
      symbol: "speedometer", priority: 0, storage: true)
    changes = Array(([event] + changes).prefix(30)); showNotice(event)
  }
  func formatMessage(_ volume: ExternalVolume, title: String, detail: String) {
    record(volume, title: title, detail: detail)
  }
  func eject(_ volume: ExternalVolume) async {
    guard !StorageFormatStore.shared.running else {
      record(volume, title: "请等待格式化完成", detail: "格式化期间无法推出存储"); return
    }
    guard !StorageSpeedStore.shared.running else {
      record(volume, title: "请先停止测速", detail: "测速结束后即可安全推出"); return
    }
    guard !busy.contains(volume.id), !ejecting.contains(volume.id) else { return }
    guard volumes.contains(where: { $0.id == volume.id && $0.path == volume.path }) else {
      record(volume, title: volume.name + " 已移除", detail: "未执行推出"); return
    }
    busy.insert(volume.id); ejecting.insert(volume.id)
    record(volume, title: "正在推出 " + volume.name, detail: "正在安全卸载，请稍候")
    let result = await ejector(volume)
    busy.remove(volume.id); ejecting.remove(volume.id)
    switch result {
    case .ejected:
      remove(matching: { $0.id == volume.id && $0.path == volume.path })
      suppressed[volume.id] = volume
      record(volume, title: volume.name + " 已安全推出", detail: "此卷已完成安全卸载")
    case .unavailable:
      remove(matching: { $0.id == volume.id && $0.path == volume.path })
      record(volume, title: volume.name + " 已移除", detail: "连接已变化，未执行推出")
    case .failed(let reason):
      error = "无法推出「" + volume.name + "」。请关闭正在使用它的文件或 App 后重试。\n" + reason
      record(volume, title: volume.name + " 推出失败", detail: "可能仍在使用中，请关闭相关文件后重试", priority: 1)
    }
    scheduleEventRefresh()
  }
  private func probeContent() {
    guard probing == nil else { return }
    let candidates = volumes.filter { !$0.contentChecked }
    guard !candidates.isEmpty else { return }
    probing = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        candidates.map { ($0.id, $0.path, ExternalStorageReader.cameraFolder(at: URL(fileURLWithPath: $0.path))) }
      }.value
      guard let self, !Task.isCancelled else { return }
      for (id, path, folder) in result {
        guard let i = volumes.firstIndex(where: { $0.id == id && $0.path == path }) else { continue }
        hints[id] = Hint(path: path, folder: folder, checkedAt: Date())
        volumes[i].cameraFolder = folder; volumes[i].contentChecked = true
      }
      probing = nil; probeContent()
    }
  }
  static func diff(_ old: [ExternalVolume], _ next: [ExternalVolume], now: Date) -> [AIQuickMessage] {
    var result: [AIQuickMessage] = []
    func event(_ v: ExternalVolume, _ title: String, detail: String? = nil, priority: Int = 0) -> AIQuickMessage {
      AIQuickMessage(id: UUID().uuidString, time: now, title: title,
        detail: detail ?? v.subtitle + " · " + v.capacityText, symbol: v.symbol, priority: priority, storage: true)
    }
    for v in next {
      guard let before = old.first(where: { $0.id == v.id }) else {
        result.append(event(v, v.name + (v.lowSpace ? " 已连接 · 空间不足" : " 已连接"), priority: v.lowSpace ? 1 : 0)); continue
      }
      if before.name != v.name { result.append(event(v, before.name + " 已更名为 " + v.name)) }
      if !before.lowSpace && v.lowSpace { result.append(event(v, v.name + " 空间不足", priority: 1)) }
      else if before.lowSpace && !v.lowSpace && v.fraction != nil { result.append(event(v, v.name + " 可用空间已恢复")) }
      if let readOnly = v.readOnly, before.readOnly != nil, before.readOnly != v.readOnly { result.append(event(v, v.name + (readOnly ? " 已变为只读" : " 已可写入"))) }
    }
    for v in old where !next.contains(where: { $0.id == v.id }) {
      result.append(event(v, v.name + " 已移除", detail: "已从外接存储列表移除"))
    }
    return result
  }
  /// Revalidate the mounted identity before opening, never open a stale /Volumes directory.
  func open(_ volume: ExternalVolume, photos: Bool = false) {
    guard !busy.contains(volume.id) else { return }
    busy.insert(volume.id)
    Task {
      let current = await Task.detached(priority: .userInitiated) { ExternalStorageReader.readMounted(volume) }.value
      defer { busy.remove(volume.id) }
      guard let live = current else {
        error = "存储已移除或尚未挂载。"; refresh(); return
      }
      var url = URL(fileURLWithPath: live.path, isDirectory: true)
      if photos {
        let folder = await Task.detached(priority: .userInitiated) { ExternalStorageReader.cameraFolder(at: url) }.value
        guard let folder else { error = "照片目录已不可用。"; return }
        url.appendPathComponent(folder, isDirectory: true)
      }
      if !NSWorkspace.shared.open(url) { error = "无法打开此存储，请在 Finder 中检查访问权限。" }
    }
  }
}
