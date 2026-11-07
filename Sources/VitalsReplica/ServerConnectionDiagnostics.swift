import Combine
import Darwin
import Foundation

struct ServerSiteTest: Identifiable, Equatable, Sendable {
  var name: String
  var url: URL
  var milliseconds: Double?
  var failure: String?
  var id: String { name }
  static let sites: [Self] = [
    .init(name: "Apple", url: URL(string: "https://www.apple.com/library/test/success.html")!),
    .init(name: "GitHub", url: URL(string: "https://github.com")!),
    .init(name: "Google", url: URL(string: "https://www.google.com/generate_204")!),
    .init(name: "YouTube", url: URL(string: "https://www.youtube.com/generate_204")!),
  ]
}

enum ServerTCPProbe {
  static func measure(ip: String, port: Int) async throws -> Double {
    guard let ip = PublicIPAddress.canonical(ip), (1...65535).contains(port) else { throw NetworkReadingError.configuration }
    return try await Task.detached(priority: .utility) {
      let start = DispatchTime.now().uptimeNanoseconds
      let fd = try LocalProxyHTTP.connect(.tcp(ip, UInt16(port)), deadline: start + 2_500_000_000)
      Darwin.close(fd)
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }.value
  }
}

@MainActor final class ServerConnectionDiagnostics: ObservableObject {
  static let shared = ServerConnectionDiagnostics()
  @Published private(set) var ip: String?
  @Published private(set) var info: ServerIPInfo?
  @Published private(set) var infoError: String?
  @Published private(set) var lookingUp = false
  @Published private(set) var latency: Double?
  @Published private(set) var probing = false
  @Published private(set) var probeFailed = false
  @Published private(set) var probeTime: Date?
  @Published private(set) var port = 22
  @Published private(set) var sites = ServerSiteTest.sites
  @Published private(set) var testingSites = false
  @Published private(set) var sitesTime: Date?
  private var target = "", revision = 0, siteRevision = 0
  private var nextLookup = Date.distantPast
  private var infoTask: Task<Void, Never>?, probeTask: Task<Void, Never>?, siteTask: Task<Void, Never>?
  private var cache: [String: ServerIPInfo] = [:]
  func observe(addresses: [String], fallback: String?, port: Int?) {
    let candidates = (addresses + [fallback].compactMap { $0 }).compactMap(PublicIPAddress.canonical)
    let resolved = candidates.first(where: { !$0.contains(":") }) ?? candidates.first
    let port = port ?? 22, identity = (resolved ?? "") + ":" + String(port)
    if target != identity {
      revision += 1; infoTask?.cancel(); probeTask?.cancel(); lookingUp = false; probing = false
      target = identity; ip = resolved; self.port = port; info = resolved.flatMap { cache[$0] }; infoError = nil
      nextLookup = .distantPast
      latency = nil; probeFailed = false; probeTime = nil
    }
    guard ip != nil else { return }
    if Date() >= nextLookup && (info.map({ Date().timeIntervalSince($0.fetched) >= 86400 }) ?? true) { lookup() }
    if probeTime.map({ Date().timeIntervalSince($0) >= 60 }) ?? true { probe() }
  }
  func lookup() {
    guard let ip, !lookingUp else { return }
    lookingUp = true; let ticket = revision
    infoTask = Task {
      do {
        let request = try ServerIPInfo.request(ip)
        let data = try await NetworkReadClient.read(request)
        let value = try ServerIPInfo.parse(data, expected: ip)
        guard !Task.isCancelled, ticket == revision else { return }
        cache[ip] = value; info = value; infoError = nil
        nextLookup = Date().addingTimeInterval(86400)
      } catch {
        guard !Task.isCancelled, ticket == revision else { return }
        infoError = "归属查询暂不可用"
        nextLookup = Date().addingTimeInterval(900)
      }
      lookingUp = false
    }
  }
  func probe() {
    guard let ip, !probing else { return }
    probing = true; let ticket = revision, port = port
    probeTask = Task {
      do {
        let value = try await ServerTCPProbe.measure(ip: ip, port: port)
        guard !Task.isCancelled, ticket == revision else { return }
        latency = value; probeFailed = false
      } catch {
        guard !Task.isCancelled, ticket == revision else { return }
        latency = nil; probeFailed = true
      }
      probeTime = .now; probing = false
    }
  }
  func testSites(proxyPort: Int) {
    guard (1...65535).contains(proxyPort), !testingSites else { return }
    testingSites = true; sites = ServerSiteTest.sites; sitesTime = nil; siteRevision += 1; let ticket = siteRevision
    siteTask = Task {
      await withTaskGroup(of: ServerSiteTest.self) { group in
        for site in ServerSiteTest.sites {
          group.addTask {
            var result = site
            var request = URLRequest(url: site.url); request.httpMethod = "HEAD"; request.timeoutInterval = 8
            let start = DispatchTime.now().uptimeNanoseconds
            do {
              _ = try await NetworkReadClient.read(request, limit: 1024, proxyPort: proxyPort)
              result.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            } catch let error as NetworkReadingError {
              if case .http(let code) = error { result.failure = "HTTP \(code)" } else { result.failure = "未响应" }
            } catch { result.failure = "未响应" }
            return result
          }
        }
        for await result in group {
          guard !Task.isCancelled, ticket == siteRevision else { group.cancelAll(); return }
          if let index = sites.firstIndex(where: { $0.id == result.id }) { sites[index] = result }
        }
      }
      if ticket == siteRevision { testingSites = false; sitesTime = .now }
    }
  }
  func resetSites() {
    siteRevision += 1; siteTask?.cancel(); sites = ServerSiteTest.sites; sitesTime = nil; testingSites = false
  }
  func clear() {
    revision += 1; siteRevision += 1; infoTask?.cancel(); probeTask?.cancel(); siteTask?.cancel()
    ip = nil; info = nil; target = ""; latency = nil; probeTime = nil; probeFailed = false
    sites = ServerSiteTest.sites; sitesTime = nil; lookingUp = false; probing = false; testingSites = false; nextLookup = .distantPast
  }
}
