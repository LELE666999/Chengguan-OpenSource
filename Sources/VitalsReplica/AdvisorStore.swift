import AppKit
import Combine
import Foundation
import MonitorBridge

private struct AdvisorArchive: Codable {
  var episodes: [AdvisorEpisode] = []
  var coverage = ObservationCoverage()
  var baseline = PersonalBaseline()
  var runs: [ActionRun] = []
  var usage = AIUsageLedger()
}

@MainActor final class AdvisorStore: ObservableObject {
  static let shared = AdvisorStore()
  @Published private(set) var episodes: [AdvisorEpisode] = []
  @Published private(set) var runs: [ActionRun] = []
  @Published private(set) var candidates: [AdvisorAction] = []
  @Published private(set) var coverage = ObservationCoverage()
  @Published private(set) var baseline = PersonalBaseline()
  @Published private(set) var usage = AIUsageLedger()
  @Published private(set) var current = MonitorSnapshot()
  @Published private(set) var storageError: String?
  private var readings: [ActionReading] = []
  private var previousTime: Date?
  private var newSpan = true
  private var lastSave = Date.distantPast
  private let file: URL
  private let io = DispatchQueue(label: "studio.lele.Chengguan.advisor-history", qos: .utility)
  private var network = AINetworkState()
  var activeEpisodes: [AdvisorEpisode] { episodes.filter(\.active) }
  var todayUsage: AIUsageDay { usage.days.first { $0.id == AIUsageLedger.dayKey(Date()) } ?? AIUsageDay(id: AIUsageLedger.dayKey(Date())) }
  var primary: AdvisorEpisode? {
    activeEpisodes.sorted { rank($0.kind) < rank($1.kind) }.first
  }
  private func rank(_ kind: AIMonitorEvent.Kind) -> Int {
    switch kind { case .memory: 0; case .cpu: 1; case .temperature: 2; case .disk: 3; case .network: 4; case .endpoint: 5; default: 6 }
  }
  var conclusion: String {
    guard current.totalMemory > 0 else { return "正在观察" }
    guard Date().timeIntervalSince(current.time) < 20 else { return "等待实时采样" }
    return primary?.title ?? "运行正常"
  }
  var evidence: String {
    if let primary { return primary.detail }
    let labels = DeveloperContext.labels(current)
    return labels.isEmpty ? "未见持续资源压力" : "正在\(labels.joined(separator: "、"))，暂未见持续压力"
  }
  init(file: URL? = nil) {
    self.file = file ?? AIHistoryFile.standard.url.deletingLastPathComponent().appendingPathComponent("advisor.json")
    if let size = try? self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_000_000,
      let data = try? Data(contentsOf: self.file), let archive = try? JSONDecoder().decode(AdvisorArchive.self, from: data) {
      episodes = archive.episodes; coverage = archive.coverage; baseline = archive.baseline; runs = archive.runs; usage = archive.usage
      // Restart is a missing observation, not a recovery or an observed successful action.
      for i in episodes.indices where episodes[i].active { episodes[i].endedAt = episodes[i].lastSeen; episodes[i].ending = "监测中断" }
      for i in runs.indices where [.confirming, .executing, .observing].contains(runs[i].state) { runs[i].state = .inconclusive; runs[i].detail = "App 重启，复测未完成" }
    }
  }
  func observe(_ s: MonitorSnapshot, events: [AIMonitorEvent], network: AINetworkState) {
    guard !s.isWarmup, s.totalMemory > 0, s.error == nil, s.time > (previousTime ?? .distantPast) else { return }
    self.network = network
    let gap = previousTime.map { s.time.timeIntervalSince($0) > 20 } ?? false
    if gap {
      for i in episodes.indices where episodes[i].active { episodes[i].endedAt = episodes[i].lastSeen; episodes[i].ending = "采样中断" }
    }
    previousTime = s.time; current = s; coverage.record(s.time, newSpan: newSpan); newSpan = false; baseline.observe(s)
    for i in episodes.indices where episodes[i].active {
      if isRecovered(episodes[i], snapshot: s) { episodes[i].endedAt = s.time; episodes[i].ending = "已恢复" }
      else {
        episodes[i].lastSeen = s.time
        let value: Double? = switch episodes[i].kind { case .cpu: s.cpu; case .temperature: s.temperature; default: nil }
        if let value { episodes[i].peak = max(episodes[i].peak ?? value, value) }
      }
    }
    for event in events where !event.resolved && event.kind != .recovery {
      let instant = [.address, .power].contains(event.kind) || (event.kind == .network && network.connected != false)
      if !instant, episodes.contains(where: { $0.active && $0.kind == event.kind && $0.appID == event.appID }) { continue }
      episodes.insert(AdvisorEpisode(id: event.id, kind: event.kind, target: event.target, appID: event.appID, title: event.title, detail: event.detail,
        startedAt: event.time.addingTimeInterval(-event.duration), lastSeen: s.time, endedAt: instant ? s.time : nil, ending: instant ? "已记录" : nil, peak: event.value), at: 0)
    }
    episodes = Array(episodes.filter { s.time.timeIntervalSince($0.lastSeen) < 31 * 86400 }.prefix(500))
    readings.append(ActionReading(time: s.time, cpu: s.cpu, memory: Double(s.usedMemory), pressure: s.pressureLevel, workload: DeveloperContext.workload(s)))
    readings.removeAll { s.time.timeIntervalSince($0.time) > 240 }
    updateRuns(s)
    candidates = makeCandidates(s)
    if s.time.timeIntervalSince(lastSave) >= 60 || !events.isEmpty { persist(); lastSave = s.time }
  }
  private func isRecovered(_ e: AdvisorEpisode, snapshot s: MonitorSnapshot) -> Bool {
    switch e.kind {
    case .cpu: s.cpu < 65
    case .memory: s.pressureLevel == 1
    case .temperature: s.temperature.map { $0 < 82 } ?? false
    case .disk: s.primaryVolume.map { Double($0.free) / Double(max(1, $0.total)) >= 0.12 } ?? false
    case .network: network.connected == true
    case .endpoint: e.peak == nil ? network.endpointReachable == true : (network.endpointLatencyMS.map { $0 < 1500 } ?? false)
    case .battery: s.battery.plugged || (s.battery.percent ?? 0) >= 20
    default: false
    }
  }
  private func makeCandidates(_ s: MonitorSnapshot) -> [AdvisorAction] {
    var result: [AdvisorAction] = []
    if let episode = primary {
      if [.cpu, .memory, .temperature].contains(episode.kind), let id = episode.appID,
        let app = s.groups.first(where: { $0.id == id }), app.bundlePath != nil,
        !app.processes.contains(where: { $0.pid == getpid() }), app.id != "system.macos" {
        let a = AdvisorAction.quit(app, snapshot: s, evidence: episode.detail, metric: episode.target)
        if a.invalidReason(snapshot: s, now: s.time, uid: getuid(), selfPID: getpid()) == nil { result.append(a) }
      }
      switch episode.target {
      case .network: result.append(.simple(.networkDiagnosis, "诊断网络", snapshot: s))
      case .disk:
        result.append(.simple(.cleanupReview, "整理空间", snapshot: s))
        result.append(.simple(.diskUsage, "查看占用", snapshot: s))
      case .battery: result.append(.simple(.batterySettings, "电池设置", snapshot: s))
      default: if episode.kind == .temperature { result.append(.simple(.batterySettings, "电池设置", snapshot: s)) }
      }
    }
    if let address = episodes.first(where: { $0.kind == .address }), s.time.timeIntervalSince(address.lastSeen) < 300, s.localNetwork.primary != nil {
      result.append(.simple(.copyAddress, "复制新地址", snapshot: s))
    }
    return result
  }
  func baselineText(for app: AppGroup) -> String {
    guard let b = baseline.value(appID: app.id, context: PersonalBaseline.context(current), now: current.time), b.ready else { return "基线积累中 · 同场景至少 30 个历史样本" }
    return String(format: "常态 CPU %.0f%% · P95 %.0f%% · 内存 %@", b.medianCPU, b.p95CPU, Format.memory(b.medianMemory))
  }
  func pause() {
    newSpan = true
    for i in episodes.indices where episodes[i].active { episodes[i].endedAt = episodes[i].lastSeen; episodes[i].ending = "采样暂停" }
    for i in runs.indices where runs[i].state == .observing { runs[i].state = .inconclusive; runs[i].detail = "采样暂停，复测未完成" }
    candidates = []; persist()
  }
  func recordUsage(usage: AITokenUsage?, success: Bool) { self.usage.record(at: Date(), usage: usage, success: success); persist() }
  func begin(_ action: AdvisorAction) -> UUID {
    let id = UUID()
    let before = ResourceWindow.summarize(readings, from: Date().addingTimeInterval(-60), to: Date())
    runs.insert(ActionRun(id: id, action: action, time: Date(), state: .confirming, detail: action.impact, before: before), at: 0)
    runs = Array(runs.prefix(100)); persist(); return id
  }
  func transition(_ id: UUID, _ state: ActionRun.State, _ detail: String) {
    guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
    runs[i].state = state; runs[i].detail = detail; runs[i].updatedAt = Date()
    if state == .observing {
      runs[i].observationStartedAt = Date()
      runs[i].before = ResourceWindow.summarize(readings, from: Date().addingTimeInterval(-60), to: Date())
    }
    persist()
  }
  private func updateRuns(_ s: MonitorSnapshot) {
    for i in runs.indices where runs[i].state == .observing {
      let run = runs[i]
      let began = run.observationStartedAt ?? run.time
      let exited = run.action.targetEnded(snapshot: s, after: began)
      runs[i].targetExited = exited
      if run.action.kind == .stopProject {
        // Project scanner has an independent cadence; only assess after a fresh scan.
        runs[i].portsReleased = s.projectScanTime.map { $0 > began } == true
          ? Set(s.listeningPorts).isDisjoint(with: run.action.ports) : nil
      }
      guard s.time.timeIntervalSince(began) >= 60 else { continue }
      let after = ResourceWindow.summarize(readings, from: began.addingTimeInterval(20), to: s.time)
      let before = run.before ?? ResourceWindow(cpu: 0, memory: 0, pressure: 0, seconds: 0, samples: 0)
      let workloads = Set(readings.filter { $0.time >= began.addingTimeInterval(-60) }.map(\.workload))
      let result = ActionOutcome.assess(before: before, after: after, targetExited: exited == true, workloadChanged: workloads.count > 1)
      runs[i].after = after; runs[i].state = result.0; runs[i].detail = result.1
      runs[i].updatedAt = s.time
      if exited == nil { runs[i].state = .inconclusive; runs[i].detail = "目标复查未完成，不能判断处理效果" }
      if exited == false, run.action.kind == .stopProject { runs[i].state = .unchanged; runs[i].detail = "服务仍在运行或已重新启动，未确认停止完成" }
      if run.action.kind == .stopProject { runs[i].detail += runs[i].portsReleased.map { $0 ? " 端口已释放。" : " 端口仍在占用。" } ?? " 端口复查未完成。" }
      persist()
    }
  }
  func dailyText(on day: Date = Date()) -> String {
    let start = Calendar.current.startOfDay(for: day), end = min(Date(), start.addingTimeInterval(86400))
    let observed = coverage.seconds(from: start, to: end)
    let today = episodes.filter { $0.lastSeen >= start && $0.startedAt < end }
    let incidents = today.filter { ![.address, .power].contains($0.kind) }
    let todayRuns = runs.filter { $0.time >= start && $0.time < end }
    guard observed > 0 else { return "今天尚无连续观测。未运行和休眠时段留白。" }
    return "已观察 \(observed < 60 ? "\(Int(observed)) 秒" : Format.duration(observed)) · \(incidents.count) 次值得关注的变化 · \(todayRuns.count) 次操作\n"
      + "\(incidents.filter { $0.ending == "已恢复" }.count) 次已恢复 · \(todayRuns.filter { $0.state == .improved }.count) 次处理后改善。未运行、暂停和休眠时段不计入。"
  }
  func flush() async { await withCheckedContinuation { c in io.async { c.resume() } } }
  private func persist() {
    let archive = AdvisorArchive(episodes: episodes, coverage: coverage, baseline: baseline, runs: runs, usage: usage)
    let file = file
    io.async { [weak self] in
      do {
        let data = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      } catch { Task { @MainActor in self?.storageError = "本机记录暂时无法保存" } }
    }
  }
}

