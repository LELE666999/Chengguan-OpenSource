import Foundation

/// Local facts only. A gap ends an observation; it is never evidence of recovery.
struct AdvisorEpisode: Identifiable, Codable, Equatable {
  let id: UUID
  let kind: AIMonitorEvent.Kind
  let target: AIReport.Target
  let appID: String?
  let title: String
  let detail: String
  let startedAt: Date
  var lastSeen: Date
  var endedAt: Date?
  var ending: String?
  var peak: Double?
  var active: Bool { endedAt == nil }
  var duration: Double { max(0, (endedAt ?? lastSeen).timeIntervalSince(startedAt)) }
}

struct BaselineReading: Codable {
  let time: Date
  let appID: String
  let context: String
  let cpu: Double
  let memory: Double
}
struct AppBaseline: Equatable {
  let count: Int
  let medianCPU: Double
  let p95CPU: Double
  let medianMemory: Double
  let p95Memory: Double
  var ready: Bool { count >= 30 }
}
struct PersonalBaseline: Codable {
  var readings: [BaselineReading] = []
  private(set) var lastSample: Date = .distantPast
  static func context(_ s: MonitorSnapshot) -> String {
    let power = s.battery.percent == nil ? "unknown" : s.battery.plugged ? "power" : "battery"
    let workloads = DeveloperContext.labels(s).sorted()
    return power + ":" + (workloads.isEmpty ? "general" : workloads.joined(separator: "+"))
  }
  mutating func observe(_ s: MonitorSnapshot) {
    guard s.totalMemory > 0, s.error == nil, s.time.timeIntervalSince(lastSample) >= 60 else { return }
    lastSample = s.time
    readings.removeAll { s.time.timeIntervalSince($0.time) > 30 * 86400 || $0.time > s.time }
    // Do not learn resource pressure into the normal baseline.
    guard s.cpu < 85, s.pressureLevel == 1, (s.temperature ?? 0) < 90 else { return }
    for app in s.groups.sorted(by: { $0.cpu > $1.cpu }).prefix(48) where app.measuredCount > 0 {
      readings.append(BaselineReading(time: s.time, appID: app.id, context: Self.context(s), cpu: app.cpu, memory: Double(app.memory)))
    }
    if readings.count > 24_000 { readings.removeFirst(readings.count - 24_000) }
  }
  func value(appID: String, context: String, now: Date) -> AppBaseline? {
    let values = readings.filter { $0.appID == appID && $0.context == context && now.timeIntervalSince($0.time) >= 300 && now.timeIntervalSince($0.time) <= 30 * 86400 }
    guard !values.isEmpty else { return nil }
    func quantile(_ input: [Double], _ q: Double) -> Double {
      let a = input.sorted(); return a[Int(Double(a.count - 1) * q)]
    }
    return AppBaseline(count: values.count, medianCPU: quantile(values.map(\.cpu), 0.5), p95CPU: quantile(values.map(\.cpu), 0.95), medianMemory: quantile(values.map(\.memory), 0.5), p95Memory: quantile(values.map(\.memory), 0.95))
  }
}

struct ObservationSpan: Codable, Equatable {
  var start: Date
  var end: Date
}
struct ObservationCoverage: Codable {
  var spans: [ObservationSpan] = []
  mutating func record(_ time: Date, newSpan: Bool = false) {
    if let last = spans.last, time <= last.end { return }
    if !newSpan, let last = spans.last, time.timeIntervalSince(last.end) <= 20 {
      spans[spans.count - 1].end = time
    } else { spans.append(ObservationSpan(start: time, end: time)) }
    spans.removeAll { time.timeIntervalSince($0.end) > 31 * 86400 }
  }
  func seconds(from: Date, to: Date) -> Double {
    spans.reduce(0) { $0 + max(0, min($1.end, to).timeIntervalSince(max($1.start, from))) }
  }
}

struct ResourceWindow: Codable, Equatable {
  var cpu: Double
  var memory: Double
  var pressure: Double
  var seconds: Double
  var samples: Int
  static func summarize(_ snapshots: [ActionReading], from: Date, to: Date) -> Self {
    let points = snapshots.filter { $0.time >= from && $0.time <= to }
    var duration = 0.0, cpu = 0.0, memory = 0.0, pressure = 0.0
    for (a, b) in zip(points, points.dropFirst()) {
      let dt = b.time.timeIntervalSince(a.time)
      guard dt > 0, dt <= 20 else { continue }
      duration += dt; cpu += a.cpu * dt; memory += a.memory * dt; pressure += Double(a.pressure) * dt
    }
    return Self(cpu: duration > 0 ? cpu / duration : 0, memory: duration > 0 ? memory / duration : 0,
      pressure: duration > 0 ? pressure / duration : 0, seconds: duration, samples: points.count)
  }
}
struct ActionReading {
  let time: Date
  let cpu: Double
  let memory: Double
  let pressure: Int
  let workload: String
}

