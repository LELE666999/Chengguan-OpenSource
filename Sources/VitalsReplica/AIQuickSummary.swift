import AppKit
import SwiftUI

extension AIReport.Target {
  var settingsURL: URL? {
    switch self {
    case .battery: URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
    case .network: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
    default: nil
    }
  }
}

@MainActor enum AdvicePresentation {
  static func summary(advisor: AdvisorStore, record: AIAnalysisRecord?) -> String {
    guard advisor.current.totalMemory > 0, Date().timeIntervalSince(advisor.current.time) < 20 else { return advisor.conclusion }
    if let record, record.isRecent() {
      if let incident = advisor.primary, record.sampledAt >= incident.startedAt, record.report.status == .attention {
        return record.conciseSummary
      }
      let latestRecovery = advisor.episodes.compactMap(\.endedAt).max() ?? .distantPast
      if advisor.primary == nil, record.report.status == .normal, record.sampledAt >= latestRecovery { return record.conciseSummary }
    }
    return advisor.conclusion
  }
}

/// Shared current conclusion. Old cloud reports cannot override a newer local recovery.
@MainActor struct AIQuickSummary: View {
  @ObservedObject var model: MonitorModel
  var compact = false
  @ObservedObject private var store = AIAnalysisStore.shared
  @ObservedObject private var watch = AISentinel.shared
  @ObservedObject private var advisor = AdvisorStore.shared
  @ObservedObject private var usage = AIUsageStore.shared
  @ObservedObject private var resets = CodexResetStore.shared
  @ObservedObject private var care = CareStore.shared
  @ObservedObject private var live = LiveActivity.shared
  @ObservedObject private var cables = CableMonitor.shared
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  private var messages: [AIQuickMessage] {
    let feed = AIMessageFeed.messages(events: watch.events, runs: advisor.runs, providers: usage.providers,
      error: store.error, activity: store.activity, status: store.status, messageTime: store.messageTime, record: store.records.first, extra: care.feed + live.changes + cables.changes + storage.changes + resets.changes)
    if let notice = storage.notice { return [notice] + feed.filter { $0.id != notice.id } }
    return feed
  }
  @AppStorage("ai.menu.presentation") private var presentation = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var headline: String {
    if let notice = storage.notice { return notice.title + (notice.detail.isEmpty ? "" : " · " + notice.detail) }
    if let message = messages.first, message.usage, message.priority > 0 { return message.title }
    if advisor.primary != nil || messages.isEmpty { return AdvicePresentation.summary(advisor: advisor, record: store.records.first) }
    guard let message = messages.first else { return advisor.conclusion }
    return message.title + (message.detail.isEmpty ? "" : " · " + message.detail)
  }
  private func setPresentation(_ value: Int) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { presentation = value } }
  var body: some View {
    Group {
      if presentation == 0 {
        AIRevealButton { setPresentation(1) }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Button { setPresentation(presentation == 1 ? 2 : 1) } label: {
              HStack(spacing: 7) {
                GlassStatusCapsule { Label("AI", systemImage: "sparkles").fontWeight(.semibold).foregroundStyle(Theme.accent) }
                if presentation == 1 {
                  GlassStatusCapsule { Text(headline).font(.system(size: 12)).lineLimit(1).truncationMode(.tail) }
                } else {
                  GlassStatusCapsule { Text(watch.shortState).font(.system(size: 10)).foregroundStyle(.secondary) }
                  Spacer(minLength: 2)
                  if let message = messages.first { Text(message.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(presentation == 1 ? "展开 AI 提示" : "收起 AI 提示").help(headline)
            Button { setPresentation(presentation == 1 ? 2 : 1) } label: {
              Image(systemName: presentation == 1 ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(GlassCircleButtonStyle()).accessibilityLabel(presentation == 1 ? "展开提示内容" : "收起提示内容")
            Button { setPresentation(0) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 28).contentShape(Circle()) }
              .buttonStyle(GlassCircleButtonStyle()).help("隐藏 AI 提示").accessibilityLabel("隐藏 AI 提示")
          }
          if presentation == 2 {
            if advisor.primary != nil || messages.isEmpty {
              Text(AdvicePresentation.summary(advisor: advisor, record: store.records.first)).font(.system(size: 13, weight: .medium)).lineLimit(3)
              if !advisor.evidence.isEmpty { Text(advisor.evidence).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            if !messages.isEmpty { AIMessageRows(model: model, messages: messages, limit: 3) }
            HStack(spacing: 8) {
              if store.busy { ProgressView().controlSize(.mini) }
              AdvisorActionButtons(model: model, compact: true)
              Spacer(minLength: 2)
              Button(store.hasKey ? "详情" : "连接模型") {
                if store.hasKey { model.presentAI() } else { model.presentSettings(section: "AI 分析") }
              }.buttonStyle(AIControlButtonStyle(compact: true))
            }
          }
        }.font(.system(size: 12)).padding(compact ? 12 : 16)
          .background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
      }
    }
  }
}


@MainActor struct AIStatusStrip: View {
  @ObservedObject var model: MonitorModel
  var showConnect = true
  @ObservedObject private var store = AIAnalysisStore.shared
  @ObservedObject private var watch = AISentinel.shared
  @ObservedObject private var advisor = AdvisorStore.shared
  @ObservedObject private var usage = AIUsageStore.shared
  @ObservedObject private var resets = CodexResetStore.shared
  @ObservedObject private var care = CareStore.shared
  @ObservedObject private var live = LiveActivity.shared
  @ObservedObject private var cables = CableMonitor.shared
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @AppStorage("ai.window.presentation") private var presentation = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var messages: [AIQuickMessage] {
    let feed = AIMessageFeed.messages(events: watch.events, runs: advisor.runs, providers: usage.providers,
      error: store.error, activity: store.activity, status: store.status, messageTime: store.messageTime, record: store.records.first, extra: care.feed + live.changes + cables.changes + storage.changes + resets.changes)
    if let notice = storage.notice { return [notice] + feed.filter { $0.id != notice.id } }
    return feed
  }
  private var headline: String {
    if let notice = storage.notice { return notice.title + (notice.detail.isEmpty ? "" : " · " + notice.detail) }
    if let message = messages.first, message.usage, message.priority > 0 { return message.title }
    return advisor.primary == nil ? messages.first?.title ?? AdvicePresentation.summary(advisor: advisor, record: store.records.first)
      : AdvicePresentation.summary(advisor: advisor, record: store.records.first)
  }
  private func setPresentation(_ value: Int) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { presentation = value } }
  var body: some View {
    Group {
      if presentation == 0 { AIRevealButton { setPresentation(1) } }
      else {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 8) {
            Button { setPresentation(presentation == 1 ? 2 : 1) } label: {
              HStack(spacing: 7) {
                GlassStatusCapsule { Label("AI", systemImage: "sparkles").fontWeight(.semibold).foregroundStyle(Theme.accent) }
                GlassStatusCapsule { Text(watch.shortState).font(.system(size: 10)).foregroundStyle(.secondary) }.fixedSize()
                GlassStatusCapsule { Text(headline).lineLimit(1) }.layoutPriority(1)
                Spacer(minLength: 0)
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(presentation == 1 ? "展开 AI 提示" : "收起 AI 提示").help(headline)
            if store.busy { ProgressView().controlSize(.mini).padding(.horizontal, 5) }
            Button { setPresentation(presentation == 1 ? 2 : 1) } label: {
              Image(systemName: presentation == 1 ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(GlassCircleButtonStyle()).accessibilityLabel(presentation == 1 ? "展开提示内容" : "收起提示内容")
            Button { setPresentation(0) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 28).contentShape(Circle()) }
              .buttonStyle(GlassCircleButtonStyle()).help("隐藏 AI 提示").accessibilityLabel("隐藏 AI 提示")
          }.padding(.vertical, 9)
          if presentation == 2 {
            HStack(alignment: .top, spacing: 28) {
              VStack(alignment: .leading, spacing: 8) {
                Text(AdvicePresentation.summary(advisor: advisor, record: store.records.first)).font(.system(size: 13, weight: .medium)).lineLimit(3)
                Text(advisor.evidence).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                  AdvisorActionButtons(model: model, compact: true)
                  if store.hasKey || showConnect {
                    Button(store.hasKey ? "详情" : "连接模型") {
                      if store.hasKey { model.presentAI() } else { model.presentSettings(section: "AI 分析") }
                    }.buttonStyle(AIControlButtonStyle(compact: true))
                  }
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
              if !messages.isEmpty { AIMessageRows(model: model, messages: messages, limit: 3).frame(maxWidth: .infinity) }
            }.padding(.top, 6).padding(.bottom, 16)
          }
        }.font(.system(size: 12)).padding(.horizontal, 16)
      }
    }
  }
}
private struct AIRevealButton: View {
  let action: () -> Void
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  var body: some View {
    HStack {
      if let notice = storage.notice {
        Label(notice.title, systemImage: notice.symbol).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.accent)
      }
      Spacer(minLength: 6)
      Button(action: action) { Label("显示 AI 提示", systemImage: "sparkles").font(.system(size: 10)).padding(.horizontal, 10).frame(height: 26).contentShape(Capsule()) }
        .buttonStyle(.plain).modifier(ChromeGlass()).foregroundStyle(.secondary)
    }.padding(.horizontal, 8)
  }
}
