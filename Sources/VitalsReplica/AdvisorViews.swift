import AppKit
import Charts
import SwiftUI

struct AppHistoryTarget: Identifiable { let id: String; let name: String }
struct SegmentedAppPoint: Identifiable {
  let point: AppHistoryPoint
  let segment: Int
  var id: Date { point.time }
  static func make(_ points: [AppHistoryPoint]) -> [Self] {
    var segment = 0, previous: Date?
    return points.map { p in
      if let previous, p.time.timeIntervalSince(previous) > 90 { segment += 1 }
      previous = p.time; return Self(point: p, segment: segment)
    }
  }
}

@MainActor struct AppHistoryView: View {
  @ObservedObject var model: MonitorModel
  let target: AppHistoryTarget
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var advisor = AdvisorStore.shared
  @State private var seconds = 900
  @State private var points: [AppHistoryPoint] = []
  @State private var metric = "CPU"
  @State private var loading = false
  @State private var request = UUID()
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(target.name).font(.system(size: 20, weight: .semibold))
        Spacer()
        Button("完成") { dismiss() }.buttonStyle(AIControlButtonStyle())
      }
      HStack {
        Picker("指标", selection: $metric) { Text("CPU").tag("CPU"); Text("内存").tag("内存") }.pickerStyle(.segmented).frame(width: 140)
        Spacer()
        Picker("时间", selection: $seconds) { Text("15 分钟").tag(900); Text("1 小时").tag(3600); Text("今天").tag(86400) }.pickerStyle(.segmented).frame(width: 250)
      }
      if loading { ProgressView().frame(maxWidth: .infinity).frame(height: 195) }
      else if points.count < 2 { ContentUnavailableView("正在积累历史", systemImage: "chart.xyaxis.line", description: Text("每 30 秒记录一次；空白时段不补值。")).frame(height: 195) }
      else {
        Chart(SegmentedAppPoint.make(points)) { p in
          LineMark(x: .value("时间", p.point.time), y: .value(metric, metric == "CPU" ? p.point.cpu : p.point.memory / pow(1024, 3)), series: .value("连续窗口", p.segment))
            .foregroundStyle(Theme.accent).interpolationMethod(.linear)
        }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
          .chartYAxisLabel(metric == "CPU" ? "% · 单核" : "GB").frame(height: 195)
      }
      HStack(spacing: 24) {
        SmallStat(title: "CPU 峰值 · 单核", value: points.map(\.cpu).max().map { String(format: "%.0f%%", $0) } ?? "—")
        SmallStat(title: "内存变化", value: memoryChange)
        Spacer()
        Text("\(points.count) 个样本 · 断档留白").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if let app = model.snapshot.groups.first(where: { $0.id == target.id }) {
        Text(advisor.baselineText(for: app)).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      let episodes = advisor.episodes.filter { $0.appID == target.id && $0.lastSeen >= since }
      if !episodes.isEmpty {
        Divider()
        ScrollView { VStack(spacing: 10) { ForEach(episodes.prefix(8)) { EpisodeRow(episode: $0, model: model, navigates: false) } } }.frame(maxHeight: 145)
      }
    }.padding(24).frame(width: 650).background(Color(nsColor: .windowBackgroundColor))
      .onAppear(perform: load).onChange(of: seconds) { _, _ in load() }
  }
  private var since: Date { seconds == 86400 ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-Double(seconds)) }
  private var memoryChange: String {
    guard let a = points.first, let b = points.last, points.count >= 2 else { return "—" }
    let d = b.memory - a.memory; return (d < 0 ? "−" : "+") + Format.memory(abs(d))
  }
  private func load() {
    loading = true; let token = UUID(); request = token
    model.loadAppPoints(id: target.id, since: since) { result in guard request == token else { return }; points = result; loading = false }
  }
}

