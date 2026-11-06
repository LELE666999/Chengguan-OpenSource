import Foundation

struct AINetworkState: Equatable, Sendable {
  var connected: Bool?
  var transport = "unknown"
  var endpointReachable: Bool?
  var endpointLatencyMS: Double?
}

struct AIMonitorEvent: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case cpu, memory, temperature, disk, network, endpoint, address, power, battery, recovery
  }
  let id: UUID
  let time: Date
  let kind: Kind
  let title: String
  let detail: String
  let target: AIReport.Target
  var appID: String?
  var duration: Double = 0
  var value: Double?
  var urgent = false
  var resolved = false
  var requiresAI: Bool { kind != .power }
}

struct AIAppTrend {
  let id: String, name: String
  let seconds: Double, meanCPU: Double, peakCPU: Double, memoryGrowth: Double
}

/// Deterministic local checks. A resource correlation is never labelled a confirmed cause of a hang.
struct AIMonitorEngine {
  private struct Reading { let time: Date; let cpu: Double; let memory: UInt64 }
  private var readings: [String: [Reading]] = [:]
  private var names: [String: String] = [:]
  private var since: [String: Date] = [:]
  private var active = Set<String>()
  private var lastEmitted: [String: Date] = [:]
  private var previousTime: Date?
  private var previousAddresses: [LocalIPv4Address]?
  private var previousNetwork: AINetworkState?
  private var previousPower: Bool?
  private var personalCPUAppID: String?

