import SwiftUI

struct AIQuickMessage: Identifiable {
  let id: String
  let time: Date
  let title: String
  let detail: String
  var symbol = "arrow.triangle.2.circlepath"
  var priority = 0
  var target: AIReport.Target?
  var appID: String?
  var usage = false
  var carePage: CarePage?
  var cables = false
  var storage = false
}

enum AIMessageFeed {
  static func messages(events: [AIMonitorEvent], runs: [ActionRun], providers: [ProviderUsage] = [],
                       error: String? = nil, activity: String? = nil, status: String? = nil,
                       messageTime: Date? = nil, record: AIAnalysisRecord? = nil, now: Date = Date(), extra: [AIQuickMessage] = []) -> [AIQuickMessage] {
    var result = events.filter { $0.time <= now && now.timeIntervalSince($0.time) < 86400 }.map {
      AIQuickMessage(id: $0.id.uuidString, time: $0.time, title: $0.title, detail: $0.detail,
        symbol: $0.resolved ? "checkmark.circle" : $0.urgent ? "exclamationmark.circle" : "arrow.triangle.2.circlepath",
        target: $0.target, appID: $0.appID)
    }
    for run in runs {
      let time = run.updatedAt ?? run.observationStartedAt ?? run.time
      // Keep the compact inbox current; the full processing history remains in the timeline.
      guard time <= now, now.timeIntervalSince(time) < 1800 else { continue }
      let active = [.confirming, .executing, .observing].contains(run.state)
      let name = run.action.targetName ?? run.action.title.replacingOccurrences(of: "…", with: "")
      result.append(AIQuickMessage(id: run.id.uuidString, time: time, title: name + " · " + run.state.rawValue,
        detail: run.detail, symbol: active ? "clock" : run.state == .failed ? "exclamationmark.circle" : "checkmark.circle",
        priority: active && now.timeIntervalSince(time) < 600 ? 2 : 0))
    }
    if let activity {
      result.append(AIQuickMessage(id: "ai-activity", time: now, title: activity, detail: "完成后自动更新结论", symbol: "sparkles", priority: 1))
    } else if let time = messageTime, time <= now, now.timeIntervalSince(time) < 86400 {
      if let error {
        result.append(AIQuickMessage(id: "ai-error", time: time, title: "AI 分析需要处理", detail: String(error.prefix(160)), symbol: "exclamationmark.circle", priority: 1))
      } else if let status, !status.hasPrefix("分析完成") {
        result.append(AIQuickMessage(id: "ai-status", time: time, title: String(status.prefix(80)), detail: "", symbol: "checkmark.circle"))
      }
    }
    for provider in providers where !provider.stale(at: now) {
      guard let window = provider.limits.flatMap(\.windows).max(by: { $0.used < $1.used }), window.used >= 90,
        let time = provider.updated, time <= now, now.timeIntervalSince(time) < 86400 else { continue }
      result.append(AIQuickMessage(id: "quota-" + provider.id, time: time,
        title: provider.id + String(format: " 额度剩余 %.1f%%", 100 - window.used),
        detail: provider.source, symbol: "gauge.with.dots.needle.67percent", usage: true))
    }
    if let record, record.createdAt <= now, now.timeIntervalSince(record.createdAt) < 86400 {
      let changed = events.contains { $0.time > record.sampledAt && $0.time <= now }
      result.append(AIQuickMessage(id: record.id.uuidString, time: record.createdAt,
        title: changed ? "变化前的 AI 结论" : record.isRecent(at: now) ? "AI 结论已更新" : "上次 AI 结论",
        detail: record.conciseSummary, symbol: "sparkles", priority: changed ? -1 : 0))
    }
    result.append(contentsOf: extra.filter { $0.time <= now && now.timeIntervalSince($0.time) < 1800 })
    return result.sorted { $0.priority == $1.priority ? $0.time > $1.time : $0.priority > $1.priority }
  }
}

@MainActor struct AIMessageRows: View {
  @ObservedObject var model: MonitorModel
  let messages: [AIQuickMessage]
  var limit = 2
  var body: some View {
    VStack(spacing: 3) {
      ForEach(messages.prefix(limit)) { message in
        Button {
          if message.storage { model.select(.overview); model.onShowMain?(); model.showAIAnalysis = false }
          else if message.cables { model.select(.cables); model.onShowMain?(); model.showAIAnalysis = false }
          else if let page = message.carePage { model.presentCare(page) }
          else if message.usage { model.select(.agents); model.onShowMain?(); model.showAIAnalysis = false }
          else if let tab = message.target?.tab {
            model.select(tab); model.selection = message.appID; model.onShowMain?(); model.showAIAnalysis = false
          } else { model.presentAI() }
        } label: {
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: message.symbol).foregroundStyle(Theme.accent).frame(width: 13).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
              Text(message.title).foregroundStyle(.primary).lineLimit(1)
              if !message.detail.isEmpty { Text(message.detail).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(message.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
          }.font(.system(size: 11)).multilineTextAlignment(.leading).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(CareRowStyle())
      }
    }
  }
}
