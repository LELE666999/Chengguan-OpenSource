import AppKit
import Combine
import SwiftUI

/// Presentation rules shared by the window and the menu panel.
enum AIQuotaPresentation {
  static func provider(for agent: String) -> String {
    let name = agent.lowercased()
    if name.contains("claude") { return "Claude" }
    if name.contains("codex") { return "Codex" }
    if name.contains("cursor") { return "Cursor" }
    if name.contains("grok") { return "Grok Bot" }
    return agent
  }
  static func windowName(_ window: UsageWindow) -> String {
    if let label = window.label { return label }
    if window.minutes >= 10080 { return "每周额度" }
    if window.minutes >= 1440 { return "每日额度" }
    return "\(max(1, window.minutes / 60))小时会话"
  }
  static func countdown(to reset: Date, now: Date, trial: Bool = false) -> String {
    let remaining = reset.timeIntervalSince(now)
    guard remaining > 0 else { return trial ? "标注时间已到" : "等待更新" }
    let total = Int(min(ceil(remaining / 60), 525_600_000))
    let days = total / 1440, hours = total % 1440 / 60, minutes = total % 60
    if days > 0 { return "\(days)天\(hours)小时\(minutes)分" }
    if hours > 0 { return "\(hours)小时\(minutes)分" }
    return "\(minutes)分钟"
  }
  static func tokens(_ value: Int64) -> String {
    value >= 1_000_000 ? String(format: "%.2f M", Double(value) / 1_000_000)
      : value >= 1000 ? String(format: "%.1f K", Double(value) / 1000) : String(value)
  }
  static func color(_ provider: String) -> Color {
    let light: NSColor, dark: NSColor
    switch provider {
    case "Claude":
      light = NSColor(srgbRed: 0.68, green: 0.30, blue: 0.19, alpha: 1)
      dark = NSColor(srgbRed: 0.94, green: 0.58, blue: 0.45, alpha: 1)
    case "Codex":
      light = NSColor(srgbRed: 0.02, green: 0.46, blue: 0.36, alpha: 1)
      dark = NSColor(srgbRed: 0.26, green: 0.83, blue: 0.67, alpha: 1)
    case "Cursor":
      light = NSColor(srgbRed: 0.45, green: 0.32, blue: 0.72, alpha: 1)
      dark = NSColor(srgbRed: 0.73, green: 0.61, blue: 0.96, alpha: 1)
    case "Grok", "Grok Bot":
      light = NSColor(srgbRed: 0.32, green: 0.37, blue: 0.43, alpha: 1)
      dark = NSColor(srgbRed: 0.76, green: 0.80, blue: 0.85, alpha: 1)
    default: return Theme.accent
    }
    return Theme.adaptive(light: light, dark: dark)
  }
}

private struct AIQuotaRow: Identifiable {
  let id: String
  let name: String
  let window: UsageWindow
}