  mutating func observe(_ s: MonitorSnapshot, network: AINetworkState, baseline: PersonalBaseline? = nil) -> [AIMonitorEvent] {
    let now = s.time
    guard s.totalMemory > 0, s.cpu.isFinite else { return [] }
    if let previousTime, now <= previousTime { return [] }
    // No threshold duration or growth calculation may bridge sleep or a sampling gap.
    if let previousTime, now.timeIntervalSince(previousTime) > 20 {
      since.removeAll(); active.removeAll(); readings.removeAll()
    }
    previousTime = now
    let currentIDs = Set(s.groups.map(\.id))
    readings = readings.filter { currentIDs.contains($0.key) }
    names = names.filter { currentIDs.contains($0.key) }
    since = since.filter { !$0.key.hasPrefix("growth:") || currentIDs.contains(String($0.key.dropFirst(7))) }
    active = active.filter { !$0.hasPrefix("growth:") || currentIDs.contains(String($0.dropFirst(7))) }
    if s.pressureLevel == 1 {
      active = active.filter { !$0.hasPrefix("growth:") }
      since = since.filter { !$0.key.hasPrefix("growth:") }
    }
    lastEmitted = lastEmitted.filter { now.timeIntervalSince($0.value) < 86400 }
    for app in s.groups where app.measuredCount > 0 && app.cpu.isFinite {
      names[app.id] = String(app.name.prefix(80))
      readings[app.id, default: []].append(Reading(time: now, cpu: app.cpu, memory: app.memory))
      readings[app.id]?.removeAll { now.timeIntervalSince($0.time) > 120 }
    }
    var events: [AIMonitorEvent] = []
    func event(_ kind: AIMonitorEvent.Kind, _ title: String, _ detail: String,
               _ target: AIReport.Target, appID: String? = nil, duration: Double = 0,
               value: Double? = nil, urgent: Bool = false, resolved: Bool = false) -> AIMonitorEvent {
      AIMonitorEvent(id: UUID(), time: now, kind: kind, title: title, detail: detail, target: target,
        appID: appID, duration: duration, value: value, urgent: urgent, resolved: resolved)
    }
    let topCPU = s.groups.filter { $0.measuredCount > 0 && $0.cpu.isFinite }.max { $0.cpu < $1.cpu }
    let topMemory = s.groups.filter { $0.measuredCount > 0 }.max { $0.memory < $1.memory }
    let cpuDetail = topCPU.map { app in
      let process = app.id == "system.macos" ? app.processes.filter { $0.measured && $0.cpu.isFinite }.max { $0.cpu < $1.cpu }?.name : nil
      let title = app.name + (process.map { "（" + $0 + "）" } ?? "")
      return "\(title) 当前占用 \(Int(app.cpu))%（单核口径），是优先排查的线索。"
    } ?? "部分进程无法测量，暂不能定位到 App。"
    let reference = topCPU.flatMap { baseline?.value(appID: $0.id, context: PersonalBaseline.context(s), now: now) }
    if personalCPUAppID != topCPU?.id {
      since["personalCPU"] = nil
      personalCPUAppID = topCPU?.id
    }
    let exceedsPersonal = reference?.ready == true && s.cpu >= 65 && (topCPU?.cpu ?? 0) > max(100, (reference?.p95CPU ?? 0) * 2)
    if sustained("personalCPU", condition: exceedsPersonal, hold: 30, now: now), !active.contains("cpu") {
      events.append(event(.cpu, "CPU 高于同场景常态", cpuDetail + "已持续 30 秒超过自身 P95 的两倍，整机压力同时升高。", .cpu, appID: topCPU?.id, duration: 30, value: s.cpu, urgent: true))
      active.insert("cpu")
    }
    _ = recover("personalCPU", clear: s.cpu < 65)
    let highCPU = sustained("cpu", condition: s.cpu >= 85, hold: 12, now: now)
    let criticalCPU = sustained("cpuCritical", condition: s.cpu >= 97, hold: 4, now: now)
    if highCPU || criticalCPU {
      events.append(event(.cpu, criticalCPU ? "CPU 接近满载" : "CPU 持续高占用", "整机 \(Int(s.cpu))%。" + cpuDetail, .cpu,
        appID: topCPU?.id, duration: now.timeIntervalSince(since[criticalCPU ? "cpuCritical" : "cpu"] ?? now), value: s.cpu, urgent: true))
      if criticalCPU { active.insert("cpu") }
    }
    _ = recover("cpuCritical", clear: s.cpu < 65)
    if recover("cpu", clear: s.cpu < 65) {
      events.append(event(.recovery, "CPU 已回落", "整机 CPU 已回落至 \(Int(s.cpu))%。", .cpu, resolved: true))
    }
    if sustained(s.pressureLevel == 4 ? "memoryCritical" : "memory", condition: s.pressureLevel == 2 || s.pressureLevel == 4,
                 hold: s.pressureLevel == 4 ? 0 : 8, now: now) {
      let detail = topMemory.map { "\($0.name) 占用最多：\(Format.memory($0.memory))。" } ?? "部分 App 指标受系统限制。"
      events.append(event(.memory, s.pressureLevel == 4 ? "内存压力严重" : "内存压力升高",
        detail + "交换空间 \(Format.memory(s.swap))，占用高不等于泄漏。", .memory,
        appID: topMemory?.id, value: Double(s.pressureLevel), urgent: true))
      if s.pressureLevel == 4 { active.insert("memory") }
    }
    _ = recover("memoryCritical", clear: s.pressureLevel == 1)
    if recover("memory", clear: s.pressureLevel == 1) {
      events.append(event(.recovery, "内存压力已恢复", "当前压力正常，继续观察即可。", .memory, resolved: true))
    }
    if let temperature = s.temperature, temperature.isFinite {
      let warm = sustained("temperature", condition: temperature >= 90, hold: 20, now: now)
      let hot = sustained("temperatureCritical", condition: temperature >= 98, hold: 4, now: now)
      if warm || hot {
        events.append(event(.temperature, "温度持续偏高", "CPU \(Int(temperature)) °C。" + cpuDetail, .cpu,
          appID: topCPU?.id, value: temperature, urgent: true))
        if hot { active.insert("temperature") }
      }
      _ = recover("temperatureCritical", clear: temperature < 82)
      if recover("temperature", clear: temperature < 82) {
        events.append(event(.recovery, "温度已回落", "CPU \(Int(temperature)) °C。", .cpu, resolved: true))
      }
    }
    if let volume = s.primaryVolume, volume.total > 0 {
      let fraction = Double(volume.free) / Double(volume.total)
      if sustained("disk", condition: fraction < 0.1, hold: 0, now: now) {
        events.append(event(.disk, "磁盘空间不足", "剩余 \(Format.bytes(volume.free))，低于总容量的 10%。", .disk,
          value: fraction * 100, urgent: fraction < 0.03))
      }
      _ = recover("disk", clear: fraction >= 0.12)
    }
    // Growth is a clue only when actual memory pressure also rises.
    if s.pressureLevel == 2 || s.pressureLevel == 4,
      let growth = trends(now: now).filter({ $0.seconds >= 60 && $0.memoryGrowth > 1_073_741_824 }).max(by: { $0.memoryGrowth < $1.memoryGrowth }),
      sustained("growth:\(growth.id)", condition: true, hold: 0, now: now) {
      events.append(event(.memory, "\(growth.name) 内存增长较快",
        "\(Int(growth.seconds)) 秒内增加 \(Format.memory(growth.memoryGrowth))，同时出现内存压力；尚不能确认泄漏。",
        .memory, appID: growth.id, duration: growth.seconds, value: growth.memoryGrowth, urgent: true))
    }
    if let old = previousAddresses, old != s.localNetwork.addresses {
      let detail: String
      if let address = s.localNetwork.primary { detail = "\(address.interface) · \(address.address)，点击查看或复制。" }
      else { detail = "当前没有活动的局域网 IPv4 地址。" }
      events.append(event(.address, "局域网地址已变化", detail, .network))
    }
    previousAddresses = s.localNetwork.addresses
    if previousNetwork?.connected == nil, network.connected == false {
      events.append(event(.network, "网络连接不可用", "系统当前没有可用网络路由；本地监测继续。", .network, urgent: true))
    }
    if let old = previousNetwork, let connected = network.connected, old.connected != nil,
      old.connected != connected {
      events.append(event(.network, connected ? "网络连接已恢复" : "网络连接中断",
        connected ? "系统路由已恢复，外部服务是否可达仍需验证。" : "系统当前没有可用网络路由；AI 分析会等待联网。",
        .network, urgent: !connected, resolved: connected))
    } else if let old = previousNetwork, network.connected == true, old.connected == true,
      old.transport != network.transport {
      events.append(event(.network, "网络接口已切换", "当前使用 \(network.transport)。", .network))
    }
    if let reachable = network.endpointReachable {
      if sustained("endpoint", condition: !reachable, hold: 0, now: now) {
        events.append(event(.endpoint, "AI 接口暂时不可达", "连接当前模型服务超时或失败；这不代表所有网站都断网。", .network, urgent: true))
      }
      if recover("endpoint", clear: reachable) {
        events.append(event(.recovery, "AI 接口已恢复", "当前模型服务已能建立连接。", .network, resolved: true))
      }
    }
    if let ms = network.endpointLatencyMS {
      if sustained("latency", condition: ms > 3000, hold: 30, now: now) {
        events.append(event(.endpoint, "模型服务响应较慢", "探测响应头耗时 \(Int(ms)) ms；仅代表当前接口。", .network, value: ms))
      }
      _ = recover("latency", clear: ms < 1500)
    }
    previousNetwork = network
    if s.battery.percent?.isFinite == true {
      if let previousPower, previousPower != s.battery.plugged {
        events.append(event(.power, s.battery.plugged ? "已接通电源" : "已切换电池供电", "电量 \(Int(s.battery.percent ?? 0))%。", .battery))
      }
      previousPower = s.battery.plugged
      if sustained("battery", condition: !s.battery.plugged && (s.battery.percent ?? 100) <= 10, hold: 0, now: now) {
        events.append(event(.battery, "电量较低", "剩余 \(Int(s.battery.percent ?? 0))%，建议接通电源。", .battery, urgent: true))
      }
      _ = recover("battery", clear: s.battery.plugged || (s.battery.percent ?? 100) >= 20)
    }
    return events
  }