struct ProcessIdentity: Codable, Equatable {
  let pid: Int32
  let start: UInt64
  let uid: UInt32
  let path: String
  init(_ p: ProcessSample) { pid = p.pid; start = p.start; uid = p.uid; path = p.path }
}
struct AdvisorAction: Identifiable, Codable, Equatable {
  enum Kind: String, Codable { case quitApp, stopProject, copyAddress, networkDiagnosis, diskUsage, batterySettings, cleanupReview }
  let id: UUID
  let kind: Kind
  let createdAt: Date
  let expiresAt: Date
  let title: String
  let evidence: String
  let targetID: String?
  let targetName: String?
  let tokens: [ProcessIdentity]
  let ports: [Int]
  let pressureRequired: Bool
  var metric: AIReport.Target? = nil
  var needsConfirmation: Bool { kind == .quitApp || kind == .stopProject }
  var impact: String {
    switch kind {
    case .quitApp: "向 App 发送正常退出请求；请先保存工作。退出无法撤销。"
    case .stopProject: "向所列开发进程发送 SIGTERM；正在执行的任务会中断，无法撤销。"
    default: "只读检查或打开对应设置。"
    }
  }
  static func quit(_ app: AppGroup, snapshot s: MonitorSnapshot, evidence: String, pressureRequired: Bool = true, metric: AIReport.Target? = nil) -> Self {
    Self(id: UUID(), kind: .quitApp, createdAt: s.time, expiresAt: s.time.addingTimeInterval(90), title: "退出 \(app.name)…", evidence: evidence, targetID: app.id, targetName: app.name, tokens: app.processes.map(ProcessIdentity.init), ports: [], pressureRequired: pressureRequired, metric: metric)
  }
  static func stop(_ project: ProjectSample, snapshot s: MonitorSnapshot) -> Self {
    Self(id: UUID(), kind: .stopProject, createdAt: s.time, expiresAt: s.time.addingTimeInterval(90), title: "停止 \(project.name)…", evidence: "\(project.processes.count) 个进程 · 端口 \(project.ports.map(String.init).joined(separator: "、"))", targetID: project.path, targetName: project.name, tokens: project.processes.map(ProcessIdentity.init), ports: project.ports, pressureRequired: false)
  }
  static func simple(_ kind: Kind, _ title: String, snapshot s: MonitorSnapshot, evidence: String = "") -> Self {
    Self(id: UUID(), kind: kind, createdAt: s.time, expiresAt: s.time.addingTimeInterval(90), title: title, evidence: evidence, targetID: kind == .copyAddress ? s.localNetwork.primary?.address : nil, targetName: nil, tokens: [], ports: [], pressureRequired: false)
  }
  /// A replacement process for the same App/project means the target is still running.
  func targetEnded(snapshot s: MonitorSnapshot, after began: Date) -> Bool? {
    if tokens.contains(where: { token in s.processes.contains { $0.pid == token.pid && $0.start == token.start } }) { return false }
    switch kind {
    case .quitApp: return !s.groups.contains { $0.id == targetID }
    case .stopProject:
      guard let scanned = s.projectScanTime, scanned > began else { return nil }
      return !s.projects.contains { $0.path == targetID }
    default: return nil
    }
  }
  /// Pure validation is repeated against a fresh native sample immediately before acting.
  func invalidReason(snapshot s: MonitorSnapshot, now: Date, uid: UInt32, selfPID: Int32) -> String? {
    guard now >= createdAt, now <= expiresAt, now.timeIntervalSince(s.time) <= 10, s.time <= now else { return "证据已过期，请查看当前状态" }
    if pressureRequired, s.cpu < 65, s.pressureLevel < 2, (s.temperature ?? 0) < 82 { return "压力已恢复，取消旧建议" }
    if kind == .copyAddress, targetID != s.localNetwork.primary?.address { return "地址已改变，请复制新地址" }
    guard needsConfirmation else { return nil }
    guard !tokens.isEmpty, tokens.allSatisfy({ $0.uid == uid && $0.pid > 1 && $0.pid != selfPID && $0.start > 0 && !$0.path.hasPrefix("/System/") && !$0.path.hasPrefix("/usr/libexec/") }) else { return "系统、其他用户和澄观自身不支持结束操作" }
    let current = Dictionary(uniqueKeysWithValues: s.processes.map { ($0.pid, $0) })
    for token in tokens {
      guard let p = current[token.pid], ProcessIdentity(p) == token else { return "目标已退出或重新启动，请重新选择" }
    }
    if kind == .quitApp {
      guard let group = s.groups.first(where: { $0.id == targetID }), group.id != "system.macos",
        group.bundlePath != nil, Set(group.processes.map(\.identity)) == Set(tokens.map { "\($0.pid):\($0.start)" }) else { return "App 身份或进程组成已改变，请重新选择" }
      if pressureRequired, metric == .cpu, group.cpu < 20 { return "目标 App 的 CPU 已回落，请重新观察" }
      if pressureRequired, metric == .memory, s.groups.max(by: { $0.memory < $1.memory })?.id != group.id { return "主要内存占用目标已改变，请重新观察" }
    }
    if kind == .stopProject {
      guard let p = s.projects.first(where: { $0.path == targetID }),
        Set(p.processes.map(\.identity)) == Set(tokens.map { "\($0.pid):\($0.start)" }), Set(p.ports) == Set(ports) else { return "项目进程或端口已改变，请重新核对" }
    }
    return nil
  }
}

