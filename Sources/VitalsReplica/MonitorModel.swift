import AppKit
import Combine
import MonitorBridge
import SwiftUI

final class MonitorModel: ObservableObject {
  @Published var snapshot = MonitorSnapshot()
  @Published var history: [HistoryPoint] = []
  @Published var overviewFrames: [OverviewFrame] = []
  @Published var sensorExtrema = SensorExtremaTracker()
  @Published var showDeviceDetails = false
  @Published var deviceDetailsPage = "健康"
  @Published var savedHistory: [HistoryPoint] = []
  @Published var tab: MonitorTab = .overview
  @Published var cableSelection: String?
  @Published var search = ""
  @Published var selection: String?
  @Published var expanded: Set<String> = []
  @Published var paused = false
  @Published var bars = false
  @Published var sortColumn = "CPU"
  @Published var ascending = false
  @Published var insights: [String] = []
  @Published var notice: String?
  @Published var showAIAnalysis = false
  @Published var appHistoryTarget: AppHistoryTarget?
  @Published var showDiagnostics = false
  @Published var showDiskUsage = false
  @Published var carePage: CarePage?
  @Published var settingsRequest: UUID?
  var onShowMain: (() -> Void)?
  func presentCare(_ page: CarePage = .clean) {
    showAIAnalysis = false
    selection = nil
    carePage = page
    onShowMain?()
  }
  func presentAI() {
    onShowMain?()
    DispatchQueue.main.async { self.showAIAnalysis = true }
  }
  func presentSettings(section: String? = nil) {
    if let section { UserDefaults.standard.set(section, forKey: "settingsSection") }
    onShowMain?()
    DispatchQueue.main.async { self.settingsRequest = UUID() }
  }
  @Published var dayTotals = HistoryTotals()
  @Published var weekTotals = HistoryTotals()
  @Published var monthTotals = HistoryTotals()
  @Published var appHistory: [AppHistorySummary] = []
  @Published var range: Double = 43200 { didSet { loadHistory() } }
  private let queue = DispatchQueue(label: "studio.lele.vitals-replica.collector", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var collector: SystemCollector?
  private var store: HistoryStore?
  private var lastHistoryRefresh = Date.distantPast
  private var highCPUCount = 0
  var onSnapshot: ((MonitorSnapshot) -> Void)?
  var selectedGroup: AppGroup? { snapshot.groups.first { $0.id == selection } }
  var plottedHistory: [HistoryPoint] {
    range <= 1800 ? history.filter { $0.time >= Date().addingTimeInterval(-range) } : savedHistory
  }
  init() { start() }
  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      self.collector = SystemCollector()
      self.store = HistoryStore()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(150))
      timer.setEventHandler { [weak self] in self?.sample() }
      self.timer = timer
      timer.resume()
    }
  }
  deinit { timer?.cancel() }
  func updateInterval(_ seconds: Double) {
    queue.async {
      self.timer?.schedule(
        deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(150))
    }
  }
  func setPaused(_ value: Bool) {
    paused = value
    DispatchQueue.main.async { AISentinel.shared.samplingPaused(value) }
    queue.async { [self] in
      if value {
        self.timer?.setEventHandler {}
      } else {
        self.timer?.setEventHandler { [weak self] in self?.sample() }
      }
    }
  }
  private func sample() {
    guard let snapshot = collector?.sample() else { return }
    store?.record(snapshot)
    if snapshot.time.timeIntervalSince(lastHistoryRefresh) >= 30 {
      lastHistoryRefresh = snapshot.time
      let day =
        store?.totals(since: Calendar.current.startOfDay(for: snapshot.time)) ?? HistoryTotals()
      let week =
        store?.totals(since: snapshot.time.addingTimeInterval(-7 * 86400)) ?? HistoryTotals()
      let month =
        store?.totals(since: snapshot.time.addingTimeInterval(-30 * 86400)) ?? HistoryTotals()
      let selectedRange = UserDefaults.standard.double(forKey: "historyRange")
      let since = snapshot.time.addingTimeInterval(-(selectedRange > 0 ? selectedRange : 43200))
      let points = store?.points(since: since) ?? []
      let ranking = store?.appSummary(since: since) ?? []
      DispatchQueue.main.async {
        self.dayTotals = day
        self.weekTotals = week
        self.monthTotals = month
        self.savedHistory = points
        self.appHistory = ranking
      }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.snapshot = snapshot
      AppAudioMixer.shared.reconcile(snapshot: snapshot)
      if !snapshot.isWarmup {
        self.history.append(snapshot.point)
        self.overviewFrames.append(OverviewFrame(snapshot))
        self.overviewFrames.removeAll { snapshot.time.timeIntervalSince($0.id) > 1800 }
        if self.overviewFrames.count > 900 { self.overviewFrames.removeFirst(self.overviewFrames.count - 900) }
        self.sensorExtrema.observe(snapshot.sensors)
      }
      self.history.removeAll { $0.time < Date().addingTimeInterval(-1800) }
      self.onSnapshot?(snapshot)
      self.updateInsights(snapshot)
      AISentinel.shared.observe(snapshot: snapshot, history: self.history, paused: self.paused)
      AIUsageStore.shared.refresh()
      CodexResetStore.shared.refresh()
      let policy = CollectionPolicy(visible: NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized },
        battery: snapshot.battery.percent != nil && !snapshot.battery.plugged,
        incident: !AdvisorStore.shared.activeEpisodes.isEmpty)
      self.queue.async { self.collector?.policy = policy }
    }
  }
  func loadHistory() {
    UserDefaults.standard.set(range, forKey: "historyRange")
    let since = Date().addingTimeInterval(-range)
    queue.async { [weak self] in
      guard let self else { return }
      let pts = self.store?.points(since: since) ?? []
      let apps = self.store?.appSummary(since: since) ?? []
      DispatchQueue.main.async {
        self.savedHistory = pts
        self.appHistory = apps
      }
    }
  }
  func freshSnapshot(_ completion: @escaping @MainActor (MonitorSnapshot) -> Void) {
    queue.async { [weak self] in
      guard let self, let s = self.collector?.freshForAction() else { return }
      DispatchQueue.main.async { completion(s) }
    }
  }
  func loadAppPoints(id: String, since: Date, completion: @escaping ([AppHistoryPoint]) -> Void) {
    queue.async { [weak self] in
      let points = self?.store?.appPoints(id: id, since: since) ?? []
      DispatchQueue.main.async { completion(points) }
    }
  }
  func select(_ tab: MonitorTab) {
    guard MonitorTab.visibleTabs.contains(tab) else { return }
    carePage = nil
    self.tab = tab
    selection = nil
    search = ""
    sortColumn = tab == .memory ? "内存" : (tab == .disk ? "写入" : (tab == .network ? "下载" : "CPU"))
    ascending = false
  }
  func sortedGroups() -> [AppGroup] {
    snapshot.groups.filter {
      (UserDefaults.standard.object(forKey: "showMacOS") as? Bool ?? true
        || $0.id != "system.macos")
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          || $0.processes.contains {
            $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search
          })
    }.sorted { a, b in
      if sortColumn == "名称" {
        return ascending
          ? a.name.localizedStandardCompare(b.name) == .orderedAscending
          : a.name.localizedStandardCompare(b.name) == .orderedDescending
      }
      func value(_ g: AppGroup) -> Double {
        switch sortColumn {
        case "内存": Double(g.memory)
        case "进程": Double(g.processes.count)
        case "写入": g.writeRate
        case "读取": g.readRate
        case "下载": g.networkIn ?? -1
        case "上传": g.networkOut ?? -1
        default: g.cpu
        }
      }
      let x = value(a)
      let y = value(b)
      return x == y ? a.id < b.id : (ascending ? x < y : x > y)
    }
  }
  func sort(_ column: String) {
    if sortColumn == column {
      ascending.toggle()
    } else {
      sortColumn = column
      ascending = column == "名称"
    }
  }
  private func updateInsights(_ s: MonitorSnapshot) {
    var messages: [String] = []
    highCPUCount = s.cpu > 85 ? highCPUCount + 1 : 0
    if highCPUCount >= 10 { messages.append("CPU 持续高于 85%，查看最忙的 App。") }
    if s.pressureLevel >= 2 { messages.append("内存压力升高，当前交换空间 \(Format.memory(s.swap))。") }
    if let v = s.primaryVolume, Double(v.free) / Double(v.total) < 0.1 {
      messages.append("磁盘可用空间不足 10%，剩余 \(Format.bytes(v.free))。")
    }
    if let t = s.temperature, t > 90 { messages.append("CPU 温度 \(Int(t)) °C，建议检查持续占用资源的 App。") }
    insights = messages
  }
  func exportCSV() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Chengguan-\(Date().formatted(.iso8601.year().month().day())).csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let points = plottedHistory
    do {
      try HistoryStore.csv(points).write(to: url, atomically: true, encoding: .utf8)
      notice = "已导出 \(points.count) 条历史记录"
    } catch { notice = "导出失败：\(error.localizedDescription)" }
  }
  func exportHistoryBundle(range: Double) {
    let since = Date().addingTimeInterval(-range)
    queue.async { [weak self] in
      guard let self else { return }
      let files = self.store?.exportFiles(since: since) ?? []
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
      let folder = downloads.appendingPathComponent("Chengguan-\(Int(Date().timeIntervalSince1970))")
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, csv) in files {
          try csv.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
      } catch { DispatchQueue.main.async { self.notice = error.localizedDescription } }
    }
  }
  func exportApps() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Chengguan-Apps.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let csv =
      "app,cpu_percent,memory_bytes,processes,measured_processes\n"
      + snapshot.groups.map {
        "\(HistoryStore.csvField($0.name)),\($0.cpu),\($0.memory),\($0.processes.count),\($0.measuredCount)"
      }.joined(separator: "\n")
    do {
      try csv.write(to: url, atomically: true, encoding: .utf8)
      notice = "已导出 App 列表"
    } catch { notice = error.localizedDescription }
  }
  func reveal(_ group: AppGroup) {
    if let path = group.bundlePath {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
  }
  func activate(_ group: AppGroup) {
    for p in group.processes {
      if let a = NSRunningApplication(processIdentifier: p.pid), a.activationPolicy == .regular {
        a.activate()
        return
      }
    }
  }
  func quit(_ group: AppGroup) {
    Task { @MainActor in AdvisorExecutor.execute(.quit(group, snapshot: snapshot, evidence: "正常退出 App", pressureRequired: false), model: self) }
  }
  func stopProject(_ project: ProjectSample) {
    Task { @MainActor in AdvisorExecutor.execute(.stop(project, snapshot: snapshot), model: self) }
  }
}
