import Combine
import Darwin
import Foundation

enum LocalProxyEndpoint: Equatable, Sendable {
  case unix(String), tcp(String, UInt16)
}

struct MihomoConfiguration: Equatable, Sendable {
  var endpoint: LocalProxyEndpoint
  var secret: String
  var source: String
  static func scalar(_ key: String, in yaml: String) -> String? {
    guard let line = yaml.split(separator: "\n", omittingEmptySubsequences: false).first(where: { $0.hasPrefix(key + ":") }) else { return nil }
    let value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\"") {
      // JSON string syntax is also valid YAML for controller fields.
      if let end = value.lastIndex(of: "\""), end > value.startIndex {
        return try? JSONDecoder().decode(String.self, from: Data(value[...end].utf8))
      }
      return nil
    }
    if value.hasPrefix("'") {
      guard let end = value.lastIndex(of: "'"), end > value.startIndex else { return nil }
      return String(value[value.index(after: value.startIndex)..<end]).replacingOccurrences(of: "''", with: "'")
    }
    let plain = value.components(separatedBy: " #").first?.trimmingCharacters(in: .whitespaces) ?? ""
    return ["null", "~"].contains(plain) ? nil : plain
  }
  static func parse(_ yaml: String, source: String) -> [Self] {
    let secret = scalar("secret", in: yaml) ?? ""
    guard secret.count <= 4096, !secret.contains(where: { $0.isNewline || $0 == "\0" }) else { return [] }
    var values: [Self] = []
    if let path = scalar("external-controller-unix", in: yaml), path.hasPrefix("/"), path.utf8.count < 104 {
      values.append(.init(endpoint: .unix(path), secret: secret, source: source))
    }
    if let address = scalar("external-controller", in: yaml), let url = URL(string: "http://" + address),
       ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""), let port = url.port, (1...65535).contains(port),
       url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty {
      values.append(.init(endpoint: .tcp(url.host?.contains(":") == true ? "::1" : "127.0.0.1", UInt16(port)), secret: secret, source: source))
    }
    return values
  }
  static func discover(custom: String? = nil) -> [Self] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let verge = home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
    var files: [(URL, String)] = []
    if let custom, !custom.isEmpty { files.append((URL(fileURLWithPath: custom), "自选配置")) }
    files += [(verge.appendingPathComponent("clash-verge.yaml"), "Clash Verge"), (verge.appendingPathComponent("config.yaml"), "Clash Verge"),
      (home.appendingPathComponent(".config/mihomo/config.yaml"), "Mihomo"), (home.appendingPathComponent(".config/clash/config.yaml"), "Clash"),
      (home.appendingPathComponent("Library/Application Support/com.follow.clash/config.yaml"), "Clash")]
    var found: [Self] = []
    for (url, source) in files {
      guard let data = try? Data(contentsOf: url), data.count <= 4_000_000, let yaml = String(data: data, encoding: .utf8) else { continue }
      var candidates = parse(yaml, source: source)
      if source == "Clash Verge" {
        // New Verge service mode has an owner-scoped IPC socket, separate from the GUI's stale YAML path.
        let path = "/var/run/clash-verge-service/users/\(geteuid())/verge-mihomo.sock"
        if FileManager.default.fileExists(atPath: path) {
          candidates.insert(.init(endpoint: .unix(path), secret: scalar("secret", in: yaml) ?? "", source: source), at: 0)
        }
      }
      for value in candidates where !found.contains(value) { found.append(value) }
    }
    return found
  }
}

