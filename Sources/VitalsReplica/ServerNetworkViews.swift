import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum NetworkLatencyAppearance {
  case unknown, fast, normal, slow, high, failed
  init(_ milliseconds: Double?, failed: Bool = false) {
    if failed { self = .failed }
    else if let milliseconds, milliseconds.isFinite, milliseconds >= 0 {
      switch milliseconds {
      case ..<300: self = .fast
      case ..<800: self = .normal
      case ..<1500: self = .slow
      default: self = .high
      }
    } else { self = .unknown }
  }
  var color: Color {
    switch self {
    case .unknown: return .secondary
    case .fast: return Theme.adaptive(light: .init(srgbRed: 0.12, green: 0.45, blue: 0.32, alpha: 1), dark: .init(srgbRed: 0.44, green: 0.80, blue: 0.69, alpha: 1))
    case .normal: return Theme.adaptive(light: .init(srgbRed: 0.56, green: 0.40, blue: 0.04, alpha: 1), dark: .init(srgbRed: 0.94, green: 0.77, blue: 0.33, alpha: 1))
    case .slow: return Theme.adaptive(light: .init(srgbRed: 0.68, green: 0.30, blue: 0.05, alpha: 1), dark: .init(srgbRed: 1, green: 0.64, blue: 0.34, alpha: 1))
    case .high, .failed: return Theme.adaptive(light: .init(srgbRed: 0.74, green: 0.19, blue: 0.18, alpha: 1), dark: .init(srgbRed: 1, green: 0.45, blue: 0.44, alpha: 1))
    }
  }
  var label: String {
    switch self {
    case .unknown: return "未测试"
    case .fast: return "快速"
    case .normal: return "一般"
    case .slow: return "偏慢"
    case .high: return "高延迟"
    case .failed: return "连接失败"
    }
  }
  static let guide = "小于 300 ms 为绿色；300–799 ms 为黄色；800–1499 ms 为橙色；1500 ms 及以上为红色。"
}

