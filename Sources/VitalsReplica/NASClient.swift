import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum NASVault {
  private static let service = "studio.lele.Chengguan.nas"
  private static let queue = DispatchQueue(label: "studio.lele.Chengguan.nas-keychain", qos: .utility)
  private static func query(_ config: NASConfiguration) throws -> [String: Any] {
    let base = try NASConfiguration.baseURL(config.endpoint).absoluteString
    let account = SHA256.hash(data: Data((base + ":" + config.username).utf8)).map { String(format: "%02x", $0) }.joined()
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }
  static func read(_ config: NASConfiguration) async throws -> String {
    try await withCheckedThrowingContinuation { c in queue.async {
      do {
        var q = try query(config)
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        q[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &data) == errSecSuccess,
          let bytes = data as? Data, let password = String(data: bytes, encoding: .utf8) else { throw NASError.keychain }
        c.resume(returning: password)
      } catch { c.resume(throwing: error) }
    } }
  }
  static func save(_ password: String, config: NASConfiguration) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async {
      do {
        let q = try query(config), attrs = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
          var item = q.merging(attrs) { _, new in new }
          item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
          item[kSecAttrLabel as String] = "澄观 · NAS"
          status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NASError.keychain }
        c.resume()
      } catch { c.resume(throwing: error) }
    } }
  }
  static func remove(_ config: NASConfiguration) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async {
      do {
        let status = SecItemDelete(try query(config) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NASError.keychain }
        c.resume()
      } catch { c.resume(throwing: error) }
    } }
  }
}

enum NASRSA {
  /// Convert an RSA SPKI (or PKCS#1) public key to Security.framework's PKCS#1.
  static func keyData(_ header: String) throws -> Data {
    func decode(_ text: String) -> Data? {
      let cleaned = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }
        .joined().components(separatedBy: .whitespacesAndNewlines).joined()
      return Data(base64Encoded: cleaned)
    }
    guard var data = decode(header), data.count <= 8192 else { throw NASError.message("NAS 未返回有效的登录公钥。") }
    // DXP4800 GT / UGOS 1.19 wraps a PEM document in base64, and labels an
    // SPKI key "RSA PUBLIC KEY". Inspect DER tags instead of trusting that label.
    if let pem = String(data: data, encoding: .utf8), pem.hasPrefix("-----BEGIN ") {
      guard let inner = decode(pem), inner.count <= 8192 else { throw NASError.message("NAS 登录公钥格式无效。") }
      data = inner
    }
    let bytes = [UInt8](data)
    func element(_ offset: Int) throws -> (tag: UInt8, start: Int, end: Int) {
      guard offset + 2 <= bytes.count else { throw NASError.message("NAS 登录公钥不完整。") }
      var length = Int(bytes[offset + 1]), start = offset + 2
      if length >= 128 {
        let count = length & 127
        guard (1...4).contains(count), start + count <= bytes.count else { throw NASError.message("NAS 登录公钥格式无效。") }
        length = 0
        for i in 0..<count { length = length * 256 + Int(bytes[start + i]) }
        start += count
      }
      guard length > 0, start + length <= bytes.count else { throw NASError.message("NAS 登录公钥格式无效。") }
      return (bytes[offset], start, start + length)
    }
    let outer = try element(0), first = try element(outer.start)
    guard outer.tag == 0x30, outer.end == bytes.count else { throw NASError.message("NAS 登录公钥格式无效。") }
    if first.tag == 0x02 { return data }
    let bits = try element(first.end)
    guard first.tag == 0x30, bits.tag == 0x03, bytes[bits.start] == 0, bits.end == outer.end else {
      throw NASError.message("NAS 登录公钥格式无效。")
    }
    return Data(bytes[(bits.start + 1)..<bits.end])
  }
  static func encrypt(_ password: String, header: String) throws -> String {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(try keyData(header) as CFData, attrs as CFDictionary, &error),
      SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1),
      let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, &error)
    else { throw NASError.message("无法加密 NAS 登录密码，请检查地址和固件。") }
    return (encrypted as Data).base64EncodedString()
  }
}

