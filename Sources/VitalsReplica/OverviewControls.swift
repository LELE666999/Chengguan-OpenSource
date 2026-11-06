import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct TabSymbol: View {
  let tab: MonitorTab
  var size: CGFloat = 15
  var body: some View {
    Group {
      if tab == .agents {
        Image(nsImage: VisualResources.image("bot")).resizable().renderingMode(.template)
          .scaledToFit().frame(
            width: size * 0.88, height: size)
      } else {
        Image(systemName: tab.symbol).font(.system(size: size, weight: .semibold))
      }
    }.frame(width: size, height: size)
  }
}
enum VisualResources {
  static func image(_ name: String) -> NSImage {
    let bundleURL = Bundle.main.resourceURL?.appendingPathComponent(
      "VitalsReplica_VitalsReplica.bundle")
    let bundle = bundleURL.flatMap(Bundle.init(url:)) ?? Bundle.module
    if let image = bundle.url(forResource: name, withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) { return image }
    // Public builds use system artwork when provider-specific resources are absent.
    let symbol: String
    switch name {
    case "bot": symbol = "terminal.fill"
    case "provider-claude": symbol = "sun.max.fill"
    case "provider-codex": symbol = "chevron.left.forwardslash.chevron.right"
    case "provider-cursor": symbol = "cursorarrow.rays"
    case "provider-grok": symbol = "sparkle"
    default: symbol = "sparkles"
    }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage()
  }
}
struct NavigationGlass: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      content.background(.regularMaterial, in: Capsule()).overlay(
        Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
    }
  }
}
struct ChartStyleControl: View {
  @Binding var bars: Bool
  var body: some View {
    HStack(spacing: 0) {
      ForEach([true, false], id: \.self) { value in
        Button { bars = value } label: {
          Image(systemName: value ? "chart.bar.fill" : "chart.xyaxis.line")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(bars == value ? .primary : .secondary)
            .frame(width: 31, height: 22)
            .background {
              if bars == value { Capsule().fill(Color(nsColor: .controlBackgroundColor)) }
            }.contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(value ? "条形" : "折线")
          .accessibilityAddTraits(bars == value ? .isSelected : [])
          .help(value ? "以条形显示历史记录" : "以折线显示历史记录")
      }
    }.padding(2).background(.quaternary.opacity(0.45), in: Capsule()).accessibilityElement(children: .contain).accessibilityLabel("图表样式")
  }
}
struct OverviewLayoutPopover: View {
  @ObservedObject var model: MonitorModel
  @AppStorage("overviewSummary") var summary = true
  @AppStorage("overviewNow") var now = true
  @AppStorage("overviewHardware") var hardware = true
  @AppStorage("overviewHistory") var history = true
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("概览").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
      Toggle("摘要", isOn: $summary)
      Toggle("此刻", isOn: $now)
      Toggle("硬件", isOn: $hardware)
      Toggle("随时间变化", isOn: $history)
      Divider()
      Text("图表样式").font(.system(size: 11)).foregroundStyle(.secondary)
      Picker("图表样式", selection: $model.bars) {
        Label("条形", systemImage: "chart.bar.fill").tag(true)
        Label("折线", systemImage: "chart.xyaxis.line").tag(false)
      }.pickerStyle(.segmented).labelsHidden()
    }.toggleStyle(.checkbox).padding(16).frame(width: 250)
  }
}
struct ExportPopover: View {
  @ObservedObject var model: MonitorModel
  @State private var summary = true
  @State private var now = true
  @State private var hardware = false
  @State private var history = true
  @State private var range = 2592000.0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      section("分享卡片")
      HStack(spacing: 10) {
        ForEach([true, false], id: \.self) { bars in
          Button {
            exportCard(bars: bars)
          } label: {
            VStack(spacing: 6) {
              ShareCardView(snapshot: model.snapshot, history: model.history, bars: bars).frame(
                width: 900, height: 480
              ).scaleEffect(0.16, anchor: .topLeading).frame(width: 144, height: 77, alignment: .topLeading).clipped()
                .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(
                  RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
              Text(bars ? "条形" : "折线").font(.system(size: 12, weight: .medium))
            }
          }.buttonStyle(.plain).accessibilityLabel("导出分享卡片，" + (bars ? "条形" : "折线"))
        }
      }
      Divider()
      section("仪表盘")
      exportToggle("摘要", isOn: $summary)
      exportToggle("此刻", isOn: $now)
      exportToggle("硬件", isOn: $hardware)
      exportToggle("随时间变化", isOn: $history)
      HStack {
        Button("导出仪表盘") { exportDashboard(copy: false) }.buttonStyle(.borderedProminent).frame(
          maxWidth: .infinity)
        Button {
          exportDashboard(copy: true)
        } label: {
          Image(systemName: "doc.on.doc")
        }.help("拷贝仪表盘图像")
      }
      Divider()
      section("历史记录")
      HStack {
        Picker("范围", selection: $range) {
          Text("12小时").tag(43200.0)
          Text("7天").tag(604800.0)
          Text("30天").tag(2592000.0)
        }.labelsHidden().frame(width: 100)
        Button("导出CSV") { model.exportHistoryBundle(range: range) }.frame(maxWidth: .infinity)
      }
      Text("在“下载”中存储三个文件：按天统计的App、按小时统计的Mac，以及每5分钟一次的读数。").font(.system(size: 11)).foregroundStyle(
        .secondary
      )
      .fixedSize(horizontal: false, vertical: true)
    }.padding(14).frame(width: 330)
  }
  private func section(_ title: String) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
  }
  private func exportToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Button {
      isOn.wrappedValue.toggle()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if isOn.wrappedValue {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
        }
      }.padding(.horizontal, 10).frame(height: 30).background(
        isOn.wrappedValue ? Theme.accent.opacity(0.16) : .clear,
        in: RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(.plain)
  }
  @MainActor private func exportCard(bars: Bool) {
    save(
      ShareCardView(snapshot: model.snapshot, history: model.history, bars: bars).frame(
        width: 900, height: 480), name: bars ? "Chengguan-bar" : "Chengguan-line", copy: false)
  }
  @MainActor private func exportDashboard(copy: Bool) {
    save(
      DashboardExportView(
        model: model, summary: summary, now: now, hardware: hardware, history: history
      ).frame(width: 1200), name: "Chengguan-dashboard", copy: copy)
  }
  @MainActor private func save<V: View>(_ view: V, name: String, copy: Bool) {
    let mode = UserDefaults.standard.string(forKey: "exportBackground") ?? "跟随窗口"
    let scheme: ColorScheme =
      mode == "深色"
      ? .dark
      : mode == "浅色"
        ? .light
        : (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? .dark : .light)
    let backdrop: Color =
      mode == "透明" ? .clear : (scheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white)
    let renderer = ImageRenderer(
      content: view.background(backdrop).environment(\.colorScheme, scheme).allowedDynamicRange(.standard))
    renderer.scale = 2
    renderer.colorMode = .nonLinear
    if #available(macOS 26.0, *) { renderer.allowedDynamicRange = .standard }
    // Explicit SDR destination avoids HDR App icons promoting the whole dashboard
    // to a PQ PNG, which changes its appearance in ordinary image viewers.
    var raster: CGImage?
    renderer.render(rasterizationScale: 2) { size, draw in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: Int(ceil(size.width * 2)),
          height: Int(ceil(size.height * 2)), bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.scaleBy(x: 2, y: 2)
      draw(context)
      raster = context.makeImage()
    }
    let data = NSMutableData()
    guard let cgImage = raster,
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else {
      model.notice = "无法生成图像"
      return
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { model.notice = "无法编码图像"; return }
    if copy {
      let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
      return
    }
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let path = downloads.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).png")
    do {
      try data.write(to: path)
      NSWorkspace.shared.activateFileViewerSelecting([path])
    } catch { model.notice = error.localizedDescription }
  }
}
struct ShareCardView: View {
  let snapshot: MonitorSnapshot, history: [HistoryPoint], bars: Bool
  @AppStorage("exportBrand") private var brand = true
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if brand {
        HStack {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
          Text("澄观").font(.system(size: 16, weight: .bold))
          Spacer()
          Text(
            "\(SystemValue.chip) · \(snapshot.coreUsage.count)个内核 · \(Int(Double(snapshot.totalMemory)/pow(1024,3))) GB"
          ).foregroundStyle(
            .secondary)
        }
      }
      HStack(alignment: .top, spacing: 30) {
        VStack(alignment: .leading, spacing: 12) {
          Text("内存").foregroundStyle(MonitorTab.memory.color)
          ValueText(text: Format.memory(snapshot.usedMemory), size: 50)
          HStack {
            SmallStat(title: "App", value: Format.memory(snapshot.appMemory), color: .blue)
            SmallStat(title: "联动", value: Format.memory(snapshot.wired), color: .orange)
            SmallStat(title: "被压缩", value: Format.memory(snapshot.compressed), color: .green)
          }
        }
        Spacer()
        VStack(spacing: 13) {
          ForEach([MonitorTab.cpu, .gpu, .disk, .network, .battery]) { tab in
            HStack {
              TabSymbol(tab: tab, size: 13).foregroundStyle(tab.color)
              Text(tab.title).frame(width: 40, alignment: .leading)
              GaugeBar(value: value(tab) / 100, color: tab.color).frame(width: 70)
              Text(label(tab)).font(Theme.number(13)).frame(width: 70, alignment: .trailing)
            }
          }
        }
      }
      Spacer()
      HistoryGraph(
        values: history.map(\.cpu), color: MonitorTab.cpu.color, ceiling: 100, bars: bars,
        grid: true
      ).frame(height: 160)
      HStack {
        Text(history.first?.time.formatted(date: .omitted, time: .shortened) ?? "")
        Spacer()
        Text("现在")
      }.font(.system(size: 11)).foregroundStyle(.secondary)
    }.padding(28)
  }
  private func value(_ tab: MonitorTab) -> Double {
    switch tab {
    case .cpu: snapshot.cpu
    case .gpu: snapshot.gpu ?? 0
    case .battery: snapshot.battery.percent ?? 0
    case .disk: snapshot.primaryVolume.map { (1 - Double($0.free) / Double($0.total)) * 100 } ?? 0
    case .network:
      snapshot.download / max(1, history.map(\.download).max() ?? snapshot.download) * 100
    default: 0
    }
  }
  private func label(_ tab: MonitorTab) -> String {
    switch tab {
    case .cpu: Format.percent(snapshot.cpu)
    case .gpu: Format.percent(snapshot.gpu)
    case .disk: snapshot.primaryVolume.map { Format.bytes($0.free) } ?? "—"
    case .network: Format.networkRate(snapshot.download)
    case .battery: Format.percent(snapshot.battery.percent)
    default: "—"
    }
  }
}
struct DashboardExportView: View {
  @ObservedObject var model: MonitorModel
  let summary: Bool, now: Bool, hardware: Bool, history: Bool
  @AppStorage("exportBrand") private var brand = true
  var body: some View {
    let dashboard = DashboardView(model: model)
    VStack(alignment: .leading, spacing: 26) {
      if brand {
        HStack {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
          Text("澄观").font(.system(size: 18, weight: .bold))
          Spacer()
          Text(SystemValue.chip).foregroundStyle(.secondary)
        }
      }
      if summary { dashboard.summaryCards }
      if now { dashboard.nowSection }
      if hardware {
        Panel {
          HStack {
            SmallStat(
              title: "CPU温度", value: model.snapshot.temperature.map(Format.temperature) ?? "—")
            SmallStat(
              title: "风扇", value: model.snapshot.fan.map { String(format: "%.0f rpm", $0) } ?? "—")
            SmallStat(title: "电池健康度", value: Format.percent(model.snapshot.battery.health))
          }
        }
      }
      if history { DashboardHistory(model: model, exporting: true) }
    }.padding(20)
  }
}
