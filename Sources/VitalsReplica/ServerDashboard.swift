import AppKit
import SwiftUI

enum ServerPalette {
  static let memory = Theme.adaptive(light: .init(srgbRed: 0.54, green: 0.36, blue: 0.74, alpha: 1), dark: .init(srgbRed: 0.75, green: 0.61, blue: 0.94, alpha: 1))
  static let load = Theme.adaptive(light: .init(srgbRed: 0.28, green: 0.52, blue: 0.72, alpha: 1), dark: .init(srgbRed: 0.48, green: 0.76, blue: 0.94, alpha: 1))
  static let traffic = Theme.adaptive(light: .init(srgbRed: 0.20, green: 0.52, blue: 0.44, alpha: 1), dark: .init(srgbRed: 0.44, green: 0.80, blue: 0.69, alpha: 1))
  static let disk = Theme.adaptive(light: .init(srgbRed: 0.67, green: 0.45, blue: 0.15, alpha: 1), dark: .init(srgbRed: 0.93, green: 0.73, blue: 0.39, alpha: 1))
  static let track = Color.primary.opacity(0.07)
}

private enum ServerTrendMetric: String, CaseIterable {
  case memory = "内存", load = "负载"
  var color: Color { self == .memory ? ServerPalette.memory : ServerPalette.load }
  var title: String { self == .memory ? "内存趋势" : "系统负载趋势" }
  func value(_ sample: ServerResourceSample) -> Double? { self == .memory ? sample.memory : sample.load }
  func display(_ value: Double?) -> String { self == .memory ? serverBytes(value) : value.map { String(format: "%.2f", $0) } ?? "—" }
}

struct ServerWorkspace: View {
  var compact = false
  @ObservedObject private var server = ServerMonitor.shared
  @ObservedObject private var proxy = MacProxyMonitor.shared
  @ObservedObject private var diagnostics = ServerConnectionDiagnostics.shared
  @State private var showConnection = false
  @State private var detailExpanded: Bool
  @State private var metric = ServerTrendMetric.memory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  init(compact: Bool = false) { self.compact = compact; _detailExpanded = State(initialValue: !compact) }

