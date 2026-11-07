import Darwin
import Foundation

enum NetworkReadingError: LocalizedError {
  case unavailable, malformed, http(Int), credentials, configuration
  var errorDescription: String? {
    switch self {
    case .unavailable: return "暂时无法读取，稍后重试。"
    case .malformed: return "未返回可识别的数据。"
    case .http(let code): return "接口暂不可用（HTTP \(code)）。"
    case .credentials: return "本机代理未接受认证，请检查所选配置。"
    case .configuration: return "未找到可连接的本机代理，请选择正在使用的配置。"
    }
  }
}

enum NetworkNumber {
  static func read(_ value: Any?) -> Double? {
    let number: Double?
    if let string = value as? String { number = Double(string) }
    else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
    else { number = nil }
    return number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
}

/// KiwiVM reports bytes transferred during each interval, not cumulative counters.
struct ServerNetworkSample: Equatable, Sendable, Identifiable {
  var time: Date
  var incoming: Double
  var outgoing: Double
  var id: Date { time }
}

struct ServerNetworkStats: Equatable, Sendable {
  var samples: [ServerNetworkSample]
  var fetched: Date
  var latest: ServerNetworkSample? { samples.last }
  var interval: TimeInterval? {
    guard samples.count >= 2 else { return nil }
    let delta = samples[samples.count - 1].time.timeIntervalSince(samples[samples.count - 2].time)
    return (1...900).contains(delta) ? delta : nil
  }
  var fresh: Bool { latest.map { fetched.timeIntervalSince($0.time) >= -60 && fetched.timeIntervalSince($0.time) <= 1200 } ?? false }
  var download: Double? { guard fresh, let interval, let latest else { return nil }; return latest.incoming / interval }
  var upload: Double? { guard fresh, let interval, let latest else { return nil }; return latest.outgoing / interval }
  var day: [ServerNetworkSample] { samples.filter { $0.time > fetched.addingTimeInterval(-86400) && $0.time <= fetched } }
  var dayIncoming: Double? { day.isEmpty ? nil : day.reduce(0) { $0 + $1.incoming } }
  var dayOutgoing: Double? { day.isEmpty ? nil : day.reduce(0) { $0 + $1.outgoing } }
  static func parse(_ data: Data, now: Date = .now) throws -> Self {
    guard data.count <= 16_000_000,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          NetworkNumber.read(object["error"]) == 0,
          let rows = object["data"] as? [[String: Any]] else { throw NetworkReadingError.malformed }
    var keyed: [Date: ServerNetworkSample] = [:]
    for row in rows {
      guard let timestamp = NetworkNumber.read(row["timestamp"]), timestamp > 0, timestamp <= now.timeIntervalSince1970 + 60,
            let incoming = NetworkNumber.read(row["network_in_bytes"]), let outgoing = NetworkNumber.read(row["network_out_bytes"]) else { continue }
      let time = Date(timeIntervalSince1970: timestamp)
      if time >= now.addingTimeInterval(-86400 - 900) { keyed[time] = .init(time: time, incoming: incoming, outgoing: outgoing) }
    }
    return .init(samples: Array(keyed.values.sorted { $0.time < $1.time }.suffix(2000)), fetched: now)
  }
}

/// Canonical numeric IPs only: no domains, URLs, local addresses or mapped IPv4 bypass.
enum PublicIPAddress {
  static func canonical(_ value: String) -> String? {
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, value, &v4) == 1 {
      let bytes = withUnsafeBytes(of: v4) { Array($0) }
      guard !(bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 ||
              (bytes[0] == 100 && (64...127).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254) ||
              (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) ||
              (bytes[0] == 192 && bytes[1] == 0) || (bytes[0] == 192 && bytes[1] == 88 && bytes[2] == 99) ||
              (bytes[0] == 198 && (18...19).contains(bytes[1])) ||
              (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113)) else { return nil }
      return bytes.map(String.init).joined(separator: ".")
    }
    if inet_pton(AF_INET6, value, &v6) == 1 {
      let bytes = withUnsafeBytes(of: v6) { Array($0) }
      // Restrict lookups to global unicast, excluding documentation and transition prefixes.
      guard (0x20...0x3f).contains(bytes[0]), !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8),
            !(bytes[0] == 0x20 && bytes[1] == 0x02), !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0) else { return nil }
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
      return String(cString: buffer)
    }
    return nil
  }
}

struct ServerIPInfo: Equatable, Sendable {
  var ip: String
  var family: String
  var country: String?, region: String?, city: String?
  var asn: String?, isp: String?, organization: String?, timezone: String?
  var fetched: Date
  var location: String { [country, region, city].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ") }
  static func request(_ ip: String) throws -> URLRequest {
    guard let ip = PublicIPAddress.canonical(ip) else { throw NetworkReadingError.configuration }
    var parts = URLComponents(); parts.scheme = "https"; parts.host = "ipwho.is"; parts.path = "/" + ip
    parts.queryItems = [URLQueryItem(name: "fields", value: "success,ip,type,country,region,city,connection,timezone")]
    guard let url = parts.url else { throw NetworkReadingError.configuration }
    var request = URLRequest(url: url); request.timeoutInterval = 8; return request
  }
  static func parse(_ data: Data, expected: String, now: Date = .now) throws -> Self {
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], j["success"] as? Bool == true,
          let ip = j["ip"] as? String, let canonical = PublicIPAddress.canonical(ip), canonical == PublicIPAddress.canonical(expected) else { throw NetworkReadingError.malformed }
    func text(_ obj: [String: Any], _ key: String) -> String? { (obj[key] as? String).map { String($0.prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 } }
    let connection = j["connection"] as? [String: Any] ?? [:], timezone = j["timezone"] as? [String: Any] ?? [:]
    let asn = NetworkNumber.read(connection["asn"]).flatMap { $0 > 0 && $0 < 4_294_967_296 ? "AS" + String(Int($0)) : nil }
    return .init(ip: canonical, family: canonical.contains(":") ? "IPv6" : "IPv4", country: text(j, "country"), region: text(j, "region"), city: text(j, "city"), asn: asn, isp: text(connection, "isp"), organization: text(connection, "org"), timezone: text(timezone, "id"), fetched: now)
  }
}

enum NetworkReadClient {
  static func read(_ request: URLRequest, limit: Int = 64_000, proxyPort: Int? = nil) async throws -> Data {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    // Explicit proxy only for the user's site tests. No controller bearer token is sent here.
    if let proxyPort {
      config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort]
    }
    let session = URLSession(configuration: config, delegate: NetworkNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw NetworkReadingError.unavailable }
    guard (200..<400).contains(http.statusCode) else { throw NetworkReadingError.http(http.statusCode) }
    var data = Data()
    for try await byte in bytes { guard data.count < limit else { throw NetworkReadingError.malformed }; data.append(byte) }
    try Task.checkCancellation()
    return data
  }
}
private final class NetworkNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