@MainActor enum AdvisorExecutor {
  static func execute(_ action: AdvisorAction, model: MonitorModel) {
    let store = AdvisorStore.shared, run = store.begin(action)
    if action.needsConfirmation {
      let alert = NSAlert(); alert.messageText = action.title.replacingOccurrences(of: "…", with: "？")
      alert.informativeText = action.evidence + "\n\n" + action.impact
        + "\n" + action.tokens.map { "PID \($0.pid) · \(URL(fileURLWithPath: $0.path).lastPathComponent)" }.joined(separator: "\n")
      alert.addButton(withTitle: action.kind == .quitApp ? "退出 App" : "停止服务"); alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { store.transition(run, .cancelled, "用户取消，未执行"); return }
    }
    store.transition(run, .executing, "正在核对最新目标")
    model.freshSnapshot { snapshot in
      if let reason = action.invalidReason(snapshot: snapshot, now: Date(), uid: getuid(), selfPID: getpid()) { store.transition(run, .cancelled, reason); return }
      switch action.kind {
      case .quitApp:
        guard let app = action.tokens.compactMap({ NSRunningApplication(processIdentifier: $0.pid) }).first(where: { $0.activationPolicy == .regular }),
          let bundle = app.bundleURL?.standardizedFileURL.path, bundle == snapshot.groups.first(where: { $0.id == action.targetID })?.bundlePath,
          action.tokens.contains(where: { $0.pid == app.processIdentifier && vr_process_start($0.pid) == $0.start }) else { store.transition(run, .cancelled, "未找到可正常退出的同一 App"); return }
        guard app.terminate() else { store.transition(run, .failed, "App 拒绝退出请求"); return }
        store.transition(run, .observing, "退出请求已发出，等待保存确认并复测 60 秒")
      case .stopProject:
        guard let path = action.targetID else { store.transition(run, .cancelled, "项目不存在"); return }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // Validate every target before sending the first signal.
        for token in action.tokens {
          var bytes = [CChar](repeating: 0, count: 4096)
          guard vr_process_start(token.pid) == token.start, vr_process_cwd(token.pid, &bytes, 4096) else { store.transition(run, .cancelled, "进程身份已改变"); return }
          let cwd = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
          guard cwd == root || cwd.hasPrefix(root + "/") else { store.transition(run, .cancelled, "进程已离开该项目"); return }
        }
        var failures: [String] = []
        for token in action.tokens {
          let result = vr_process_signal(token.pid, token.start, SIGTERM)
          if result != 0 { failures.append("\(token.pid)：\(String(cString: strerror(result)))") }
        }
        store.transition(run, failures.isEmpty ? .observing : .failed, failures.isEmpty ? "已发送停止请求，复查进程与端口并观察 60 秒" : "部分进程未停止：" + failures.joined(separator: "；"))
      case .copyAddress:
        guard let address = snapshot.localNetwork.primary?.address else { store.transition(run, .cancelled, "当前无局域网 IPv4"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
        store.transition(run, .completed, "已复制当前局域网地址")
      case .networkDiagnosis:
        store.transition(run, .executing, "正在检查本机接入、DNS 与目标服务")
        NetworkDiagnosticsStore.shared.start { detail in store.transition(run, .completed, detail) }
        model.showAIAnalysis = false; model.onShowMain?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.showDiagnostics = true }
      case .diskUsage:
        model.presentCare(.space)
        store.transition(run, .completed, "已打开空间分析，点击目录可继续展开")
      case .cleanupReview:
        model.presentCare(.clean)
        CareStore.shared.start(ai: false)
        store.transition(run, .completed, "已开始清理预览，选择项目后再移到废纸篓")
      case .batterySettings:
        let opened = NSWorkspace.shared.open(AIReport.Target.battery.settingsURL!)
        store.transition(run, opened ? .completed : .failed, opened ? "已打开电池设置；未更改设置" : "无法打开系统设置")
      }
    }
  }
}
