import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Claude Desktop, Cowork and Code use the same account allowance. Only named
/// usage endpoints are called; credentials remain in memory and redirects are denied.
final class ClaudeQuota {
  private var lastAttempt = Date.distantPast
  private var retryAfter = Date.distantPast
  private var cached: ProviderUsage?

  func fetch(home: URL, force: Bool, allowInteraction: Bool = false, now: Date = Date()) -> ProviderUsage {
    if now < retryAfter || (!force && now.timeIntervalSince(lastAttempt) < 300), let cached { return cached }
    lastAttempt = now
    var value = ProviderUsage(id: "Claude", tokenCountsAvailable: false, source: "Claude 套餐 · Code / Cowork",
      unavailable: "在 Claude 登录后自动读取额度")
    do {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
      configuration.timeoutIntervalForRequest = 7; configuration.timeoutIntervalForResource = 9
      let session = URLSession(configuration: configuration, delegate: AINoRedirectDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      // Prefer the desktop account actually in use. CLI login can belong to a different account.
      if let login = try Self.desktopLogin(home: home, allowInteraction: allowInteraction, now: now) {
        let response = try Self.read(URL(string: "https://claude.ai/api/organizations/\(login.organization)/usage")!,
          header: "sessionKey=\(login.session)", oauth: false, session: session)
        guard let parsed = Self.parse(response, now: now) else { throw Failure.unreadable }
        value = parsed
      } else if let token = try Self.oauthToken(home: home, allowInteraction: allowInteraction, now: now) {
        let response = try Self.read(URL(string: "https://api.anthropic.com/api/oauth/usage")!,
          header: "Bearer \(token)", oauth: true, session: session)
        guard let parsed = Self.parse(response, now: now) else { throw Failure.unreadable }
        value = parsed
      }
    } catch let failure as Failure {
      value.unavailable = failure.message
      if case .rateLimited(let seconds) = failure { retryAfter = now.addingTimeInterval(seconds) }
    } catch { value.unavailable = "额度同步失败 · 点刷新重试" }
    // Retain an earlier valid reading as explicitly stale during a temporary outage.
    if value.limits.isEmpty, var previous = cached, !previous.limits.isEmpty {
      previous.expires = now; previous.unavailable = value.unavailable; value = previous
    }
    cached = value
    return value
  }

  static func parse(_ json: [String: Any], now: Date) -> ProviderUsage? {
    let definitions = [("five_hour", 300, "当前会话"), ("seven_day", 10080, "每周额度"),
      ("seven_day_sonnet", 10080, "Sonnet · 每周"), ("seven_day_opus", 10080, "Opus · 每周")]
    let windows = definitions.compactMap { key, minutes, label -> UsageWindow? in
      guard let object = json[key] as? [String: Any], let used = UsageNumeric.value(object["utilization"]),
        used >= 0, used <= 100 else { return nil }
      return UsageWindow(used: used, minutes: minutes, resets: UsageLogParser.date(object["resets_at"] as? String), label: label)
    }
    guard !windows.isEmpty else { return nil }
    return ProviderUsage(id: "Claude", limits: [UsageLimit(provider: "Claude", name: "Claude", time: now, windows: windows)],
      updated: now, tokenCountsAvailable: false, source: "Claude 套餐 · Code / Cowork", expires: now.addingTimeInterval(600))
  }

  private enum Failure: Error {
    case keychain, signedOut, unreadable, network, denied, region, rateLimited(TimeInterval)
    var message: String {
      switch self {
      case .keychain: "钥匙串未授权 · 点刷新连接"
      case .signedOut: "登录已过期 · 请在 Claude 重新登录"
      case .unreadable: "Claude 暂未返回可读额度"
      case .network: "无法连接 Claude · 点刷新重试"
      case .denied: "Claude 拒绝额度请求 · 请在 App 查看用量"
      case .region: "接口受地区限制 · 请在 Claude 查看额度"
      case .rateLimited: "Claude 暂时限流 · 稍后自动重试"
      }
    }
  }
  private final class Response: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<[String: Any], Failure> = .failure(.network)
    func set(_ result: Result<[String: Any], Failure>) { lock.lock(); defer { lock.unlock() }; self.result = result }
    func get() throws -> [String: Any] { lock.lock(); defer { lock.unlock() }; return try result.get() }
  }
  private static func read(_ url: URL, header: String, oauth: Bool, session: URLSession) throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.setValue(header, forHTTPHeaderField: oauth ? "Authorization" : "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if oauth { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
    let box = Response(), done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
      defer { done.signal() }
      guard let http = response as? HTTPURLResponse else { return }
      switch http.statusCode {
      case 200:
        guard let data, data.count <= 1_000_000,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { box.set(.failure(.unreadable)); return }
        box.set(.success(object))
      case 401: box.set(.failure(.signedOut))
      case 403:
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = object?["error"] as? [String: Any], details = error?["details"] as? [String: Any]
        box.set(.failure(details?["error_code"] as? String == "region_unavailable" ? .region : .denied))
      case 429:
        let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 600
        box.set(.failure(.rateLimited(min(86400, max(300, delay)))))
      default: box.set(.failure(.network))
      }
    }
    task.resume()
    guard done.wait(timeout: .now() + 10) == .success else { task.cancel(); throw Failure.network }
    return try box.get()
  }
  private static func secret(service: String, allowInteraction: Bool) throws -> Data? {
    let context = LAContext(); context.interactionNotAllowed = !allowInteraction
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count <= 64_000 else { throw Failure.keychain }
    return data
  }
  private struct DesktopLogin { let session: String; let organization: String }
  private static func desktopLogin(home: URL, allowInteraction: Bool, now: Date) throws -> DesktopLogin? {
    let path = home.appendingPathComponent("Library/Application Support/Claude/Cookies").path
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if db != nil { sqlite3_close(db) }; return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var versionQuery: OpaquePointer?, schemaVersion = 24
    if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &versionQuery, nil) == SQLITE_OK,
      sqlite3_step(versionQuery) == SQLITE_ROW { schemaVersion = Int(sqlite3_column_int(versionQuery, 0)) }
    sqlite3_finalize(versionQuery)
    var statement: OpaquePointer?
    // Never enumerate browser cookies or other desktop session storage.
    let sql = "SELECT host_key,name,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('.claude.ai','claude.ai') AND name IN ('sessionKey','lastActiveOrg') ORDER BY last_access_utc DESC"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    var values: [String: String] = [:], password: Data?
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let hostText = sqlite3_column_text(statement, 0), let nameText = sqlite3_column_text(statement, 1) else { continue }
      let name = String(cString: nameText), host = String(cString: hostText)
      guard values[name] == nil else { continue }
      let expiry = sqlite3_column_int64(statement, 4)
      if expiry > 0, Double(expiry) / 1_000_000 - 11_644_473_600 <= now.timeIntervalSince1970 { continue }
      var value = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
      if value.isEmpty, let bytes = sqlite3_column_blob(statement, 3) {
        let count = Int(sqlite3_column_bytes(statement, 3)); guard count > 3, count <= 16_384 else { continue }
        if password == nil { password = try secret(service: "Claude Safe Storage", allowInteraction: allowInteraction) }
        if let password {
          value = decryptCookie(Data(bytes: bytes, count: count), password: password, host: host, schemaVersion: schemaVersion) ?? ""
        }
      }
      if !value.isEmpty { values[name] = value }
    }
    guard let session = values["sessionKey"], validSession(session), let organization = values["lastActiveOrg"],
      UUID(uuidString: organization) != nil else { return nil }
    return DesktopLogin(session: session, organization: organization)
  }
  static func validSession(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16_000 && value.utf8.allSatisfy { (33...126).contains($0) && $0 != 59 && $0 != 44 }
  }
  /// macOS Chromium v10, including the host hash used by cookie schema 24+.
  static func decryptCookie(_ encrypted: Data, password: Data, host: String, schemaVersion: Int = 24) -> String? {
    guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { return nil }
    let salt = Array("saltysalt".utf8), iv = [UInt8](repeating: 32, count: 16)
    var key = [UInt8](repeating: 0, count: 16)
    let derived = password.withUnsafeBytes { passwordBytes in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress,
          password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
      }
    }
    guard derived == kCCSuccess else { return nil }
    let payload = Data(encrypted.dropFirst(3))
    var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128), length = 0
    let result = payload.withUnsafeBytes { bytes in
      CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        key, key.count, iv, bytes.baseAddress, payload.count, &output, output.count, &length)
    }
    guard result == kCCSuccess else { return nil }
    let data = Data(output.prefix(length)), hash = Data(SHA256.hash(data: Data(host.utf8)))
    if data.starts(with: hash) { return String(data: data.dropFirst(hash.count), encoding: .utf8) }
    guard schemaVersion < 24 else { return nil }
    // Schema <24 has no host prefix.
    guard let value = String(data: data, encoding: .utf8), validSession(value) else { return nil }
    return value
  }
  private static func oauthToken(home: URL, allowInteraction: Bool, now: Date) throws -> String? {
    let path = home.appendingPathComponent(".claude/.credentials.json")
    let data: Data?
    if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000 { data = try? Data(contentsOf: path) }
    else { data = try secret(service: "Claude Code-credentials", allowInteraction: allowInteraction) }
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String,
      validSession(token) else { return nil }
    if let expiry = UsageNumeric.value(oauth["expiresAt"]), expiry / 1000 <= now.timeIntervalSince1970 { throw Failure.signedOut }
    return token
  }
}

