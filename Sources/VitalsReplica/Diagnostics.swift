import AppKit
import Combine
import Darwin
import Foundation
import Network

struct DiagnosticStep: Identifiable, Equatable {
  enum State { case checking, passed, failed, unknown }
  let id: String
  let title: String
  var state: State
  var detail: String
}
/// No packet contents, Key, proxy settings or network configuration are read or changed.
@MainActor final class NetworkDiagnosticsStore: ObservableObject {
  static let shared = NetworkDiagnosticsStore()
  @Published private(set) var steps: [DiagnosticStep] = []
  @Published private(set) var running = false
  @Published private(set) var target = ""
  @Published private(set) var time: Date?
  private var task: Task<Void, Never>?
  private var completion: ((String) -> Void)?
  func start(completion: ((String) -> Void)? = nil) {
    guard !running else { completion?("已打开正在进行的网络诊断"); return }
    guard let url = try? AIEndpoint.models(AIAnalysisStore.shared.config), let host = url.host else { completion?("诊断未开始 · 请检查模型接口地址"); return }
    self.completion = completion
    target = host; running = true; time = Date()
    steps = [DiagnosticStep(id: "local", title: "本机接入", state: .checking, detail: "检查地址与默认路由"),
      DiagnosticStep(id: "dns", title: "DNS", state: .checking, detail: "解析 \(host)"),
      DiagnosticStep(id: "target", title: "目标服务", state: .checking, detail: "连接 \(host) · 不带 Key")]
    task = Task {
      let local = await Task.detached(priority: .utility) { () -> DiagnosticStep in
        let addresses = LocalNetworkSnapshot.read()
        let route4 = Command.run("/sbin/route", ["-n", "get", "default"], timeout: 2)
        let route6 = route4.status == 0 ? nil : Command.run("/sbin/route", ["-n", "get", "-inet6", "default"], timeout: 2)
        let hasRoute = route4.status == 0 || route6?.status == 0
        return DiagnosticStep(id: "local", title: "本机接入", state: hasRoute ? .passed : .unknown,
          detail: (addresses.primary.map { "\($0.interface) · \($0.address)" } ?? "无局域网 IPv4（可能使用 IPv6）") + (hasRoute ? " · 已找到默认路由" : " · 未读取到默认路由，需核对网络设置"))
      }.value
      guard !Task.isCancelled else { self.finish(); return }; self.steps[0] = local
      let dns = await DNSProbe.resolve(host: host, timeout: 5)
      guard !Task.isCancelled else { self.finish(); return }
      self.steps[1] = DiagnosticStep(id: "dns", title: "DNS", state: dns == true ? .passed : dns == false ? .failed : .unknown,
        detail: dns == true ? "\(host) 解析成功" : dns == false ? "当前系统解析失败；代理可能使用远端 DNS" : "解析超时，尚不能定位原因")
      let config = URLSessionConfiguration.ephemeral
      config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
      config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
      let session = URLSession(configuration: config, delegate: AINoRedirectDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: url); request.httpMethod = "HEAD"
      let begin = Date()
      do {
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode
        self.steps[2] = DiagnosticStep(id: "target", title: "目标服务", state: code == nil ? .unknown : .passed,
          detail: code.map { "HTTP \($0) · \(Int(Date().timeIntervalSince(begin) * 1000)) ms。服务可达；未验证 Key 或模型权限。" } ?? "未获得 HTTP 响应")
      } catch {
        self.steps[2] = DiagnosticStep(id: "target", title: "目标服务", state: .failed,
          detail: "\(host) 连接失败；仅代表该目标，不等于整个互联网断网。")
      }
      self.finish()
    }
  }
  private func finish() {
    running = false; task = nil
    let issues = steps.filter { $0.state == .failed || $0.state == .unknown }.map(\.title)
    let detail = issues.isEmpty ? "网络诊断完成 · 本机接入、DNS 与目标服务检查通过" : "网络诊断完成 · 请查看" + issues.joined(separator: "、")
    let callback = completion; completion = nil; callback?(detail)
  }
}

/// The resolver may outlive the timeout. A locked single completion prevents double resume.
private final class DNSCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool?, Never>?
  init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
  func finish(_ value: Bool?) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning: value) }
}
enum DNSProbe {
  static func resolve(host: String, timeout: Double) async -> Bool? {
    await withCheckedContinuation { continuation in
      let once = DNSCompletion(continuation)
      DispatchQueue.global(qos: .utility).async {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        once.finish(code == 0)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
    }
  }
}

struct DiskFolder: Identifiable, Sendable {
  let url: URL
  let bytes: UInt64
  let partial: Bool
  var id: String { url.path }
}
@MainActor final class DiskUsageStore: ObservableObject {
  static let shared = DiskUsageStore()
  @Published private(set) var folders: [DiskFolder] = []
  @Published private(set) var running = false
  @Published private(set) var message = ""
  private var task: Task<Void, Never>?
  private var completion: ((String) -> Void)?
  func cancel() {
    task?.cancel(); task = nil; running = false; message = "扫描已停止，保留已完成结果"
    let callback = completion; completion = nil; callback?(message)
  }
  func start(completion: ((String) -> Void)? = nil) {
    guard !running else { completion?("已打开正在进行的磁盘扫描"); return }
    self.completion = completion
    running = true; folders = []; message = "仅扫描常用目录 · 不跟随符号链接"
    task = Task {
      let home = FileManager.default.homeDirectoryForCurrentUser
      for name in ["Downloads", "Movies", "Documents", "Desktop", "Library/Caches"] {
        if Task.isCancelled { break }
        let url = home.appendingPathComponent(name)
        let result = await Task.detached(priority: .utility) { Self.scan(url) }.value
        if Task.isCancelled { break }
        folders.append(result); folders.sort { $0.bytes > $1.bytes }
      }
      guard !Task.isCancelled else { return }
      running = false; task = nil; message = "近似占用 · 每目录最多 5 秒 / 40,000 项；权限限制、云文件和 APFS 共享空间可能影响结果。"
      let callback = self.completion; self.completion = nil
      let largest = folders.first.map { " · \($0.url.lastPathComponent) 约 \(Format.bytes($0.bytes))" } ?? ""
      callback?("磁盘扫描完成" + largest + (folders.contains(where: \.partial) ? " · 部分目录未完整读取" : ""))
    }
  }
  nonisolated static func scan(_ url: URL) -> DiskFolder {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileResourceIdentifierKey]
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var partial = false, count = 0, bytes: UInt64 = 0
    var seen = Set<AnyHashable>()
    guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in partial = true; return true }) else { return DiskFolder(url: url, bytes: 0, partial: true) }
    for case let file as URL in iterator {
      count += 1
      if count > 40_000 || ProcessInfo.processInfo.systemUptime > deadline { partial = true; break }
      guard let v = try? file.resourceValues(forKeys: Set(keys)) else { partial = true; continue }
      if v.isSymbolicLink == true { iterator.skipDescendants(); continue }
      guard v.isRegularFile == true else { continue }
      if let id = v.fileResourceIdentifier as? AnyHashable { if !seen.insert(id).inserted { continue } }
      bytes += UInt64(max(0, v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0))
    }
    return DiskFolder(url: url, bytes: bytes, partial: partial)
  }
}