struct NetworkMetricView: View {
  let title: String, value: String
  var note: String? = nil
  var color: Color = .primary
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      Text(value).font(Theme.number(compact ? 20 : 24)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
      if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ServerNetworkPanel: View {
  let stats: ServerNetworkStats?
  var compact = false
  @ObservedObject private var diagnostics = ServerConnectionDiagnostics.shared
  private var outdated: Bool { stats?.latest.map { Date().timeIntervalSince($0.time) > 1200 } ?? true }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 14 : 19) {
      HStack {
        Label("服务器网络", systemImage: "cloud").font(.system(size: 12, weight: .medium))
          .help("服务器整机的区间平均速度，非带宽上限；近 24h 为接口采样覆盖的数据，不等于计费流量。")
        Spacer(minLength: 6)
        if let seconds = stats?.interval {
          Text(seconds >= 60 ? "\(Int(seconds / 60)) 分钟均速" : "\(Int(seconds)) 秒均速").font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.frame(height: 26)
      HStack(spacing: 20) {
        NetworkMetricView(title: "↓ 入站", value: Format.rate(outdated ? nil : stats?.download), note: "近 24h " + serverBytes(stats?.dayIncoming), color: ServerPalette.load, compact: compact)
        NetworkMetricView(title: "↑ 出站", value: Format.rate(outdated ? nil : stats?.upload), note: "近 24h " + serverBytes(stats?.dayOutgoing), color: ServerPalette.disk, compact: compact)
      }
      HStack(spacing: 5) {
        Circle().fill(outdated ? Color.secondary : ServerPalette.traffic).frame(width: 5, height: 5)
        if let latest = stats?.latest {
          Text(outdated ? "上次采样" : "采样于")
          Text(latest.time, style: .time).monospacedDigit()
        } else { Text("KiwiVM 暂未返回分向统计") }
        Spacer(minLength: 4)
        Button { diagnostics.probe() } label: {
          HStack(spacing: 5) {
            Image(systemName: "waveform.path")
            Text(diagnostics.probing ? "测试中" : diagnostics.latency.map { String(format: "%.0f ms", $0) } ?? (diagnostics.probeFailed ? "未响应" : "测延迟"))
              .monospacedDigit()
          }.padding(.horizontal, 9).frame(height: 29).contentShape(Capsule())
        }.buttonStyle(AIControlButtonStyle(tint: NetworkLatencyAppearance(diagnostics.latency, failed: diagnostics.probeFailed).color)).disabled(diagnostics.probing || diagnostics.ip == nil)
          .help("Mac 到服务器 TCP \(diagnostics.port) 端口的连接耗时；端口拒绝或超时不代表服务器离线。")
          .accessibilityLabel("测试服务器连接延迟")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
    }.padding(compact ? 16 : 20).frame(maxWidth: .infinity, minHeight: compact ? nil : 173, alignment: .topLeading)
      .frame(maxHeight: compact ? nil : .infinity, alignment: .topLeading)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
  }
}

struct MacProxyPanel: View {
  var compact = false
  @ObservedObject private var proxy = MacProxyMonitor.shared
  @ObservedObject private var diagnostics = ServerConnectionDiagnostics.shared
  @State private var showTests = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 14 : 19) {
      HStack(spacing: 6) {
        Label("Mac 代理", systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .medium))
          .help("每 2 秒读取本机代理内核；包含经过该内核的直连和代理流量，累计值自内核计数器启动或重置起算。不是整台 VPS 的用量。")
        Spacer(minLength: 4)
        Circle().fill(proxy.stale ? Color.secondary : ServerPalette.traffic).frame(width: 5, height: 5)
        Text(proxy.stale ? "待连接" : proxy.source ?? "Mihomo").font(.system(size: 10)).foregroundStyle(.secondary)
        Button { chooseConfiguration() } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Circle()) }
          .buttonStyle(GlassCircleButtonStyle()).help("选择本机 Clash / Mihomo 配置").accessibilityLabel("选择本机代理配置")
      }
      if proxy.snapshot != nil {
        HStack(spacing: 20) {
          NetworkMetricView(title: "↓ 下载", value: Format.rate(proxy.stale ? nil : proxy.download), note: "累计 " + serverBytes(proxy.snapshot?.downloadTotal), color: ServerPalette.load, compact: compact)
          NetworkMetricView(title: "↑ 上传", value: Format.rate(proxy.stale ? nil : proxy.upload), note: "累计 " + serverBytes(proxy.snapshot?.uploadTotal), color: ServerPalette.disk, compact: compact)
        }
        HStack(spacing: 10) {
          Label(proxy.stale ? "待更新" : "\(proxy.snapshot?.connections ?? 0) 个连接", systemImage: "link")
          if let memory = proxy.snapshot?.memory { Text("内核 " + serverBytes(memory)) }
          Spacer(minLength: 0)
          Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showTests.toggle() }
          } label: {
            HStack(spacing: 4) { Text("连通测试"); Image(systemName: "chevron.down").rotationEffect(.degrees(showTests ? 180 : 0)) }
              .padding(.horizontal, 9).frame(height: 29).contentShape(Capsule())
          }.buttonStyle(AIControlButtonStyle()).disabled(proxy.stale || proxy.mixedPort == nil)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
        if let error = proxy.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      } else {
        HStack(alignment: .center, spacing: 12) {
          Text(proxy.loading ? "正在连接本机代理…" : "打开 Clash / Mihomo 后自动识别")
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button { proxy.refresh() } label: { Text("重试").padding(8).contentShape(Capsule()) }.buttonStyle(AIControlButtonStyle()).disabled(proxy.loading)
        }.frame(minHeight: 77)
      }
      if showTests {
        Divider().opacity(0.5)
        HStack {
          Text("经本机代理端口 · 当前规则").font(.system(size: 10)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button {
            if let port = proxy.mixedPort { diagnostics.testSites(proxyPort: port) }
          } label: { Text(diagnostics.testingSites ? "测试中…" : "测试全部").font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Capsule()) }
            .buttonStyle(AIControlButtonStyle()).disabled(diagnostics.testingSites || proxy.stale || proxy.mixedPort == nil)
        }
        HStack(spacing: 6) {
          ForEach(diagnostics.sites) { site in
            let appearance = NetworkLatencyAppearance(site.milliseconds, failed: site.failure != nil)
            let value = site.milliseconds.map { String(format: "%.0f ms", $0) } ?? site.failure ?? "—"
            VStack(spacing: 6) {
              Text(site.name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
              HStack(spacing: 4) {
                Circle().fill(appearance.color).frame(width: 4, height: 4).accessibilityHidden(true)
                Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(appearance.color).lineLimit(1).minimumScaleFactor(0.8)
              }
            }.frame(maxWidth: .infinity).padding(.vertical, 11)
              .background(appearance.color.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
              .help(appearance.label + " · 经当前代理规则的网站响应耗时。" + NetworkLatencyAppearance.guide)
              .accessibilityElement(children: .ignore).accessibilityLabel(site.name + "，" + value + "，" + appearance.label)
          }
        }
        HStack {
          if let version = proxy.version { Text("Mihomo " + version) }
          Spacer()
          if let time = diagnostics.sitesTime { Text(time, style: .time).monospacedDigit() }
          if let mode = proxy.mode { Text(mode) }
          if let port = proxy.mixedPort { Text("· :" + String(port)) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }.padding(compact ? 16 : 20).frame(maxWidth: .infinity, minHeight: compact ? nil : 173, alignment: .topLeading)
      .frame(maxHeight: compact ? nil : .infinity, alignment: .topLeading)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
      .onChange(of: proxy.mixedPort) { _, _ in diagnostics.resetSites() }
  }
  private func chooseConfiguration() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.yaml]; panel.message = "选择正在使用的 Clash / Mihomo 配置；只在本机读取，不会修改配置。"
    if panel.runModal() == .OK, let url = panel.url { proxy.selectConfiguration(url) }
  }
}

