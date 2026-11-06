import Charts
import Combine
import SwiftUI

struct DashboardView: View {
  @ObservedObject var model: MonitorModel
  @AppStorage("overviewSummary") private var summary = true
  @AppStorage("overviewNow") private var now = true
  @AppStorage("overviewHardware") private var hardware = true
  @AppStorage("overviewHistory") private var history = true
  @AppStorage("graphMinutes") private var graphMinutes = 5
  @ObservedObject private var peripherals = Peripherals.shared
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        if summary { summaryCards }
        if !model.insights.isEmpty { insightsSection }
        HStack(alignment: .top, spacing: 14) {
          Panel { LiveActivityPanel(model: model).frame(maxWidth: .infinity) }
          Button { model.presentCare() } label: {
            Panel {
              VStack(alignment: .leading, spacing: 12) {
                Label("整理", systemImage: "sparkles.rectangle.stack").foregroundStyle(Theme.accent)
                Text("空间 · 软件 · 维护").font(.system(size: 18, weight: .medium))
                HStack { Text("扫描并查看可处理项目").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.right") }
              }.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }
          }.buttonStyle(CareRowStyle())
        }
        if now && !model.snapshot.projects.isEmpty { nowSection }
        if hardware { hardwareSection }
        if history { DashboardHistory(model: model) }
      }.padding(20)
    }.onAppear {
      peripherals.refreshAudio()
      peripherals.refreshBluetooth()
    }.onReceive(refresh) { _ in
      peripherals.refreshAudio()
      peripherals.refreshBluetooth()
    }
  }
  var summaryCards: some View {
    DiagnosticOverview(model: model)
  }
  var insightsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("值得关注").font(.system(size: 16, weight: .bold))
        Spacer()
        Button("清除") { model.insights = [] }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(
          .system(size: 12))
      }
      if model.insights.isEmpty {
        Panel {
          HStack(spacing: 12) {
            MetricIcon(symbol: "checkmark.circle.fill", color: .green)
            VStack(alignment: .leading, spacing: 4) {
              Text("没有异常").font(.system(size: 13, weight: .semibold))
              Text("CPU、内存、磁盘和温度的提醒会显示在这里。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      } else {
        ForEach(model.insights, id: \.self) { insight in
          Button {
            model.select(.cpu)
          } label: {
            Panel {
              HStack {
                MetricIcon(symbol: "exclamationmark.triangle.fill", color: .orange)
                Text(insight).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
              }
            }
          }.buttonStyle(.plain)
        }
      }
    }
  }
  var nowSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("此刻").font(.system(size: 16, weight: .bold))
      if model.snapshot.projects.isEmpty {
        Panel {
          HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text("没有正在运行的项目").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
          }
        }
      } else {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14
        ) {
          ForEach(model.snapshot.projects.prefix(6)) { project in
            Button {
              model.select(.projects)
            } label: {
              Panel {
                VStack(alignment: .leading, spacing: 14) {
                  Label(project.name, systemImage: "folder.fill").font(
                    .system(size: 13, weight: .semibold)
                  ).foregroundStyle(MonitorTab.projects.color)
                  HStack {
                    SmallStat(title: "CPU", value: Format.percent(project.cpu))
                    SmallStat(title: "内存", value: Format.memory(project.memory))
                    SmallStat(
                      title: "端口", value: project.ports.map(String.init).joined(separator: ", "))
                  }
                }.frame(height: 80)
              }
            }.buttonStyle(.plain)
          }
        }
      }
    }
  }
  var hardwareSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("硬件").font(.system(size: 16, weight: .bold))
      HStack(alignment: .top, spacing: 14) {
        Button {
          model.select(.cpu)
        } label: {
          Panel {
            VStack(alignment: .leading, spacing: 14) {
              Label("温度与风扇", systemImage: "thermometer.medium").font(
                .system(size: 13, weight: .semibold)
              ).foregroundStyle(.orange)
              HStack {
                SmallStat(
                  title: "CPU",
                  value: model.snapshot.temperature.map { Format.temperature($0) } ?? "—")
                SmallStat(
                  title: "GPU",
                  value: model.snapshot.sensors.first { $0.name.contains("GPU") }.map {
                    String(format: "%.0f °C", $0.value)
                  } ?? "—")
                SmallStat(
                  title: "最高温度",
                  value: model.snapshot.sensors.filter { $0.unit == "°C" }.map(\.value).max().map {
                    Format.temperature($0)
                  } ?? "—")
              }
              ForEach(model.snapshot.sensors.filter { $0.unit == "rpm" }.prefix(2)) { sensor in
                HStack {
                  Image(systemName: "fan.fill").foregroundStyle(.secondary)
                  Text(sensor.name)
                  Spacer()
                  GaugeBar(value: sensor.value / 6000, color: .orange).frame(width: 45)
                  Text(String(format: "%.0f rpm", sensor.value)).font(Theme.number(13))
                }
              }
              Spacer(minLength: 0)
            }.font(.system(size: 12)).frame(height: 140, alignment: .top)
          }
        }.buttonStyle(.plain)
        Button {
          model.select(.sound)
        } label: {
          Panel {
            VStack(alignment: .leading, spacing: 18) {
              Label("音量混音器", systemImage: "speaker.wave.2.fill").font(
                .system(size: 13, weight: .semibold)
              ).foregroundStyle(.pink)
              HStack {
                Text("macOS")
                Spacer()
                GaugeBar(value: peripherals.outputVolume / 100, color: .pink).frame(width: 70)
                Text(Format.percent(peripherals.outputVolume))
              }
              Spacer(minLength: 0)
            }.font(.system(size: 12)).frame(height: 140, alignment: .top)
          }
        }.buttonStyle(.plain)
        Button {
          model.select(.bluetooth)
        } label: {
          Panel {
            VStack(alignment: .leading, spacing: 18) {
              Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right").font(
                .system(size: 13, weight: .semibold)
              ).foregroundStyle(Theme.accent)
              ForEach(peripherals.bluetooth.filter(\.connected).prefix(3)) { device in
                HStack {
                  Image(systemName: "iphone").foregroundStyle(.secondary)
                  Text(device.name).lineLimit(1)
                  Spacer()
                  Text("—").foregroundStyle(.secondary)
                }
              }
              if peripherals.bluetooth.allSatisfy({ !$0.connected }) {
                Text("没有已连接的设备").foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
            }.font(.system(size: 12)).frame(height: 140, alignment: .top)
          }
        }.buttonStyle(.plain)
      }
    }
  }
  private func overviewCard(_ tab: MonitorTab) -> some View {
    let s = model.snapshot
    return Button {
      model.select(tab)
    } label: {
      Panel {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 7) {
            TabSymbol(tab: tab, size: 13)
            Text(tab.title).fontWeight(.semibold)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.secondary.opacity(0.4))
          }.font(.system(size: 13)).foregroundStyle(tab.color)
          VStack(alignment: .leading, spacing: 4) {
            Text(subtitle(tab)).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              ValueText(text: value(tab), size: 43)
              if tab == .network {
                Text("↑ " + Format.networkRate(s.upload)).font(Theme.number(12)).foregroundStyle(
                  .secondary)
              }
              if tab == .disk, let v = s.primaryVolume {
                Text("已使用 \(Int((1-Double(v.free)/Double(v.total))*100))%").font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              if tab == .memory {
                Label(s.pressureLevel < 2 ? "正常" : "压力升高", systemImage: "checkmark.circle.fill")
                  .font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    s.pressureLevel < 2 ? .green : .orange
                  ).padding(.horizontal, 8).padding(.vertical, 3).background(
                    (s.pressureLevel < 2 ? Color.green : .orange).opacity(0.1), in: Capsule())
              }
            }
          }
          HStack(spacing: 8) {
            ForEach(Array(details(tab).enumerated()), id: \.offset) { _, d in
              SmallStat(title: d.0, value: d.1, color: d.2)
            }
          }
          Spacer(minLength: 0)
          if tab == .agents {
            Text("在“代理”标签页查看AI用量限额和Token统计。").font(.system(size: 10)).foregroundStyle(
              .tertiary
            ).lineLimit(1).minimumScaleFactor(0.7)
          } else {
            HistoryGraph(
              values: model.history.filter { $0.time >= Date().addingTimeInterval(-Double(graphMinutes) * 60) }.compactMap { $0.value(tab) }, color: tab.color,
              ceiling: [.cpu, .gpu, .battery].contains(tab) ? 100 : nil, bars: model.bars
            ).frame(height: 22)
          }
        }.frame(height: 167, alignment: .top)
      }
    }.buttonStyle(.plain).accessibilityLabel("\(tab.title)，\(value(tab))")
  }
  private func subtitle(_ tab: MonitorTab) -> String {
    let s = model.snapshot
    switch tab {
    case .cpu: return "当前"
    case .memory: return "已使用，共 \(Int(Double(s.totalMemory)/pow(1024,3))) GB"
    case .gpu: return SystemValue.chip
    case .disk: return "可用，共 \(s.primaryVolume.map { Format.bytes($0.total) } ?? "—")"
    case .network: return "正在下载"
    case .battery: return s.battery.plugged ? "已接通电源" : "正在使用电池"
    case .agents: return "会话"
    default: return ""
    }
  }
  private func value(_ tab: MonitorTab) -> String {
    let s = model.snapshot
    switch tab {
    case .cpu: return String(format: "%.0f %%", s.cpu)
    case .memory: return Format.memory(s.usedMemory)
    case .gpu: return s.gpu.map { String(format: "%.0f %%", $0) } ?? "—"
    case .disk: return s.primaryVolume.map { Format.bytes($0.free) } ?? "—"
    case .network: return Format.networkRate(s.download)
    case .battery: return s.battery.percent.map { String(format: "%.0f %%", $0) } ?? "—"
    case .agents: return "\(s.agents.count) 个正在运行"
    default: return "—"
    }
  }
  private func details(_ tab: MonitorTab) -> [(String, String, Color?)] {
    let s = model.snapshot
    switch tab {
    case .cpu:
      return [
        ("用户", Format.percent(s.user), nil), ("系统", Format.percent(s.system), nil),
        ("今日平均", Format.percent(model.dayTotals.cpu), nil),
        ("运行时间", Format.duration(ProcessInfo.processInfo.systemUptime), nil),
      ]
    case .memory:
      return [
        ("App", Format.memory(s.appMemory), .blue), ("联动", Format.memory(s.wired), .orange),
        ("被压缩", Format.memory(s.compressed), .green),
      ]
    case .gpu:
      let values = model.history.compactMap(\.gpu)
      return [
        ("内存", s.gpuMemory.map { Format.memory($0) } ?? "—", nil),
        (
          "平均", Format.percent(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)),
          nil
        ), ("峰值", Format.percent(values.max()), nil),
      ]
    case .disk:
      return [
        ("读取速度", Format.rate(s.read), nil), ("写入速度", Format.rate(s.write), nil),
        ("今日写入", Format.bytes(model.dayTotals.written), nil),
      ]
    case .network:
      return [
        ("今天", Format.bytes(model.dayTotals.downloaded), nil),
        ("过去7天", Format.bytes(model.weekTotals.downloaded), nil),
        ("过去30天", Format.bytes(model.monthTotals.downloaded), nil),
      ]
    case .battery:
      return [
        ("循环次数", s.battery.cycles.map(String.init) ?? "—", nil),
        ("耗电功率", s.battery.watts.map { String(format: "%.1f W", $0) } ?? "—", nil),
        ("健康度", Format.percent(s.battery.health), nil),
      ]
    case .agents:
      return [
        ("在等你", "—", nil),
        ("内存", Format.memory(s.agents.reduce(UInt64(0)) { $0 + $1.process.memory }), nil),
        ("CPU", String(format: "%.1f%%", s.agents.reduce(0) { $0 + $1.process.cpu }), nil),
      ]
    default: return []
    }
  }
}