struct AIUsagePanel: View {
  @ObservedObject var model: MonitorModel
  var compact = false
  var open: (() -> Void)? = nil
  @ObservedObject private var usage = AIUsageStore.shared
  @ObservedObject private var subscriptions = AISubscriptionStore.shared
  @ObservedObject private var activity = AISessionActivityStore.shared
  @AppStorage("aiUsageEnabled") private var enabled = false
  @AppStorage("aiUsageSelectedProvider") private var selected = "Codex"
  @AppStorage("menuQuotaSelection") private var menuQuotaSelection = "[]"
  @State private var expandedDetails = Set<String>()
  @State private var showAllSessions = false
  @State private var showMoreSessions = false
  @State private var tokenPeriod = "近7天"
  @State private var showModels = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
  private let activityTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
  private func hasDetails(_ provider: ProviderUsage) -> Bool {
    provider.id == "Claude" || !provider.limits.isEmpty || provider.tokenCountsAvailable || subscriptions.value(for: provider) != nil
  }
  private var available: [ProviderUsage] {
    let order = ["Claude", "Codex", "Grok Bot", "Cursor"]
    return usage.providers.filter { hasDetails($0) || $0.id == selected }.sorted {
      let a = order.firstIndex(of: $0.id) ?? 100, b = order.firstIndex(of: $1.id) ?? 100
      return a == b ? $0.id < $1.id : a < b
    }
  }
  private var provider: ProviderUsage? { usage.providers.first { $0.id == selected } ?? available.first }
  private var allSessions: [AIRuntimeSession] {
    let pids = Set(model.snapshot.agents.map { $0.process.pid })
    let known = activity.codexSessions.filter { pids.contains($0.process.pid) }
    let fallback = model.snapshot.agents.filter { $0.name != "Codex" || known.isEmpty }.map { agent in
      let title = agent.directory.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
      return AIRuntimeSession(id: agent.id, provider: AIQuotaPresentation.provider(for: agent.name),
        title: title ?? agent.name, directory: agent.directory, process: agent.process,
        phase: AIRuntimePhase.process(cpu: agent.process.cpu))
    }
    return known + fallback
  }
  private var sessions: [AIRuntimeSession] {
    allSessions.filter { showAllSessions || $0.provider == provider?.id }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 12 : 16) {
      if !enabled {
        Panel {
          HStack {
            Text("自动发现 AI 软件与用量").font(.system(size: 13, weight: .medium))
            Spacer()
            Button("开启") { enabled = true; usage.refresh(force: true) }.buttonStyle(AIControlButtonStyle(compact: true))
          }
        }
      } else if usage.providers.isEmpty {
        Panel {
          HStack(spacing: 10) {
            if usage.loading { ProgressView().controlSize(.small) }
            Text(usage.loading ? "正在读取用量…" : "使用 AI 软件后，用量会自动显示。")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
      } else if let provider {
        AIQuotaOverview(providers: available, sessions: allSessions, selected: provider.id,
          allSessionsSelected: showAllSessions, compact: compact, choose: choose) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showAllSessions = true }
          }
        if compact {
          Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
              quotaContent(provider)
              Divider().opacity(0.5)
              tokenContent(provider)
              Divider().opacity(0.5)
              sessionContent(provider)
            }
          }
        } else {
          Panel(padding: 22) { quotaContent(provider) }
          AIQuotaLowerLayout {
            Panel(padding: 20) { tokenContent(provider) }
            Panel(padding: 20) { sessionContent(provider) }
          }
        }
      }
    }.onAppear { usage.refresh(); activity.refresh(agents: model.snapshot.agents) }
      .onReceive(timer) { _ in usage.refresh() }
      .onReceive(activityTimer) { _ in activity.refresh(agents: model.snapshot.agents) }
      .onChange(of: enabled) { _, value in if value { usage.refresh(force: true) } }
      .onChange(of: selected) { _, _ in showAllSessions = false; showMoreSessions = false }
  }
  private func choose(_ id: String) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
      selected = id; showAllSessions = false; showMoreSessions = false
    }
  }
  private func rows(_ provider: ProviderUsage) -> [AIQuotaRow] {
    provider.limits.flatMap { limit in
      limit.windows.enumerated().map { index, window in
        AIQuotaRow(id: MenuBarSelection.quotaID(provider: provider, limit: limit, window: window, index: index),
          name: AIQuotaPresentation.windowName(window), window: window)
      }
    }
  }
  @ViewBuilder private func quotaContent(_ provider: ProviderUsage) -> some View {
    let tint = AIQuotaPresentation.color(provider.id)
    let quotaRows = rows(provider)
    let primaryWindow = AIQuotaOverviewData.primaryWindow(provider)
    let primary = quotaRows.first { $0.window == primaryWindow }
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      HStack(spacing: 8) {
        AIProviderLogo(provider: provider, size: 22)
        Text(provider.id).font(.system(size: compact ? 14 : 16, weight: .semibold))
        if provider.running { Circle().fill(.green).frame(width: 5, height: 5).help("App 正在运行") }
        Spacer(minLength: 8)
        if let path = provider.appPath {
          Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
            Image(systemName: "arrow.up.right").frame(width: 30, height: 30)
          }.buttonStyle(AIQuotaButtonStyle(tint: tint)).help("打开 " + provider.id)
            .accessibilityLabel("打开 " + provider.id)
        }
        Button { usage.refresh(force: true, authorizeClaude: provider.id == "Claude") } label: {
          if usage.loading { ProgressView().controlSize(.mini).frame(width: 30, height: 30) }
          else { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30) }
        }.buttonStyle(AIQuotaButtonStyle(tint: tint)).disabled(usage.loading)
          .help("刷新用量").accessibilityLabel("刷新 " + provider.id + " 用量")
      }
      if let primary {
        HStack(alignment: .bottom, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
              Text(String(format: (100 - primary.window.used).rounded() == 100 - primary.window.used ? "%.0f%%" : "%.1f%%", 100 - primary.window.used))
                .font(Theme.number(compact ? 34 : 42, .bold)).monospacedDigit().contentTransition(.numericText())
              Text(provider.stale() ? "上次剩余" : "剩余").font(.system(size: 12)).foregroundStyle(.secondary)
              if compact { Text("· " + primary.name).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if !compact { Text(primary.name).font(.system(size: 11)).foregroundStyle(.secondary) }
          }
          Spacer(minLength: 0)
          if !compact, let reset = primary.window.resets {
            AIQuotaResetTime(reset: reset, tint: tint, trial: primary.window.label == "试用额度", headline: true)
          }
        }
        quotaTable(provider, rows: quotaRows, tint: tint)
      } else {
        HStack(spacing: 8) {
          Image(systemName: "info.circle").foregroundStyle(tint)
          Text(provider.unavailable ?? "暂无可读取的额度").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
      }
      if provider.id == "Codex" || subscriptions.value(for: provider) != nil {
        DisclosureGroup(isExpanded: Binding(get: { expandedDetails.contains(provider.id) }, set: {
          if $0 { expandedDetails.insert(provider.id) } else { expandedDetails.remove(provider.id) }
        })) {
          if subscriptions.value(for: provider) != nil { AISubscriptionRow(provider: provider) }
          if provider.id == "Codex" { CodexResetSection() }
        } label: {
          Text(provider.id == "Codex" ? "订阅与特别重置" : "订阅信息").font(.system(size: 11))
        }.disclosureGroupStyle(AIWholeRowDisclosureStyle(tint: tint))
      }
      HStack(alignment: .top, spacing: 8) {
        Text(provider.stale() ? "上次额度 · 打开 App 更新" : provider.source)
        Spacer(minLength: 6)
        if let updated = provider.updated {
          Text("更新于 " + updated.formatted(.dateTime.hour().minute())).monospacedDigit()
            .help(updated.formatted(.dateTime.month().day().hour().minute()))
        }
      }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }
  private func quotaTable(_ provider: ProviderUsage, rows: [AIQuotaRow], tint: Color) -> some View {
    VStack(spacing: 0) {
      quotaColumns(name: Text("额度"), remaining: Text("剩余"), reset: Text("下次重置"), pin: Color.clear.frame(width: 26, height: 1))
        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 8)
      ForEach(rows) { row in
        Divider().opacity(0.45)
        quotaColumns(name: Text(row.name).font(.system(size: compact ? 11 : 12, weight: .medium))
          .fixedSize(horizontal: false, vertical: true), remaining: quotaRemaining(row.window, tint: tint, stale: provider.stale()), reset: Group {
            if let reset = row.window.resets { AIQuotaResetTime(reset: reset, tint: tint, trial: row.window.label == "试用额度") }
            else { Text("未提供").font(.system(size: 10)).foregroundStyle(.secondary) }
          }, pin: pinButton(row, provider: provider, tint: tint)).padding(.vertical, compact ? 8 : 12)
      }
    }
  }
  private func quotaColumns<N: View, R: View, T: View, P: View>(name: N, remaining: R, reset: T, pin: P) -> some View {
    AIQuotaTableColumns(compact: compact) {
      name.frame(maxWidth: .infinity, alignment: .leading)
      remaining.frame(maxWidth: .infinity, alignment: .leading)
      reset.frame(maxWidth: .infinity, alignment: .trailing)
      pin.frame(width: 26)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func quotaRemaining(_ window: UsageWindow, tint: Color, stale: Bool) -> some View {
    let color: Color = stale ? .secondary : window.used >= 90 ? .orange : tint
    return VStack(alignment: .leading, spacing: 6) {
      Text(String(format: "%.1f%%", 100 - window.used)).font(Theme.number(compact ? 13 : 16)).monospacedDigit()
      GeometryReader { geometry in
        Capsule().fill(color.opacity(0.13))
          .overlay(alignment: .leading) { Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, (100 - window.used) / 100))) }
      }.frame(height: 4).accessibilityHidden(true)
    }
  }
  private func pinButton(_ row: AIQuotaRow, provider: ProviderUsage, tint: Color) -> some View {
    let pinned = MenuBarSelection.parse(menuQuotaSelection).contains(row.id)
    return Button { menuQuotaSelection = MenuBarSelection.toggle(row.id, in: menuQuotaSelection) } label: {
      Image(systemName: pinned ? "eye.fill" : "eye.slash").font(.system(size: 12)).frame(width: 26, height: 30)
        .foregroundStyle(pinned ? tint : Color.secondary)
    }.buttonStyle(AIQuotaButtonStyle(tint: tint))
      .help(pinned ? "从菜单栏移除" : "在菜单栏显示")
      .accessibilityLabel((pinned ? "从菜单栏移除 " : "在菜单栏显示 ") + provider.id + " " + row.name)
  }
  private func tokenContent(_ provider: ProviderUsage) -> some View {
    VStack(alignment: .leading, spacing: compact ? 12 : 20) {
      HStack {
        Text("Token").font(.system(size: 12, weight: .semibold))
        Spacer()
        if provider.tokenCountsAvailable {
          SettingsGlassSegments(selection: $tokenPeriod, options: ["近7天", "本月"], compact: true,
            tint: AIQuotaPresentation.color(provider.id))
            .frame(width: compact ? 118 : 142)
        }
      }
      if provider.tokenCountsAvailable {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 20) {
            tokenStat("今天", value: provider.today)
            tokenStat(tokenPeriod == "本月" ? "本月" : "近 7 天", value: tokenPeriod == "本月" ? provider.month : provider.last7Days)
            if !compact { tokenStat("今日缓存", value: provider.cached) }
            Spacer(minLength: 0)
          }
          VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
              tokenStat("今天", value: provider.today)
              tokenStat(tokenPeriod == "本月" ? "本月" : "近 7 天", value: tokenPeriod == "本月" ? provider.month : provider.last7Days)
            }
            if !compact { tokenStat("今日缓存", value: provider.cached) }
          }
        }
        if !provider.daily.isEmpty {
          AITokenBars(days: tokenPeriod == "本月" ? provider.monthlyDaily : provider.daily, tint: AIQuotaPresentation.color(provider.id), compact: compact)
        }
        if !provider.models.isEmpty {
          Button { withAnimation(.easeInOut(duration: 0.18)) { showModels.toggle() } } label: {
            HStack {
              Text("本月模型"); Spacer(); Text("\(provider.models.count)")
              Image(systemName: showModels ? "chevron.up" : "chevron.down")
            }.font(.system(size: 11, weight: .medium)).padding(.vertical, 8)
              .padding(.horizontal, 10).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 10))
          }.buttonStyle(AIControlButtonStyle(compact: true, tint: AIQuotaPresentation.color(provider.id)))
          if showModels {
            ForEach(provider.models) { row in
              HStack(spacing: 12) {
                Text(row.id).lineLimit(1).help(row.id)
                Spacer(minLength: 4)
                Text(AIQuotaPresentation.tokens(row.total)).monospacedDigit().fixedSize()
              }.font(.system(size: 11)).padding(.vertical, 4)
            }
          }
        }
      } else {
        Text("服务商未提供 Token 明细").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func tokenStat(_ name: String, value: Int64) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(AIQuotaPresentation.tokens(value)).font(Theme.number(compact ? 18 : 23)).monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
  }
  private func sessionContent(_ provider: ProviderUsage) -> some View {
    let shown = compact && !showMoreSessions ? Array(sessions.prefix(4)) : sessions
    return VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      HStack {
        Text("运行会话").font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 8)
        Text("\(sessions.count) 个" + (sessions.contains { $0.phase == .working } ? " · \(sessions.filter { $0.phase == .working }.count) 工作中" : ""))
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if sessions.isEmpty {
        Text("暂无" + (showAllSessions ? "" : " " + provider.id + " ") + "运行会话")
          .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
      } else {
        VStack(spacing: 0) {
          HStack {
            Text("会话").frame(maxWidth: .infinity, alignment: .leading)
            Text("状态").frame(width: compact ? 72 : 84, alignment: .leading)
            if !compact { Text("CPU").frame(width: 54, alignment: .trailing) }
            Text("内存").frame(width: compact ? 67 : 80, alignment: .trailing)
          }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 7)
          ForEach(shown) { agent in
            Divider().opacity(0.45)
            sessionRow(agent)
          }
        }
      }
      HStack {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showAllSessions.toggle() } } label: {
          Text(showAllSessions ? "只看 " + provider.id : "全部会话 · \(allSessions.count)")
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
        }.buttonStyle(AIQuotaButtonStyle(tint: AIQuotaPresentation.color(provider.id)))
          .accessibilityValue(showAllSessions ? "全部会话" : "当前 AI")
        Spacer()
        if compact && sessions.count > 4 {
          Button { withAnimation { showMoreSessions.toggle() } } label: {
            Text(showMoreSessions ? "收起" : "再看 \(sessions.count - 4) 个")
              .font(.system(size: 10)).padding(.horizontal, 8).frame(height: 30)
          }.buttonStyle(AIQuotaButtonStyle(tint: .secondary))
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func sessionRow(_ agent: AIRuntimeSession) -> some View {
    let group = model.snapshot.groups.first { $0.processes.contains { $0.pid == agent.process.pid } }
    return Button {
      if let group { model.select(.cpu); model.selection = group.id; open?() }
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text(agent.title).font(.system(size: compact ? 12 : 13, weight: .medium)).lineLimit(1)
          Text(agent.provider + (group.map { " · " + $0.name } ?? ""))
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 4) {
          Circle().fill(agent.phase == .working || agent.phase == .activeProcess ? Color.green : agent.phase == .unknown ? Color.orange : Color.secondary).frame(width: 5, height: 5)
          Text(agent.phase.title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(width: compact ? 72 : 84, alignment: .leading).help(agent.phase.explanation)
        if !compact {
          Text(agent.sharedResources ? "—" : Format.appCPU(agent.process.cpu)).font(Theme.number(11)).frame(width: 54, alignment: .trailing)
        }
        Text(agent.sharedResources ? "共享" : Format.memory(agent.process.memory)).font(Theme.number(compact ? 12 : 13)).monospacedDigit()
          .help(agent.sharedResources ? "多个会话共用同一后台进程，合计 " + Format.memory(agent.process.memory) + "，无法分摊到单个会话。" : "进程内存")
          .frame(width: compact ? 67 : 80, alignment: .trailing)
      }.padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48).contentShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(AIQuotaButtonStyle(tint: .primary, quiet: true)).disabled(group == nil)
      .help(agent.phase.explanation + " 查看进程 · " + (agent.directory ?? agent.provider))
  }
}

