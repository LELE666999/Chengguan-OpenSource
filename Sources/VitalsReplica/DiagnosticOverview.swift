import Charts
import SwiftUI

/// One diagnostic composition: current state, a shared timeline, then the likely contributors.
struct DiagnosticOverview: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @State private var selection: ClosedRange<Date>?
  @State private var hover: Date?
  @State private var memoryRanking = false
  @AppStorage("graphMinutes") private var minutes = 5
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var s: MonitorSnapshot { model.snapshot }
  private var frames: [OverviewFrame] {
    let cutoff = s.time.addingTimeInterval(-Double(max(1, minutes)) * 60)
    return model.overviewFrames.filter { $0.id >= cutoff }
  }
  private var effectiveRange: ClosedRange<Date>? { selection ?? hover.map { $0...$0 } }
  private var selected: [OverviewFrame] { OverviewTimeline.frames(frames, in: effectiveRange) }
  private var ranking: [OverviewAppReading] {
    if s.isWarmup { return [] }
    return OverviewTimeline.ranking(effectiveRange == nil ? [OverviewFrame(s)] : selected, memory: memoryRanking)
  }
  private var period: String {
    guard let range = effectiveRange else { return "实时" }
    let start = range.lowerBound.formatted(date: .omitted, time: .standard)
    return range.upperBound.timeIntervalSince(range.lowerBound) < 1 ? start
      : start + " – " + range.upperBound.formatted(date: .omitted, time: .standard)
  }
  var body: some View {
    VStack(spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        systemPanel.frame(width: 202)
        cpuPanel.frame(maxWidth: .infinity)
        processesPanel.frame(width: 306)
      }.frame(height: 300)
      memoryPanel
      HStack(spacing: 14) {
        metricTile(.network, value: Format.networkRate(s.download), note: "↑ " + Format.networkRate(s.upload), values: model.history.map(\.download))
        metricTile(.disk, value: Format.rate(s.read), note: "写入 " + Format.rate(s.write), values: model.history.map(\.read))
        metricTile(.gpu, value: Format.percent(s.gpu), note: s.gpuMemory.map(Format.memory) ?? SystemValue.chip, values: model.history.compactMap(\.gpu))
        metricTile(.battery, value: Format.percent(s.battery.percent), note: s.battery.plugged ? "已接通电源" : "电池供电", values: model.history.compactMap(\.battery))
        NASSummaryCard { model.select(.nas) }
        ServerSummaryCard { model.select(.server) }
      }
      if !storage.volumes.isEmpty {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
          ForEach(storage.volumes) { volume in ExternalStorageCard(volume: volume) }
        }.transition(.opacity.combined(with: .move(edge: .top)))
      }
      HStack(spacing: 8) {
        Label("\(s.processes.count) 个进程", systemImage: "circle.grid.2x2").foregroundStyle(.secondary)
        if let ip = s.localNetwork.primary?.address {
          Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string) } label: {
            Label(ip, systemImage: "network").padding(.horizontal, 8).padding(.vertical, 5).contentShape(Capsule())
          }.buttonStyle(CareRowStyle()).help("复制局域网地址")
        }
        Spacer()
        Button { details("健康") } label: { Label("设备健康", systemImage: "checkmark.shield").padding(.horizontal, 10).padding(.vertical, 7) }
        Button { details("硬件") } label: { Label("硬件详情", systemImage: "cpu").padding(.horizontal, 10).padding(.vertical, 7) }
      }.font(.system(size: 11)).buttonStyle(AIControlButtonStyle(compact: true))
    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: storage.volumes.map(\.id))
      .onChange(of: minutes) { _, _ in selection = nil; hover = nil }
  }
  private func details(_ page: String) { model.deviceDetailsPage = page; model.showDeviceDetails = true }
  private var systemPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("整机状态").font(.system(size: 13, weight: .semibold))
          Spacer()
          Circle().fill(model.paused ? .orange : .green).frame(width: 6, height: 6)
          Text(model.paused ? "暂停" : "实时").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        HStack(alignment: .bottom, spacing: 12) {
          meter("CPU", value: s.isWarmup ? nil : s.cpu, maximum: 100, text: Format.percent(s.isWarmup ? nil : s.cpu), color: MonitorTab.cpu.color, tab: .cpu)
          meter("GPU", value: s.gpu, maximum: 100, text: Format.percent(s.gpu), color: MonitorTab.gpu.color, tab: .gpu)
          meter("温度", value: s.temperature, maximum: 110, text: s.temperature.map(Format.temperature) ?? "—", color: .orange, tab: .cpu)
          meter("内存", value: s.totalMemory > 0 ? Double(s.usedMemory) / Double(s.totalMemory) * 100 : nil, maximum: 100,
                text: s.totalMemory > 0 ? Format.percent(Double(s.usedMemory) / Double(s.totalMemory) * 100) : "—", color: MonitorTab.memory.color, tab: .memory)
        }.frame(maxHeight: .infinity)
        Text(SystemValue.chip).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func meter(_ title: String, value: Double?, maximum: Double, text: String, color: Color, tab: MonitorTab) -> some View {
    Button { model.select(tab) } label: {
      VStack(spacing: 9) {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        GeometryReader { g in
          ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09))
            if let value {
              RoundedRectangle(cornerRadius: 6).fill(color).frame(height: max(2, g.size.height * min(1, max(0, value / maximum))))
            }
          }
        }
        Text(text).font(Theme.number(11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(color)
      }.frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(CareRowStyle()).accessibilityLabel("\(title) \(text)，查看详情")
  }
  private var cpuPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("CPU 趋势", systemImage: "cpu.fill").font(.system(size: 13, weight: .semibold))
          Spacer()
          ValueText(text: s.isWarmup ? "—" : Format.percent(effectiveRange == nil ? s.cpu : average { $0.point.cpu }), size: 25)
        }
        HStack(spacing: 12) {
          legend("总占用", color: MonitorTab.cpu.color)
          legend("系统", color: .orange)
          Spacer()
          Text(period).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        OverviewTrendChart(frames: frames, memory: false, totalMemory: s.totalMemory, selection: $selection, hover: $hover)
        HStack {
          Text("用户 \(Format.percent(effectiveRange == nil ? s.user : average { $0.user }))")
          Text("系统 \(Format.percent(effectiveRange == nil ? s.system : average { $0.system }))")
          Spacer()
          if selection != nil {
            Button("返回实时") { selection = nil; hover = nil }.buttonStyle(.plain).foregroundStyle(Theme.accent)
          } else { Text("点击回看 · 拖选时段").foregroundStyle(.secondary) }
        }.font(.system(size: 10)).lineLimit(1)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private var processesPanel: some View {
    Panel(padding: 14) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(effectiveRange == nil ? "高占用 App" : "时段内的 App").font(.system(size: 13, weight: .semibold))
          Spacer()
          Picker("排序指标", selection: $memoryRanking) { Text("CPU").tag(false); Text("内存").tag(true) }
            .pickerStyle(.segmented).labelsHidden().frame(width: 105)
        }
        HStack {
          Text("应用"); Spacer(); Text(memoryRanking ? "内存" : "CPU").frame(width: 60, alignment: .trailing)
          Text(memoryRanking ? "CPU" : "内存").frame(width: 66, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 5)
          .help("App CPU 默认按单个内核计量，可超过 100%；整机 CPU 为所有内核的平均占用。时段数据是已有采样的平均值。")
        if ranking.isEmpty {
          Text(effectiveRange == nil ? "正在采样…" : "此处没有采样记录").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ForEach(Array(ranking.prefix(6).enumerated()), id: \.element.id) { i, app in
            Button { model.appHistoryTarget = AppHistoryTarget(id: app.id, name: app.name) } label: {
              HStack(spacing: 7) {
                AppIcon(path: app.bundlePath, size: 16)
                Text(app.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(memoryRanking ? Format.memory(app.memory) : Format.appCPU(app.cpu)).font(Theme.number(11)).frame(width: 60, alignment: .trailing)
                Text(memoryRanking ? Format.appCPU(app.cpu) : Format.memory(app.memory)).font(Theme.number(10, .regular)).foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
              }.font(.system(size: 11)).padding(.horizontal, 5).frame(height: 27)
                .background(Color.primary.opacity(i.isMultiple(of: 2) ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(CareRowStyle()).help("查看 \(app.name) 的历史用量")
          }
          Spacer(minLength: 0)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private var memoryPanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("内存", systemImage: "memorychip.fill").font(.system(size: 13, weight: .semibold))
          Text(s.pressureLevel < 2 ? "当前正常" : "当前压力升高").font(.system(size: 10, weight: .medium))
            .foregroundStyle(s.pressureLevel < 2 ? .green : .orange).padding(.horizontal, 8).padding(.vertical, 4)
            .background((s.pressureLevel < 2 ? Color.green : .orange).opacity(0.09), in: Capsule())
          Spacer()
          ValueText(text: Format.memory(effectiveRange == nil ? Double(s.usedMemory) : average { $0.point.memory }), size: 24)
          Text("/ \(Format.memory(s.totalMemory))").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        OverviewTrendChart(frames: frames, memory: true, totalMemory: s.totalMemory, selection: $selection, hover: $hover).frame(height: 90)
        HStack {
          SmallStat(title: "当前可用", value: Format.memory(s.availableMemory))
          SmallStat(title: "App", value: Format.memory(s.appMemory))
          SmallStat(title: "已压缩", value: Format.memory(s.compressed))
          SmallStat(title: "已缓存", value: Format.memory(s.cached))
          SmallStat(title: "交换", value: Format.memory(s.swap))
        }
      }
    }
  }
  private func average(_ value: (OverviewFrame) -> Double) -> Double {
    selected.isEmpty ? .nan : selected.map(value).reduce(0, +) / Double(selected.count)
  }
  private func legend(_ title: String, color: Color) -> some View {
    HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(title).foregroundStyle(.secondary) }.font(.system(size: 10))
  }
  private func metricTile(_ tab: MonitorTab, value: String, note: String, values: [Double]) -> some View {
    Button {
      model.select(tab)
    } label: {
      Panel(padding: 14) {
        VStack(alignment: .leading, spacing: 7) {
          HStack { TabSymbol(tab: tab, size: 12).foregroundStyle(tab.color); Text(tab.title).font(.system(size: 12, weight: .semibold)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
          ValueText(text: value, size: 25)
          HStack { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 0) }
          HistoryGraph(values: Array(values.suffix(90)), color: tab.color, ceiling: [.gpu, .battery].contains(tab) ? 100 : nil).frame(height: 18)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.contentShape(RoundedRectangle(cornerRadius: 18))
    }.buttonStyle(CareRowStyle())
  }
}

struct OverviewTrendChart: View {
  let frames: [OverviewFrame]
  let memory: Bool
  let totalMemory: UInt64
  @Binding var selection: ClosedRange<Date>?
  @Binding var hover: Date?
  private var color: Color { memory ? MonitorTab.memory.color : MonitorTab.cpu.color }
  private var axisColor: Color { Color.primary.opacity(0.62) }
  private var domain: ClosedRange<Date> {
    let last = frames.last?.id ?? Date()
    let first = frames.first?.id ?? last.addingTimeInterval(-60)
    return first...max(first.addingTimeInterval(2), last)
  }
  var body: some View {
    Chart {
      ForEach(Array(OverviewTimeline.segments(frames).enumerated()), id: \.offset) { segment in
       ForEach(segment.element) { f in
        AreaMark(x: .value("时间", f.id), y: .value("占用", memory ? f.point.memory : f.point.cpu), series: .value("时段", "填充\(segment.offset)"))
          .foregroundStyle(color.opacity(0.08))
        LineMark(x: .value("时间", f.id), y: .value("占用", memory ? f.point.memory : f.point.cpu), series: .value("指标", "主指标\(segment.offset)"))
          .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        if !memory {
          LineMark(x: .value("时间", f.id), y: .value("系统", f.system), series: .value("指标", "系统\(segment.offset)"))
            .foregroundStyle(Color.orange.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 1.2))
        }
       }
      }
      if let range = selection {
        if range.upperBound.timeIntervalSince(range.lowerBound) >= 1 {
          RectangleMark(xStart: .value("起点", range.lowerBound), xEnd: .value("终点", range.upperBound))
            .foregroundStyle(color.opacity(0.1))
        }
        RuleMark(x: .value("选中", range.lowerBound)).foregroundStyle(color.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      } else if let hover {
        RuleMark(x: .value("回看", hover)).foregroundStyle(color.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }.chartXScale(domain: domain).chartYScale(domain: 0...(memory ? Double(max(1, totalMemory)) : 100))
      .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
        AxisValueLabel(format: domain.upperBound.timeIntervalSince(domain.lowerBound) < 120 ? .dateTime.minute().second() : .dateTime.hour().minute()).font(.system(size: 9)).foregroundStyle(axisColor)
      } }
      .chartYAxis { AxisMarks(position: .leading, values: memory ? [0, Double(totalMemory) / 2, Double(totalMemory)] : [0, 50, 100]) { v in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.secondary.opacity(0.15))
        AxisValueLabel { if let n = v.as(Double.self) { Text(memory ? String(format: "%.0f GB", n / pow(1024, 3)) : "\(Int(n))%").font(.system(size: 9)).foregroundStyle(axisColor) } }
      } }
      .chartOverlay { proxy in
        GeometryReader { g in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
              guard let plot = proxy.plotFrame else { return }
              let origin = g[plot].minX, width = g[plot].width
              guard let start: Date = proxy.value(atX: min(width, max(0, drag.startLocation.x - origin))),
                    let end: Date = proxy.value(atX: min(width, max(0, drag.location.x - origin))) else { return }
              hover = nil
              selection = abs(drag.translation.width) < 5 ? end...end : min(start, end)...max(start, end)
            })
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard selection == nil, let plot = proxy.plotFrame else { return }
                let x = min(g[plot].width, max(0, location.x - g[plot].minX))
                hover = proxy.value(atX: x, as: Date.self)
              case .ended: hover = nil
              }
            }
        }
      }
      .overlay { if frames.count < 2 { Text("正在积累采样…").font(.system(size: 11)).foregroundStyle(.secondary).allowsHitTesting(false) } }
      .accessibilityLabel(memory ? "内存历史曲线" : "CPU 历史曲线")
      .accessibilityHint("点击回看一个时刻，拖动选择时段，右侧同步显示对应 App")
  }
}