  private mutating func sustained(_ key: String, condition: Bool, hold: Double, now: Date) -> Bool {
    guard condition else { since[key] = nil; return false }
    if since[key] == nil { since[key] = now }
    guard now.timeIntervalSince(since[key]!) >= hold else { return false }
    // One event per incident; a recovery is needed before it can fire again.
    guard !active.contains(key), now.timeIntervalSince(lastEmitted[key] ?? .distantPast) >= 120 else { return false }
    active.insert(key); lastEmitted[key] = now
    return true
  }
  private mutating func recover(_ key: String, clear: Bool) -> Bool {
    guard clear else { return false }
    since[key] = nil
    return active.remove(key) != nil
  }
  func trends(now: Date) -> [AIAppTrend] {
    readings.compactMap { id, all in
      let points = all.filter { now.timeIntervalSince($0.time) <= 120 }
      guard let first = points.first, let last = points.last else { return nil }
      return AIAppTrend(id: id, name: names[id] ?? "App", seconds: last.time.timeIntervalSince(first.time),
        meanCPU: points.map(\.cpu).reduce(0, +) / Double(points.count), peakCPU: points.map(\.cpu).max() ?? 0,
        memoryGrowth: Double(last.memory) - Double(first.memory))
    }
  }
}

/// Persist only automatic attempt times; never credentials, IP addresses or device measurements.
struct AIAutomaticBudget {
  var attempts: [Date] = []
  var failureCount = 0
  var retryAfter = Date.distantPast
  var blocked = false
  mutating func mayRun(now: Date, intervalMinutes: Int, event: Bool) -> Bool {
    attempts.removeAll { now.timeIntervalSince($0) >= 3600 }
    guard !blocked, now >= retryAfter, attempts.count < 12 else { return false }
    guard let last = attempts.last else { return true }
    return now.timeIntervalSince(last) >= (event ? 60 : Double(intervalMinutes) * 60)
  }
  mutating func started(now: Date) { attempts.append(now) }
  mutating func finished(now: Date, error: Error?) {
    guard let error else { failureCount = 0; retryAfter = .distantPast; return }
    failureCount += 1
    if case AIAnalysisError.http(let status) = error, [401, 402, 403, 404].contains(status) { blocked = true }
    if case AIAnalysisError.keychain = error { blocked = true }
    retryAfter = now.addingTimeInterval(min(1800, 60 * pow(2, Double(min(failureCount, 5)))))
  }
  mutating func resume() { blocked = false; failureCount = 0; retryAfter = .distantPast }
}

