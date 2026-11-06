import SwiftUI
import AppKit

/// A real window keeps a test accessible after the menu or volume details popover closes.
@MainActor enum StorageSpeedWindow {
  private static var window: NSWindow?
  static func show(volume: ExternalVolume? = nil, port: CablePort? = nil) {
    if StorageSpeedStore.shared.running, let window {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    if window == nil {
      let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 680),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      value.title = "存储测速"; value.isReleasedWhenClosed = false
      value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
      value.backgroundColor = .windowBackgroundColor
      value.minSize = NSSize(width: 790, height: 690); value.center(); window = value
    }
    let previousSize = window?.contentLayoutRect.size ?? NSSize(width: 850, height: 680)
    window?.contentViewController = NSHostingController(rootView: StorageSpeedView(preferredID: volume?.id, port: port))
    // Apply this after hosting: its intrinsic sizing must not shrink the workspace below two readable columns.
    window?.contentMinSize = NSSize(width: 790, height: 668)
    window?.setContentSize(NSSize(width: max(790, previousSize.width), height: max(668, previousSize.height)))
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
}

struct StorageSpeedButton: View {
  var volume: ExternalVolume? = nil
  var port: CablePort? = nil
  @ObservedObject private var speed = StorageSpeedStore.shared
  @ObservedObject private var formatting = StorageFormatStore.shared
  var body: some View {
    Button { StorageSpeedWindow.show(volume: volume, port: port) } label: {
      Label(speed.running ? "测速中" : "测速", systemImage: "speedometer")
        .padding(.horizontal, 12).frame(height: 32).contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(StorageActionButtonStyle()).font(.system(size: 12, weight: .medium)).disabled(formatting.running)
      .accessibilityLabel("存储测速" + (volume.map { " " + $0.name } ?? ""))
  }
}

struct CableSpeedSection: View {
  let port: CablePort
  var compact = false
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Label("实测", systemImage: "speedometer").font(.system(size: compact ? 12 : 14, weight: .semibold))
        Text("选择此接口连接的硬盘或读卡器").font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      StorageSpeedButton(port: port).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }.padding(compact ? 12 : 18).background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 20))
  }
}

