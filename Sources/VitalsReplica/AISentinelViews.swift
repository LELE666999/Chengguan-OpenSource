import AppKit
import SwiftUI

@MainActor struct AISentinelPreferences: View {
  @ObservedObject private var watch = AISentinel.shared
  @Environment(\.scenePhase) private var scenePhase
  @State private var info = false
  @ObservedObject private var advisor = AdvisorStore.shared
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Label("自动分析", systemImage: "sparkles").fontWeight(.medium)
        Spacer()
        Picker("频率", selection: $watch.intervalMinutes) {
          ForEach([5, 10, 15, 30], id: \.self) { Text("每 \($0) 分钟").tag($0) }
        }.labelsHidden().frame(width: 120).disabled(!watch.enabled)
        Toggle("自动分析", isOn: $watch.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
      }
      HStack {
        Toggle("自适应", isOn: $watch.adaptive).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        Text(watch.automaticDescription).font(.system(size: 11)).foregroundStyle(.secondary)
        Button { info = true } label: { Image(systemName: "info.circle") }.buttonStyle(.plain)
          .popover(isPresented: $info) {
            VStack(alignment: .leading, spacing: 10) {
              Text("今日 \(advisor.todayUsage.requests) 次请求 · \(advisor.todayUsage.tokens.formatted()) Token；\(advisor.todayUsage.missingUsage) 次未返回用量。目录查询不计入，账单以服务商为准。")
              Text("自适应开启时，平稳 10 分钟后延长至至少 15 分钟、30 分钟后延长至至少 30 分钟；异常和恢复优先。")
              Text("本地持续检查，异常时提前分析。自动调用最多 12 次/小时，可能产生 API 费用；本小时 \(watch.callsThisHour) 次。")
              Text("自动发送匿名指标和变化类型；App 名称在本机还原，IP 与地址变化详情仅存本机。接口连通探测不带 Key。")
              Text("不能仅靠资源读数确认所有卡顿根因。未打开 App、休眠或暂停采样期间不持续监测。")
              Text("网络诊断目标：" + ((try? AIEndpoint.models(AIAnalysisStore.shared.config).host) ?? "当前模型接口"))
              Button("恢复自动重试") { watch.resume() }
            }.font(.system(size: 12)).padding(18).frame(width: 310)
          }.accessibilityLabel("自动分析与用量")
        Spacer()
        Toggle("通知", isOn: $watch.notifications).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        if watch.notificationDenied {
          Button("开启通知") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
          }.font(.system(size: 11))
        }
      }
    }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
      .onAppear { if watch.notifications { watch.requestNotifications() } }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active, watch.notifications { watch.requestNotifications() }
      }
  }
}

@MainActor struct AIWatchOverview: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var watch = AISentinel.shared
  @ObservedObject private var store = AIAnalysisStore.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: watch.enabled ? "waveform.path.ecg" : "pause.circle").foregroundStyle(Theme.accent)
        Text(watch.automaticDescription).font(.system(size: 16, weight: .semibold))
        Spacer()
        if store.busy { ProgressView().controlSize(.small) }
        if !store.hasKey { Button("连接模型") { model.showAIAnalysis = false; model.presentSettings(section: "AI 分析") } }
      }
      if watch.events.isEmpty {
        Text("变化会出现在这里，结论自动更新。")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        ForEach(watch.events.prefix(8)) { event in AIEventRow(model: model, event: event) }
      }
    }
  }
}

@MainActor struct AIEventRow: View {
  @ObservedObject var model: MonitorModel
  let event: AIMonitorEvent
  var body: some View {
    Button {
      if let tab = event.target.tab { model.select(tab) }
      model.selection = event.appID; model.onShowMain?(); model.showAIAnalysis = false
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: event.resolved ? "checkmark.circle" : event.urgent ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
          .foregroundStyle(event.resolved ? .green : event.urgent ? .orange : Theme.accent).padding(.top, 2)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(event.title).fontWeight(.medium)
            Spacer()
            Text(event.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
          }
          Text(event.detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain).font(.system(size: 12))
  }
}