struct AIProviderLogo: View {
  let provider: ProviderUsage
  var size: CGFloat = 20
  private var asset: String? {
    switch provider.id {
    case "Codex": "provider-codex"
    case "Claude": "provider-claude"
    case "Cursor": "provider-cursor"
    case "Grok", "Grok Bot": "provider-grok"
    default: nil
    }
  }
  var body: some View {
    Group {
      if let asset {
        Image(nsImage: VisualResources.image(asset)).resizable().renderingMode(.template).scaledToFit()
          .foregroundStyle(AIQuotaPresentation.color(provider.id))
      } else if let path = provider.appPath {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
      } else { Image(systemName: "sparkles").resizable().scaledToFit() }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

private struct AIQuotaResetTime: View {
  let reset: Date
  let tint: Color
  var trial = false
  var headline = false
  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let pending = reset <= context.date
      let color = reset.timeIntervalSince(context.date) <= 3600 ? Color.orange : tint
      VStack(alignment: .trailing, spacing: 4) {
        Text(AIQuotaPresentation.countdown(to: reset, now: context.date, trial: trial) + (headline && !pending ? "后重置" : ""))
          .font(.system(size: headline ? 13 : 11, weight: .semibold)).foregroundStyle(color)
        Text(reset.formatted(.dateTime.month().day().hour().minute()))
          .font(.system(size: 10)).foregroundStyle(.secondary)
        if trial { Text("App 标注时间").font(.system(size: 9)).foregroundStyle(.secondary) }
      }.monospacedDigit().fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, headline ? 12 : 7).padding(.vertical, headline ? 9 : 6)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: headline ? 10 : 8))
        .help(trial ? "App 标注时间，并非已确认的订阅到期时间" : "本地时区 · 倒计时自动更新，额度以服务商为准")
        .accessibilityElement(children: .combine)
    }
  }
}