struct DashboardHistory: View {
  @ObservedObject private var advisor = AdvisorStore.shared
  @ObservedObject var model: MonitorModel
  var exporting = false
  @State private var metric = "CPU"
  @State private var bars = false
  private var points: [HistoryPoint] { model.plottedHistory }
  private var values: [Double] { points.compactMap { value($0) } }
  private var color: Color {
    metric == "内存"
      ? MonitorTab.memory.color
      : metric == "网络" ? MonitorTab.network.color : metric == "磁盘" ? MonitorTab.disk.color : Theme.accent
  }
  private var heading: String {
    switch metric {
    case "内存": "平均内存使用"
    case "网络": "平均下载速度"
    case "能耗": "平均功率"
    case "磁盘": "平均写入速度"
    default: "平均CPU负载"
    }
  }
  private func value(_ p: HistoryPoint) -> Double? {
    switch metric {
    case "内存": p.memory
    case "网络": p.download
    case "磁盘": p.write
    case "能耗": nil
    default: p.cpu
    }
  }
  private func label(_ value: Double?) -> String {
    guard let value else { return "—" }
    switch metric {
    case "内存": return Format.memory(value)
    case "网络", "磁盘": return Format.rate(value)
    case "能耗": return String(format: "%.1f W", value)
    default: return Format.percent(value)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Text("随时间变化").font(.system(size: 18, weight: .bold))
        Spacer()
        if exporting {
          Text("CPU · \(Int(model.range / 3600))小时").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
        Picker("图表样式", selection: $bars) {
          Image(systemName: "chart.xyaxis.line").tag(false)
          Image(systemName: "chart.bar.fill").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 60)
        Picker("指标", selection: $metric) {
          ForEach(["CPU", "内存", "网络", "能耗", "磁盘"], id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 255)
        Picker("范围", selection: $model.range) {
          Text("12小时").tag(43200.0)
          Text("24小时").tag(86400.0)
          Text("7天").tag(604800.0)
          Text("30天").tag(2592000.0)
        }.labelsHidden().frame(width: 90)
        Button {
          model.exportHistoryBundle(range: model.range)
        } label: {
          Label("导出CSV", systemImage: "square.and.arrow.up")
        }
        }
      }
      HStack(alignment: .top, spacing: 14) {
        Panel {
          VStack(alignment: .leading, spacing: 7) {
            Label(heading, systemImage: metric == "内存" ? "memorychip.fill" : "cpu.fill").font(
              .system(size: 12, weight: .semibold)
            ).foregroundStyle(color)
            Text(label(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))).font(
              Theme.number(32, .bold)
            ).contentTransition(.numericText())
            Text("按时间段聚合 · 仅包含已记录的采样").font(.system(size: 11)).foregroundStyle(.secondary)
            if metric == "能耗" || points.isEmpty {
              Text(metric == "能耗" ? "尚无功率历史记录" : "正在积累历史记录…").font(.system(size: 12))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              Chart(points) { p in
                if let number = value(p) {
                  if bars {
                    BarMark(x: .value("时间", p.time), y: .value(metric, number)).foregroundStyle(
                      color
                    ).cornerRadius(2)
                  } else {
                    AreaMark(x: .value("时间", p.time), y: .value(metric, number))
                      .interpolationMethod(.monotone).foregroundStyle(
                        LinearGradient(
                          colors: [color.opacity(0.35), color.opacity(0.01)], startPoint: .top,
                          endPoint: .bottom))
                    LineMark(x: .value("时间", p.time), y: .value(metric, number))
                      .interpolationMethod(.monotone).foregroundStyle(color).lineStyle(
                        StrokeStyle(lineWidth: 2.2))
                  }
                }
              }.chartYScale(domain: 0...max(1, (values.max() ?? 0) * 1.15)).chartYAxis {
                AxisMarks(position: .trailing) { axis in
                  AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(
                    color.opacity(0.2))
                  AxisValueLabel {
                    if let n = axis.as(Double.self) {
                      Text(label(n)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                  }
                }
              }.chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) {
                  AxisValueLabel(format: .dateTime.hour().minute())
                }
              }.padding(.top, 8)
            }
          }.frame(height: 330)
        }.frame(maxWidth: .infinity)
        Panel {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Label("CPU时间最多的App", systemImage: "list.number").foregroundStyle(Theme.accent).font(
                .system(size: 12, weight: .semibold))
              Spacer()
              Text("今天").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(model.appHistory.prefix(7)) { app in
              Button {
                model.appHistoryTarget = AppHistoryTarget(id: app.id, name: app.name)
              } label: {
                HStack(spacing: 10) {
                  AppIcon(path: app.id.hasPrefix("/") ? app.id : nil, size: 22)
                  Text(app.name).font(.system(size: 13)).lineLimit(1)
                  Spacer(minLength: 8)
                  GaugeBar(
                    value: app.cpuSeconds / max(1, model.appHistory.first?.cpuSeconds ?? 0),
                    color: Theme.accent
                  ).frame(width: 55)
                  Text(timeLabel(app.cpuSeconds)).font(Theme.number(12)).frame(
                    width: 75, alignment: .trailing)
                }.frame(height: 27)
              }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
          }.frame(height: 330)
        }.frame(width: 360)
      }
      Panel {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label("峰值", systemImage: "gauge.with.dots.needle.67percent").foregroundStyle(Theme.accent)
              .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("聚合读数中的最高值").font(.system(size: 11)).foregroundStyle(.secondary)
          }
          HStack {
            peak("CPU", point: points.max { $0.cpu < $1.cpu }, label: { Format.percent($0.cpu) })
            peak("内存压力", point: nil, label: { _ in "—" })
            peak(
              "温度",
              point: points.filter { $0.temperature != nil }.max {
                ($0.temperature ?? 0) < ($1.temperature ?? 0)
              }, label: { $0.temperature.map { Format.temperature($0) } ?? "—" })
            peak("功率", point: nil, label: { _ in "—" })
          }
          Divider()
          Text("变化记录").font(.system(size: 11)).foregroundStyle(.secondary)
          if advisor.episodes.isEmpty {
            Label("尚无值得关注的变化", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
          } else {
            ForEach(advisor.episodes.prefix(3)) { episode in EpisodeRow(episode: episode, model: model) }
          }
        }
      }
    }
  }
  private func timeLabel(_ seconds: Double) -> String {
    let n = Int(seconds)
    return "\(n/60)分钟\(n%60)秒"
  }
  private func peak(_ title: String, point: HistoryPoint?, label: (HistoryPoint) -> String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(point.map(label) ?? "—").font(Theme.number(22))
      Text(point?.time.formatted(date: .omitted, time: .shortened) ?? " ").font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