  var body: some View {
    Group {
      if compact { content.padding(6) }
      else { ScrollView { content.padding(24).frame(maxWidth: 1220).frame(maxWidth: .infinity) } }
    }.sheet(isPresented: $showConnection) { ServerConnectionView() }
      .onAppear { proxy.show(); updateDiagnostics() }
      .onDisappear { proxy.hide() }
      .onChange(of: server.snapshot) { _, _ in updateDiagnostics() }
      .onChange(of: server.profile) { _, profile in if profile == nil { diagnostics.clear() } else { updateDiagnostics() } }
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: compact ? 14 : 18) {
      header
      if let error = server.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
      }
      if let snapshot = server.snapshot {
        resources(snapshot)
        network(snapshot)
        if compact { ServerTrendPanel(samples: server.history.samples, end: snapshot.time, metric: $metric, compact: true) }
        else {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
              ServerTrendPanel(samples: server.history.samples, end: snapshot.time, metric: $metric).frame(minWidth: 360)
              ServerDailyTrafficPanel(history: server.history, end: snapshot.time).frame(minWidth: 280)
            }
            VStack(spacing: 16) {
              ServerTrendPanel(samples: server.history.samples, end: snapshot.time, metric: $metric)
              ServerDailyTrafficPanel(history: server.history, end: snapshot.time)
            }
          }
        }
        traffic(snapshot)
        ServerIPPanel(addresses: snapshot.addresses, compact: compact)
        details(snapshot)
      } else { emptyState }
      HStack(spacing: 5) {
        Image(systemName: "lock.shield")
        Text(compact ? "只读监测" : "只读 · 服务器 1 分钟 / 代理 2 秒")
        Spacer()
        if let snapshot = server.snapshot {
          Text(server.stale ? "上次" : "同步于")
          Text(snapshot.time, style: .time).monospacedDigit()
        }
      }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
    }
  }
  private func updateDiagnostics() {
    guard server.snapshot != nil else { return }
    diagnostics.observe(addresses: server.snapshot?.addresses ?? [], fallback: server.profile?.host, port: server.snapshot?.sshPort)
  }
  private func network(_ snapshot: ServerSnapshot) -> some View {
    Group {
      if compact {
        VStack(spacing: 14) { ServerNetworkPanel(stats: snapshot.network, compact: true); MacProxyPanel(compact: true) }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            ServerNetworkPanel(stats: snapshot.network).frame(minWidth: 330, maxHeight: .infinity, alignment: .top)
            MacProxyPanel().frame(minWidth: 330, maxHeight: .infinity, alignment: .top)
          }
          VStack(spacing: 16) { ServerNetworkPanel(stats: snapshot.network); MacProxyPanel() }
        }
      }
    }
  }
  private var header: some View {
    HStack(spacing: 8) {
      if !compact {
        Image(systemName: "cloud").font(.system(size: 21, weight: .medium)).foregroundStyle(ServerPalette.traffic)
          .frame(width: 43, height: 43).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(server.profile?.name ?? "服务器").font(.system(size: compact ? 18 : 23, weight: .semibold)).lineLimit(2)
        HStack(spacing: 5) {
          Circle().fill(server.stale ? Color.secondary : server.snapshot?.state?.lowercased() == "running" ? ServerPalette.traffic : .orange).frame(width: 6, height: 6)
          Text(server.loading ? "正在同步…" : server.stateLabel)
          if let location = server.snapshot?.location { Text("· " + location).lineLimit(1) }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if let panel = server.profile?.panelURL {
        Button { NSWorkspace.shared.open(panel) } label: { Image(systemName: "arrow.up.right").frame(width: 30, height: 30).contentShape(Circle()) }
          .buttonStyle(GlassCircleButtonStyle()).help("打开 KiwiVM").accessibilityLabel("打开 KiwiVM")
      }
      Button { server.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).contentShape(Circle()) }
        .buttonStyle(GlassCircleButtonStyle()).disabled(server.loading || server.needsKey || server.profile == nil).help("刷新服务器").accessibilityLabel("刷新服务器")
      Button { showConnection = true } label: { Image(systemName: "gearshape").frame(width: 30, height: 30).contentShape(Circle()) }
        .buttonStyle(GlassCircleButtonStyle()).help("服务器连接").accessibilityLabel("服务器连接")
    }
  }
  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "cloud").font(.system(size: 42, weight: .light)).foregroundStyle(ServerPalette.traffic)
      Text("连接搬瓦工").font(.system(size: 20, weight: .semibold))
      Text("内存 · 系统负载 · 月流量").font(.system(size: 13)).foregroundStyle(.secondary)
      Button { showConnection = true } label: {
        Label("连接设置", systemImage: "key").padding(.horizontal, 22).padding(.vertical, 10).contentShape(Capsule())
      }.buttonStyle(AIControlButtonStyle(prominent: true))
    }.frame(maxWidth: .infinity).padding(.vertical, compact ? 32 : 62).background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
  }
  private func resources(_ snapshot: ServerSnapshot) -> some View {
    HStack(spacing: compact ? 7 : 12) {
      resource("内存", value: serverBytes(snapshot.memoryUsed), note: "共 " + serverBytes(snapshot.memoryTotal),
               color: ServerPalette.memory, used: snapshot.memoryUsed, total: snapshot.memoryTotal) { metric = .memory }
      resource("系统负载", value: ServerTrendMetric.load.display(snapshot.load.first), note: "1 分钟平均", color: ServerPalette.load) { metric = .load }
      resource("磁盘映像", value: serverBytes(snapshot.mappedDiskUsed), note: "共 " + serverBytes(snapshot.diskTotal),
               color: ServerPalette.disk, used: snapshot.mappedDiskUsed, total: snapshot.diskTotal) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { detailExpanded = true }
      }
    }
  }
  private func resource(_ title: String, value: String, note: String, color: Color, used: Double? = nil, total: Double? = nil, action: @escaping () -> Void) -> some View {
    let fraction: Double? = { if let used, let total, total > 0 { return used / total }; return nil }()
    return Button(action: action) {
      Group {
        if compact { VStack(spacing: 9) { resourceGraphic(title, fraction: fraction, color: color); resourceText(title, value: value, note: note) } }
        else { HStack(spacing: 13) { resourceGraphic(title, fraction: fraction, color: color); resourceText(title, value: value, note: note); Spacer(minLength: 0) } }
      }.frame(maxWidth: .infinity, minHeight: compact ? 133 : 78).padding(compact ? 10 : 17)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 17 : 22))
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }.buttonStyle(CareRowStyle()).accessibilityLabel("\(title)，\(value)，\(note)")
  }
  @ViewBuilder private func resourceGraphic(_ title: String, fraction: Double?, color: Color) -> some View {
    if title == "系统负载" { Image(systemName: "waveform.path.ecg").font(.system(size: 31, weight: .light)).foregroundStyle(color).frame(width: 60, height: 60) }
    else { ServerUsageRing(fraction: fraction, color: color).frame(width: 60, height: 60) }
  }
  private func resourceText(_ title: String, value: String, note: String) -> some View {
    VStack(alignment: compact ? .center : .leading, spacing: 5) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(value).font(Theme.number(compact ? 16 : 22)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
      Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }.frame(maxWidth: compact ? .infinity : nil, alignment: compact ? .center : .leading)
  }
  private func traffic(_ snapshot: ServerSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("本月流量", systemImage: "arrow.up.arrow.down").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text("剩余 " + serverBytes(snapshot.transferRemaining)).font(Theme.number(compact ? 15 : 17)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
      }
      ServerSegmentMeter(used: snapshot.transferUsed, total: snapshot.transferTotal)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { trafficUsed(snapshot); Spacer(minLength: 0); reset(snapshot) }
        VStack(alignment: .leading, spacing: 10) { trafficUsed(snapshot); reset(snapshot) }
      }
    }.padding(compact ? 16 : 20).background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
  }
  private func trafficUsed(_ snapshot: ServerSnapshot) -> some View {
    Text("已用 " + serverBytes(snapshot.transferUsed) + " / " + serverBytes(snapshot.transferTotal))
      .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
  }
  @ViewBuilder private func reset(_ snapshot: ServerSnapshot) -> some View {
    if let reset = snapshot.reset {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(spacing: 6) {
          Image(systemName: "clock")
          Text(reset > context.date ? Format.duration(reset.timeIntervalSince(context.date)) + "后重置" : "等待重置同步").fontWeight(.medium)
          Text(reset, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()).foregroundStyle(.secondary)
        }.font(.system(size: 11)).monospacedDigit().fixedSize()
          .padding(.horizontal, 10).padding(.vertical, 8).foregroundStyle(ServerPalette.traffic)
          .background(ServerPalette.traffic.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
      }
    }
  }
  private func details(_ snapshot: ServerSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { detailExpanded.toggle() }
      } label: {
        HStack { Text("连接详情"); Spacer(); Image(systemName: "chevron.down").rotationEffect(.degrees(detailExpanded ? 180 : 0)) }
          .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4).frame(height: 34).contentShape(Rectangle())
      }.buttonStyle(CareRowStyle()).accessibilityLabel(detailExpanded ? "收起连接详情" : "展开连接详情")
      if detailExpanded {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: compact ? 1 : 2), alignment: .leading, spacing: 14) {
          if let os = snapshot.os { detail("系统", value: os) }
          if let hostname = snapshot.hostname { detail("主机名", value: hostname) }
          if let port = snapshot.sshPort { detail("SSH 端口", value: String(port)) }
          detail("Swap", value: serverBytes(snapshot.swapUsed) + " / " + serverBytes(snapshot.swapTotal))
          if let cpu = snapshot.cpuThrottled { detail("CPU 限速", value: cpu ? "已限速" : "未限速", warning: cpu) }
          if let disk = snapshot.diskThrottled { detail("磁盘限速", value: disk ? "已限速" : "未限速", warning: disk) }
        }.padding(.horizontal, 4)
        Text("磁盘映像为已分配空间，非文件用量。系统负载非 CPU 百分比。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        if compact { ServerDailyTrafficPanel(history: server.history, end: snapshot.time, compact: true) }
      }
    }
  }
  private func detail(_ label: String, value: String, copy: Bool = false, warning: Bool = false) -> some View {
    HStack(spacing: 10) {
      Text(label).foregroundStyle(.secondary).fixedSize()
      Spacer(minLength: 4)
      Text(value).foregroundStyle(warning ? Color.orange : .primary).multilineTextAlignment(.trailing).textSelection(.enabled)
      if copy {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: {
          Image(systemName: "doc.on.doc").frame(width: 28, height: 28).contentShape(Circle())
        }.buttonStyle(GlassCircleButtonStyle()).help("复制地址").accessibilityLabel("复制服务器地址")
      }
    }.font(.system(size: 12))
  }
}