private struct AITokenBars: View {
  let days: [UsageDay]
  let tint: Color
  var compact: Bool
  var body: some View {
    let peak = max(1, days.map(\.tokens).max() ?? 1)
    let dense = days.count > 10
    HStack(alignment: .bottom, spacing: dense ? (compact ? 3 : 5) : compact ? 12 : 18) {
      ForEach(days) { day in
        VStack(spacing: 7) {
          GeometryReader { geometry in
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              RoundedRectangle(cornerRadius: 4).fill(tint.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.55))
                .frame(height: day.tokens == 0 ? 1 : max(3, geometry.size.height * Double(day.tokens) / Double(peak)))
            }
          }.frame(height: compact ? 24 : 82)
          Text(Calendar.current.isDateInToday(day.date) ? "今" : dense
            ? (Calendar.current.component(.day, from: day.date) % 7 == 1 ? day.date.formatted(.dateTime.day()) : "")
            : day.date.formatted(.dateTime.weekday(.narrow)))
            .font(.system(size: dense ? 8 : 10)).foregroundStyle(.secondary).frame(height: 12)
        }.frame(maxWidth: .infinity)
          .help(day.date.formatted(.dateTime.month().day()) + " · " + AIQuotaPresentation.tokens(day.tokens) + " Token")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(day.date.formatted(.dateTime.month().day()) + "，" + String(day.tokens) + " Token")
      }
    }
  }
}