/// A compact workspace: target and workload, two readings, then separate result summaries.
struct StorageSpeedView: View {
  var preferredID: String? = nil
  var port: CablePort? = nil
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @ObservedObject private var speed = StorageSpeedStore.shared
  @ObservedObject private var formatting = StorageFormatStore.shared
  @AppStorage("appearance") private var appearance = "auto"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection = ""
  @State private var size: StorageSpeedSize = .standard
  @State private var showTargets = false
  @State private var showHistory = false
  @State private var showDetails = false
  @State private var copied = false
  @State private var rawLaunchError = false
  private var targets: [StorageSpeedTarget] {
    (port == nil ? [StorageSpeedTarget.internalDisk] : []) + storage.volumes.map { StorageSpeedTarget(volume: $0) }
  }
  private var target: StorageSpeedTarget? { speed.active ?? targets.first { $0.id == selection } ?? targets.first }
  private var result: StorageSpeedResult? { target.flatMap { speed.result(for: $0.id) } }
  private var write: StorageSpeedReading? { speed.running ? speed.progress?.completedWrite : result?.write }
  private var read: StorageSpeedReading? { speed.running ? nil : result?.read }
  private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
  private func live(_ writing: Bool) -> Bool {
    speed.running && (writing ? speed.progress?.phase == .writing || speed.progress?.phase == .syncing : speed.progress?.phase == .reading)
  }
  var body: some View {
    content.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
      .onAppear { selection = speed.active?.id ?? preferredID ?? targets.first?.id ?? ""; storage.refresh() }
      .onChange(of: selection) { _, _ in copied = false }
      .onChange(of: targets.map(\.id)) { _, ids in if !speed.running && !ids.contains(selection) { selection = ids.first ?? "" } }
  }
  var content: some View {
    VStack(alignment: .leading, spacing: 17) {
      header
      HStack(spacing: 14) {
        targetSelector
        workload.frame(width: 286)
      }
      HStack(spacing: 14) {
        speedCard("写入", writing: true, color: .orange)
        speedCard("读取", writing: false, color: Theme.accent)
      }
      controls
      GeometryReader { space in
        HStack(spacing: 14) {
          StorageTransferEstimate(write: write, read: read).frame(width: (space.size.width - 14) / 2)
          completion.frame(width: (space.size.width - 14) / 2)
        }
      }.frame(height: 124)
      HStack {
        Text("顺序读写 · 当前存储连接").foregroundStyle(.secondary)
        Spacer()
        Button { showDetails.toggle() } label: {
          Label("测试说明", systemImage: "info.circle").padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(CareRowStyle()).foregroundStyle(.secondary).popover(isPresented: $showDetails, arrowEdge: .leading) { details }
      }.font(.system(size: 11))
      Spacer(minLength: 0)
    }.padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 12)
      .frame(minWidth: 790, maxWidth: .infinity, minHeight: 668, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .alert("暂时无法打开 RAW 测试", isPresented: $rawLaunchError) { Button("好", role: .cancel) {} }
  }
  private var header: some View {
    HStack {
      Text("存储测速").font(.system(size: 23, weight: .semibold))
      Spacer()
      Button { showHistory.toggle() } label: {
        Label("最近测试", systemImage: "clock").font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 13).frame(height: 34).contentShape(RoundedRectangle(cornerRadius: 11))
      }.buttonStyle(CareRowStyle()).foregroundStyle(.secondary)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
        .popover(isPresented: $showHistory, arrowEdge: .leading) { history }
    }.frame(height: 38)
  }
  private var targetSelector: some View {
    Button { showTargets.toggle() } label: {
      HStack(spacing: 12) {
        Image(systemName: target?.external?.symbol ?? "internaldrive.fill").font(.system(size: 21))
          .foregroundStyle(Theme.accent).frame(width: 42, height: 42)
          .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 5) {
          Text(target?.name ?? "选择存储").font(.system(size: 14, weight: .semibold)).lineLimit(1)
          Text(target.map { [$0.format, $0.transport].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "连接硬盘或读卡器")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 3)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
      }.padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 78).contentShape(RoundedRectangle(cornerRadius: 18))
    }.buttonStyle(CareRowStyle()).foregroundStyle(.primary)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).disabled(speed.running)
      .accessibilityLabel("选择测速存储").popover(isPresented: $showTargets) { targetList }
  }
  private var workload: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("测试数据").font(.system(size: 11)).foregroundStyle(.secondary)
      HStack(spacing: 5) {
        ForEach(StorageSpeedSize.allCases) { item in
          Button { withAnimation(motion) { size = item } } label: {
            Text(item.title).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 29)
              .contentShape(RoundedRectangle(cornerRadius: 9))
          }.buttonStyle(CareRowStyle()).foregroundStyle(size == item ? Theme.selectionForeground : .primary)
            .background(size == item ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel("测试数据量 " + item.title).accessibilityAddTraits(size == item ? .isSelected : [])
        }
      }.disabled(speed.running)
    }.padding(.horizontal, 15).frame(height: 78).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
  }
  private func speedCard(_ title: String, writing: Bool, color: Color) -> some View {
    let measuring = live(writing)
    let reading = writing ? write : read
    let value = measuring ? speed.progress?.megabytesPerSecond : reading?.average
    let samples = measuring ? speed.progress?.samples ?? [] : reading?.samples ?? []
    let peak = measuring ? samples.max() : reading?.peak
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label(title, systemImage: writing ? "arrow.down.to.line" : "arrow.up.to.line").font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        Spacer()
        Text(measuring ? "实时" : "平均").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
          .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.07), in: Capsule())
      }
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(value.map(StorageSpeedResult.rate) ?? "—").font(Theme.number(44)).monospacedDigit()
          .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6).animation(motion, value: value)
        Text("MB/s").font(.system(size: 12)).foregroundStyle(.secondary)
      }.padding(.top, 14)
      Group {
        if samples.count > 1 { HistoryGraph(values: samples, color: color) }
        else {
          HStack(spacing: 6) {
            Circle().fill(color.opacity(reading == nil ? 0.25 : 0.75)).frame(width: 5, height: 5)
            Text(measuring ? "正在采样" : reading != nil ? "短时测量" : "等待测试")
              .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
          }
        }
      }.frame(height: 34).padding(.top, 11).accessibilityHidden(true)
      HStack(spacing: 10) {
        metric("采样峰值", peak.map { StorageSpeedResult.rate($0) + " MB/s" } ?? "—")
        Spacer()
        metric("用时", reading.map { duration($0.seconds) } ?? "—", trailing: true)
      }.padding(.top, 13)
    }.padding(20).frame(maxWidth: .infinity).frame(height: 230)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
  }
  private func metric(_ label: String, _ value: String, trailing: Bool = false) -> some View {
    VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
      Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(value).font(Theme.number(12, .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
  }
  private var controls: some View {
    HStack(spacing: 10) {
      Button {
        if speed.running { speed.cancel() }
        else if let target { speed.start(target, size: size) }
      } label: {
        Label(speed.cancelling ? "正在停止" : speed.running ? "停止测试" : result == nil ? "开始测速" : "重新测速", systemImage: speed.running ? "stop.fill" : "play.fill")
          .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 21).frame(height: 42)
          .contentShape(RoundedRectangle(cornerRadius: 13))
      }.buttonStyle(CareRowStyle()).foregroundStyle(Theme.selectionForeground)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13))
        .disabled(formatting.running || speed.cancelling || (!speed.running && (target == nil || target?.external?.readOnly == true)))
      Button {
        if let result { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string); copied = true }
      } label: {
        Label(copied ? "已复制" : "复制结果", systemImage: "doc.on.doc").font(.system(size: 12))
          .padding(.horizontal, 14).frame(height: 42).contentShape(RoundedRectangle(cornerRadius: 13))
      }.buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13)).disabled(result == nil || speed.running)
      Spacer(minLength: 14)
      if speed.running {
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text(speed.cancelling ? "正在结束当前 I/O" : speed.progress?.phase.title ?? "准备中")
            Spacer()
            Text("\(Int((speed.progress?.fraction ?? 0) * 100))%").monospacedDigit()
          }.font(.system(size: 10)).foregroundStyle(.secondary)
          ProgressView(value: speed.progress?.fraction ?? 0).tint(Theme.accent).animation(motion, value: speed.progress?.fraction)
        }.frame(width: 225)
      } else {
        Label("临时数据，结束后释放", systemImage: "checkmark.shield")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.frame(height: 44)
  }
  private var completion: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: completionSymbol).font(.system(size: 23)).foregroundStyle(completionColor)
      VStack(alignment: .leading, spacing: 7) {
        Text(completionTitle).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        Text(completionDetail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          .help(completionDetail)
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, 19).frame(maxWidth: .infinity).frame(height: 124)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
  }
  private var completionSymbol: String {
    speed.status != nil || target?.external?.readOnly == true ? "info.circle" : speed.running ? "arrow.triangle.2.circlepath" : result == nil ? "externaldrive.badge.checkmark" : "checkmark.circle"
  }
  private var completionColor: Color { speed.status != nil || target?.external?.readOnly == true ? .orange : speed.running || result == nil ? Theme.accent : .green }
  private var completionTitle: String {
    if speed.status != nil { return "测试提示" }
    if target?.external?.readOnly == true { return "只读存储" }
    if speed.running { return "正在测试" }
    return result == nil ? "准备就绪" : "读回校验通过"
  }
  private var completionDetail: String {
    if let status = speed.status { return status }
    if target?.external?.readOnly == true { return "当前存储无法执行写入测试。" }
    if speed.running { return "请保持设备连接，可随时停止。" }
    if let result {
      return result.date.formatted(date: .omitted, time: .shortened) + " · " + Format.bytes(UInt64(result.write.bytes)) + "\n" + (result.shortTest ? "短时测试，建议增大数据量复测" : "临时数据已释放")
    }
    return target == nil ? "连接硬盘或读卡器后即可测试。" : "现有文件保持不变。"
  }
  private var targetList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("选择存储").font(.system(size: 14, weight: .semibold)).padding(.bottom, 5)
      if targets.isEmpty { Text("连接硬盘或读卡器后即可测试。").font(.system(size: 12)).foregroundStyle(.secondary) }
      ForEach(targets) { item in
        Button { selection = item.id; showTargets = false } label: {
          HStack(spacing: 11) {
            Image(systemName: item.external?.symbol ?? "internaldrive.fill").font(.system(size: 19)).foregroundStyle(Theme.accent).frame(width: 27)
            VStack(alignment: .leading, spacing: 4) {
              Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
              Text(item.external?.capacityText ?? item.format).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if target?.id == item.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
          }.padding(11).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(CareRowStyle()).foregroundStyle(.primary)
          .accessibilityLabel("测速目标 " + item.name).accessibilityAddTraits(target?.id == item.id ? .isSelected : [])
      }
    }.padding(16).frame(width: 330)
  }
  private var history: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("最近测试").font(.system(size: 15, weight: .semibold))
      if speed.history.isEmpty { Text("暂无记录").font(.system(size: 12)).foregroundStyle(.secondary) }
      ForEach(speed.history.prefix(5)) { record in
        HStack(spacing: 24) {
          VStack(alignment: .leading, spacing: 4) {
            Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(record.date.formatted(date: .abbreviated, time: .shortened) + " · " + Format.bytes(UInt64(record.write.bytes)))
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text("写 \(StorageSpeedResult.rate(record.write.average))")
            Text("读 \(StorageSpeedResult.rate(record.read.average)) MB/s")
          }.font(.system(size: 11)).monospacedDigit()
        }
        if record.id != speed.history.prefix(5).last?.id { Divider() }
      }
      if let issue = speed.historyIssue { Text(issue).font(.system(size: 10)).foregroundStyle(.orange) }
    }.padding(20).frame(width: 440)
  }
  private var details: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("测试说明").font(.system(size: 15, weight: .semibold))
      if let target {
        VStack(alignment: .leading, spacing: 6) {
          Text(target.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
          if let device = target.external?.device, !device.isEmpty { Text(device) }
          HStack { Text(target.format); Spacer(); Text(target.transport) }
          if let free = target.external?.free { Text(Format.bytes(free) + " 可用") }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 13))
      }
      if let port {
        Text("接口参考 · \(port.title) · \(port.link ?? port.identity?.speed ?? "速率未报告")")
        Text("请确认存储连接在此接口，当前对应关系由你选择。")
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("如何测量").fontWeight(.medium).foregroundStyle(.primary)
        Text("4 MiB 顺序读写，绕过系统文件缓存。逐块读回校验，写入均值包含同步耗时。")
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("如何看结果").fontWeight(.medium).foregroundStyle(.primary)
        Text("实测包含存储、线缆、接口与读卡器。峰值是采样窗口值；1 GB 耗时按本次平均速度估算。")
        if let result {
          Text(result.fullSync ? "F_FULLFSYNC · 读回校验通过" : "使用 fsync，硬件写入缓存可能影响结果。")
          if result.shortTest { Text("本次测试较短，建议增大数据量复测。") }
        }
      }
      if let issue = speed.historyIssue { Text(issue).foregroundStyle(.orange) }
      Button(action: openRAW) {
        HStack { Text("CPU / GPU 解码测试"); Spacer(); Image(systemName: "arrow.up.right") }
          .padding(12).contentShape(RoundedRectangle(cornerRadius: 10))
      }.buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent).background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .disabled(speed.running).help("打开 Blackmagic RAW Speed Test")
    }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(20).frame(width: 360)
  }
  private func duration(_ seconds: Double) -> String {
    seconds < 1 ? String(format: "%.0f 毫秒", max(1, seconds * 1000)) : StorageSpeedResult.rate(seconds) + " 秒"
  }
  private func openRAW() {
    let candidates = ["/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app", "/Applications/Blackmagic RAW Speed Test.app"]
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
      rawLaunchError = !NSWorkspace.shared.open(URL(fileURLWithPath: path))
    } else { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/id1466185689")!) }
  }
}