struct ActionRun: Identifiable, Codable {
  enum State: String, Codable {
    case confirming = "待确认", executing = "执行中", observing = "观察中", improved = "已改善", unchanged = "无明显改善", inconclusive = "无法判断", failed = "失败", cancelled = "已取消", completed = "已完成"
  }
  let id: UUID
  let action: AdvisorAction
  let time: Date
  var state: State
  var detail: String
  var updatedAt: Date?
  var observationStartedAt: Date?
  var before: ResourceWindow?
  var after: ResourceWindow?
  var targetExited: Bool?
  var portsReleased: Bool?
}

enum ActionOutcome {
  static func assess(before: ResourceWindow, after: ResourceWindow, targetExited: Bool, workloadChanged: Bool) -> (ActionRun.State, String) {
    guard before.seconds >= 20, after.seconds >= 30, !workloadChanged else { return (.inconclusive, "连续样本不足或工作负载改变，不能判断处理效果") }
    guard targetExited else { return (.unchanged, "退出尚未完成；App 可能仍在等待保存确认") }
    let improved = (before.cpu >= 65 && after.cpu <= before.cpu - 15) || (before.pressure >= 2 && after.pressure < 2) || before.memory - after.memory >= 512 * 1024 * 1024
    let comparison = "CPU \(Int(before.cpu))% → \(Int(after.cpu))% · 内存 \(Format.memory(UInt64(max(0, before.memory)))) → \(Format.memory(UInt64(max(0, after.memory))))"
    return (improved ? .improved : .unchanged, comparison + "。这是同期变化，不能单独证明因果。")
  }
}

struct AIUsageDay: Codable, Identifiable {
  let id: String
  var requests = 0
  var succeeded = 0
  var failed = 0
  var tokens = 0
  var missingUsage = 0
}
struct AIUsageLedger: Codable {
  var days: [AIUsageDay] = []
  static func dayKey(_ time: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: time)
  }
  mutating func record(at time: Date, usage: AITokenUsage?, success: Bool) {
    let key = Self.dayKey(time)
    if !days.contains(where: { $0.id == key }) { days.insert(AIUsageDay(id: key), at: 0) }
    guard let i = days.firstIndex(where: { $0.id == key }) else { return }
    days[i].requests += 1
    if success { days[i].succeeded += 1 } else { days[i].failed += 1 }
    if let n = usage?.totalTokens, n >= 0 { days[i].tokens += n }
    else if let a = usage?.promptTokens, let b = usage?.completionTokens, a >= 0, b >= 0 { days[i].tokens += a + b }
    else { days[i].missingUsage += 1 }
    days = Array(days.prefix(31))
  }
}

struct AdaptiveAnalysisPolicy {
  var previousCPU: Double?
  var stableSince: Date?
  var lastObserved: Date?
  mutating func observe(_ s: MonitorSnapshot, hasIncident: Bool) {
    if let lastObserved, s.time <= lastObserved || s.time.timeIntervalSince(lastObserved) > 20 {
      stableSince = nil; previousCPU = nil
    }
    lastObserved = s.time
    if hasIncident || s.pressureLevel >= 2 || s.cpu >= 65 || abs(s.cpu - (previousCPU ?? s.cpu)) > 15 { stableSince = nil }
    else if stableSince == nil { stableSince = s.time }
    previousCPU = s.cpu
  }
  func minutes(base: Int, now: Date, enabled: Bool) -> Int {
    guard enabled, let stableSince, let lastObserved, now >= lastObserved,
      now.timeIntervalSince(lastObserved) <= 20 else { return base }
    let stable = now.timeIntervalSince(stableSince)
    return stable >= 1800 ? max(base, 30) : stable >= 600 ? max(base, 15) : base
  }
}

