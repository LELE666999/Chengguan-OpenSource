import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable {
  case mimo, deepseek, qwen, zhipu, kimi, minimax, siliconflow, compatible
  var id: String { rawValue }
  var title: String {
    switch self {
    case .mimo: "小米 MiMo"; case .deepseek: "DeepSeek"; case .qwen: "通义千问"
    case .zhipu: "智谱 GLM"; case .kimi: "Kimi"; case .minimax: "MiniMax"
    case .siliconflow: "硅基流动"; case .compatible: "自定义接口"
    }
  }
  var endpoint: String {
    switch self {
    case .mimo: "https://api.xiaomimimo.com/v1"
    case .deepseek: "https://api.deepseek.com"
    case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
    case .kimi: "https://api.moonshot.cn/v1"
    case .minimax: "https://api.minimax.cn/v1"
    case .siliconflow: "https://api.siliconflow.cn/v1"
    case .compatible: ""
    }
  }
  var models: [String] {
    switch self {
    case .mimo: ["mimo-v2.6-flash", "mimo-v2.6-pro", "mimo-v2.6-pro-ultraspeed"]
    case .deepseek: ["deepseek-flash", "deepseek-v4-pro"]
    case .qwen: ["qwen3.8-flash", "qwen3.7-plus", "qwen3.8-max"]
    case .zhipu: ["glm-5.3-flash", "glm-5.3-flashx", "glm-5.3"]
    case .kimi: ["kimi-k2.6", "kimi-k2.7-code"]
    case .minimax: ["MiniMax-M3.1-Flash", "MiniMax-M3"]
    case .siliconflow, .compatible: []
    }
  }
  static func matching(_ endpoint: String) -> Self? {
    guard let url = try? AIEndpoint.base(endpoint), let host = url.host else { return nil }
    return allCases.first { provider in
      guard provider != .compatible, let known = try? AIEndpoint.base(provider.endpoint) else { return false }
      return known.host == host && known.path == url.path
    }
  }
}

struct AIConfiguration: Codable, Equatable {
  var provider: AIProvider = .mimo
  var endpoint = AIProvider.mimo.endpoint
  var model = "mimo-v2.6-flash"

  func validated() throws -> AIConfiguration {
    let url = try AIEndpoint.base(endpoint)
    let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 150,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw AIAnalysisError.message("请填写有效的模型名称。") }
    return AIConfiguration(provider: provider, endpoint: url.absoluteString, model: name)
  }
}

enum AIEndpoint {
  static func base(_ text: String) throws -> URL {
    guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
    else { throw AIAnalysisError.message("接口地址需为 HTTPS，且不能包含账号、密码、查询参数或片段。") }
    parts.scheme = "https"
    parts.host = host.lowercased()
    if parts.port == 443 { parts.port = nil }
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    if parts.path.hasSuffix("/chat/completions") { parts.path.removeLast("/chat/completions".count) }
    guard let url = parts.url else { throw AIAnalysisError.message("接口地址无效。") }
    return url
  }
  static func completion(_ text: String) throws -> URL {
    try base(text).appendingPathComponent("chat/completions")
  }
  static func models(_ config: AIConfiguration) throws -> URL {
    let url = try base(config.endpoint).appendingPathComponent("models")
    guard config.provider == .siliconflow else { return url }
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "sub_type", value: "chat")]
    return parts.url!
  }
  static func isTokenPlan(_ text: String) -> Bool {
    guard let url = try? base(text), let host = url.host else { return false }
    return host.hasSuffix(".xiaomimimo.com") && host.hasPrefix("token-plan-")
  }
}

enum AIAnalysisMode: String, CaseIterable, Identifiable, Codable {
  case overview = "综合体检", lag = "卡顿排查", energy = "省电建议", summary = "运行摘要"
  var shortTitle: String { switch self { case .overview: "体检"; case .lag: "卡顿"; case .energy: "省电"; case .summary: "摘要" } }
  var id: String { rawValue }
  var symbol: String {
    switch self { case .overview: "stethoscope"; case .lag: "speedometer"; case .energy: "leaf"; case .summary: "text.alignleft" }
  }
  var instruction: String {
    switch self {
    case .overview: "综合分析资源压力、容量、温度和当前资源大户，优先给最值得处理的事项。"
    case .lag: "排查可能的卡顿原因，区分证据和假设，给出下一步观察方法。"
    case .energy: "结合电池、CPU、GPU和资源占用给省电建议，接通电源时说明上下文。"
    case .summary: "用容易理解的中文概括本次采样和观察窗口，不将瞬时读数描述为持续状态。"
    }
  }
}

