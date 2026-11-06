import SwiftUI

struct ProcessView: View {
  @ObservedObject var model: MonitorModel
  var s: MonitorSnapshot { model.snapshot }
  var tab: MonitorTab { model.tab }
  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Panel {
          HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 9) {
                MetricIcon(symbol: tab.symbol, color: tab.color)
                Text(tab.title).font(.system(size: 16, weight: .semibold))
              }
              ValueText(text: headline, size: 49)
              Text(subtitle).foregroundStyle(.secondary).font(.system(size: 12))
              Spacer()
            }.frame(width: 200, alignment: .leading)
            VStack(spacing: 7) {
              HStack {
                Spacer()
                Text(scaleText).foregroundStyle(.secondary).font(.system(size: 11))
              }
              HistoryGraph(
                values: model.history.filter {
                  $0.time
                    >= Date().addingTimeInterval(
                      -Double(
                        UserDefaults.standard.integer(forKey: "graphMinutes") == 0
                          ? 5 : UserDefaults.standard.integer(forKey: "graphMinutes")) * 60)
                }.compactMap { $0.value(tab) }, secondary: secondaryValues,
                color: tab.color, secondaryColor: .orange,
                ceiling: [.cpu, .gpu, .battery].contains(tab) ? 100 : nil, bars: model.bars,
                grid: true)
              HStack {
                Text(model.history.first?.time.formatted(date: .omitted, time: .shortened) ?? "")
                Spacer()
                Text("现在")
              }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
          }.frame(height: 184)
        }.frame(maxWidth: .infinity)
        if tab != .gpu { sidePanel.frame(width: 390) }
      }.padding(.horizontal, 20)
      HStack(spacing: 12) {
        ForEach(Array(stats.enumerated()), id: \.offset) { index, st in
          Panel(padding: 14) {
            if tab == .network && index == 2 {
              LocalAddressView(network: s.localNetwork).frame(height: 85, alignment: .top)
            } else {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 7) {
                MetricIcon(symbol: st.0, color: tab.color)
                Text(st.1).foregroundStyle(.secondary).font(.system(size: 12))
              }
              ValueText(text: st.2, size: 27)
              Text(st.3).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 85, alignment: .top)
            }
          }
        }
      }.padding(.horizontal, 20)
      if tab == .network || tab == .disk {
        HStack {
          Spacer()
          if tab == .network {
            Button("网卡与连接") { model.deviceDetailsPage = "网络"; model.showDeviceDetails = true }
            Button("诊断网络") { model.showDiagnostics = true; NetworkDiagnosticsStore.shared.start() }
          }
          else {
            Button("硬盘健康") { model.deviceDetailsPage = "健康"; model.showDeviceDetails = true }
            StorageSpeedButton()
            Button("查看磁盘占用") { model.showDiskUsage = true; DiskUsageStore.shared.start() }
          }
        }.buttonStyle(AIControlButtonStyle(compact: true)).padding(.horizontal, 20)
      }
      if tab == .battery { PowerFlowView(power: s.power, groups: s.groups).padding(.horizontal, 20) }
      ProcessOutline(model: model)
    }.padding(.top, 20)
  }
  private var headline: String {
    switch tab {
    case .memory: Format.memory(s.usedMemory)
    case .disk: Format.rate(s.read)
    case .network: Format.networkRate(s.download)
    case .gpu: s.gpu.map { String(format: "%.0f %%", $0) } ?? "—"
    case .battery: s.battery.percent.map { String(format: "%.0f %%", $0) } ?? "—"
    default: String(format: "%.0f %%", s.cpu)
    }
  }
  private var subtitle: String {
    switch tab {
    case .memory: "已使用，共 \(Int(Double(s.totalMemory)/pow(1024,3))) GB"
    case .disk: "读取  ·  写入 \(Format.rate(s.write))"
    case .network: "下载  ·  上传 \(Format.networkRate(s.upload))"
    case .battery: s.battery.plugged ? "已接通电源" : "正在使用电池"
    default: SystemValue.chip
    }
  }
  private var scaleText: String {
    [.cpu, .gpu, .battery].contains(tab)
      ? "100%" : (tab == .memory ? Format.memory(s.totalMemory) : "实时速率")
  }
  private var secondaryValues: [Double] {
    switch tab {
    case .network: model.history.map(\.upload)
    case .disk: model.history.map(\.read)
    default: []
    }
  }
  @ViewBuilder private var sidePanel: some View {
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        if tab == .cpu {
          Text("内核").font(.system(size: 12)).foregroundStyle(.secondary)
          HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(s.coreUsage.enumerated()), id: \.offset) { i, value in
              VStack(spacing: 6) {
                GeometryReader { g in
                  ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(tab.color.opacity(0.14))
                    RoundedRectangle(cornerRadius: 4).fill(tab.color).frame(
                      height: max(2, g.size.height * value / 100))
                  }
                }
                Text(i < s.coreLabels.count ? s.coreLabels[i] : "\(i+1)").font(.system(size: 10))
                  .foregroundStyle(.tertiary)
              }
            }
          }.frame(height: 122)
          Text(s.clusterDescription).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(
            1
          ).minimumScaleFactor(0.7)
        } else if tab == .memory {
          Text("按类型").font(.system(size: 12)).foregroundStyle(.secondary)
          memoryBar
          ForEach(
            Array(
              [
                ("App", s.appMemory, Color.blue), ("联动", s.wired, Color.orange),
                ("被压缩", s.compressed, Color.green), ("已缓存", s.cached, Color.gray),
              ].enumerated()), id: \.offset
          ) { _, v in
            HStack {
              Circle().fill(v.2).frame(width: 6, height: 6)
              Text(v.0)
              Spacer()
              Text(Format.memory(v.1)).fontWeight(.medium)
            }.font(.system(size: 12))
          }
        } else if tab == .disk {
          Text("宗卷").font(.system(size: 12)).foregroundStyle(.secondary)
          ForEach(s.volumes.prefix(3)) { v in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Image(systemName: v.removable ? "externaldrive.fill" : "internaldrive.fill")
                  .foregroundStyle(tab.color)
                Text(v.name).fontWeight(.medium)
                Spacer()
                Text("\(Int((1-Double(v.free)/Double(v.total))*100))%")
              }.font(.system(size: 12))
              GaugeBar(value: 1 - Double(v.free) / Double(v.total), color: tab.color)
              Text("\(Format.bytes(v.free)) 可用，共 \(Format.bytes(v.total))").foregroundStyle(
                .secondary
              ).font(.system(size: 11))
            }
          }
          Spacer(minLength: 0)
        } else if tab == .gpu {
          Text("图形处理器").font(.system(size: 12)).foregroundStyle(.secondary)
          HStack {
            MetricIcon(symbol: tab.symbol, color: tab.color)
            Text(SystemValue.chip).fontWeight(.semibold)
          }.padding(.top, 8)
          Spacer()
          SmallStat(title: "GPU 内存", value: s.gpuMemory.map { Format.memory($0) } ?? "—")
          Text("统一内存 · 硬件计数器").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if tab == .battery {
          Text("电池状态").font(.system(size: 12)).foregroundStyle(.secondary)
          Image(systemName: s.battery.plugged ? "battery.100percent.bolt" : "battery.75percent")
            .font(.system(size: 48, weight: .light)).foregroundStyle(tab.color).padding(
              .vertical, 8)
          Text(s.battery.charging ? "正在充电" : (s.battery.plugged ? "由电源适配器供电" : "由电池供电")).font(
            .system(size: 13, weight: .medium))
          Text(s.battery.minutes.map { "预计剩余 \(Format.duration(Double($0*60)))" } ?? "剩余时间由系统估算")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          Text("下载和上传").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          HStack {
            MetricIcon(symbol: "arrow.down", color: tab.color)
            ValueText(text: Format.networkRate(s.download), size: 26)
          }
          HStack {
            MetricIcon(symbol: "arrow.up", color: .orange)
            ValueText(text: Format.networkRate(s.upload), size: 26)
          }
          Spacer()
        }
      }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 184)
    }
  }
  private var memoryBar: some View {
    GeometryReader { g in
      HStack(spacing: 1) {
        ForEach(
          Array(
            [(s.appMemory, Color.blue), (s.wired, Color.orange), (s.compressed, Color.green)]
              .enumerated()), id: \.offset
        ) { _, v in
          Rectangle().fill(v.1).frame(
            width: g.size.width * Double(v.0) / Double(max(s.totalMemory, 1)))
        }
        Spacer(minLength: 0)
      }.background(Color.secondary.opacity(0.12)).clipShape(Capsule())
    }.frame(height: 10).padding(.vertical, 4)
  }
  private var stats: [(String, String, String, String)] {
    let top = s.groups.max { a, b in
      func value(_ g: AppGroup) -> Double {
        switch tab {
        case .memory: Double(g.memory)
        case .disk: g.writeRate
        case .network: g.networkIn ?? -1
        default: g.cpu
        }
      }
      return value(a) < value(b)
    }
    let busiest = (
      "crown.fill", tab == .memory ? "占用最多的 App" : "最忙的 App", top?.name ?? "—",
      top.map { "\(Format.memory($0.memory)) · \($0.processes.count)个进程" } ?? ""
    )
    switch tab {
    case .memory:
      return [
        (
          "gauge.medium", "压力", s.pressureLevel < 2 ? "正常" : (s.pressureLevel < 4 ? "升高" : "紧张"),
          "系统报告的内存压力"
        ), ("memorychip", "可用", Format.memory(s.availableMemory), "空闲或可回收"),
        (
          "arrow.left.arrow.right", "已使用的交换", Format.memory(s.swap), s.swap == 0 ? "无需交换" : "磁盘交换空间"
        ), busiest,
      ]
    case .disk:
      return [
        ("arrow.down", "读取速度", Format.rate(s.read), "当前"),
        ("arrow.up", "写入速度", Format.rate(s.write), "当前"),
        ("internaldrive", "本次写入", Format.bytes(s.written), "从启动监测起累计"), busiest,
      ]
    case .network:
      return [
        ("arrow.down", "本次已下载", Format.bytes(s.received), "从启动监测起累计"),
        ("arrow.up", "本次已上传", Format.bytes(s.sent), "从启动监测起累计"),
        ("network", "网络采样", "\(Int(s.networkSampleInterval)) 秒", "App 网络速率刷新间隔"), busiest,
      ]
    case .gpu:
      return [
        ("memorychip", "GPU 内存", s.gpuMemory.map { Format.memory($0) } ?? "—", "已使用"),
        (
          "chart.xyaxis.line", "平均", Format.percent(model.history.compactMap(\.gpu).average),
          "当前窗口内"
        ),
        (
          "thermometer.medium", "温度",
          s.sensors.filter { $0.name.hasPrefix("GPU") }.map(\.value).average.map {
            Format.temperature($0)
          } ?? "—",
          "GPU 传感器均值"
        ), busiest,
      ]
    case .battery:
      return [
        (
          "bolt.fill", "耗电功率", s.battery.watts.map { String(format: "%.1f W", $0) } ?? "—",
          s.battery.plugged ? "由电源适配器供电" : "电池端测量"
        ), ("heart.fill", "最大容量", Format.percent(s.battery.health), "相对于全新时"),
        ("arrow.triangle.2.circlepath", "循环次数", s.battery.cycles.map(String.init) ?? "—", "完整充电次数"),
        (
          "thermometer.medium", "温度",
          s.battery.temperature.map { Format.temperature($0) } ?? "—", "电池温度"
        ),
      ]
    default:
      return [
        ("person.fill", "用户", Format.percent(s.user), "你的 App"),
        ("gearshape.2.fill", "系统", Format.percent(s.system), "macOS"),
        ("gauge.medium", "负载平均值", String(format: "%.2f", s.load), "共 \(s.coreUsage.count) 个内核"),
        (
          "thermometer.medium", "温度", s.temperature.map { Format.temperature($0) } ?? "—",
          s.fan.map { String(format: "风扇转速 %.0f rpm", $0) } ?? "传感器未提供"
        ),
        (
          "square.stack.3d.up.fill", "进程", String(s.processes.count),
          "分布在 \(s.groups.count) 个 App 中"
        ), busiest,
      ]
    }
  }
}
extension Array where Element == Double {
  var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

struct ProcessTable: View {
  @ObservedObject var model: MonitorModel
  @AppStorage("compact") var compact = false
  private var extras: [String] {
    switch model.tab {
    case .disk: ["写入", "读取"]
    case .network: ["下载", "上传"]
    case .gpu: ["GPU"]
    case .battery: ["唤醒/s"]
    default: []
    }
  }
  private var columns: [String] { extras + ["CPU", "内存", "进程"] }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        header("名称").frame(maxWidth: .infinity, alignment: .leading)
        ForEach(columns, id: \.self) { c in
          header(c).frame(width: columnWidth(c), alignment: .trailing)
        }
      }.padding(.horizontal, 8).padding(.vertical, 9)
      Divider()
      ScrollView {
        LazyVStack(spacing: 1) {
          ForEach(Array(model.sortedGroups().enumerated()), id: \.element.id) { i, g in
            VStack(spacing: 0) {
              HStack(spacing: 0) {
                Button {
                  if model.expanded.contains(g.id) {
                    model.expanded.remove(g.id)
                  } else {
                    model.expanded.insert(g.id)
                  }
                } label: {
                  Image(
                    systemName: model.expanded.contains(g.id) ? "chevron.down" : "chevron.right"
                  ).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(
                    width: 14)
                }.buttonStyle(.plain).accessibilityLabel("展开 \(g.name)")
                AppIcon(path: g.bundlePath).padding(.trailing, 8)
                Text(g.name).font(.system(size: 13)).lineLimit(1).frame(
                  maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { c in
                  metric(g, c).frame(width: columnWidth(c), alignment: .trailing)
                }
              }.padding(.horizontal, 8).frame(height: compact ? 25 : 31).contentShape(Rectangle())
                .onTapGesture { model.selection = g.id }
                .background(
                  model.selection == g.id
                    ? Theme.accent.opacity(0.18) : (i % 2 == 1 ? Theme.panel : Color.clear),
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .contextMenu {
                  Button("显示 App") { model.activate(g) }
                  Button("在 Finder 中显示") { model.reveal(g) }
                  Divider()
                  Button("退出 App…", role: .destructive) { model.quit(g) }.disabled(
                    g.id == "system.macos")
                }
              if model.expanded.contains(g.id) {
                ForEach(g.processes) { p in
                  HStack {
                    Text("\(p.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(
                      .tertiary
                    ).frame(width: 47, alignment: .trailing)
                    Text(p.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(p.measured ? String(format: "%.1f%%", p.cpu) : "—").frame(
                      width: 75, alignment: .trailing)
                    Text(p.measured ? Format.memory(p.memory) : "—").frame(
                      width: 100, alignment: .trailing)
                    Text("PID \(p.pid)").foregroundStyle(.tertiary).frame(
                      width: 70, alignment: .trailing)
                  }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 26).background(
                    Theme.panel.opacity(0.6))
                }
              }
            }
          }
        }.padding(.top, 3)
      }
    }
  }
  private func columnWidth(_ c: String) -> CGFloat {
    switch c {
    case "CPU": model.tab == .cpu ? 180 : 90
    case "内存": 125
    case "进程": 70
    default: 105
    }
  }
  private func header(_ c: String) -> some View {
    Button {
      model.sort(c)
    } label: {
      HStack(spacing: 5) {
        Text(c).font(.system(size: 12, weight: .medium))
        if model.sortColumn == c {
          Image(systemName: model.ascending ? "chevron.up" : "chevron.down").font(
            .system(size: 8, weight: .semibold))
        }
      }
    }.buttonStyle(.plain)
  }
  @ViewBuilder private func metric(_ g: AppGroup, _ column: String) -> some View {
    let measured = g.measuredCount > 0
    HStack(spacing: 10) {
      if column == "CPU", model.tab == .cpu {
        GaugeBar(
          value: g.cpu / max(100, model.snapshot.groups.map(\.cpu).max() ?? 100),
          color: model.tab.color
        ).frame(width: 44)
      }
      Text(value(g, column, measured: measured)).font(.system(size: 13, design: .rounded))
        .monospacedDigit().foregroundStyle(column == "进程" ? .secondary : .primary)
    }
  }
  private func value(_ g: AppGroup, _ c: String, measured: Bool) -> String {
    switch c {
    case "CPU": measured ? String(format: "%.1f%%", g.cpu) : "—"
    case "内存": measured ? Format.memory(g.memory) : "—"
    case "进程": String(g.processes.count)
    case "读取": measured ? Format.rate(g.readRate) : "—"
    case "写入": measured ? Format.rate(g.writeRate) : "—"
    case "下载": Format.networkRate(g.networkIn)
    case "上传": Format.networkRate(g.networkOut)
    case "唤醒/s": measured ? String(format: "%.0f", g.processes.reduce(0) { $0 + $1.wakeups }) : "—"
    default: "—"
    }
  }
}