enum DeveloperContext {
  static func labels(_ s: MonitorSnapshot) -> [String] {
    let names = s.processes.filter { $0.measured && $0.cpu > 10 }.map { $0.name.lowercased() }
    var labels: [String] = []
    if names.contains(where: { ["swift-frontend", "clang", "rustc", "swift", "cargo", "cc1"].contains($0) }) { labels.append("编译") }
    if names.contains(where: { $0.contains("sourcekit") || $0.contains("indexstore") || $0 == "mdworker_shared" }) { labels.append("索引") }
    if names.contains(where: { $0.contains("xctest") || $0 == "pytest" || $0 == "testhost" }) { labels.append("测试") }
    if s.projects.contains(where: { !$0.ports.isEmpty }) { labels.append("本地服务") }
    if !s.agents.isEmpty { labels.append("编码代理") }
    return labels
  }
  static func workload(_ s: MonitorSnapshot) -> String { labels(s).sorted().joined(separator: ",") }
}

extension AIPreparedSample {
  func addingAdvisor(snapshot s: MonitorSnapshot, baseline: PersonalBaseline, actions: [AdvisorAction], care: CareScan? = nil) throws -> Self {
    var payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let values: [[String: Any]] = s.groups.sorted { $0.cpu > $1.cpu }.prefix(10).compactMap { app in
      guard let label = appIdentifiers[app.id] else { return nil }
      let b = baseline.value(appID: app.id, context: PersonalBaseline.context(s), now: sampledAt)
      return ["label": label, "baseline_ready": b?.ready ?? false, "baseline_sample_count": b?.count ?? 0,
        "median_single_core_cpu_percent": b?.ready == true ? b!.medianCPU as Any : NSNull(),
        "p95_single_core_cpu_percent": b?.ready == true ? b!.p95CPU as Any : NSNull(),
        "median_memory_bytes": b?.ready == true ? b!.medianMemory as Any : NSNull()]
    }
    // Never include process tokens, bundle/project paths, ports, local addresses or action evidence text.
    payload["local_advisor"] = ["same_context_baselines": values, "power": s.battery.plugged ? "external" : "battery",
      "workloads": DeveloperContext.labels(s), "project_count": s.projects.count,
      "service_count": s.projects.filter { !$0.ports.isEmpty }.count,
      "action_candidates": actions.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "requires_user_confirmation": $0.needsConfirmation] as [String: Any] }]
    if let care, let time = care.completedAt, time <= sampledAt, sampledAt.timeIntervalSince(time) < 86400 {
      payload["cleanup_preview"] = ["partial": care.partial, "age_seconds": sampledAt.timeIntervalSince(time),
        "is_reclaimed_space": false, "requires_user_selection": true,
        "categories": Dictionary(grouping: care.files, by: { $0.kind.rawValue }).map { key, files in
          ["kind": key, "candidate_count": files.count, "estimated_allocated_bytes": files.reduce(UInt64(0)) { $0 + $1.bytes }] as [String: Any]
        }]
    }
    return Self(json: String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self), sampledAt: sampledAt, sampleCount: sampleCount,
      observedSeconds: observedSeconds, requestedMinutes: requestedMinutes, appLabels: appLabels, includesAppNames: includesAppNames, appIdentifiers: appIdentifiers)
  }
}


struct DeveloperServiceNote: Identifiable, Equatable {
  let projectID: String
  let title: String
  let detail: String
  var id: String { projectID + title }
}
extension DeveloperContext {
  static func serviceNotes(_ s: MonitorSnapshot) -> [DeveloperServiceNote] {
    var notes: [DeveloperServiceNote] = []
    let ports = Dictionary(grouping: s.projects.flatMap { p in p.ports.map { ($0, p.path) } }, by: { $0.0 })
    for project in s.projects {
      let shared = project.ports.filter { Set((ports[$0] ?? []).map { $0.1 }).count > 1 }
      if !shared.isEmpty {
        notes.append(DeveloperServiceNote(projectID: project.path, title: "同号端口待核对", detail: "多个项目监听 \(shared.map(String.init).joined(separator: "、"))；可能使用不同地址或协议，尚不能确认冲突。"))
      }
      if !project.ports.isEmpty, project.processes.contains(where: { $0.ppid == 1 && $0.uid == getuid() && $0.start > 0 && s.time.timeIntervalSince1970 - Double($0.start) > 3600 }) {
        notes.append(DeveloperServiceNote(projectID: project.path, title: "长期后台服务", detail: "已运行超过一小时且由 launchd 托管；可能是正常服务，请核对是否仍需运行。"))
      }
    }
    return notes
  }
}
