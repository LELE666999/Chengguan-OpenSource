import Foundation

/// Verdicts describe reported evidence, never a benchmark or a certification check.
struct CableUseCase: Identifiable, Equatable {
  enum Verdict { case supported, limited, unknown }
  let id: String
  let symbol: String
  let title: String
  let detail: String
  let verdict: Verdict
  static func evaluate(_ port: CablePort) -> [CableUseCase] {
    let identity = port.identity
    let watts = identity?.ratedWatts
    let charge: Verdict = watts.map { $0 >= 100 ? .supported : .limited } ?? .unknown
    let chargeText = watts.map { "线缆额定 \($0) W" } ?? "线缆功率尚未确认"
    let speed = identity?.speedCode ?? -1
    // USB4 on an active cable does not itself establish USB3 fallback support.
    let fast: Verdict = identity?.active == false && (2...4).contains(speed) ? .supported : (speed >= 0 && speed < 2 ? .limited : .unknown)
    let usb4: Verdict = (3...4).contains(speed) ? .supported : (speed >= 0 ? .limited : .unknown)
    return [
      CableUseCase(id: "charging", symbol: "bolt", title: "100 W 充电", detail: chargeText, verdict: charge),
      CableUseCase(id: "storage", symbol: "externaldrive", title: "10 Gbps 移动硬盘", detail: speed >= 0 ? "芯片声明 · \(identity!.speed)" : "数据能力尚未确认", verdict: fast),
      CableUseCase(id: "display", symbol: "display", title: "外接显示器", detail: port.display != nil ? "当前正在输出视频" : "需实际连接显示器确认", verdict: port.display != nil ? .supported : .unknown),
      CableUseCase(id: "dock", symbol: "point.3.connected.trianglepath.dotted", title: "USB4 扩展坞", detail: usb4 == .supported ? "芯片声明支持 USB4 · 非雷雳认证" : speed >= 0 ? "芯片未声明 USB4 能力" : "USB4 能力尚未确认", verdict: usb4)
    ]
  }
}

struct CablePortRecord: Identifiable, Equatable {
  let id: String
  let number: Int
  let firstObserved: Date
  var observations = 1
  var observedSeconds: TimeInterval = 0
  var peakSupplyWatts: Int? = nil
}
struct CableHistoryEvent: Identifiable, Equatable {
  let id = UUID()
  let portID: String
  let time: Date
  let title: String
  let detail: String
}

/// In-memory, per-port observations. A port is not a globally unique physical cable.
/// Gaps (sleep, app suspension, unavailable controller) do not count as measured time.
struct CableObservationLog: Equatable {
  var records: [String: CablePortRecord] = [:]
  var events: [CableHistoryEvent] = []
  private var previous: CableSnapshot?
  private var previousTime: Date?
  mutating func observe(_ next: CableSnapshot, at now: Date) {
    guard next.readable else { previous = nil; previousTime = nil; return }
    let gap = previousTime.map { now.timeIntervalSince($0) } ?? 0
    for port in next.ports {
      let before = previous?.ports.first { $0.id == port.id }
      var record = records[port.id] ?? CablePortRecord(id: port.id, number: port.number, firstObserved: now)
      let existed = records[port.id] != nil
      if before == nil && existed { record.observations += 1 }
      if before != nil && gap > 0 && gap <= 12 { record.observedSeconds += gap }
      if let watts = port.supplyWatts { record.peakSupplyWatts = max(record.peakSupplyWatts ?? 0, watts) }
      records[port.id] = record
      let title: String?
      if before == nil { title = previous == nil ? "开始观察" : "已连接" }
      else if port.liquidDetected && before?.liquidDetected != true { title = "检测到液体" }
      else if before?.identity == nil && port.identity != nil { title = "芯片已识别" }
      else if before != port { title = "连接已更新" }
      else { title = nil }
      if let title { events.insert(CableHistoryEvent(portID: port.id, time: now, title: title, detail: port.summary), at: 0) }
    }
    for port in previous?.ports ?? [] where !next.ports.contains(where: { $0.id == port.id }) {
      events.insert(CableHistoryEvent(portID: port.id, time: now, title: "已断开", detail: port.subtitle), at: 0)
    }
    events = Array(events.prefix(100))
    previous = next; previousTime = now
  }
}