extension AIPreparedSample {
  func addingMonitoring(events: [AIMonitorEvent], trends: [AIAppTrend], network: AINetworkState) throws -> Self {
    var payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let appEvidence: [[String: Any]] = trends.sorted { $0.meanCPU > $1.meanCPU }.prefix(10).compactMap { trend in
      guard let tag = appIdentifiers[trend.id] else { return nil }
      return ["label": tag, "observed_seconds": trend.seconds, "mean_single_core_cpu_percent": trend.meanCPU,
              "group_kind": trend.id == "system.macos" ? "system_aggregate" : "application",
              "peak_single_core_cpu_percent": trend.peakCPU, "memory_growth_bytes": trend.memoryGrowth]
    }
    // Deliberately exclude local titles/details: those contain names and addresses.
    let signals: [[String: Any]] = events.prefix(12).map {
      ["kind": $0.kind.rawValue, "target": $0.target.rawValue, "age_seconds": max(0, sampledAt.timeIntervalSince($0.time)),
       "duration_seconds": $0.duration, "value": $0.value as Any? ?? NSNull(), "resolved": $0.resolved]
    }
    payload["continuous_monitoring"] = ["events": signals, "app_window": appEvidence,
      "network_route_available": network.connected as Any? ?? NSNull(),
      "ai_endpoint_reachable": network.endpointReachable as Any? ?? NSNull(),
      "ai_endpoint_headers_latency_ms": network.endpointLatencyMS as Any? ?? NSNull(),
      "causation_limit": "Resource correlation is not proof of a hang or its cause. No per-app responsiveness measurement."]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    return Self(json: String(decoding: data, as: UTF8.self), sampledAt: sampledAt, sampleCount: sampleCount,
      observedSeconds: observedSeconds, requestedMinutes: requestedMinutes, appLabels: appLabels, includesAppNames: includesAppNames, appIdentifiers: appIdentifiers)
  }
}