@MainActor struct AdvisorActionButtons: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var advisor = AdvisorStore.shared
  var compact = false
  var body: some View {
    HStack(spacing: 8) {
      if let p = advisor.primary, let id = p.appID, let app = model.snapshot.groups.first(where: { $0.id == id }) {
        Button("查看 \(app.name)") {
          model.showAIAnalysis = false
          model.onShowMain?()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.appHistoryTarget = AppHistoryTarget(id: app.id, name: app.name) }
        }.lineLimit(1)
      }
      ForEach(advisor.candidates.prefix(compact ? 1 : 2)) { action in
        Button(action.title) { AdvisorExecutor.execute(action, model: model) }.lineLimit(1)
      }
    }.buttonStyle(AIControlButtonStyle(compact: compact)).font(.system(size: 11))
  }
}

@MainActor struct AdvisorTimeline: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var advisor = AdvisorStore.shared
  var openReport: ((UUID) -> Void)? = nil
  @ObservedObject private var ai = AIAnalysisStore.shared
  @ObservedObject private var watch = AISentinel.shared
  @ObservedObject private var quota = AIUsageStore.shared
  @ObservedObject private var care = CareStore.shared
  @ObservedObject private var live = LiveActivity.shared
  @State private var showActions = false
  @State private var showEvents = true
  @State private var showCost = false
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(AdvicePresentation.summary(advisor: advisor, record: ai.records.first)).font(.system(size: 18, weight: .semibold))
        Text(advisor.evidence).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        HStack {
          AdvisorActionButtons(model: model)
          Spacer()
          if let record = ai.records.first, let openReport {
            Button("AI 报告") { openReport(record.id) }.buttonStyle(AIControlButtonStyle(compact: true))
              .help(record.sampledAt.formatted() + (record.isRecent() ? "" : " · 历史分析"))
          }
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
      let messages = AIMessageFeed.messages(events: watch.events, runs: advisor.runs, providers: quota.providers,
        error: ai.error, activity: ai.activity, status: ai.status, messageTime: ai.messageTime, record: ai.records.first, extra: care.feed + live.changes)
      if !messages.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("最新消息").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          AIMessageRows(model: model, messages: messages, limit: 6)
        }
      }
      DisclosureGroup("处理记录", isExpanded: $showActions) {
        if advisor.runs.isEmpty { Text("处理后的复测结果会留在这里。").font(.system(size: 12)).foregroundStyle(.secondary) }
        ForEach(advisor.runs.prefix(8)) { run in
          VStack(alignment: .leading, spacing: 7) {
            HStack {
              Text(run.action.targetName ?? run.action.title).fontWeight(.medium)
              Spacer(); Text(run.state.rawValue).foregroundStyle(run.state == .improved ? .green : Theme.accent)
              Text(run.time.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
            }
            Text(run.detail).foregroundStyle(.secondary).textSelection(.enabled)
          }.font(.system(size: 12)).padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
      }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
      DisclosureGroup("时间线", isExpanded: $showEvents) {
        if advisor.episodes.isEmpty { Text("尚无值得关注的变化").font(.system(size: 12)).foregroundStyle(.secondary) }
        ForEach(advisor.episodes.prefix(15)) { e in EpisodeRow(episode: e, model: model) }
      }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
      VStack(alignment: .leading, spacing: 9) {
        Label("今日日结", systemImage: "sun.max").font(.system(size: 13, weight: .medium))
        Text(advisor.dailyText()).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
      }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
      DisclosureGroup("用量与采样", isExpanded: $showCost) { AdvisorTelemetry(model: model) }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
      if let error = advisor.storageError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
    }
  }
}

