import AppKit
import Combine

@MainActor final class CableMonitor: ObservableObject {
  static let shared = CableMonitor()
  @Published private(set) var snapshot = CableSnapshot()
  @Published private(set) var checked = false
  @Published private(set) var changes: [AIQuickMessage] = []
  @Published private(set) var observations = CableObservationLog()
  private var timer: AnyCancellable?
  private var wake: NSObjectProtocol?
  private var reading: Task<Void, Never>?
  private var generation = 0
  func start() {
    guard timer == nil else { return }
    timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    refresh()
  }
  func stop() {
    timer?.cancel(); timer = nil; generation += 1; reading?.cancel(); reading = nil
    if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake); self.wake = nil }
  }
  func refresh() {
    guard reading == nil else { return }
    let token = generation
    reading = Task { [weak self] in
      let result = await Task.detached(priority: .utility) { CableReader.read() }.value
      guard let self, !Task.isCancelled, token == generation else { return }
      apply(result); reading = nil
    }
  }
  func apply(_ next: CableSnapshot, now: Date = Date()) {
    observations.observe(next, at: now)
    if checked {
      let events = Self.diff(snapshot, next, now: now)
      if !events.isEmpty { changes = Array((events + changes).prefix(20)) }
    }
    if snapshot != next { snapshot = next }
    if !checked { checked = true }
  }
  static func diff(_ old: CableSnapshot, _ next: CableSnapshot, now: Date) -> [AIQuickMessage] {
    guard old.readable && next.readable else { return [] }
    var result: [AIQuickMessage] = []
    for port in next.ports {
      let before = old.ports.first { $0.id == port.id }
      let title: String?
      if before == nil { title = port.title + " 已连接" }
      else if port.liquidDetected && before?.liquidDetected != true { title = port.title + " 检测到液体" }
      else if before?.identity == nil && port.identity != nil { title = port.title + " 线缆已识别" }
      else if before?.connectionSignature != port.connectionSignature { title = port.title + " 连接已变化" }
      else if before != port { title = port.title + " 连接状态已更新" }
      else { title = nil }
      if let title { result.append(AIQuickMessage(id: UUID().uuidString, time: now, title: title,
        detail: port.liquidDetected ? "请检查接口并断开受潮线缆" : port.summary,
        symbol: "cable.connector", priority: port.liquidDetected ? 1 : 0, cables: true)) }
    }
    for port in old.ports where !next.ports.contains(where: { $0.id == port.id }) {
      result.append(AIQuickMessage(id: UUID().uuidString, time: now, title: port.title + " 已断开", detail: port.devices.joined(separator: " · "), symbol: "cable.connector", cables: true))
    }
    return result
  }
}
