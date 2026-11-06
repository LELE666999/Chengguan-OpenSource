import SwiftUI

/// The overview and detail use the same quota, even when a provider has several windows.
enum AIQuotaOverviewData {
  static func primaryWindow(_ provider: ProviderUsage) -> UsageWindow? {
    let windows = provider.limits.flatMap(\.windows).filter { $0.used.isFinite }
    return windows.first { $0.minutes >= 10080 } ?? windows.first
  }
  static func remaining(_ window: UsageWindow?) -> Double? {
    guard let used = window?.used, used.isFinite else { return nil }
    return max(0, min(100, 100 - used))
  }
  static func countdown(to reset: Date, now: Date) -> String {
    let interval = reset.timeIntervalSince(now)
    guard interval > 0 else { return "等待更新" }
    let total = Int(min(ceil(interval / 60), 525_600_000))
    let days = total / 1440, hours = total % 1440 / 60, minutes = total % 60
    if days > 0 { return "\(days)天\(hours)小时" }
    if hours > 0 { return "\(hours)小时\(minutes)分" }
    return "\(minutes)分钟"
  }
}

struct AISessionOverviewData {
  let working: Int, active: Int, ended: Int, unknown: Int
  let memory: UInt64
  let cpu: Double
  var total: Int { working + active + ended + unknown }
  init(_ sessions: [AIRuntimeSession]) {
    working = sessions.filter { $0.phase == .working }.count
    active = sessions.filter { $0.phase == .activeProcess }.count
    ended = sessions.filter { $0.phase == .idle }.count
    unknown = sessions.filter { $0.phase == .unknown }.count
    // Several live conversations can share one app-server. Count its resources once.
    let processes = Dictionary(grouping: sessions, by: { $0.process.pid }).values.compactMap(\.first).map(\.process)
    memory = processes.reduce(0) { $0 + $1.memory }
    cpu = processes.reduce(0) { $0 + $1.cpu }
  }
}

struct AIQuotaOverview: View {
  let providers: [ProviderUsage]
  let sessions: [AIRuntimeSession]
  let selected: String
  var allSessionsSelected: Bool
  var compact: Bool
  let choose: (String) -> Void
  let chooseSessions: () -> Void
  var body: some View {
    Panel(padding: compact ? 8 : 12) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 4 : 10), count: 4),
                alignment: .leading, spacing: compact ? 6 : 10) {
        ForEach(providers) { provider in
          Button { choose(provider.id) } label: {
            AIQuotaOverviewItem(provider: provider, compact: compact)
          }.buttonStyle(AIOverviewButtonStyle(tint: AIQuotaPresentation.color(provider.id), selected: selected == provider.id && !allSessionsSelected))
            .accessibilityLabel("查看 " + provider.id + " 用量")
            .accessibilityAddTraits(selected == provider.id && !allSessionsSelected ? .isSelected : [])
            .help(provider.unavailable ?? "查看 " + provider.id + " 的额度、Token 与运行会话")
        }
        if !sessions.isEmpty {
          Button(action: chooseSessions) {
            AISessionOverviewItem(data: AISessionOverviewData(sessions), compact: compact)
          }.buttonStyle(AIOverviewButtonStyle(tint: .orange, selected: allSessionsSelected))
            .accessibilityLabel("查看全部 \(sessions.count) 个运行会话")
            .accessibilityAddTraits(allSessionsSelected ? .isSelected : [])
        }
      }
    }
  }
}

