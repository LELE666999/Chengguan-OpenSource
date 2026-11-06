import Foundation

/// Only the documented monitoring fields enter the UI. Serial numbers, tokens and
/// user/file lists are deliberately absent from this model and from AI payloads.
struct NASConfiguration: Codable, Equatable, Sendable {
  var endpoint = ""
  var username = ""
  var clientID = UUID().uuidString
  var isConfigured: Bool { !endpoint.isEmpty && !username.isEmpty }
  static func baseURL(_ input: String) throws -> URL {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let c = URLComponents(string: text), let host = c.host, !host.isEmpty,
      ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.user == nil, c.password == nil,
      c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
      c.port == nil || (1...65535).contains(c.port!), let url = c.url
    else { throw NASError.message("请填写 NAS 地址，例如 http://nas.local:9999") }
    if c.scheme?.lowercased() == "http" && !isLocalHost(host) {
      throw NASError.message("远程连接请使用 HTTPS；HTTP 仅用于局域网地址。")
    }
    return url
  }
  static func isLocalHost(_ host: String) -> Bool {
    let h = host.lowercased()
    if h == "localhost" || h.hasSuffix(".local") || h == "[::1]" || h == "::1" { return true }
    let parts = h.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, h.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
    return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
      || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
  }
}

enum NASError: LocalizedError {
  case message(String), connection(String), expired, otp(String), keychain
  var errorDescription: String? {
    switch self {
    case .message(let text), .connection(let text): return text
    case .expired: return "登录已失效，请重新连接 NAS。"
    case .otp: return "请输入 NAS 的两步验证码。"
    case .keychain: return "请解锁登录钥匙串，或重新输入 NAS 密码。"
    }
  }
}

/// Firmware occasionally changes numbers to strings. Decode either, without
/// interpreting missing values as zero or guessing that 0.8 means 80 percent.
enum NASValue: Decodable, Sendable {
  case object([String: NASValue]), array([NASValue]), string(String), number(Double), bool(Bool), null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([NASValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: NASValue].self)) }
  }
  subscript(_ key: String) -> NASValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
  var list: [NASValue] { if case .array(let v) = self { return v }; return [] }
  var first: NASValue { list.first ?? .null }
  var text: String? { if case .string(let v) = self, !v.isEmpty { return v }; return nil }
  var number: Double? {
    let v: Double?
    switch self { case .number(let n): v = n; case .string(let s): v = Double(s); default: v = nil }
    return v.flatMap { $0.isFinite ? $0 : nil }
  }
  var flag: Bool { if case .bool(let v) = self { return v }; return false }
  var percent: Double? { number.flatMap { (0...100).contains($0) ? $0 : nil } }
  var nonnegative: Double? { number.flatMap { $0 >= 0 ? $0 : nil } }
  var integerText: String? { number.map { String(format: "%.0f", $0) } }
  var temperature: Double? { number.flatMap { (-30...150).contains($0) ? $0 : nil } }
  var rate: Double? {
    guard let n = self["value"].nonnegative, let unit = self["unit"].text?.lowercased() else { return nil }
    let scale: Double
    switch unit { case "b/s": scale = 1; case "kb/s": scale = 1_000; case "mb/s": scale = 1_000_000
    case "gb/s": scale = 1_000_000_000; case "kib/s": scale = 1024; case "mib/s": scale = 1_048_576
    default: return nil }
    return n * scale
  }
}

struct NASDisk: Identifiable, Sendable {
  let id: String, name: String, model: String
  let size: Double?, temperature: Double?, status: String
}
struct NASPool: Identifiable, Sendable {
  let id: String, name: String, total: Double?, used: Double?, free: Double?, filesystem: String
  var level = ""
  var medium = ""
  var poolCapacity: Double?
  var unallocated: Double?
  var volumes: [NASVolume] = []
  var fraction: Double? { guard let total, total > 0, let used else { return nil }; return min(1, max(0, used / total)) }
}
struct NASVolume: Identifiable, Sendable {
  let id: String, name: String, total: Double?, used: Double?, available: Double?, filesystem: String
}
struct NASFan: Identifiable, Sendable { let id: String, name: String; let rpm: Double? }
struct NASSnapshot: Sendable {
  var time = Date()
  var name = "NAS", model = "", firmware = "", cpuModel = ""
  var cpu: Double?, memory: Double?, memoryTotal: Double?, memoryUsed: Double?, temperature: Double?
  var upload: Double?, download: Double?, uptime: Double?
  var disks: [NASDisk] = [], pools: [NASPool] = [], fans: [NASFan] = []
  var unavailable: [String] = []
  var total: Double? { pools.isEmpty || pools.contains(where: { $0.total == nil }) ? nil : pools.compactMap(\.total).reduce(0, +) }
  var free: Double? { pools.isEmpty || pools.contains(where: { $0.free == nil }) ? nil : pools.compactMap(\.free).reduce(0, +) }

