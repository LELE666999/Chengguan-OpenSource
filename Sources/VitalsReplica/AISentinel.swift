import AppKit
import Combine
import Foundation
import Network
import UserNotifications

@MainActor final class AISentinel: ObservableObject {
  static let shared = AISentinel()
  @Published var enabled: Bool {
    didSet {
      prefs.set(enabled, forKey: "aiWatchEnabled")
      if !enabled, store.automaticInFlight { store.cancel() }
      if !enabled { probe?.cancel(); probe = nil }
      if enabled { budget.resume() }
    }
  }
  @Published var intervalMinutes: Int { didSet { prefs.set(intervalMinutes, forKey: "aiWatchInterval") } }
  @Published var notifications: Bool {
    didSet { prefs.set(notifications, forKey: "aiWatchNotifications"); if notifications { requestNotifications() } }
  }
  @Published var adaptive: Bool { didSet { prefs.set(adaptive, forKey: "aiWatchAdaptive") } }
  private var adaptivePolicy = AdaptiveAnalysisPolicy()
  @Published private(set) var effectiveInterval = 5
  @Published private(set) var events: [AIMonitorEvent] = []
  @Published private(set) var state = "正在观察"
  @Published private(set) var notificationDenied = false
  @Published private(set) var network = AINetworkState()
  private let prefs: UserDefaults
  private let store: AIAnalysisStore
  private let path = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "studio.lele.Chengguan.network-watch", qos: .utility)
  private var engine = AIMonitorEngine()
  private var budget: AIAutomaticBudget
  private var started = false
  private var pendingEvent = false
  private var observedSince: Date?
  private var lastObserved: Date?
  private var lastProbe = Date.distantPast
  private var probe: Task<Void, Never>?
  private var lastEndpoint = ""
  private var subscriptions = Set<AnyCancellable>()
  private var lastNotice = Date.distantPast
  private var keychainBlocked = false
  private var historyURL: URL {
    AIHistoryFile.standard.url.deletingLastPathComponent().appendingPathComponent("monitor-events.json")
  }
  var latest: AIMonitorEvent? { events.first }
  var callsThisHour: Int { budget.attempts.filter { Date().timeIntervalSince($0) < 3600 }.count }
  var automaticDescription: String { enabled ? state : "自动分析已暂停" }
  var shortState: String {
    if !enabled { return "已暂停" }
    if state == "采样已暂停" { return "采样暂停" }
    if !store.hasKey { return "待连接" }
    if store.automaticInFlight { return "更新中" }
    if network.connected == false { return "离线" }
    if budget.blocked { return keychainBlocked ? "需授权" : "检查接口" }
    if callsThisHour >= 12 { return "调用限频" }
    if Date() < budget.retryAfter { return "稍后重试" }
    return "自动"
  }

  init(prefs: UserDefaults = .standard, store injectedStore: AIAnalysisStore? = nil) {
    self.prefs = prefs; self.store = injectedStore ?? .shared
    adaptive = prefs.object(forKey: "aiWatchAdaptive") as? Bool ?? true
    enabled = prefs.object(forKey: "aiWatchEnabled") as? Bool ?? true
    let minutes = prefs.integer(forKey: "aiWatchInterval")
    intervalMinutes = [5, 10, 15, 30].contains(minutes) ? minutes : 5
    notifications = prefs.object(forKey: "aiWatchNotifications") as? Bool ?? true
    budget = AIAutomaticBudget(attempts: (prefs.array(forKey: "aiWatchAttempts") as? [Date] ?? [])
      .filter { Date().timeIntervalSince($0) < 3600 && $0 <= Date() })
    if let size = try? historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 500_000,
      let data = try? Data(contentsOf: historyURL),
      let saved = try? JSONDecoder().decode([AIMonitorEvent].self, from: data) { events = Array(saved.prefix(50)) }
    self.store.$config.removeDuplicates().dropFirst().sink { [weak self] _ in self?.configurationChanged() }.store(in: &subscriptions)
    self.store.$hasKey.removeDuplicates().dropFirst().sink { [weak self] _ in self?.budget.resume() }.store(in: &subscriptions)
  }
  private func configurationChanged() {
    budget.resume(); keychainBlocked = false; lastProbe = .distantPast; probe?.cancel(); probe = nil
    network.endpointReachable = nil; network.endpointLatencyMS = nil
  }
  func resume() { budget.resume(); keychainBlocked = false; state = "等待下一轮采样" }
  func samplingPaused(_ paused: Bool) {
    if paused {
      AdvisorStore.shared.pause()
      if store.automaticInFlight { store.cancel() }
      probe?.cancel(); probe = nil; state = "采样已暂停"
    } else { observedSince = nil; state = "正在观察" }
  }
  func start() {
    guard !started else { return }; started = true
    path.pathUpdateHandler = { [weak self] route in
      let connected: Bool? = route.status == .satisfied ? true : route.status == .unsatisfied ? false : nil
      let transport = route.usesInterfaceType(.wifi) ? "Wi-Fi" : route.usesInterfaceType(.wiredEthernet) ? "以太网" : "其他网络"
      Task { @MainActor [weak self] in
        self?.network.connected = connected; self?.network.transport = transport
        if connected == false { self?.network.endpointReachable = nil; self?.network.endpointLatencyMS = nil }
        else if connected == true { self?.lastProbe = .distantPast }
      }
    }
    path.start(queue: networkQueue)
    if notifications { requestNotifications() }
  }
  func observe(snapshot: MonitorSnapshot, history: [HistoryPoint], paused: Bool) {
    start()
    let now = snapshot.time
    guard !paused, !snapshot.isWarmup, snapshot.totalMemory > 0, Date().timeIntervalSince(now) < 30 else { state = "等待实时采样"; return }
    if let lastObserved, now.timeIntervalSince(lastObserved) > 20 { observedSince = now }
    if observedSince == nil { observedSince = now }
    lastObserved = now
    let fresh = engine.observe(snapshot, network: network, baseline: AdvisorStore.shared.baseline)
    AdvisorStore.shared.observe(snapshot, events: fresh, network: network)
    adaptivePolicy.observe(snapshot, hasIncident: !AdvisorStore.shared.activeEpisodes.isEmpty)
    effectiveInterval = adaptivePolicy.minutes(base: intervalMinutes, now: now, enabled: adaptive)
    if !fresh.isEmpty {
      let ordered = fresh.sorted { $0.urgent && !$1.urgent }
      events = Array((ordered + events).prefix(50))
      saveEvents()
      if fresh.contains(where: \.requiresAI) { pendingEvent = true }
      notify(fresh)
    }
    if enabled, store.hasKey, network.connected != false { probeEndpoint(now: now) }
    guard enabled else { state = "自动分析已暂停"; return }
    guard store.hasKey else { state = "连接模型后自动开始"; return }
    guard !store.busy else { state = store.automaticInFlight ? "正在自动分析…" : "分析中…"; return }
    guard network.connected == true else { state = "等待联网 · 本地监测继续"; return }
    guard !budget.blocked else { state = keychainBlocked ? "钥匙串需授权 · 请测试连接" : "接口需处理 · 检查 Key 或额度"; return }
    guard network.endpointReachable != false else { state = "等待接口恢复 · 本地监测继续"; return }
    guard now.timeIntervalSince(observedSince ?? now) >= (pendingEvent ? 4 : 20) else { state = "正在积累样本"; return }
    // A user-created report also postpones periodic work, while a new incident may still pre-empt it.
    if !pendingEvent, let record = store.records.first, now.timeIntervalSince(record.sampledAt) < Double(effectiveInterval) * 60 {
      state = "自动 · 每 \(effectiveInterval) 分钟"; return
    }
    guard budget.mayRun(now: now, intervalMinutes: effectiveInterval, event: pendingEvent) else {
      state = callsThisHour >= 12 ? "本小时调用已达上限 · 本地监测继续" : now < budget.retryAfter ? "接口恢复后再试 · 本地监测继续" : "自动 · 每 \(effectiveInterval) 分钟"
      return
    }
    do {
      let recentEvents = events.filter { now.timeIntervalSince($0.time) <= 300 }
      let sample = try AIPreparedSample.prepare(snapshot: snapshot, history: history, minutes: pendingEvent ? 5 : 15,
        includeAppNames: false, paused: paused, now: now)
        .addingMonitoring(events: recentEvents, trends: engine.trends(now: now), network: network)
        .addingAdvisor(snapshot: snapshot, baseline: AdvisorStore.shared.baseline, actions: AdvisorStore.shared.candidates, care: CareStore.shared.scan)
      let trigger = pendingEvent ? "异常触发" : "定时观察"
      pendingEvent = false
      budget.started(now: now)
      prefs.set(budget.attempts, forKey: "aiWatchAttempts")
      state = "正在自动分析…"
      store.analyze(sample: sample, mode: .overview,
        question: "主动监测：优先给出一个当前结论。结合连续窗口和变化事件，指出有证据的可疑 App，区分相关性与根因。不要为正常波动凑建议。", trigger: trigger) { [weak self] error in
          guard let self else { return }
          self.budget.finished(now: Date(), error: error)
          if case AIAnalysisError.keychain? = error { self.keychainBlocked = true }
          self.state = error == nil ? "自动 · 每 \(self.intervalMinutes) 分钟" : "分析暂不可用 · 本地监测继续"
          if error == nil, let record = self.store.records.first, record.report.status == .attention,
            Date().timeIntervalSince(self.lastNotice) > 120 {
            self.sendNotification(title: "AI · 值得关注", body: record.conciseSummary, target: record.primaryFinding?.target ?? .other)
          }
        }
    } catch { state = "等待更多有效样本" }
  }
  func clearEvents() { events = []; saveEvents() }
  private func saveEvents() {
    do {
      try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(events).write(to: historyURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    } catch { /* Local monitoring and alerts continue even if history cannot be written. */ }
  }
  private func probeEndpoint(now: Date) {
    guard probe == nil, now.timeIntervalSince(lastProbe) >= 60 else { return }
    guard let url = try? AIEndpoint.models(store.config) else { return }
    lastProbe = now; lastEndpoint = url.absoluteString
    let currentEndpoint = lastEndpoint
    probe = Task { [weak self] in
      let setup = URLSessionConfiguration.ephemeral
      setup.urlCache = nil; setup.httpCookieStorage = nil; setup.httpShouldSetCookies = false
      setup.timeoutIntervalForRequest = 8; setup.timeoutIntervalForResource = 10
      let session = URLSession(configuration: setup, delegate: AINoRedirectDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 8
      let began = Date()
      var reachable = false
      do {
        let (_, response) = try await session.data(for: request)
        reachable = response is HTTPURLResponse // 401/404 still prove that the selected server is reachable.
      } catch { }
      guard let self, !Task.isCancelled, self.lastEndpoint == currentEndpoint else { return }
      self.network.endpointReachable = reachable
      self.network.endpointLatencyMS = reachable ? Date().timeIntervalSince(began) * 1000 : nil
      self.probe = nil
    }
  }
  func requestNotifications() {
    Task { [weak self] in
      guard let self else { return }
      let center = UNUserNotificationCenter.current()
      let settings = await center.notificationSettings()
      self.notificationDenied = settings.authorizationStatus == .denied
      if settings.authorizationStatus == .notDetermined, !self.prefs.bool(forKey: "aiWatchNotificationRequested") {
        self.prefs.set(true, forKey: "aiWatchNotificationRequested")
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        self.notificationDenied = !allowed
      }
    }
  }
  private func notify(_ fresh: [AIMonitorEvent]) {
    let relevant = fresh.filter { $0.urgent || $0.kind == .address || $0.kind == .network }
    guard let event = relevant.first else { return }
    let body = relevant.prefix(3).map { $0.title + "：" + $0.detail }.joined(separator: "\n")
    sendNotification(title: event.title, body: body, target: event.target, appID: event.appID)
  }
  private func sendNotification(title: String, body: String, target: AIReport.Target, appID: String? = nil) {
    guard notifications else { return }
    lastNotice = Date()
    let content = UNMutableNotificationContent()
    content.title = "澄观 · " + title; content.body = body
    content.userInfo = ["target": target.rawValue, "appID": appID ?? ""]
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
}