private struct ServerUsageRing: View {
  let fraction: Double?
  let color: Color
  var body: some View {
    ZStack {
      Circle().stroke(ServerPalette.track, lineWidth: 5)
      if let fraction {
        Circle().trim(from: 0, to: min(1, max(0, fraction))).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
      }
      Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
        .font(Theme.number(16)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).padding(8)
    }.padding(3).accessibilityElement(children: .ignore).accessibilityLabel(fraction.map { String(format: "已用 %.1f%%", $0 * 100) } ?? "用量未知")
  }
}

private struct ServerSegmentMeter: View {
  let used: Double?, total: Double?
  private var fraction: Double? { guard let used, let total, total > 0 else { return nil }; return min(1, max(0, used / total)) }
  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<32, id: \.self) { index in
        GeometryReader { geometry in
          let fill = min(1, max(0, (fraction ?? 0) * 32 - Double(index)))
          RoundedRectangle(cornerRadius: 3).fill(ServerPalette.track)
            .overlay(alignment: .leading) {
              if fill > 0 { Rectangle().fill((fraction ?? 0) >= 0.9 ? Color.orange : ServerPalette.traffic).frame(width: geometry.size.width * fill) }
            }.clipShape(RoundedRectangle(cornerRadius: 3))
        }
      }
    }.frame(height: 9).accessibilityElement(children: .ignore)
      .accessibilityLabel(fraction.map { String(format: "本月流量已用 %.1f%%", $0 * 100) } ?? "本月流量未知")
  }
}

