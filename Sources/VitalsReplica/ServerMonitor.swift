import Combine
import Foundation
import LocalAuthentication
import Security

struct ServerProfile: Codable, Equatable, Sendable {
  var name: String
  var veid: String
  var host: String
  static let storageKey = "kiwiServerProfile"
  var panelURL: URL? { valid ? URL(string: "https://kiwivm.64clouds.com/\(veid)/main.php") : nil }
  var valid: Bool { !veid.isEmpty && veid.utf8.allSatisfy { (48...57).contains($0) } && veid.count < 20 }
  static func load(_ defaults: UserDefaults = .standard) -> Self? {
    guard let data = defaults.data(forKey: storageKey), let p = try? JSONDecoder().decode(Self.self, from: data), p.valid else { return nil }
    return p
  }
}

enum ServerError: LocalizedError {
  case profile, key, transport, http(Int), api(Int), malformed, vault(OSStatus)
  var errorDescription: String? {
    switch self {
    case .profile: return "请填写有效的 VEID。"
    case .key: return "请在连接设置中保存 KiwiVM API Key。"
    case .transport: return "暂时无法连接 KiwiVM，稍后自动重试。"
    case .http(let code): return "KiwiVM 接口暂不可用（HTTP \(code)）。"
    case .api(let code): return "KiwiVM 未接受请求（\(code)），请核对 VEID、API Key 和接口权限。"
    case .malformed: return "KiwiVM 未返回可识别的监测数据。"
    case .vault(let code): return "本机钥匙串暂不可用（\(code)）。"
    }
  }
}