struct AIPreparedSample {
  let json: String
  let sampledAt: Date
  let sampleCount: Int
  let observedSeconds: Double
  let requestedMinutes: Int
  let appLabels: [String: String] // Only used locally; never serialized into a request by default.
  let includesAppNames: Bool
  var appIdentifiers: [String: String] = [:] // Local stable ID → anonymous label; never uploaded.

  static func prepare(snapshot s: MonitorSnapshot, history: [HistoryPoint], minutes: Int,
                      includeAppNames: Bool, paused: Bool, now: Date = Date()) throws -> Self {
    guard !paused else { throw AIAnalysisError.message("当前已暂停采样，请继续采样后再准备分析数据。") }
    guard s.totalMemory > 0, now.timeIntervalSince(s.time) >= -5,
      now.timeIntervalSince(s.time) <= 30 else {
      throw AIAnalysisError.message("监测数据尚未就绪或已过期，请等待新一轮采样。")
    }
    let window = [5, 15, 30].contains(minutes) ? minutes : 15
    func number(_ value: Double?) -> Any {
      guard let value, value.isFinite, value >= 0 else { return NSNull() }
      return (value * 100).rounded() / 100
    }
    let points = history.filter {
      $0.time >= s.time.addingTimeInterval(-Double(window) * 60) && $0.time <= s.time
    }.sorted { $0.time < $1.time }
    let span = points.last.flatMap { last in points.first.map { last.time.timeIntervalSince($0.time) } } ?? 0
    let maxGap = zip(points, points.dropFirst()).map { $1.time.timeIntervalSince($0.time) }.max() ?? 0
    func stats(_ values: [Double]) -> [String: Any] {
      let valid = values.filter { $0.isFinite && $0 >= 0 }
      return ["sample_count": valid.count, "mean": number(valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)),
              "max": number(valid.max())]
    }
    let measured = s.groups.filter { $0.measuredCount > 0 }
    let candidates = Array(measured.sorted { $0.cpu > $1.cpu }.prefix(5))
      + Array(measured.sorted { $0.memory > $1.memory }.prefix(5))
      + Array(measured.sorted { $0.readRate + $0.writeRate > $1.readRate + $1.writeRate }.prefix(3))
      + Array(measured.sorted { ($0.networkIn ?? 0) + ($0.networkOut ?? 0) > ($1.networkIn ?? 0) + ($1.networkOut ?? 0) }.prefix(3))
    var identifiers: [String: String] = [:]
    var seen = Set<String>(), labels: [String: String] = [:], apps: [[String: Any]] = []
    for app in candidates where seen.insert(app.id).inserted {
      let label = "App\(apps.count + 1)"
      let name = String(app.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(80))
      labels[label] = name
      identifiers[app.id] = label
      var record: [String: Any] = ["label": label, "cpu_single_core_percent": number(app.cpu),
        "group_kind": app.id == "system.macos" ? "system_aggregate" : "application",
        "memory_bytes": app.memory, "disk_read_bytes_per_second": number(app.readRate),
        "disk_write_bytes_per_second": number(app.writeRate), "measured_process_count": app.measuredCount,
        "download_bytes_per_second": number(app.networkIn), "upload_bytes_per_second": number(app.networkOut),
        "process_count": app.processes.count]
      if includeAppNames { record["name"] = name }
      apps.append(record)
    }
    let pressure: Any = switch s.pressureLevel {
    case 1: "normal"
    case 2: "warning"
    case 4: "critical"
    default: NSNull()
    }
    let payload: [String: Any] = [
      "schema_version": 1,
      "units": ["cpu_percent": "whole_machine_0_to_100", "app_cpu_single_core_percent": "one_core_100_can_exceed_100",
                "memory_and_disk": "bytes", "rates": "bytes_per_second", "temperature": "celsius"],
      "hardware": ["chip": SystemValue.chip, "logical_cpu_count": s.coreUsage.count,
                   "macos_version": ProcessInfo.processInfo.operatingSystemVersionString],
      "current": ["sample_age_seconds": number(now.timeIntervalSince(s.time)),
        "cpu_percent": number(s.cpu), "cpu_user_percent": number(s.user), "cpu_system_percent": number(s.system),
        "load_average_1m": number(s.load), "gpu_percent": number(s.gpu),
        "memory_total_bytes": s.totalMemory, "memory_used_bytes": s.usedMemory, "memory_pressure": pressure,
        "swap_bytes": s.swap, "disk_total_bytes": s.primaryVolume?.total as Any? ?? NSNull(),
        "disk_free_bytes": s.primaryVolume?.free as Any? ?? NSNull(),
        "disk_read_bytes_per_second": number(s.read), "disk_write_bytes_per_second": number(s.write),
        "download_bytes_per_second": number(s.download), "upload_bytes_per_second": number(s.upload),
        "temperature_c": number(s.temperature), "fan_rpm": number(s.fan),
        "battery_percent": number(s.battery.percent), "battery_health_percent": number(s.battery.health),
        "battery_cycles": s.battery.cycles as Any? ?? NSNull(), "battery_power_watts": number(s.battery.watts),
        "battery_charging": s.battery.percent == nil ? NSNull() : s.battery.charging as Any,
        "power_connected": s.battery.percent == nil ? NSNull() : s.battery.plugged as Any,
        "unmeasured_process_count": s.unmeasured, "collector_reported_error": s.error != nil] as [String: Any],
      "observed_window": ["requested_minutes": window, "sample_count": points.count,
        "observed_span_seconds": number(span), "maximum_sample_gap_seconds": number(maxGap),
        "cpu_percent": stats(points.map(\.cpu)), "memory_used_bytes": stats(points.map(\.memory)),
        "gpu_percent": stats(points.compactMap(\.gpu)), "temperature_c": stats(points.compactMap(\.temperature)),
        "download_bytes_per_second": stats(points.map(\.download)), "upload_bytes_per_second": stats(points.map(\.upload)),
        "disk_read_bytes_per_second": stats(points.map(\.read)), "disk_write_bytes_per_second": stats(points.map(\.write))] as [String: Any],
      "top_apps_current_sample_only": apps,
      "limitations": ["Only observed samples; gaps and sleep are not continuous monitoring.",
        "system_aggregate combines many OS processes; it is not an app that can be restarted or configured.",
        "Process counts and resource ranks have no personal baseline; neither alone establishes an anomaly.",
        "App metrics may be partial when processes cannot be measured.",
        "Network rates do not measure Internet latency or maximum bandwidth.",
        "Missing metrics are null or have zero valid samples, never infer a measurement from them."]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    return Self(json: String(decoding: data, as: UTF8.self), sampledAt: s.time, sampleCount: points.count,
                observedSeconds: span, requestedMinutes: window, appLabels: labels, includesAppNames: includeAppNames, appIdentifiers: identifiers)
  }
}