/// Keep the complete estimate readable even when this summary is reused in a compact surface.
struct StorageTransferEstimate: View {
  let write: StorageSpeedReading?
  let read: StorageSpeedReading?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        Text("传输 1 GB").fontWeight(.medium)
        Text("预计")
      }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          column("写入", reading: write, symbol: "arrow.down")
          Spacer(minLength: 0)
          column("读取", reading: read, symbol: "arrow.up")
        }
        VStack(spacing: 9) {
          row("写入", reading: write, symbol: "arrow.down")
          row("读取", reading: read, symbol: "arrow.up")
        }
      }
    }.padding(.horizontal, 19).frame(maxWidth: .infinity, alignment: .leading).frame(height: 124)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
  }
  private func column(_ title: String, reading: StorageSpeedReading?, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      label(title, symbol: symbol)
      value(reading, fontSize: 20)
    }.fixedSize(horizontal: true, vertical: true)
  }
  private func row(_ title: String, reading: StorageSpeedReading?, symbol: String) -> some View {
    HStack(spacing: 10) {
      label(title, symbol: symbol)
      Spacer(minLength: 0)
      value(reading, fontSize: 16)
    }
  }
  private func label(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
  }
  private func value(_ reading: StorageSpeedReading?, fontSize: CGFloat) -> some View {
    Text(reading.map { "≈ " + Self.duration(1000 / max($0.average, 0.001)) } ?? "—")
      .font(Theme.number(fontSize, .medium)).monospacedDigit().foregroundStyle(.primary).fixedSize()
  }
  private static func duration(_ seconds: Double) -> String {
    if seconds < 1 { return String(format: "%.0f 毫秒", max(1, seconds * 1000)) }
    if seconds < 60 { return StorageSpeedResult.rate(seconds) + " 秒" }
    if seconds < 3600 { return StorageSpeedResult.rate(seconds / 60) + " 分钟" }
    return StorageSpeedResult.rate(seconds / 3600) + " 小时"
  }
}