struct ServerSnapshot: Equatable, Sendable {
  var time: Date
  var state: String?
  var hostname: String?, location: String?, os: String?
  var addresses: [String]
  var memoryTotal: Double?, memoryAvailable: Double?
  var diskTotal: Double?, mappedDiskUsed: Double?
  var transferTotal: Double?, transferUsed: Double?, reset: Date?
  var swapTotal: Double?, swapAvailable: Double?
  var load: [Double]
  var sshPort: Int?
  var cpuThrottled: Bool?, diskThrottled: Bool?
  var apiSeconds: Double
  var memoryUsed: Double? { Self.used(total: memoryTotal, available: memoryAvailable) }
  var swapUsed: Double? { Self.used(total: swapTotal, available: swapAvailable) }
  var transferRemaining: Double? { guard let total = transferTotal, let used = transferUsed else { return nil }; return max(0, total - used) }
  private static func used(total: Double?, available: Double?) -> Double? {
    guard let total, total > 0, let available, available <= total else { return nil }; return total - available
  }
  static func parse(_ data: Data, now: Date = Date(), apiSeconds: Double = 0) throws -> Self {
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = number(j["error"]), error.rounded() == error, error < Double(Int.max) else { throw ServerError.malformed }
    guard error == 0 else { throw ServerError.api(Int(error)) }
    // An empty successful envelope is not a fresh server reading.
    guard j["ve_status"] != nil || j["plan_ram"] != nil || j["data_counter"] != nil else { throw ServerError.malformed }
    func n(_ key: String, scale: Double = 1) -> Double? { number(j[key]).map { $0 * scale }.flatMap { $0.isFinite ? $0 : nil } }
    func text(_ key: String) -> String? { (j[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func flag(_ key: String) -> Bool? { n(key).flatMap { $0 == 0 ? false : ($0 == 1 ? true : nil) } }
    let loads = (text("load_average") ?? "").split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).compactMap { Double($0) }.filter { $0.isFinite && $0 >= 0 }
    return .init(time: now, state: text("ve_status"), hostname: text("live_hostname") ?? text("hostname"), location: text("node_location") ?? text("node_location_id"), os: text("os"), addresses: j["ip_addresses"] as? [String] ?? [],
      memoryTotal: n("plan_ram"), memoryAvailable: n("mem_available_kb", scale: 1024),
      diskTotal: n("plan_disk"), mappedDiskUsed: n("ve_used_disk_space_b"),
      transferTotal: n("plan_monthly_data"), transferUsed: n("data_counter"), reset: n("data_next_reset").flatMap { $0 > 0 && $0 < 4_102_444_800 ? Date(timeIntervalSince1970: $0) : nil },
      swapTotal: n("swap_total_kb", scale: 1024), swapAvailable: n("swap_available_kb", scale: 1024),
      load: Array(loads.prefix(3)), sshPort: n("ssh_port").flatMap { $0 >= 1 && $0 <= 65535 ? Int($0) : nil }, cpuThrottled: flag("is_cpu_throttled"), diskThrottled: flag("is_disk_throttled"), apiSeconds: apiSeconds)
  }
  private static func number(_ value: Any?) -> Double? {
    let v: Double?
    if let s = value as? String { v = Double(s) } else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { v = n.doubleValue } else { v = nil }
    return v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
}

/// Fixed, read-only KiwiVM endpoint. Keys stay in the POST body, never the URL.
enum KiwiClient {
  static func request(profile: ServerProfile, key: String) throws -> URLRequest {
    guard profile.valid else { throw ServerError.profile }
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServerError.key }
    var request = URLRequest(url: URL(string: "https://api.64clouds.com/v1/getLiveServiceInfo")!)
    request.httpMethod = "POST"; request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    func escaped(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
    request.httpBody = "veid=\(escaped(profile.veid))&api_key=\(escaped(key))".data(using: .utf8)
    return request
  }
  static func fetch(profile: ServerProfile, key: String) async throws -> ServerSnapshot {
    let request = try request(profile: profile, key: key)
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config, delegate: ServerNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let start = Date()
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw ServerError.transport }
    guard http.statusCode == 200 else { throw ServerError.http(http.statusCode) }
    guard data.count <= 8_000_000 else { throw ServerError.malformed }
    return try ServerSnapshot.parse(data, apiSeconds: Date().timeIntervalSince(start))
  }
}
private final class ServerNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ServerVault {
  private static let queue = DispatchQueue(label: "studio.lele.Chengguan.server-key")
  private static func query(_ veid: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "studio.lele.Chengguan.kiwivm", kSecAttrAccount as String: veid] }
  static func read(_ veid: String) async throws -> String? {
    try await withCheckedThrowingContinuation { c in queue.async {
      let context = LAContext(); context.interactionNotAllowed = true
      var q = query(veid); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecUseAuthenticationContext as String] = context
      var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
      if status == errSecItemNotFound { c.resume(returning: nil) }
      else if status == errSecSuccess, let d = result as? Data { c.resume(returning: String(data: d, encoding: .utf8)) }
      else { c.resume(throwing: ServerError.vault(status)) }
    } }
  }
  static func save(_ key: String, veid: String) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async {
      let q = query(veid), data = Data(key.utf8)
      var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(add as CFDictionary, nil)
      }
      if status == errSecSuccess { c.resume() } else { c.resume(throwing: ServerError.vault(status)) }
    } }
  }
  static func remove(_ veid: String) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async {
      let status = SecItemDelete(query(veid) as CFDictionary)
      if status == errSecSuccess || status == errSecItemNotFound { c.resume() } else { c.resume(throwing: ServerError.vault(status)) }
    } }
  }
}