private struct AIQuotaOverviewItem: View {
  let provider: ProviderUsage
  var compact: Bool
  private var window: UsageWindow? { AIQuotaOverviewData.primaryWindow(provider) }
  private var remaining: Double? { AIQuotaOverviewData.remaining(window) }
  private var tint: Color { AIQuotaPresentation.color(provider.id) }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let stale = provider.stale(at: context.date)
      VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 12) {
        HStack(spacing: 5) {
          AIProviderLogo(provider: provider, size: compact ? 13 : 16)
          Text(provider.id == "Grok Bot" ? "Grok" : provider.id)
            .font(.system(size: compact ? 10 : 12, weight: .semibold)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        if compact {
          ring(stale: stale)
          resetCaption(now: context.date)
        } else {
          HStack(spacing: 12) {
            ring(stale: stale)
            VStack(alignment: .leading, spacing: 5) {
              if let window {
                Text(window.minutes >= 10080 ? "本周" : AIQuotaPresentation.windowName(window))
                  .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
              }
              resetCaption(now: context.date)
              if provider.tokenCountsAvailable {
                Text("今天 " + AIQuotaPresentation.tokens(provider.today) + " Token")
                  .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.padding(compact ? 7 : 12).frame(maxWidth: .infinity)
        .frame(height: compact ? 130 : 126, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
  }
  private func ring(stale: Bool) -> some View {
    AIOverviewRing(value: remaining.map { $0 / 100 }, tint: stale ? .secondary : tint) {
      VStack(spacing: 1) {
        Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
          .font(Theme.number(compact ? 13 : 17, .semibold)).monospacedDigit().contentTransition(.numericText())
          .lineLimit(1).minimumScaleFactor(0.65).frame(width: compact ? 36 : 48)
        if remaining != nil {
          Text(stale ? "上次剩余" : "剩余").font(.system(size: compact ? 7 : 8)).foregroundStyle(.secondary)
        }
      }
    }.frame(width: compact ? 56 : 70, height: compact ? 56 : 70)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(remaining.map { (stale ? "上次剩余 " : "剩余 ") + String(format: "%.1f%%", $0) } ?? "暂无可读取的额度")
  }
  @ViewBuilder private func resetCaption(now: Date) -> some View {
    if let reset = window?.resets {
      VStack(alignment: compact ? .center : .leading, spacing: 2) {
        Text(AIQuotaOverviewData.countdown(to: reset, now: now))
          .font(.system(size: compact ? 9 : 11, weight: .medium)).monospacedDigit()
          .foregroundStyle(reset > now && reset.timeIntervalSince(now) <= 3600 ? .orange : tint)
          .lineLimit(1).minimumScaleFactor(0.85)
        if reset > now {
          Text(window?.label == "试用额度" ? "App 标注时间" : "后重置")
            .font(.system(size: compact ? 8 : 9)).foregroundStyle(.secondary)
        }
      }.help(reset.formatted(.dateTime.month().day().hour().minute()))
    } else {
      Text(remaining != nil ? "未提供重置时间" : provider.tokenCountsAvailable ? "仅本机用量" : "暂无额度")
        .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1)
    }
  }
}

private struct AISessionOverviewItem: View {
  let data: AISessionOverviewData
  var compact: Bool
  var body: some View {
    VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 12) {
      Label("会话", systemImage: "terminal").font(.system(size: compact ? 10 : 12, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
      if compact {
        ring
        VStack(spacing: 2) {
          Text("\(data.working + data.active) 活跃 · \(data.ended) 结束").foregroundStyle(.green)
          Text(data.unknown > 0 ? "\(data.unknown) 待确认" : "\(data.ended) 已结束").foregroundStyle(.secondary)
        }.font(.system(size: 9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
      } else {
        HStack(spacing: 12) {
          ring
          VStack(alignment: .leading, spacing: 5) {
            Text("\(data.working + data.active) 活跃 · \(data.ended) 已结束").font(.system(size: 11, weight: .medium))
            if data.unknown > 0 { Text("\(data.unknown) 状态待确认").font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(Format.memory(data.memory) + " · CPU " + Format.appCPU(data.cpu)).font(.system(size: 9)).foregroundStyle(.secondary)
          }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(compact ? 7 : 12).frame(maxWidth: .infinity)
      .frame(height: compact ? 130 : 126, alignment: .top)
      .contentShape(RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .combine)
  }
  private var ring: some View {
    let values = [data.working, data.active, data.ended, data.unknown]
    let colors: [Color] = [.green, .teal, .secondary.opacity(0.55), .orange]
    return ZStack {
      Circle().stroke(Color.primary.opacity(0.09), lineWidth: compact ? 5 : 6)
      ForEach(values.indices, id: \.self) { index in
        let start = Double(values.prefix(index).reduce(0, +)) / Double(max(1, data.total))
        let end = start + Double(values[index]) / Double(max(1, data.total))
        if end > start {
          Circle().trim(from: start + 0.008, to: max(start + 0.008, end - 0.008))
            .stroke(colors[index], style: StrokeStyle(lineWidth: compact ? 5 : 6, lineCap: .butt))
            .rotationEffect(.degrees(-90))
        }
      }
      Text(String(data.total)).font(Theme.number(compact ? 18 : 23, .semibold)).monospacedDigit().contentTransition(.numericText())
        .lineLimit(1).minimumScaleFactor(0.6).frame(width: compact ? 36 : 48)
    }.padding(3).frame(width: compact ? 56 : 70, height: compact ? 56 : 70)
      .accessibilityLabel("\(data.total) 个会话，\(data.working) 工作中，\(data.active) 进程活跃，\(data.ended) 已结束，\(data.unknown) 状态待确认")
  }
}

private struct AIOverviewRing<Content: View>: View {
  let value: Double?
  let tint: Color
  @ViewBuilder let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    ZStack {
      Circle().stroke(Color.primary.opacity(0.09), lineWidth: 5)
      if let value, value > 0 {
        Circle().trim(from: 0, to: value).stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: value)
      }
      content
    }.padding(3)
  }
}

private struct AIOverviewButtonStyle: ButtonStyle {
  let tint: Color
  let selected: Bool
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(tint.opacity(configuration.isPressed ? 0.15 : hovered ? 0.09 : selected ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(selected ? 0.25 : 0), lineWidth: 1).allowsHitTesting(false))
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .onHover { hovered = $0 }
  }
}
