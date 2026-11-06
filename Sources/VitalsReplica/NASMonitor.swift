import AppKit
import Combine
import Foundation

@MainActor
final class NASMonitor: ObservableObject {
  static let shared = NASMonitor()
  enum State: Equatable { case unconfigured, connecting, online, partial, offline, needsLogin }
  @Published private(set) var configuration: NASConfiguration
  @Published private(set) var state: State = .unconfigured
  @Published private(set) var snapshot: NASSnapshot?
  @Published private(set) var error: String?
  @Published private(set) var busy = false
  @Published private(set) var needsOTP = false
  @Published private(set) var cpuHistory: [Double] = []
  @Published private(set) var memoryHistory: [Double] = []
  @Published private(set) var uploadHistory: [Double] = []
  @Published private(set) var downloadHistory: [Double] = []
  @Published var showConnection = false
  private var client: NASClient?
  private var worker: Task<Void, Never>?
  private var started = false
  private var generation = UUID()
  private let defaults: UserDefaults
  private let key = "nas.configuration.v1"
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    configuration = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NASConfiguration.self, from: $0) } ?? NASConfiguration()
  }
  var current: Bool { state == .online || state == .partial }
  var status: String {
    switch state {
    case .unconfigured: return "未连接"
    case .connecting: return "连接中"
    case .online: return "在线"
    case .partial: return "部分数据"
    case .offline: return "离线"
    case .needsLogin: return "需要登录"
    }
  }
  func start() {
    guard !started else { return }; started = true
    guard configuration.isConfigured else { return }
    state = .connecting
    let id = generation
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        let password = try await NASVault.read(configuration)
        try Task.checkCancellation()
        guard generation == id else { return }
        let api = NASClient(config: configuration); client = api
        while !Task.isCancelled, generation == id {
          do {
            try await api.login(password: password)
            await poll(api, generation: id)
            return
          } catch NASError.connection(let message) {
            guard generation == id, !Task.isCancelled else { return }
            errorMessage(NASError.connection(message), login: false)
            try await Task.sleep(for: .seconds(30))
          }
        }
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        errorMessage(error, login: true)
      }
    }
  }
  func stop() { generation = UUID(); worker?.cancel(); worker = nil; client = nil; started = false }
  func connect(_ candidate: NASConfiguration, password: String, remember: Bool, otp: String, trust: Bool) async throws {
    guard !busy else { return }
    var candidate = candidate
    candidate.endpoint = try NASConfiguration.baseURL(candidate.endpoint).absoluteString
    candidate.username = candidate.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.username.isEmpty else { throw NASError.message("请输入 NAS 账号。") }
    guard password.utf8.count <= 4096 else { throw NASError.message("密码过长。") }
    busy = true; defer { busy = false }
    worker?.cancel(); worker = nil; generation = UUID(); let id = generation
    let api: NASClient
    if needsOTP, let previous = client, candidate == configuration { api = previous }
    else { api = NASClient(config: candidate); needsOTP = false }
    configuration = candidate; client = api; state = .connecting; error = nil
    do {
      let secret = password.isEmpty ? try await NASVault.read(candidate) : password
      try await api.login(password: secret, otp: otp, trust: trust)
      try Task.checkCancellation()
      guard generation == id else { throw CancellationError() }
      if remember { try await NASVault.save(secret, config: candidate) }
      else { try await NASVault.remove(candidate) }
      defaults.set(try JSONEncoder().encode(candidate), forKey: key)
      defaults.set(remember, forKey: "nas.remember")
      let reading = try await api.snapshot()
      try Task.checkCancellation()
      guard generation == id else { throw CancellationError() }
      needsOTP = false; accept(reading); started = true
      worker = Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled, let self else { return }
        await poll(api, generation: id)
      }
    } catch {
      guard generation == id else { throw CancellationError() }
      if case NASError.otp = error { needsOTP = true }
      errorMessage(error, login: true)
      throw error
    }
  }
  func refresh() {
    guard !busy, let client, configuration.isConfigured else { return }
    worker?.cancel(); generation = UUID(); let id = generation
    worker = Task { [weak self] in await self?.poll(client, generation: id) }
  }
  private func poll(_ api: NASClient, generation id: UUID) async {
    var failures = 0
    while !Task.isCancelled, generation == id {
      do {
        let reading = try await api.snapshot()
        guard generation == id, !Task.isCancelled else { return }
        accept(reading); failures = 0
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        if case NASError.expired = error { errorMessage(error, login: true); return }
        if case NASError.otp = error { needsOTP = true; errorMessage(error, login: true); return }
        errorMessage(error, login: false); failures += 1
      }
      do { try await Task.sleep(for: .seconds(failures > 0 ? min(60, 10 * failures) : 10)) }
      catch { return }
    }
  }
  private func accept(_ reading: NASSnapshot) {
    snapshot = reading; error = nil; state = reading.unavailable.isEmpty ? .online : .partial
    if let cpu = reading.cpu { cpuHistory.append(cpu); cpuHistory = Array(cpuHistory.suffix(90)) }
    if let value = reading.memory { memoryHistory.append(value); memoryHistory = Array(memoryHistory.suffix(90)) }
    if let value = reading.upload { uploadHistory.append(value); uploadHistory = Array(uploadHistory.suffix(90)) }
    if let value = reading.download { downloadHistory.append(value); downloadHistory = Array(downloadHistory.suffix(90)) }
  }
  private func errorMessage(_ failure: Error, login: Bool) {
    error = failure.localizedDescription
    state = login ? .needsLogin : .offline
    cpuHistory = []
    memoryHistory = []; uploadHistory = []; downloadHistory = []
  }
  func forget() async throws {
    guard !busy else { return }
    stop()
    try await NASVault.remove(configuration)
    defaults.removeObject(forKey: key); defaults.removeObject(forKey: "nas.remember")
    configuration = NASConfiguration(); snapshot = nil; error = nil; state = .unconfigured; needsOTP = false; cpuHistory = []
    memoryHistory = []; uploadHistory = []; downloadHistory = []
  }
  func openConsole() {
    guard let url = try? NASConfiguration.baseURL(configuration.endpoint) else { return }
    NSWorkspace.shared.open(url)
  }
}