  static func parse(_ values: [String: NASValue], unavailable: [String] = [], now: Date = Date()) -> NASSnapshot {
    let common = values["machine"]?["common"] ?? .null, hardware = values["machine"]?["hardware"] ?? .null
    let status = values["status"] ?? .null, monitor = values["monitor"] ?? .null, thermal = values["thermal"] ?? .null
    let stat = values["stat"] ?? .null, overview = stat["overview"]
    var s = NASSnapshot(time: now)
    s.name = status["dev_name"].text ?? common["nas_name"].text ?? "NAS"
    s.model = common["model"].text ?? ""; s.firmware = common["system_version"].text ?? ""
    s.cpuModel = hardware["cpu"].first["model"].text ?? ""
    s.cpu = overview["cpu"].first["used_percent"].percent ?? monitor["cpu_usage_rate"].percent
    s.memory = overview["mem"].first["used_percent"].percent ?? monitor["ram_usage_rate"].percent
    s.memoryTotal = stat["mem"]["structure"]["total"].nonnegative
    s.memoryUsed = stat["mem"]["structure"]["used"].nonnegative
    s.temperature = overview["cpu"].first["temp"].temperature ?? thermal["cpu_temperature"].temperature
    s.upload = values["net"]?["series"].first["send_rate"].nonnegative ?? monitor["upload_speed"].rate
    s.download = values["net"]?["series"].first["recv_rate"].nonnegative ?? monitor["download_speed"].rate
    s.uptime = (status["total_run_time"].nonnegative ?? common["run_time"].nonnegative)
      .flatMap { $0 < Double(Int.max) ? $0 : nil }
    s.pools = (values["pools"]?["result"].list ?? []).enumerated().map { i, p in
      // A pool's used/free describe allocation TO volumes, not files IN volumes.
      // A fully allocated pool can contain almost empty filesystems. Never use
      // pool allocation to calculate a file-space alert or NAS available space.
      let volumes = p["volumes"].list.enumerated().map { j, v -> NASVolume in
        let total = v["total"].nonnegative
        let used = v["used"].nonnegative.flatMap { n in total.map { n <= $0 ? n : nil } ?? n }
        let available = (v["available"].nonnegative ?? v["free"].nonnegative
          ?? total.flatMap { t in used.map { t - $0 } }).flatMap { n in total.map { n <= $0 ? n : nil } ?? n }
        return NASVolume(id: "\(i)-\(j)", name: v["label"].text ?? v["name"].text ?? "存储空间 \(j + 1)",
          total: total, used: used, available: available, filesystem: v["filesystem"].text ?? "")
      }
      func completeSum(_ key: KeyPath<NASVolume, Double?>) -> Double? {
        guard !volumes.isEmpty, volumes.allSatisfy({ $0[keyPath: key] != nil }) else { return nil }
        let sum = volumes.compactMap { $0[keyPath: key] }.reduce(0, +)
        return sum.isFinite ? sum : nil
      }
      let filesystems = Array(Set(volumes.map(\.filesystem).filter { !$0.isEmpty })).sorted().joined(separator: " · ")
      let rawLevel = p["level"].text?.uppercased() ?? ""
      let level = rawLevel == "BASIC" ? "Basic" : rawLevel
      let descriptions = p["disks"].list.map { d in ["name", "label", "model", "dev_path"].compactMap { d[$0].text }.joined(separator: " ").lowercased() }
      let medium = descriptions.contains(where: { $0.contains("nvme") }) ? "NVMe"
        : descriptions.contains(where: { $0.contains("ssd") }) ? "SSD" : ""
      return NASPool(id: String(i), name: p["label"].text ?? "存储池 \(i + 1)",
        total: completeSum(\.total), used: completeSum(\.used), free: completeSum(\.available), filesystem: filesystems,
        level: level, medium: medium, poolCapacity: p["total"].nonnegative, unallocated: p["free"].nonnegative, volumes: volumes)
    }
    s.disks = (values["disks"]?["result"].list ?? []).enumerated().map { i, d in
      // Raw numeric states vary with firmware; never label an unknown code healthy.
      let state = d["status"].text ?? d["status"].integerText.map { "状态码 \($0)" } ?? "未提供状态"
      return NASDisk(id: String(i), name: d["label"].text ?? "硬盘 \(i + 1)", model: d["model"].text ?? "",
                     size: d["size"].nonnegative, temperature: d["temperature"].temperature, status: state)
    }
    for (key, title) in [("cpu_fan", "CPU 风扇"), ("device_fan", "机箱风扇")] {
      s.fans += overview[key].list.enumerated().map { i, f in NASFan(id: "\(key)-\(i)", name: title + (i > 0 ? " \(i + 1)" : ""), rpm: f["speed"].nonnegative) }
    }
    if s.fans.isEmpty {
      s.fans = thermal["fan_list"].list.enumerated().map { i, f in NASFan(id: String(i), name: f["label"].text ?? "风扇 \(i + 1)", rpm: f["speed"].nonnegative) }
    }
    s.unavailable = unavailable
    return s
  }
  var suggestions: [String] {
    var result: [String] = []
    for p in pools where (p.fraction ?? 0) >= 0.9 { result.append("\(p.name) 已用超过 90%，建议检查大文件与备份保留份数。") }
    if let cpu, cpu >= 90 { result.append("CPU 当前 \(Int(cpu))%，可在绿联任务管理器查看高占用服务。") }
    if let temperature, temperature >= 85 { result.append("CPU 当前 \(Int(temperature))°C，建议检查通风并观察是否持续升温。") }
    if let memory, memory >= 90 { result.append("内存当前 \(Int(memory))%；缓存也会占用内存，请结合任务管理器判断。") }
    return result
  }
}