@MainActor struct EpisodeRow: View {
  let episode: AdvisorEpisode
  @ObservedObject var model: MonitorModel
  var navigates = true
  var body: some View {
    Button {
      guard navigates else { return }
      model.showAIAnalysis = false
      if let tab = episode.target.tab { model.select(tab) }
      model.selection = episode.appID; model.onShowMain?()
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: episode.active ? "exclamationmark.circle" : episode.ending == "已恢复" ? "checkmark.circle" : "clock")
          .foregroundStyle(episode.active ? .orange : .secondary)
        VStack(alignment: .leading, spacing: 6) {
          HStack { Text(episode.title).fontWeight(.medium); Spacer(); Text(episode.active ? "观察中" : episode.ending ?? "已记录").foregroundStyle(.secondary) }
          Text(episode.detail).foregroundStyle(.secondary).lineLimit(2)
          Text("\(episode.startedAt.formatted(date: .omitted, time: .shortened)) → \(episode.active ? "现在" : (episode.endedAt ?? episode.lastSeen).formatted(date: .omitted, time: .shortened)) · \(Format.duration(episode.duration))")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if navigates { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
      }.font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
  }
}

@MainActor struct AdvisorTelemetry: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var advisor = AdvisorStore.shared
  @ObservedObject private var peripherals = Peripherals.shared
  var body: some View {
    let day = advisor.todayUsage
    VStack(alignment: .leading, spacing: 10) {
      Text("今日 \(day.requests) 次请求 · \(day.succeeded) 次成功 · \(day.tokens.formatted()) Token").font(.system(size: 12))
      Text("分析和连接测试；模型目录读取不计入。\(day.missingUsage) 次未返回 Token 用量，实际费用以服务商为准。").font(.system(size: 11)).foregroundStyle(.secondary)
      let own = model.snapshot.processes.first { $0.pid == getpid() }
      Text("澄观 · CPU \(String(format: "%.1f%%", own?.cpu ?? 0)) · 内存 \(own.map { Format.memory($0.memory) } ?? "—") · 唤醒 \(String(format: "%.0f/s", own?.wakeups ?? 0))")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Text("\(model.snapshot.collectionMode) · 本次采样 \(Int(model.snapshot.samplingDuration * 1000)) ms").font(.system(size: 11)).foregroundStyle(.secondary)
      Text("蓝牙最近扫描 \(Int(peripherals.bluetoothDuration * 1000)) ms · 可见时至少 30 秒、后台至少 90 秒").font(.system(size: 11)).foregroundStyle(.secondary)
      ForEach(model.snapshot.moduleDurations.keys.sorted(), id: \.self) { key in
        HStack { Text(key); Spacer(); Text("\(Int((model.snapshot.moduleDurations[key] ?? 0) * 1000)) ms") }.font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
}

@MainActor struct NetworkDiagnosticsView: View {
  @ObservedObject private var store = NetworkDiagnosticsStore.shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("网络诊断").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { dismiss() } }
      Text(store.target).font(.system(size: 12)).foregroundStyle(.secondary)
      ForEach(store.steps) { step in
        HStack(alignment: .top, spacing: 12) {
          if step.state == .checking { ProgressView().controlSize(.small) }
          else { Image(systemName: step.state == .passed ? "checkmark.circle.fill" : "questionmark.circle").foregroundStyle(step.state == .passed ? .green : .orange) }
          VStack(alignment: .leading, spacing: 7) { Text(step.title).fontWeight(.medium); Text(step.detail).foregroundStyle(.secondary).textSelection(.enabled) }
          Spacer()
        }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
      }
      HStack {
        Button("网络设置") { NSWorkspace.shared.open(AIReport.Target.network.settingsURL!) }
        Spacer()
        Button(store.running ? "检查中…" : "重新检查") { store.start() }.disabled(store.running)
      }
    }.padding(24).frame(width: 560).buttonStyle(AIControlButtonStyle()).background(Color(nsColor: .windowBackgroundColor)).onAppear { if store.steps.isEmpty { store.start() } }
  }
}

@MainActor struct DiskUsageView: View {
  @ObservedObject private var store = DiskUsageStore.shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("磁盘占用").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { dismiss() } }
      if store.running { ProgressView().controlSize(.small) }
      ForEach(store.folders) { folder in
        Button { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) } label: {
          HStack { Image(systemName: "folder"); Text(folder.url.lastPathComponent); Spacer(); Text((folder.partial ? "≥ " : "") + Format.bytes(folder.bytes)); Image(systemName: "arrow.up.right") }
            .padding(16).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
      }
      Text(store.message).font(.system(size: 11)).foregroundStyle(.secondary)
      HStack { Spacer(); if store.running { Button("停止扫描") { store.cancel() } } else { Button("重新扫描") { store.start() } } }
    }.padding(24).frame(width: 520).buttonStyle(AIControlButtonStyle()).background(Color(nsColor: .windowBackgroundColor)).onAppear { if store.folders.isEmpty { store.start() } }
  }
}