private struct AIQuotaButtonStyle: ButtonStyle {
  var tint: Color
  var capsule = false
  var quiet = false
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.primary)
      .background(tint.opacity(configuration.isPressed ? 0.15 : hovered ? 0.09 : quiet || capsule ? 0 : 0.055),
        in: RoundedRectangle(cornerRadius: capsule ? 30 : 9))
      .contentShape(RoundedRectangle(cornerRadius: capsule ? 30 : 9))
      .opacity(enabled ? 1 : 0.45)
      .onHover { hovered = $0 }
  }
}

/// Two aligned support columns on wide windows; one readable column on narrow ones.
private struct AIQuotaLowerLayout: Layout {
  let gap: CGFloat = 14
  private func sizes(width: CGFloat, views: Subviews) -> [CGSize] {
    views.enumerated().map { index, view in
      let proposed = width < 720 ? width : (width - gap) * (index == 0 ? 0.42 : 0.58)
      return view.sizeThatFits(ProposedViewSize(width: proposed, height: nil))
    }
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 900, measured = sizes(width: width, views: subviews)
    let height = width < 720 ? measured.reduce(0) { $0 + $1.height } + gap : measured.map(\.height).max() ?? 0
    return CGSize(width: width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let measured = sizes(width: bounds.width, views: subviews)
    var x = bounds.minX, y = bounds.minY
    for (index, view) in subviews.enumerated() {
      let width = bounds.width < 720 ? bounds.width : (bounds.width - gap) * (index == 0 ? 0.42 : 0.58)
      view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: measured[index].height))
      if bounds.width < 720 { y += measured[index].height + gap } else { x += width + gap }
    }
  }
}

/// Proportional columns avoid sending the remaining value to the far edge of a wide window.
private struct AIQuotaTableColumns: Layout {
  var compact: Bool
  private var gap: CGFloat { compact ? 10 : 24 }
  private func widths(_ width: CGFloat) -> [CGFloat] {
    if compact { return [max(0, width - 64 - 134 - 26 - gap * 3), 64, 134, 26] }
    let available = max(0, width - 26 - gap * 3)
    return [available * 0.31, available * 0.24, available * 0.45, 26]
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? (compact ? 380 : 900), columns = widths(width)
    let height = subviews.enumerated().map { index, view in
      view.sizeThatFits(ProposedViewSize(width: columns[index], height: nil)).height
    }.max() ?? 0
    return CGSize(width: width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let columns = widths(bounds.width)
    var x = bounds.minX
    for (index, view) in subviews.enumerated() {
      view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: columns[index], height: bounds.height))
      x += columns[index] + gap
    }
  }
}