/// Only GET from loopback or local IPC; never routes controller credentials through a system proxy.
enum LocalProxyHTTP {
  static let limit = 8_000_000
  static func get(_ path: String, configuration: MihomoConfiguration) async throws -> Data {
    guard ["/connections", "/configs", "/version"].contains(path),
          !configuration.secret.contains(where: { $0.isNewline || $0 == "\0" }) else { throw NetworkReadingError.configuration }
    switch configuration.endpoint {
    case .tcp(let host, _): guard ["127.0.0.1", "::1"].contains(host) else { throw NetworkReadingError.configuration }
    case .unix(let path): guard path.hasPrefix("/"), path.utf8.count < 104, !path.contains("\0") else { throw NetworkReadingError.configuration }
    }
    return try await Task.detached(priority: .utility) {
      let deadline = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
      let fd = try connect(configuration.endpoint, deadline: deadline)
      defer { Darwin.close(fd) }
      let auth = configuration.secret.isEmpty ? "" : "Authorization: Bearer \(configuration.secret)\r\n"
      let request = Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\n\(auth)\r\n".utf8)
      try request.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
          try wait(fd, events: Int16(POLLOUT), deadline: deadline)
          let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
          if count < 0, errno == EAGAIN || errno == EINTR { continue }
          guard count > 0 else { throw NetworkReadingError.unavailable }; sent += count
        }
      }
      var data = Data(), buffer = [UInt8](repeating: 0, count: 32_768)
      while true {
        try wait(fd, events: Int16(POLLIN), deadline: deadline)
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count < 0, errno == EAGAIN || errno == EINTR { continue }
        guard count >= 0 else { throw NetworkReadingError.unavailable }
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        guard data.count <= limit + 32_768 else { throw NetworkReadingError.malformed }
        if let body = try body(data, eof: count == 0) { return body }
        if count == 0 { throw NetworkReadingError.malformed }
      }
    }.value
  }
  static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else { throw NetworkReadingError.unavailable }
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    let status = poll(&pfd, 1, Int32(min(2500, (deadline - now) / 1_000_000 + 1)))
    guard status > 0, pfd.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw NetworkReadingError.unavailable }
  }
  static func connect(_ endpoint: LocalProxyEndpoint, deadline: UInt64) throws -> Int32 {
    let family: Int32
    switch endpoint { case .unix: family = AF_UNIX; case .tcp(let host, _): family = host.contains(":") ? AF_INET6 : AF_INET }
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NetworkReadingError.unavailable }
    do {
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
      let result: Int32
      switch endpoint {
      case .unix(let path):
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NetworkReadingError.configuration }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      case .tcp(let host, let port):
        if family == AF_INET {
          var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw NetworkReadingError.configuration }
          result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        } else {
          var address = sockaddr_in6(); address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = port.bigEndian; address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
          guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { throw NetworkReadingError.configuration }
          result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
      }
      if result != 0 {
        guard errno == EINPROGRESS else { throw NetworkReadingError.unavailable }
        try wait(fd, events: Int16(POLLOUT), deadline: deadline)
        var code: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else { throw NetworkReadingError.unavailable }
      }
      return fd
    } catch { Darwin.close(fd); throw error }
  }
  static func body(_ response: Data, eof: Bool = false) throws -> Data? {
    guard let boundary = response.range(of: Data("\r\n\r\n".utf8)) else {
      if response.count > 32_768 || eof { throw NetworkReadingError.malformed }; return nil
    }
    guard boundary.lowerBound < 32_768, let header = String(data: response[..<boundary.lowerBound], encoding: .utf8),
          let status = header.split(separator: "\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw NetworkReadingError.malformed }
    if status == 401 || status == 403 { throw NetworkReadingError.credentials }
    guard status == 200 else { throw NetworkReadingError.http(status) }
    let fields = header.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { result, line in
      let parts = line.split(separator: ":", maxSplits: 1); if parts.count == 2 { result[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
    }
    let body = Data(response[boundary.upperBound...])
    if fields["transfer-encoding"]?.lowercased() == "chunked" {
      var offset = 0, decoded = Data()
      while offset < body.count {
        guard let end = body.range(of: Data("\r\n".utf8), in: offset..<body.count),
              let line = String(data: body[offset..<end.lowerBound], encoding: .ascii),
              let count = Int(line.split(separator: ";").first ?? "", radix: 16), count >= 0, count <= limit - decoded.count else { if eof { throw NetworkReadingError.malformed }; return nil }
        offset = end.upperBound
        if count == 0 { return decoded }
        guard body.count - offset >= count + 2 else { if eof { throw NetworkReadingError.malformed }; return nil }
        guard body[offset + count] == 13, body[offset + count + 1] == 10 else { throw NetworkReadingError.malformed }
        decoded.append(body[offset..<(offset + count)]); offset += count + 2
      }
      if eof { throw NetworkReadingError.malformed }; return nil
    }
    if let size = fields["content-length"] {
      guard let count = Int(size), (0...limit).contains(count) else { throw NetworkReadingError.malformed }
      if body.count >= count { return Data(body.prefix(count)) }
      if eof { throw NetworkReadingError.malformed }; return nil
    }
    return eof ? body : nil
  }
}

struct MacProxySnapshot: Equatable, Sendable {
  var time: Date
  var uploadTotal: Double, downloadTotal: Double
  var connections: Int
  var memory: Double?
  static func parse(_ data: Data, now: Date = .now) throws -> Self {
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let upload = NetworkNumber.read(j["uploadTotal"]), let download = NetworkNumber.read(j["downloadTotal"]),
          let connections = j["connections"] as? [Any] else { throw NetworkReadingError.malformed }
    // Destination domains, process names, rule metadata and connection payloads are deliberately discarded.
    return .init(time: now, uploadTotal: upload, downloadTotal: download, connections: connections.count, memory: NetworkNumber.read(j["memory"]))
  }
  func rates(since previous: Self?) -> (upload: Double?, download: Double?) {
    guard let previous, (0.2...15).contains(time.timeIntervalSince(previous.time)),
          uploadTotal >= previous.uploadTotal, downloadTotal >= previous.downloadTotal else { return (nil, nil) }
    let seconds = time.timeIntervalSince(previous.time)
    return ((uploadTotal - previous.uploadTotal) / seconds, (downloadTotal - previous.downloadTotal) / seconds)
  }
}

@MainActor final class MacProxyMonitor: ObservableObject {
  static let shared = MacProxyMonitor()
  @Published private(set) var snapshot: MacProxySnapshot?
  @Published private(set) var upload: Double?
  @Published private(set) var download: Double?
  @Published private(set) var source: String?
  @Published private(set) var version: String?
  @Published private(set) var mode: String?
  @Published private(set) var mixedPort: Int?
  @Published private(set) var error: String?
  @Published private(set) var loading = false
  private var configuration: MihomoConfiguration?
  private var timer: Timer?, worker: Task<Void, Never>?
  private var revision = 0, viewers = 0, nextPoll = Date.distantPast, discoveryDate = Date.distantPast
  private let defaults: UserDefaults
  private let discover: () -> [MihomoConfiguration]
  private let get: (String, MihomoConfiguration) async throws -> Data
  init(defaults: UserDefaults = .standard, discover: (() -> [MihomoConfiguration])? = nil,
       get: @escaping (String, MihomoConfiguration) async throws -> Data = { try await LocalProxyHTTP.get($0, configuration: $1) }) {
    self.defaults = defaults; self.discover = discover ?? { MihomoConfiguration.discover(custom: defaults.string(forKey: "serverProxyConfigurationPath")) }; self.get = get
  }
  var stale: Bool { error != nil || snapshot.map { Date().timeIntervalSince($0.time) > 15 } ?? true }
  func show() {
    viewers += 1
    guard timer == nil else { return }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in if Date() >= self.nextPoll { self.refresh() } } }
  }
  func hide() { viewers = max(0, viewers - 1); if viewers == 0 { stop() } }
  func stop() { timer?.invalidate(); timer = nil; worker?.cancel(); worker = nil; revision += 1; loading = false; upload = nil; download = nil }
  func selectConfiguration(_ url: URL) {
    defaults.set(url.path, forKey: "serverProxyConfigurationPath")
    stop(); configuration = nil; snapshot = nil; source = nil; version = nil; mode = nil; mixedPort = nil
    if viewers > 0 { viewers -= 1; show() }
  }
  func refresh() {
    guard !loading else { return }
    loading = true; let ticket = revision
    worker = Task {
      do {
        var choices = configuration.map { [$0] } ?? []
        if choices.isEmpty || Date().timeIntervalSince(discoveryDate) > 15 {
          let detected = discover(); discoveryDate = .now
          choices = detected + choices.filter { !detected.contains($0) }
        }
        var result: (MihomoConfiguration, MacProxySnapshot)?
        for candidate in choices.prefix(10) {
          do {
            let data = try await get("/connections", candidate)
            try Task.checkCancellation()
            result = (candidate, try MacProxySnapshot.parse(data)); break
          } catch { try Task.checkCancellation() }
        }
        guard let (config, reading) = result else { throw NetworkReadingError.configuration }
        guard !Task.isCancelled, ticket == revision else { return }
        let changed = configuration != config
        let rates = reading.rates(since: changed ? nil : snapshot)
        snapshot = reading; upload = rates.upload; download = rates.download; source = config.source
        configuration = config; error = nil; nextPoll = .now
        if changed || version == nil || mixedPort == nil {
          if let data = try? await get("/version", config), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], ticket == revision { version = (j["version"] as? String).map { String($0.prefix(80)) } }
          if let data = try? await get("/configs", config), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], ticket == revision {
            mixedPort = NetworkNumber.read(j["mixed-port"]).flatMap { (1...65535).contains($0) ? Int($0) : nil }
            mode = (j["mode"] as? String).flatMap { ["rule": "规则", "global": "全局", "direct": "直连"][$0] }
          }
        }
      } catch {
        guard !Task.isCancelled, ticket == revision else { return }
        self.error = (error as? NetworkReadingError)?.localizedDescription ?? NetworkReadingError.unavailable.localizedDescription
        upload = nil; download = nil; configuration = nil; mixedPort = nil; nextPoll = Date().addingTimeInterval(15)
      }
      guard ticket == revision else { return }; loading = false
    }
  }
}