struct AppInspector: View {
  @ObservedObject var model: MonitorModel
  let group: AppGroup
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Spacer()
        Button {
          model.selection = nil
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }.buttonStyle(.plain)
      }
      HStack(spacing: 10) {
        AppIcon(path: group.bundlePath, size: 40)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.name).font(.system(size: 17, weight: .semibold))
          Text("\(group.processes.count) 个进程").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      Divider()
      SmallStat(title: "CPU · 一个核心为 100%", value: String(format: "%.1f%%", group.cpu))
      SmallStat(title: "内存 · physical footprint", value: Format.memory(group.memory))
      HStack {
        SmallStat(title: "读取", value: Format.rate(group.readRate))
        SmallStat(title: "写入", value: Format.rate(group.writeRate))
      }
      HStack {
        SmallStat(title: "下载", value: Format.networkRate(group.networkIn))
        SmallStat(title: "上传", value: Format.networkRate(group.networkOut))
      }
      if let path = group.bundlePath {
        Text(path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if group.measuredCount < group.processes.count {
        Text("\(group.processes.count-group.measuredCount) 个进程受系统权限限制，未计入资源合计。").font(
          .system(size: 11)
        ).foregroundStyle(.orange)
      }
      Divider()
      Button("历史趋势") { model.appHistoryTarget = AppHistoryTarget(id: group.id, name: group.name) }
      Button("显示 App") { model.activate(group) }
      Button("在 Finder 中显示") { model.reveal(group) }.disabled(group.bundlePath == nil)
      Button("退出 App…", role: .destructive) { model.quit(group) }.disabled(
        group.id == "system.macos")
      Text(AdvisorStore.shared.baselineText(for: group)).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer()
    }.buttonStyle(AIControlButtonStyle()).padding(18).frame(width: 260).background(Theme.panel)
  }
}