struct ServerIPPanel: View {
  var addresses: [String]
  var compact = false
  @ObservedObject private var diagnostics = ServerConnectionDiagnostics.shared
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 6) {
        Label("服务器 IP", systemImage: "network").font(.system(size: 12, weight: .medium))
        if let family = diagnostics.info?.family { Text(family).font(.system(size: 10)).foregroundStyle(.secondary) }
        Spacer(minLength: 4)
        Button { diagnostics.lookup() } label: { Image(systemName: "arrow.clockwise").frame(width: 27, height: 27).contentShape(Circle()) }
          .buttonStyle(GlassCircleButtonStyle()).disabled(diagnostics.lookingUp || diagnostics.ip == nil).help("更新 IP 归属").accessibilityLabel("更新服务器 IP 归属")
      }
      HStack(spacing: 8) {
        Text(diagnostics.ip ?? addresses.first ?? "—").font(Theme.number(compact ? 16 : 19)).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
        Button { copy(diagnostics.ip ?? addresses.first) } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 28).contentShape(Circle()) }
          .buttonStyle(GlassCircleButtonStyle()).help("复制 IP").accessibilityLabel("复制服务器公网地址").disabled(diagnostics.ip == nil && addresses.isEmpty)
        Spacer(minLength: 0)
        if let asn = diagnostics.info?.asn { Text(asn).font(.system(size: 11, weight: .medium)).foregroundStyle(ServerPalette.traffic).padding(.horizontal, 9).padding(.vertical, 6).background(ServerPalette.traffic.opacity(0.08), in: Capsule()) }
      }
      if let info = diagnostics.info {
        if !info.location.isEmpty { Text(info.location).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      } else {
        Text(diagnostics.lookingUp ? "正在查询归属…" : diagnostics.infoError ?? (diagnostics.ip == nil ? "暂无可查询的公网 IP" : "等待归属信息"))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
      } label: {
        HStack {
          Text(diagnostics.info?.isp ?? "网络详情").lineLimit(1)
          Spacer(minLength: 5)
          Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 34).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11)).contentShape(RoundedRectangle(cornerRadius: 11))
      }.buttonStyle(CareRowStyle()).accessibilityLabel(expanded ? "收起 IP 详情" : "展开 IP 详情")
      if expanded {
        if let info = diagnostics.info {
          row("组织", info.organization)
          row("时区", info.timezone)
        }
        ForEach(Array(Set(addresses)).sorted(), id: \.self) { address in row(address.contains(":") ? "IPv6" : "IPv4", address) }
        row("连接探测", "TCP :\(diagnostics.port)")
        Text("归属：ipwho.is · 位置为 IP 数据库估计值")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(compact ? 16 : 20).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
  }
  private func row(_ label: String, _ value: String?) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(label).foregroundStyle(.secondary).fixedSize(); Spacer(minLength: 0)
      Text(value ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }.font(.system(size: 11))
  }
  private func copy(_ value: String?) { if let value { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } }
}