struct AIReport: Codable, Equatable {
  enum Status: String, Codable { case normal, attention, insufficient }
  enum Priority: String, Codable { case high, medium, low
    var title: String { switch self { case .high: "优先关注"; case .medium: "建议优化"; case .low: "可以留意" } }
    var rank: Int { switch self { case .high: 0; case .medium: 1; case .low: 2 } }
  }
  enum Target: String, Codable, Sendable {
    case cpu, memory, disk, network, gpu, battery, other
    var tab: MonitorTab? {
      switch self { case .cpu: .cpu; case .memory: .memory; case .disk: .disk; case .network: .network;
      case .gpu: .gpu; case .battery: .battery; case .other: nil }
    }
  }
  struct Finding: Codable, Equatable {
    let priority: Priority
    let title: String
    let evidence: String
    let explanation: String
    let suggestion: String
    let target: Target
  }
  let status: Status
  let summary: String
  let findings: [Finding]
  let limitations: [String]
  let nextChecks: [String]
  enum CodingKeys: String, CodingKey { case status, summary, findings, limitations; case nextChecks = "next_checks" }

  static func parse(_ content: String) throws -> Self {
    var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```"), let first = text.firstIndex(of: "\n"), text.hasSuffix("```") {
      text = String(text[text.index(after: first)...].dropLast(3))
    }
    guard text.utf8.count <= 64_000, let data = text.data(using: .utf8),
      let report = try? JSONDecoder().decode(Self.self, from: data),
      !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      report.summary.count <= 2000, report.findings.count <= 8,
      report.limitations.count <= 8, report.nextChecks.count <= 8,
      (report.limitations + report.nextChecks).allSatisfy({ !$0.isEmpty && $0.count <= 1500 }),
      report.findings.allSatisfy({ f in
        [f.title, f.evidence, f.explanation, f.suggestion].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 2000 }
      })
    else { throw AIAnalysisError.message("模型返回的报告格式不完整，未生成诊断结果。可检查模型是否支持 JSON 输出后重新分析。") }
    return report
  }
}