enum ClaudeUsageSources {
  /// Bounded metadata traversal; only .claude/projects roots and audit.jsonl are
  /// selected. Build outputs, plug-ins, symlinks and conversations are not cached.
  static func roots(home: URL) -> [URL] {
    let fm = FileManager.default
    var result = [home.appendingPathComponent(".claude/projects")]
    let support = home.appendingPathComponent("Library/Application Support/Claude")
    var queue = ["claude-code-sessions", "local-agent-mode-sessions"].map { (support.appendingPathComponent($0), 0) }
    let excluded: Set<String> = [".git", "node_modules", "outputs", "build", ".build", "skills", "skills-plugin", ".claude"]
    var index = 0
    while index < queue.count, index < 2000 {
      let (base, depth) = queue[index]; index += 1
      let projects = base.appendingPathComponent(".claude/projects"), audit = base.appendingPathComponent("audit.jsonl")
      for candidate in [projects, audit] where fm.fileExists(atPath: candidate.path) { result.append(candidate) }
      guard depth < 4 else { continue }
      for child in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
        guard !excluded.contains(child.lastPathComponent), let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          values.isDirectory == true, values.isSymbolicLink != true else { continue }
        if queue.count < 2000 { queue.append((child, depth + 1)) }
      }
    }
    return Array(Set(result.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
  }
}