@MainActor final class ServerMonitor: ObservableObject {
  static let shared = ServerMonitor()
  @Published private(set) var profile: ServerProfile?
  @Published private(set) var snapshot: ServerSnapshot?
  @Published private(set) var history = ServerHistory()
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var needsKey = false
  private var worker: Task<Void, Never>?, timer: Timer?
  private var failures = 0, nextPoll = Date.distantPast
  private var revision = 0
  private var key: String?
  private let defaults: UserDefaults
  private let fetch: (ServerProfile, String) async throws -> ServerSnapshot
  private let readKey: (String) async throws -> String?
  private let saveKey: (String, String) async throws -> Void
  private let removeKey: (String) async throws -> Void
  init(defaults: UserDefaults = .standard,
       fetch: @escaping (ServerProfile, String) async throws -> ServerSnapshot = { try await KiwiClient.fetch(profile: $0, key: $1) },
       readKey: @escaping (String) async throws -> String? = { try await ServerVault.read($0) },
       saveKey: @escaping (String, String) async throws -> Void = { try await ServerVault.save($0, veid: $1) },
       removeKey: @escaping (String) async throws -> Void = { try await ServerVault.remove($0) }) {
    self.defaults = defaults; profile = ServerProfile.load(defaults)
    self.fetch = fetch; self.readKey = readKey; self.saveKey = saveKey; self.removeKey = removeKey
    if let profile { history = .load(veid: profile.veid, defaults: defaults) }
  }
  var stale: Bool { error != nil || snapshot.map { Date().timeIntervalSince($0.time) > 150 } ?? true }
  var stateLabel: String {
    guard snapshot != nil else { return needsKey || profile != nil ? "待连接" : "未连接" }
    if stale { return "待更新" }
    switch snapshot?.state?.lowercased() { case "running": return "运行中"; case "stopped": return "已停止"; case "starting": return "启动中"; default: return "已同步" }
  }
  func start() {
    guard timer == nil else { return }
    if Date() >= nextPoll { refresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in Task { @MainActor in
      if Date() >= self.nextPoll && !self.needsKey { self.refresh() }
    } }
  }
  func stop() { timer?.invalidate(); timer = nil; worker?.cancel(); worker = nil; revision += 1; loading = false }
  func refresh() {
    guard let profile, !loading else { return }
    loading = true; let ticket = revision
    worker = Task {
      do {
        let saved: String?
        if let key { saved = key } else { saved = try await readKey(profile.veid) }
        guard !Task.isCancelled, ticket == revision else { return }
        guard let saved, !saved.isEmpty else { needsKey = true; loading = false; nextPoll = .distantFuture; return }
        key = saved; needsKey = false
        let reading = try await fetch(profile, saved)
        guard !Task.isCancelled, ticket == revision else { return }
        record(reading, veid: profile.veid)
        snapshot = reading; error = nil; failures = 0; nextPoll = Date().addingTimeInterval(60)
      } catch {
        guard !Task.isCancelled, ticket == revision else { return }
        self.error = (error as? ServerError)?.localizedDescription ?? ServerError.transport.localizedDescription
        failures = min(5, failures + 1); nextPoll = Date().addingTimeInterval(min(900, 60 * pow(2, Double(failures - 1))))
      }
      loading = false
    }
  }
  func connect(_ profile: ServerProfile, key entered: String) async throws {
    guard profile.valid else { throw ServerError.profile }
    let saved = entered.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved: String?
    if !saved.isEmpty { resolved = saved } else { resolved = try await readKey(profile.veid) }
    guard let resolved, !resolved.isEmpty else { throw ServerError.key }
    let reading = try await fetch(profile, resolved)
    try Task.checkCancellation()
    try await saveKey(resolved, profile.veid)
    worker?.cancel(); revision += 1
    if self.profile?.veid != profile.veid { history = .load(veid: profile.veid, defaults: defaults) }
    record(reading, veid: profile.veid)
    self.profile = profile; key = resolved; snapshot = reading; needsKey = false; error = nil; loading = false; failures = 0
    defaults.set(try JSONEncoder().encode(profile), forKey: ServerProfile.storageKey)
    nextPoll = Date().addingTimeInterval(60); start()
  }
  func disconnect() async throws {
    if let profile { try await removeKey(profile.veid); defaults.removeObject(forKey: ServerHistory.key(profile.veid)) }
    worker?.cancel(); revision += 1; key = nil; profile = nil; snapshot = nil; needsKey = false; loading = false; error = nil
    history = .init()
    defaults.removeObject(forKey: ServerProfile.storageKey)
  }
  private func record(_ reading: ServerSnapshot, veid: String) {
    history.record(reading)
    history.save(veid: veid, defaults: defaults)
  }
}