struct AITokenUsage: Codable, Equatable {
  let promptTokens: Int?
  let completionTokens: Int?
  let totalTokens: Int?
  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
  }
}

struct AIAnalysisRecord: Identifiable, Codable {
  let id: UUID
  let createdAt: Date
  let sampledAt: Date
  let mode: AIAnalysisMode
  let provider: String
  let model: String
  let requestedMinutes: Int
  let sampleCount: Int
  let observedSeconds: Double
  let appLabels: [String: String]
  let report: AIReport
  let usage: AITokenUsage?
  let duration: Double
  var trigger: String? = nil

  // Resolve anonymized labels locally. Actual App names never need to be sent to a model for attribution.
  func displayText(_ text: String) -> String {
    // Unicode word boundaries do not split "App1占用"; use ASCII identifier boundaries
    // so Chinese prose resolves correctly without matching MyApp1 or part of App10.
    guard let expression = try? NSRegularExpression(pattern: "(?i)(?<![A-Za-z0-9_])App\\s*([0-9]+)(?![A-Za-z0-9_])") else { return text }
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: result),
        let name = appLabels["App" + String(result[numberRange])] else { continue }
      result.replaceSubrange(range, with: name)
    }
    return result
  }

  var conciseSummary: String {
    let text = displayText(report.summary).replacingOccurrences(of: "\n", with: " ")
    return text.count > 75 ? String(text.prefix(74)) + "…" : text
  }
  var primaryFinding: AIReport.Finding? { report.findings.min { $0.priority.rank < $1.priority.rank } }
  func isRecent(at date: Date = Date()) -> Bool { date.timeIntervalSince(sampledAt) < 900 && date >= sampledAt }

  var markdown: String {
    var text = "# 澄观 · \(mode.rawValue)\n\n\(createdAt.formatted()) · \(provider) / \(model)\n\n\(report.summary)\n"
    for f in report.findings.sorted(by: { $0.priority.rank < $1.priority.rank }) {
      text += "\n## \(f.priority.title) · \(f.title)\n\n依据：\(f.evidence)\n\n分析：\(f.explanation)\n\n建议：\(f.suggestion)\n"
    }
    text += "\n## 数据范围\n\n采样时间：\(sampledAt.formatted())；观察 \(Int(observedSeconds)) 秒，\(sampleCount) 个样本。\n"
    text += "\n\n## 限制与后续观察\n"
    for line in report.limitations + report.nextChecks { text += "\n- \(line)" }
    text += "\n\nAI 建议需结合实际使用判断；澄观本报告仅分析；处理及复测结果见本机处理记录。\n"
    return displayText(text)
  }
}

enum AIAnalysisError: LocalizedError {
  case message(String)
  case http(Int)
  case keychain
  var errorDescription: String? {
    switch self {
    case .message(let text): text
    case .http(let status): AIAnalysisClient.httpError(status).localizedDescription
    case .keychain: "钥匙串暂不可用，请解锁登录钥匙串，或在设置中重新保存 Key。"
    }
  }
}