actor NASClient {
  // An explicit read allowlist prevents monitoring from becoming a generic UGOS
  // command executor. The only POSTs below are the user's own login handshake.
  static let endpoints: [(String, String, String)] = [
    ("machine", "/ugreen/v1/sysinfo/machine/common", "设备信息"),
    ("status", "/ugreen/v1/desktop/components/data?id=desktop.component.SystemStatus", "系统状态"),
    ("monitor", "/ugreen/v1/desktop/components/data?id=desktop.component.DeviceMonitoring", "资源占用"),
    ("thermal", "/ugreen/v1/desktop/components/data?id=desktop.component.TemperatureMonitoring", "温度"),
    ("stat", "/ugreen/v1/taskmgr/stat/get_all", "任务管理器"),
    ("net", "/ugreen/v1/taskmgr/stat/net", "网络"),
    ("pools", "/ugreen/v1/storage/pool/list", "存储池"),
    ("disks", "/ugreen/v2/storage/disk/list", "硬盘")
  ]
  let config: NASConfiguration
  private let session: URLSession
  private var token = "", password = "", challenge = "", authType = "url"
  private var metadata: [String: NASValue] = [:]
  private var metadataTime = Date.distantPast
  init(config: NASConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
    self.config = config
    sessionConfiguration.timeoutIntervalForRequest = 10
    sessionConfiguration.timeoutIntervalForResource = 20
    sessionConfiguration.urlCache = nil
    // Ephemeral's private in-memory cookie jar is required by some UGOS builds.
    // It is never the browser/shared jar, and is discarded with this client.
    sessionConfiguration.httpShouldSetCookies = true
    self.session = URLSession(configuration: sessionConfiguration, delegate: AINoRedirectDelegate(), delegateQueue: nil)
  }
  func login(password: String, otp: String = "", trust: Bool = false) async throws {
    self.password = password
    if !otp.isEmpty && !challenge.isEmpty {
      let (result, _) = try await request("/ugreen/v1/verify/code/login", body: ["code": otp, "type": 1, "token_id": challenge,
        "trust": trust, "trust_info": ["client_type": "pc", "system": "macos", "dev_name": "澄观"]])
      let data = try Self.unwrap(result, operation: "两步验证")
      if let t = data["token"].text { token = t; authType = data["auth_type"].text ?? "url"; challenge = ""; return }
      challenge = ""
    }
    let (_, header) = try await request("/ugreen/v1/verify/check?token=", body: ["username": config.username])
    guard let rsa = header.value(forHTTPHeaderField: "x-rsa-token") else { throw NASError.message("NAS 未返回登录公钥，请检查接口地址。") }
    let encrypted = try NASRSA.encrypt(password, header: rsa)
    let (response, _) = try await request("/ugreen/v1/verify/login", body: ["username": config.username,
      "password": encrypted, "is_simple": false, "keepalive": true, "otp": true])
    let data = try Self.unwrap(response, operation: "登录")
    if let t = data["token"].text { token = t; authType = data["auth_type"].text ?? "url"; return }
    if let id = data["token_id"].text { challenge = id; throw NASError.otp(id) }
    throw NASError.message("NAS 登录未完成，请检查账号或两步验证设置。")
  }
  static func unwrap(_ response: NASValue, operation: String = "读取监测") throws -> NASValue {
    guard response["code"].number == 200 else {
      if [1024, 1010, 401].contains(response["code"].number ?? 0) { throw NASError.expired }
      // Codes and a fixed operation identify the failing phase, without exposing
      // arbitrary server text (which may echo private identifiers or tokens).
      let code = response["code"].integerText ?? "未知"
      let detail: String
      switch code {
      case "1003": detail = "账号或密码未通过验证"
      case "1005": detail = "此固件未接受请求参数"
      case "403": detail = "账号没有读取权限"
      default: detail = "NAS 拒绝了请求"
      }
      throw NASError.message("\(operation)：\(detail)（\(code)）。")
    }
    return response["data"]
  }
  private func request(_ path: String, body: [String: Any]? = nil) async throws -> (NASValue, HTTPURLResponse) {
    let base = try NASConfiguration.baseURL(config.endpoint)
    guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
      let relative = URLComponents(string: path) else { throw NASError.message("NAS 地址无效。") }
    parts.path = relative.path; parts.queryItems = relative.queryItems
    if body == nil { parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "token", value: token)] }
    guard let url = parts.url else { throw NASError.message("NAS 地址无效。") }
    var request = URLRequest(url: url)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(config.clientID, forHTTPHeaderField: "UG-Client-Id")
    request.setValue(config.clientID, forHTTPHeaderField: "Client-Id")
    request.setValue("PC/WEB", forHTTPHeaderField: "UG-Agent")
    request.setValue("1.18.0", forHTTPHeaderField: "Client-Version")
    request.setValue("zh-CN", forHTTPHeaderField: "X-Specify-Language")
    if body == nil, authType != "url" { request.setValue(token, forHTTPHeaderField: "X-Ugreen-Token") }
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let data: Data, response: URLResponse
    do { (data, response) = try await session.data(for: request) }
    catch {
      if Task.isCancelled { throw CancellationError() }
      let code = (error as NSError).code
      if [-1200, -1202, -1203].contains(code) { throw NASError.connection("NAS 的 HTTPS 证书未通过验证，请配置可信证书。") }
      throw NASError.connection("无法连接 NAS，请检查网络和地址。")
    }
    guard let http = response as? HTTPURLResponse else { throw NASError.message("NAS 响应无效。") }
    if http.statusCode == 401 { throw NASError.expired }
    guard http.statusCode == 200, data.count <= 4_000_000,
      let result = try? JSONDecoder().decode(NASValue.self, from: data) else {
      throw NASError.message((300..<400).contains(http.statusCode) ? "NAS 重定向了连接，请直接填写目标地址。" : "NAS 接口不可用（HTTP \(http.statusCode)）。")
    }
    return (result, http)
  }
  private struct Part: Sendable { let key: String, title: String; let data: NASValue?; let error: String?; let expired: Bool }
  private func part(_ endpoint: (String, String, String)) async -> Part {
    do {
      let (result, _) = try await request(endpoint.1)
      return Part(key: endpoint.0, title: endpoint.2, data: try Self.unwrap(result, operation: endpoint.2), error: nil, expired: false)
    } catch NASError.expired { return Part(key: endpoint.0, title: endpoint.2, data: nil, error: nil, expired: true) }
    catch { return Part(key: endpoint.0, title: endpoint.2, data: nil, error: error.localizedDescription, expired: false) }
  }
  private func parts() async -> [Part] {
    let cached = Date().timeIntervalSince(metadataTime) < 60
    return await withTaskGroup(of: Part.self) { group in
      for e in Self.endpoints where !cached || e.0 != "machine" {
        group.addTask { await self.part(e) }
      }
      var result: [Part] = []
      for await part in group { result.append(part) }
      return result
    }
  }
  func snapshot() async throws -> NASSnapshot {
    var results = await parts()
    if results.contains(where: \.expired) {
      guard !password.isEmpty else { throw NASError.expired }
      try await login(password: password)
      results = await parts() // At most one login per poll, even if all endpoints expire.
      if results.contains(where: \.expired) { throw NASError.expired }
    }
    try Task.checkCancellation()
    guard results.contains(where: { ["stat", "monitor", "status"].contains($0.key) && $0.data != nil }) else {
      throw NASError.message(results.first(where: { $0.error != nil })?.error ?? "账号暂时无法读取 NAS 监测数据。")
    }
    var values = metadata
    for result in results { values[result.key] = result.data }
    let staticParts = results.filter { $0.key == "machine" }
    if !staticParts.isEmpty {
      metadata = Dictionary(uniqueKeysWithValues: staticParts.compactMap { p in p.data.map { (p.key, $0) } })
      metadataTime = Date()
    }
    // A failed fresh read must not silently reuse an older field as current data.
    let unavailable = Self.endpoints.filter { values[$0.0] == nil }.map(\.2)
    return NASSnapshot.parse(values, unavailable: unavailable)
  }
}
