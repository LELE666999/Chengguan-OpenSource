import AppKit
import Combine
import SwiftUI

/// The menu panel keeps its own selection; browsing it never changes the main window.
struct MenuPanel: View {
  @ObservedObject var model: MonitorModel
  let open: () -> Void
  var pin: (() -> Void)? = nil
  @State private var tab: MonitorTab = .overview
  @ObservedObject private var displayControl = DisplayControlStore.shared
  @ObservedObject private var peripherals = Peripherals.shared
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @ObservedObject private var mixer = AppAudioMixer.shared
  @State private var hovered: MonitorTab?
  @AppStorage("appearance") private var appearance = "auto"
  @AppStorage("menuShowActivity") private var menuShowActivity = true
  @AppStorage("menuShowQuickTools") private var menuShowQuickTools = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme
  @Namespace private var selection
  @FocusState private var focused: Bool
  private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
  static var height: CGFloat { min(810, (NSScreen.main?.visibleFrame.height ?? 900) - 60) }
  private var s: MonitorSnapshot { model.snapshot }
  private var points: [HistoryPoint] { model.history.filter { $0.time > Date().addingTimeInterval(-300) } }
  private var connected: [BluetoothInfo] { peripherals.bluetooth.filter(\.connected) }
  var body: some View {
    VStack(spacing: 0) {
      navigation.padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 7)
      if ![.agents, .displays, .server].contains(tab) && (menuShowActivity || menuShowQuickTools) {
        LiveActivityPanel(model: model, compact: true, showActivities: menuShowActivity, showTools: menuShowQuickTools)
          .padding(.horizontal, 12).padding(.bottom, 8)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if ![.agents, .displays, .server].contains(tab) {
            HStack {
              Text(tab.title).font(.system(size: 12, weight: .medium))
              Spacer()
              if tab == .overview {
                Image(systemName: "clock").font(.system(size: 11))
                Text("已运行" + Format.duration(ProcessInfo.processInfo.systemUptime)).font(.system(size: 10))
              }
            }.foregroundStyle(.secondary).padding(.horizontal, 6).padding(.bottom, 1)
          }
          Group {
            if tab == .overview { overview }
            else if tab == .sound { sound }
            else if tab == .bluetooth { bluetooth }
            else if tab == .projects { projects }
            else if tab == .agents { agents }
            else if tab == .cables { CableMenuPage { id in model.cableSelection = id; model.select(.cables); open() } }
            else if tab == .nas { NASMenuPage { model.select(.nas); open() } }
            else if tab == .server { ServerWorkspace(compact: true) }
            else if tab == .displays { DisplayMenuPage { id in DisplayControlStore.shared.selected = id; model.select(.displays); open() } }
            else { metricDetail }
          }.id(tab).transition(.opacity)
        }.padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 28)
      }.id(tab).scrollIndicators(.never)
        // Fade clipped content into the fixed summary instead of cutting through a row.
        // Matching bottom padding keeps the last row fully visible at the scroll end.
        .overlay(alignment: .bottom) {
          LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                         startPoint: .top, endPoint: .bottom)
            .frame(height: 24).allowsHitTesting(false)
        }
      if ![.agents, .displays, .server].contains(tab) {
        AIQuickSummary(model: model, compact: true).padding(.horizontal, 12).padding(.top, 8)
      }
      footer
    }.frame(width: 426, height: Self.height)
      .foregroundStyle(scheme == .dark ? Color.white : Color.black)
      .background(Color(nsColor: .windowBackgroundColor))
      .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
      .tint(Theme.accent)
      .focusable().focusEffectDisabled().focused($focused)
      .onKeyPress(keys: [.tab], phases: .down) { key in
        let tabs = MonitorTab.menuTabs
        let delta = key.modifiers.contains(.shift) ? -1 : 1
        select(tabs[((tabs.firstIndex(of: tab) ?? 0) + delta + tabs.count) % tabs.count])
        return .handled
      }
      .onAppear { focused = true; peripherals.refreshAudio(); peripherals.refreshBluetooth() }
      .onChange(of: displayControl.enabled) { _, value in if !value && tab == .displays { select(.overview) } }
      .onReceive(refresh) { _ in peripherals.refreshAudio(); peripherals.refreshBluetooth() }
      .alert("App 混音", isPresented: Binding(get: { mixer.error != nil }, set: { if !$0 { mixer.error = nil } })) {
        Button("好") { mixer.error = nil }
      } message: { Text(mixer.error ?? "") }
  }
  private func select(_ value: MonitorTab) {
    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { tab = value }
  }
  private var navigation: some View {
    HStack(spacing: 1) {
      ForEach(MonitorTab.menuTabs) { item in
        Button { select(item) } label: {
          TabSymbol(tab: item, size: 15)
            .foregroundStyle(tab == item ? Theme.selectionForeground : Color.secondary)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background {
              if tab == item {
                RoundedRectangle(cornerRadius: 10).fill(item.color).matchedGeometryEffect(id: "menu-tab", in: selection)
              } else if hovered == item {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
              }
            }.contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(CareRowStyle()).help(item.title).accessibilityLabel(item.title)
          .modifier(MenuTabShortcut(key: item.shortcut))
          .onHover { hovered = $0 ? item : nil }
          .id(item)
      }
    }.padding(5).background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 15))
  }
  private var overview: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
        ForEach([MonitorTab.cpu, .memory, .network, .disk, .gpu, .battery, .agents, .sound, .bluetooth]) { item in
          Button { select(item) } label: { miniCard(item) }.buttonStyle(CareRowStyle())
        }
        ForEach(storage.volumes) { volume in ExternalStorageCard(volume: volume, compact: true) }
        NASSummaryCard(compact: true) { select(.nas) }
        ServerSummaryCard(compact: true) { select(.server) }
      }.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: storage.volumes.map(\.id))
      busiest
      if !model.insights.isEmpty {
        Panel(padding: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Label("值得关注", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            ForEach(model.insights, id: \.self) { Text($0).font(.system(size: 11)) }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
  private func miniCard(_ item: MonitorTab) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        TabSymbol(tab: item, size: 11).foregroundStyle(item.color)
        Text(item == .sound ? "音量" : item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      }
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        if item == .network { Image(systemName: "arrow.down").font(.system(size: 14)).foregroundStyle(.secondary) }
        ValueText(text: value(item), size: 26)
        Spacer(minLength: 1)
        Text(detail(item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65)
      }.frame(height: 28)
      Spacer(minLength: 1)
      if [.cpu, .memory, .network, .gpu].contains(item) {
        HistoryGraph(values: points.compactMap { $0.value(item) }, color: item.color,
                     ceiling: item == .memory ? Double(s.totalMemory) : [.cpu, .gpu].contains(item) ? 100 : nil)
          .frame(height: 15)
      } else {
        GaugeBar(value: fraction(item), color: item.color, height: 6)
      }
    }.padding(10).frame(maxWidth: .infinity).frame(height: 91)
      .background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 15))
      .contentShape(RoundedRectangle(cornerRadius: 15))
  }
  private func value(_ item: MonitorTab) -> String {
    switch item {
    case .cpu: return String(format: "%.0f %%", s.cpu)
    case .memory: return String(format: "%.1f GB", Double(s.usedMemory) / pow(1024, 3))
    case .gpu: return s.gpu.map { String(format: "%.0f %%", $0) } ?? "—"
    case .network: return Format.networkRate(s.download)
    case .disk: return s.primaryVolume.map { Format.bytes($0.free) } ?? "—"
    case .battery: return s.battery.percent.map { String(format: "%.0f %%", $0) } ?? "—"
    case .agents: return "\(s.agents.count) 个会话"
    case .sound: return String(format: "%.0f %%", peripherals.outputVolume)
    case .bluetooth: return "\(connected.count)"
    default: return "—"
    }
  }
  private func detail(_ item: MonitorTab) -> String {
    switch item {
    case .cpu: return String(format: "负载 %.1f", s.load)
    case .memory: return "共\(Int(Double(s.totalMemory) / pow(1024, 3))) GB"
    case .network: return "↑ " + Format.networkRate(s.upload)
    case .disk: return "可用"
    case .battery: return s.battery.plugged ? "已接通电源" : "电池供电"
    case .agents: return Format.memory(s.agents.reduce(UInt64(0)) { $0 + $1.process.memory })
    case .sound: return "\(peripherals.clients.filter(\.playing).count)个正在播放"
    case .bluetooth: return connected.first?.name ?? "没有已连接设备"
    default: return ""
    }
  }
  private func fraction(_ item: MonitorTab) -> Double {
    switch item {
    case .disk: return s.primaryVolume.map { 1 - Double($0.free) / Double(max(1, $0.total)) } ?? 0
    case .battery: return (s.battery.percent ?? 0) / 100
    case .sound: return peripherals.outputVolume / 100
    case .agents: return Double(s.agents.count) / 100
    case .bluetooth: return Double(connected.count) / 100
    default: return 0
    }
  }
  private var busiest: some View {
    Panel(padding: 18, background: Theme.menuCard) {
      VStack(alignment: .leading, spacing: 12) {
        Text("当前最忙").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        let groups = s.groups.sorted { $0.cpu > $1.cpu }
        ForEach(groups.prefix(3)) { group in
          Button { show(group, metric: .cpu) } label: {
            HStack(spacing: 10) {
              AppIcon(path: group.bundlePath, size: 17)
              Text(group.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
              Spacer()
              GaugeBar(value: group.cpu / max(1, groups.first?.cpu ?? 1), color: MonitorTab.cpu.color).frame(width: 57)
              Text(Format.appCPU(group.cpu)).font(Theme.number(14)).frame(width: 72, alignment: .trailing)
            }.frame(height: 18)
          }.buttonStyle(.plain)
        }
      }
    }
  }
  private var metricDetail: some View {
    VStack(alignment: .leading, spacing: 14) {
      Panel(padding: 14) {
        VStack(alignment: .leading, spacing: 12) {
          HStack { ValueText(text: value(tab), size: 35); Spacer(); Text(detail(tab)).font(.system(size: 12)).foregroundStyle(.secondary) }
          HistoryGraph(values: points.compactMap { $0.value(tab) }, color: tab.color,
                       ceiling: [.cpu, .gpu, .battery].contains(tab) ? 100 : tab == .memory ? Double(s.totalMemory) : nil,
                       bars: model.bars).frame(height: 60)
          HStack {
            if tab == .cpu {
              SmallStat(title: "用户", value: Format.percent(s.user)); SmallStat(title: "系统", value: Format.percent(s.system))
              SmallStat(title: "温度", value: s.temperature.map(Format.temperature) ?? "—")
            } else if tab == .memory {
              SmallStat(title: "App", value: Format.memory(s.appMemory), color: .blue)
              SmallStat(title: "联动", value: Format.memory(s.wired), color: .orange)
              SmallStat(title: "被压缩", value: Format.memory(s.compressed), color: .green)
            } else if tab == .network {
              SmallStat(title: "下载", value: Format.networkRate(s.download)); SmallStat(title: "上传", value: Format.networkRate(s.upload))
            } else if tab == .disk {
              SmallStat(title: "读取", value: Format.rate(s.read)); SmallStat(title: "写入", value: Format.rate(s.write))
            } else if tab == .gpu {
              SmallStat(title: "内存", value: s.gpuMemory.map { Format.memory($0) } ?? "—")
              SmallStat(title: "芯片", value: SystemValue.chip)
            } else {
              SmallStat(title: "健康度", value: Format.percent(s.battery.health))
              SmallStat(title: "循环次数", value: s.battery.cycles.map(String.init) ?? "—")
              SmallStat(title: "功率", value: s.battery.watts.map { String(format: "%.1f W", $0) } ?? "—")
            }
          }
        }
      }
      if tab == .battery { PowerFlowView(power: s.power, compact: true, groups: s.groups) }
      if tab == .cpu {
        Panel(padding: 12) {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
            ForEach(Array(s.coreUsage.enumerated()), id: \.offset) { i, v in
              VStack(spacing: 5) {
                Text("\(i+1)").font(.system(size: 10)).foregroundStyle(.secondary)
                GaugeBar(value: v / 100, color: tab.color)
                Text(Format.percent(v)).font(Theme.number(11))
              }
            }
          }
        }
      }
      if tab == .disk {
        ForEach(s.volumes) { volume in
          Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
              Label(volume.name, systemImage: volume.removable ? "externaldrive.fill" : "internaldrive.fill")
              GaugeBar(value: 1 - Double(volume.free) / Double(max(1, volume.total)), color: tab.color)
              Text("\(Format.bytes(volume.free))可用，共\(Format.bytes(volume.total))").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      if tab == .network {
        Panel(padding: 14, background: Theme.menuCard) { LocalAddressView(network: s.localNetwork, compact: true) }
      }
      if [.cpu, .disk, .network].contains(tab) {
        Button {
          model.deviceDetailsPage = tab == .network ? "网络" : tab == .disk ? "健康" : "硬件"
          open()
          DispatchQueue.main.async { model.showDeviceDetails = true }
        } label: {
          HStack {
            Label(tab == .network ? "网卡与连接" : tab == .disk ? "硬盘健康" : "核心与传感器", systemImage: tab == .network ? "network" : tab == .disk ? "checkmark.shield" : "cpu")
            Spacer(); Image(systemName: "arrow.up.right")
          }.font(.system(size: 12, weight: .medium)).padding(12).frame(maxWidth: .infinity)
            .background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 12)).contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(CareRowStyle())
      }
      appList
    }
  }
  private var appList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack { Text("App"); Spacer(); Text(tab == .memory ? "内存" : tab == .network ? "下载" : tab == .disk ? "写入" : "CPU") }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 7)
      ForEach(s.groups.sorted { appValue($0) > appValue($1) }.prefix(12)) { group in
        Button { show(group, metric: tab) } label: {
          HStack(spacing: 9) {
            AppIcon(path: group.bundlePath, size: 18)
            Text(group.name).lineLimit(1)
            Spacer()
            Text(tab == .memory ? Format.memory(group.memory) : tab == .network ? Format.networkRate(group.networkIn) : tab == .disk ? Format.rate(group.writeRate) : Format.appCPU(group.cpu)).font(Theme.number(12))
          }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.bottom, 3)
      }
    }
  }
  private func appValue(_ group: AppGroup) -> Double {
    tab == .memory ? Double(group.memory) : tab == .network ? group.networkIn ?? 0 : tab == .disk ? group.writeRate : group.cpu
  }
  private var sound: some View {
    VStack(spacing: 12) {
      ForEach([false, true], id: \.self) { input in
        Panel(padding: 14) {
          VStack(alignment: .leading, spacing: 10) {
            Label(input ? "输入" : "输出", systemImage: input ? "mic.fill" : "speaker.wave.2.fill").foregroundStyle(MonitorTab.sound.color)
            Picker(input ? "输入设备" : "输出设备", selection: Binding(get: { input ? peripherals.input : peripherals.output }, set: { peripherals.selectDevice($0, input: input) })) {
              ForEach(peripherals.devices.filter { input ? $0.input : $0.output }) { d in Text(d.name).tag(d.id) }
            }.labelsHidden()
            HStack {
              Image(systemName: input ? "mic.fill" : "speaker.wave.2.fill").foregroundStyle(.secondary)
              Slider(value: Binding(get: { input ? peripherals.inputVolume : peripherals.outputVolume }, set: { peripherals.setVolume($0, input: input) }), in: 0...100)
                .tint(MonitorTab.sound.color).disabled(input ? !peripherals.inputWritable : !peripherals.outputWritable)
              Text(Format.percent(input ? peripherals.inputVolume : peripherals.outputVolume)).font(Theme.number(12)).frame(width: 36)
            }
          }
        }
      }
      ForEach(AudioAppRow.collect(peripherals.clients, snapshot: s)) { row in
        VStack(spacing: 7) {
          HStack(spacing: 8) {
            AppIcon(path: row.path, size: 17)
            Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
            if row.playing { Image(systemName: "waveform").foregroundStyle(MonitorTab.sound.color) }
          }
          AppVolumeControl(row: row, output: peripherals.output)
        }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }
  private var bluetooth: some View {
    VStack(spacing: 8) {
      ForEach(connected) { device in
        Panel(padding: 14) {
          HStack(spacing: 12) {
            Image(systemName: device.symbol).font(.system(size: 24)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 5) {
              Text(device.name).font(.system(size: 13, weight: .medium))
              Text("\(device.kind) · 已连接").font(.system(size: 11)).foregroundStyle(.secondary)
            }; Spacer()
            BluetoothBatteryLabel(batteries: device.batteries, compact: true)
          }
        }
      }
      if connected.isEmpty { Text(peripherals.bluetoothLoading ? "正在读取设备…" : "没有已连接的蓝牙设备").foregroundStyle(.secondary).padding(20) }
      Button("蓝牙设置…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }.padding(8)
    }
  }
  private var projects: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(s.projects.count)个项目正在运行").font(Theme.number(25)).padding(8)
      ForEach(s.projects) { project in
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) } label: {
          Panel(padding: 14) {
            HStack {
              Image(systemName: "folder.fill").foregroundStyle(MonitorTab.projects.color)
              VStack(alignment: .leading, spacing: 5) {
                Text(project.name).font(.system(size: 13, weight: .semibold))
                Text(project.ports.map { ":\($0)" }.joined(separator: "  ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
              }; Spacer()
              Text(Format.memory(project.memory)).font(Theme.number(13))
            }
          }
        }.buttonStyle(.plain)
      }
    }
  }
  private var agents: some View {
    AIUsagePanel(model: model, compact: true, open: open)
  }
  private var footer: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        Label("打开澄观", systemImage: "macwindow")
          .frame(maxWidth: .infinity).frame(height: 34)
      }.buttonStyle(MenuFooterButtonStyle()).help("打开澄观窗口")
      Button { model.presentSettings() } label: {
        Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34)
      }.buttonStyle(MenuFooterButtonStyle()).help("设置").accessibilityLabel("设置")
      Button { NSApp.terminate(nil) } label: {
        Label("退出", systemImage: "power").frame(width: 74, height: 34)
      }.buttonStyle(MenuFooterButtonStyle()).help("退出澄观").accessibilityLabel("退出澄观")
    }.font(.system(size: 13, weight: .semibold)).labelStyle(.titleAndIcon)
      .padding(.horizontal, 12).padding(.vertical, 10)
      .contextMenu {
        Button(model.paused ? "继续采样" : "暂停采样", systemImage: model.paused ? "play" : "pause") { model.setPaused(!model.paused) }
        if let pin { Button("固定速览面板", systemImage: "pin", action: pin) }
        Button("导出历史CSV…", systemImage: "square.and.arrow.up", action: model.exportCSV)
      }
  }
  private func show(_ group: AppGroup, metric: MonitorTab) { model.select(metric); model.selection = group.id; open() }
}

private struct MenuFooterButtonStyle: ButtonStyle {
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.primary)
      .background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.055 : 0)))
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .onHover { hovered = $0 }
  }
}

private struct MenuTabShortcut: ViewModifier {
  let key: String?
  @ViewBuilder func body(content: Content) -> some View {
    if let key { content.keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .command) }
    else { content }
  }
}