private struct ServerTrendPanel: View {
  let samples: [ServerResourceSample]
  let end: Date
  @Binding var metric: ServerTrendMetric
  var compact = false
  @State private var hovered: ServerResourceSample?
  private var window: [ServerResourceSample] { samples.filter { $0.time >= end.addingTimeInterval(-1800) && $0.time <= end } }
  private var value: Double? { (hovered ?? window.last).flatMap { metric.value($0) } }
  private var ceiling: Double {
    let peak = max(window.compactMap { metric.value($0) }.max() ?? 0, 0.0001) * 1.15
    if metric == .memory { return pow(2, ceil(log2(max(256 * 1024 * 1024, peak)))) }
    let magnitude = pow(10, floor(log10(max(0.1, peak))))
    return [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= max(0.1, peak) } ?? peak
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 7 : 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(metric.title).font(.system(size: 12)).foregroundStyle(.secondary)
          ValueText(text: metric.display(value), size: compact ? 23 : 29)
          Group {
            if let hovered { Text(hovered.time, style: .time) }
            else { Text("最近 30 分钟 · 本机采样") }
          }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        HStack(spacing: 2) {
          ForEach(ServerTrendMetric.allCases, id: \.self) { item in
            Button { metric = item; hovered = nil } label: {
              Text(item.rawValue).font(.system(size: 11, weight: metric == item ? .semibold : .regular))
                .foregroundStyle(metric == item ? Color.primary : .secondary)
                .padding(.horizontal, 11).frame(height: 28)
                .background(metric == item ? Color(nsColor: .windowBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(CareRowStyle()).accessibilityLabel("查看" + item.title).accessibilityAddTraits(metric == item ? .isSelected : [])
          }
        }.padding(3).background(ServerPalette.track, in: RoundedRectangle(cornerRadius: 12))
      }
      plot.frame(height: compact ? 94 : 166)
      HStack { Text("30 分钟前"); Spacer(); Text("15 分钟前"); Spacer(); Text("最新") }
        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 48)
    }.padding(compact ? 16 : 20).frame(maxWidth: .infinity)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
      .onChange(of: metric) { _, _ in hovered = nil }
  }
  private var plot: some View {
    HStack(spacing: 6) {
      VStack(alignment: .trailing) {
        Text(axis(ceiling)); Spacer(); Text(axis(ceiling / 2)); Spacer(); Text("0")
      }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75).frame(width: 42)
      GeometryReader { geometry in
        let size = geometry.size, segments = groups(size: size)
        ZStack {
          Path { path in for y in [0.0, 0.5, 1.0] { path.move(to: .init(x: 0, y: size.height * y)); path.addLine(to: .init(x: size.width, y: size.height * y)) } }
            .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
          ForEach(Array(segments.enumerated()), id: \.offset) { _, points in
            curve(points, floor: size.height).fill(metric.color.opacity(0.10))
            curve(points).stroke(metric.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if points.count == 1, let point = points.first { Circle().fill(metric.color).frame(width: 5, height: 5).position(point) }
          }
          if let hovered, let value = metric.value(hovered) {
            let point = position(time: hovered.time, value: value, size: size)
            Path { path in path.move(to: .init(x: point.x, y: 0)); path.addLine(to: .init(x: point.x, y: size.height)) }
              .stroke(metric.color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle().fill(metric.color).frame(width: 7, height: 7).position(point)
          }
          if window.compactMap({ metric.value($0) }).count < 2 {
            Text("正在积累采样").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }.contentShape(Rectangle()).onContinuousHover { phase in
          switch phase {
          case .active(let location):
            let date = end.addingTimeInterval(-1800 + min(1, max(0, location.x / max(1, size.width))) * 1800)
            let nearest = window.filter { metric.value($0) != nil }.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
            hovered = nearest.flatMap { abs($0.time.timeIntervalSince(date)) <= 90 ? $0 : nil }
          case .ended: hovered = nil
          }
        }
      }
    }.accessibilityElement(children: .ignore).accessibilityLabel(metric.title + "，\(window.compactMap { metric.value($0) }.count) 个真实采样点，当前 " + metric.display(value))
  }
  private func axis(_ value: Double) -> String { metric == .memory ? serverBytes(value).replacingOccurrences(of: ".0 ", with: " ") : String(format: value >= 1 ? "%.1f" : "%.2f", value) }
  private func position(time: Date, value: Double, size: CGSize) -> CGPoint {
    .init(x: min(1, max(0, time.timeIntervalSince(end.addingTimeInterval(-1800)) / 1800)) * size.width, y: (1 - min(1, max(0, value / ceiling))) * size.height)
  }
  private func groups(size: CGSize) -> [[CGPoint]] {
    var result: [[CGPoint]] = [], current: [CGPoint] = [], previous: Date?
    for sample in window {
      guard let value = metric.value(sample) else { if !current.isEmpty { result.append(current) }; current = []; previous = nil; continue }
      if let previous, sample.time.timeIntervalSince(previous) > 180 { if !current.isEmpty { result.append(current) }; current = [] }
      current.append(position(time: sample.time, value: value, size: size)); previous = sample.time
    }
    if !current.isEmpty { result.append(current) }; return result
  }
  private func curve(_ points: [CGPoint], floor: CGFloat? = nil) -> Path {
    Path { path in
      guard let first = points.first else { return }; path.move(to: first)
      for index in 1..<points.count {
        let a = points[index - 1], b = points[index], dx = b.x - a.x
        path.addCurve(to: b, control1: .init(x: a.x + dx * 0.45, y: a.y), control2: .init(x: a.x + dx * 0.55, y: b.y))
      }
      if let floor, let last = points.last { path.addLine(to: .init(x: last.x, y: floor)); path.addLine(to: .init(x: first.x, y: floor)); path.closeSubpath() }
    }
  }
}

private struct ServerDailyTrafficPanel: View {
  let history: ServerHistory
  let end: Date
  var compact = false
  @State private var hovered: Date?
  @State private var selected: Date?
  private var days: [(date: Date, bytes: Double?)] { history.week(ending: end) }
  private var active: Date? { hovered ?? selected }
  private var value: Double? {
    if let active { return days.first { $0.date == active }?.bytes }
    let known = days.compactMap(\.bytes); return known.isEmpty ? nil : known.reduce(0, +)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 7 : 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(active.map { $0.formatted(.dateTime.month().day()) + "流量" } ?? "7 日流量").font(.system(size: 12)).foregroundStyle(.secondary)
          ValueText(text: serverBytes(value), size: compact ? 23 : 29)
          Text(value == nil ? "开始记录后显示增量" : "本机记录 · 每日增量").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer()
        Text("近 7 天").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6)
          .background(ServerPalette.track, in: Capsule())
      }
      HStack(alignment: .bottom, spacing: compact ? 8 : 10) {
        ForEach(days, id: \.date) { day in
          Button { selected = selected == day.date ? nil : day.date } label: {
            VStack(spacing: 9) {
              GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 8).fill(ServerPalette.track)
                  .overlay(alignment: .bottom) {
                    if let bytes = day.bytes, bytes > 0 {
                      let fraction = bytes / max(1, (days.compactMap(\.bytes).max() ?? 1) * 1.15)
                      RoundedRectangle(cornerRadius: 8).fill(ServerPalette.traffic.opacity(active == nil || active == day.date ? 0.85 : 0.28))
                        .frame(height: max(2, geometry.size.height * fraction))
                    }
                  }
                if day.bytes == nil { Text("—").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity) }
              }.frame(height: compact ? 100 : 166)
              Text(Calendar.current.isDateInToday(day.date) ? "今" : day.date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 10)).foregroundStyle(active == day.date ? ServerPalette.traffic : .secondary)
            }.contentShape(Rectangle())
          }.buttonStyle(CareRowStyle()).onHover { hovered = $0 ? day.date : nil }
            .accessibilityLabel(day.date.formatted(.dateTime.month().day()) + "，" + (day.bytes.map { serverBytes($0) } ?? "尚无记录"))
        }
      }
    }.padding(compact ? 16 : 20).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
  }
}
