import AppKit
import SwiftUI
import UserNotifications
import DisplayBridge

@main enum Launcher {
  static func main() {
    if CommandLine.arguments.contains("--server-network-check-json") {
      let monitor = ServerMonitor.shared
      monitor.refresh()
      let deadline = Date().addingTimeInterval(70)
      while monitor.loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      let proxy = MacProxyMonitor.shared; proxy.show()
      let proxyDeadline = Date().addingTimeInterval(8)
      while Date() < proxyDeadline && (proxy.snapshot == nil || proxy.upload == nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      let diagnostics = ServerConnectionDiagnostics.shared
      diagnostics.observe(addresses: monitor.snapshot?.addresses ?? [], fallback: monitor.profile?.host, port: monitor.snapshot?.sshPort)
      let lookupDeadline = Date().addingTimeInterval(10)
      while (diagnostics.lookingUp || diagnostics.probing) && Date() < lookupDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      // Credentials, IP addresses and destination metadata are excluded from diagnostic output.
      let stats = monitor.snapshot?.network
      let output: [String: Any] = ["server_connected": monitor.snapshot != nil, "server_error": monitor.error as Any? ?? NSNull(),
        "server_samples": stats?.samples.count ?? 0, "server_interval_s": stats?.interval as Any? ?? NSNull(),
        "server_upload_Bps": stats?.upload as Any? ?? NSNull(), "server_download_Bps": stats?.download as Any? ?? NSNull(),
        "server_sample_time": stats?.latest?.time.timeIntervalSince1970 as Any? ?? NSNull(),
        "proxy_connected": proxy.snapshot != nil, "proxy_source": proxy.source as Any? ?? NSNull(), "proxy_version": proxy.version as Any? ?? NSNull(),
        "proxy_upload_Bps": proxy.upload as Any? ?? NSNull(), "proxy_download_Bps": proxy.download as Any? ?? NSNull(),
        "proxy_upload_total": proxy.snapshot?.uploadTotal as Any? ?? NSNull(), "proxy_download_total": proxy.snapshot?.downloadTotal as Any? ?? NSNull(),
        "proxy_connections": proxy.snapshot?.connections as Any? ?? NSNull(), "proxy_memory": proxy.snapshot?.memory as Any? ?? NSNull(),
        "ip_lookup_ok": diagnostics.info != nil, "tcp_ms": diagnostics.latency as Any? ?? NSNull()]
      if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      proxy.stop(); monitor.stop(); diagnostics.clear()
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--import-server-profile"), CommandLine.arguments.count > index + 1 {
      do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let profile = try JSONDecoder().decode(ServerProfile.self, from: data)
        guard profile.valid else { throw ServerError.profile }
        UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: ServerProfile.storageKey)
        print("Server profile imported; API Key must be entered in the application.")
      } catch { print("Server profile import failed."); exit(1) }
      return
    }
    if CommandLine.arguments.contains("--disable-display-control") {
      UserDefaults.standard.set(false, forKey: "displayControlEnabled")
      print("Display control disabled."); return
    }
    if CommandLine.arguments.contains("--energy-channels-json") {
      let reader = ChipEnergyReader(); _ = reader.read(); Thread.sleep(forTimeInterval: 2); _ = reader.read()
      if let data = try? JSONSerialization.data(withJSONObject: reader.observedChannels, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--smc-power-json") {
      let smc = SMC()
      let values = ["PPMC", "PCPT", "PCPC", "PC0C", "PG0R", "PM0R", "PSTR", "PDTR", "PDBR"].map { key in
        ["key": key, "watts": smc.getValue(key) as Any? ?? NSNull()] as [String: Any]
      }
      if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--power-json") {
      let collector = SystemCollector()
      _ = collector.sample()
      Thread.sleep(forTimeInterval: 6)
      let snapshot = collector.sample(), power = snapshot.power
      let output: [String: Any] = ["system_watts": power.system as Any? ?? NSNull(),
        "adapter_watts": power.adapter as Any? ?? NSNull(), "battery_watts_signed": power.battery as Any? ?? NSNull(),
        "components": power.components.map { ["name": $0.id, "watts": $0.watts] as [String: Any] },
        "apps": snapshot.groups.compactMap { app -> [String: Any]? in
          app.powerWatts.map { ["name": app.name, "watts": $0] }
        }.sorted { ($0["watts"] as? Double ?? 0) > ($1["watts"] as? Double ?? 0) }.prefix(5).map { $0 }]
      if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--default-apps-json") {
      let system = MacDefaultAppsSystem()
      let values: [[String: Any]] = DefaultOpenItem.builtIn.map { item in
        ["id": item.id, "title": item.title, "targets": item.targets.map { target in
          ["type": target.name, "application": system.current(target)?.path as Any? ?? NSNull()] as [String: Any]
        }]
      }
      if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--displays-json") {
      let displays = DisplayReader.read()
      if let data = try? JSONEncoder().encode(displays) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--display-memory-json") {
      let memory = DisplayModeMemoryController()
      if let data = try? JSONEncoder().encode(memory.profiles) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--display-ddc-json") {
      var output: [[String: Any]] = []
      for d in DisplayReader.read() where !d.virtual {
        var values: [String: Any] = [:]
        for code: UInt8 in [0x10, 0x62, 0x12] {
          var value: UInt16 = 0, maximum: UInt16 = 0
          let status = cd_ddc_read(d.displayID, d.id, code, &value, &maximum)
          values[String(format: "%02X", code)] = ["status": status, "current": value, "maximum": maximum]
        }
        output.append(["name": d.name, "uuid": d.id, "values": values])
      }
      if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--device-health-json") {
      let report = DeviceHealthReader.read()
      let output: [String: Any] = ["checks": report.checks.map { ["id": $0.id, "state": $0.state.rawValue] },
        "disks": report.disks.map { ["id": $0.id, "smart": $0.smart as Any? ?? NSNull(), "temperature": $0.temperature as Any? ?? NSNull(),
          "wear": $0.wear as Any? ?? NSNull(), "read_bytes": $0.readBytes as Any? ?? NSNull(), "written_bytes": $0.writtenBytes as Any? ?? NSNull()] }]
      if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments.contains("--storage-json") {
      let result = ExternalStorageReader.withContentHints(ExternalStorageReader.read())
      if let data = try? JSONEncoder().encode(result), let text = String(data: data, encoding: .utf8) { print(text) }
      return
    }
    if CommandLine.arguments.contains("--cables-json") {
      if let data = try? JSONEncoder().encode(CableReader.read()), let text = String(data: data, encoding: .utf8) { print(text) }
      return
    }
    if CommandLine.arguments.contains("--benchmark-json") {
      let collector = SystemCollector()
      if CommandLine.arguments.contains("--background") { collector.policy = CollectionPolicy(visible: false) }
      CollectorBenchmark.run(collector); return
    }
    if CommandLine.arguments.contains("--audio-tone") { AudioSmoke.tone(); return }
    if CommandLine.arguments.contains("--schedule-audio-smoke") {
      UserDefaults.standard.set(true, forKey: "runAudioSmokeOnce")
      print("Audio diagnostics scheduled for the next normal app launch.")
      return
    }
    if CommandLine.arguments.contains("--usage-json") || CommandLine.arguments.contains("--usage-local-json") {
      UserDefaults.standard.register(defaults: ["aiUsageEnabled": true])
      let store = AIUsageStore.shared
      store.refresh(force: true, localOnly: CommandLine.arguments.contains("--usage-local-json"))
      let deadline = Date().addingTimeInterval(180)
      while store.loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
      let output: [String: Any] = ["complete": !store.loading, "providers": store.providers.map { provider in
        ["name": provider.id, "today_tokens": provider.tokenCountsAvailable ? provider.today as Any : NSNull(),
         "week_tokens": provider.tokenCountsAvailable ? provider.week as Any : NSNull(),
         "month_tokens": provider.tokenCountsAvailable ? provider.month as Any : NSNull(),
         "models": provider.models.map { ["name": $0.id, "tokens": $0.total] as [String: Any] },
         "source": provider.source, "stale": provider.stale(), "unavailable": provider.unavailable as Any? ?? NSNull(),
         "subscription": AISubscriptionStore.shared.value(for: provider).map {
           ["kind": $0.kind.rawValue, "date": $0.date.timeIntervalSince1970, "source": $0.source, "date_only": $0.dateOnly] as [String: Any]
         } as Any? ?? NSNull(),
         "limits": provider.limits.map { ["name": $0.name, "updated": $0.time.timeIntervalSince1970,
            "windows": $0.windows.map { ["used_percent": $0.used, "minutes": $0.minutes, "resets": $0.resets?.timeIntervalSince1970 as Any? ?? NSNull()] }] }] as [String: Any]
      }]
      if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
      return
    }
    if CommandLine.arguments.contains("--sample-json") {
      let collector = SystemCollector()
      _ = collector.sample()
      Thread.sleep(forTimeInterval: 1)
      let s = collector.sample()
      let output: [String: Any] = [
        "time": ISO8601DateFormatter().string(from: s.time), "chip": SystemValue.chip,
        "cpu_percent": s.cpu,
        "memory_used_bytes": s.usedMemory, "memory_total_bytes": s.totalMemory,
        "gpu_percent": s.gpu as Any? ?? NSNull(),
        "core_labels": s.coreLabels, "temperature_c": s.temperature as Any? ?? NSNull(),
        "fan_rpm": s.fan as Any? ?? NSNull(),
        "download_bytes_s": s.download, "upload_bytes_s": s.upload, "disk_read_bytes_s": s.read,
        "disk_write_bytes_s": s.write,
        "process_count": s.processes.count, "unmeasured_processes": s.unmeasured,
        "permission_denied_processes": s.processes.filter { !$0.measured && [EPERM, EACCES].contains($0.measurementError) }.count,
        "local_ipv4": s.localNetwork.addresses.map { ["interface": $0.interface, "address": $0.address] },
        "primary_local_ipv4": s.localNetwork.primary?.address as Any? ?? NSNull(),
        "sampling_duration_ms": s.samplingDuration * 1000,
        "projects": s.projects.map {
          [
            "name": $0.name, "path": $0.path, "ports": $0.ports,
            "process_count": $0.processes.count,
          ] as [String: Any]
        },
        "apps": s.groups.map {
          [
            "name": $0.name, "cpu_percent": $0.cpu, "memory_bytes": $0.memory,
            "process_count": $0.processes.count, "measured_processes": $0.measuredCount,
          ] as [String: Any]
        },
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
        let json = String(data: data, encoding: .utf8)
      {
        print(json)
      }
      return
    }
    VitalsApplication.main()
  }
}

struct VitalsApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = MonitorModel()
  var body: some Scene {
    WindowGroup("澄观", id: "main") {
      RootView(model: model).background(WindowConfigurator(model: model, delegate: delegate))
    }.defaultSize(width: 1300, height: 800).windowStyle(.hiddenTitleBar).windowToolbarStyle(
      .unified
    )
    .commands {
      CommandGroup(replacing: .appSettings) { SettingsLink { Text("设置…") }.keyboardShortcut(",") }
      CommandMenu("监测") {
        ForEach(MonitorTab.allCases.filter { $0.shortcut != nil }) { tab in
          Button(tab.title) { model.select(tab) }.keyboardShortcut(
            KeyEquivalent(Character(tab.shortcut!)), modifiers: .command)
        }
        Divider()
        Button("打开下拉面板") { delegate.togglePopover() }.keyboardShortcut(
          "m", modifiers: [.command, .shift])
        Button(model.paused ? "继续采样" : "暂停采样") { model.setPaused(!model.paused) }
        Button("导出历史 CSV…", action: model.exportCSV)
        Button("设备健康与硬件详情…") { model.deviceDetailsPage = "健康"; model.showDeviceDetails = true }
        Divider()
        Button("整理空间") { model.presentCare() }.keyboardShortcut("k", modifiers: [.command, .shift])
        Button("默认打开…") { model.select(.defaultApps) }
      }
    }
    Settings { ReplicaSettings(model: model) }.windowStyle(.hiddenTitleBar)
  }
}

struct RootView: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var displayControl = DisplayControlStore.shared
  @Environment(\.openSettings) private var openSettings
  @AppStorage("appearance") private var appearance = "auto"
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Namespace private var navigation
  @State private var showExport = false
  @State private var showLayout = false
  @State private var hoveredTab: MonitorTab?
  @State private var showProcessAccess = false
  @State private var careProtectionOpen = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Group {
          if model.carePage != nil {
            CareWorkspace(model: model)
          } else if model.tab == .overview {
            DashboardView(model: model)
          } else if model.tab.isProcessTab {
            ProcessView(model: model)
          } else if model.tab == .projects {
            ProjectsView(model: model)
          } else if model.tab == .agents {
            AgentsView(model: model)
          } else if model.tab == .sound {
            SoundView(model: model)
          } else if model.tab == .cables {
            CableWorkspace(selected: $model.cableSelection)
          } else if model.tab == .nas {
            NASWorkspace()
          } else if model.tab == .server {
            ServerWorkspace()
          } else if model.tab == .displays {
            DisplayWorkspace()
          } else if model.tab == .defaultApps {
            DefaultAppsWorkspace()
          } else {
            BluetoothView(model: model)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        if model.tab.isProcessTab, let group = model.selectedGroup {
          Divider()
          AppInspector(model: model, group: group).transition(
            .move(edge: .trailing).combined(with: .opacity))
        }
      }
      Divider()
      if ![.agents, .defaultApps, .server].contains(model.tab) || model.carePage != nil { AIStatusStrip(model: model) }
      footer
    }.frame(minWidth: 1120, minHeight: 690).background(Color(nsColor: .windowBackgroundColor))
      .toolbar { toolbarContent }
      .toolbarBackground(.hidden, for: .windowToolbar)
      .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
      .tint(Theme.accent)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.selection)
      .sheet(isPresented: $model.showAIAnalysis) { AIAnalysisWorkspace(model: model) }
      .sheet(item: $model.appHistoryTarget) { target in AppHistoryView(model: model, target: target) }
      .sheet(isPresented: $model.showDiagnostics) { NetworkDiagnosticsView() }
      .sheet(isPresented: $model.showDiskUsage) { DiskUsageView() }
      .sheet(isPresented: $model.showDeviceDetails) { DeviceDetailsView(model: model) }
      .onChange(of: model.settingsRequest) { _, _ in openSettings() }
      .onChange(of: displayControl.enabled) { _, value in if !value && model.tab == .displays { model.select(.overview) } }
      .alert(
        "澄观",
        isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
      ) {
        Button("好") { model.notice = nil }
      } message: {
        Text(model.notice ?? "")
      }
  }
  private var brand: some View {
    WorkspaceModeControl(model: model)
  }
  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .navigation) { brand }.sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .navigation) { brand }
    }
    ToolbarItem(placement: .principal) {
      if model.carePage == nil { tabNavigation }
      else { CareNavigation(model: model) }
    }
    if #available(macOS 26.0, *) {
      toolbarActions.sharedBackgroundVisibility(.hidden)
    } else {
      toolbarActions
    }
  }
  @ToolbarContentBuilder private var toolbarActions: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if model.carePage == nil && (model.tab.isProcessTab || [.sound, .bluetooth].contains(model.tab)) {
        Button {
          showLayout.toggle()
        } label: {
          Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30).contentShape(Circle())
        }.buttonStyle(GlassCircleButtonStyle()).help("排列").popover(isPresented: $showLayout) { OverviewLayoutPopover(model: model) }
        HStack(spacing: 5) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("过滤App", text: $model.search).textFieldStyle(.plain)
        }.font(.system(size: 12)).padding(.horizontal, 9).frame(width: 154, height: 26)
          .background(.quaternary.opacity(0.45), in: Capsule())
          .help("仅显示名称包含此内容的App（⌘F）")
      } else if model.carePage == nil && model.tab == .overview {
        ChartStyleControl(bars: $model.bars)
        Button {
          showExport.toggle()
        } label: {
          Image(systemName: "square.and.arrow.up").frame(width: 30, height: 30).contentShape(Circle())
        }.buttonStyle(GlassCircleButtonStyle()).help("将图表导出为图像，或将历史记录导出为CSV").popover(isPresented: $showExport, arrowEdge: .bottom) {
          ExportPopover(model: model)
        }
        Button {
          showLayout.toggle()
        } label: {
          Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30).contentShape(Circle())
        }.buttonStyle(GlassCircleButtonStyle()).help("自定概览").popover(isPresented: $showLayout, arrowEdge: .bottom) {
          OverviewLayoutPopover(model: model)
        }
      }
      if model.carePage != nil {
        Button { careProtectionOpen = true } label: { Image(systemName: "shield").frame(width: 30, height: 30).contentShape(Circle()) }
          .buttonStyle(GlassCircleButtonStyle()).help("保护名单").popover(isPresented: $careProtectionOpen) { CareProtectionList() }
      }
      Button { openSettings() } label: { Image(systemName: "gearshape.fill").frame(width: 30, height: 30).contentShape(Circle()) }
        .buttonStyle(GlassCircleButtonStyle()).help("设置").accessibilityLabel("设置")
    }
  }
  private var tabNavigation: some View {
    HStack(spacing: 2) {
      ForEach(MonitorTab.visibleTabs) { tab in
        Button {
          withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            model.select(tab)
          }
        } label: {
          HStack(spacing: 8) {
            TabSymbol(tab: tab, size: 15)
            if model.tab == tab && model.carePage == nil {
              Text(tab.title).font(.system(size: 13, weight: .semibold)).fixedSize().transition(
                .opacity)
            }
          }.foregroundStyle(model.tab == tab && model.carePage == nil ? tab.color : .secondary).padding(
            .horizontal, model.tab == tab && model.carePage == nil ? 16 : 9
          ).frame(height: 28).contentShape(Capsule()).background {
            if model.tab == tab && model.carePage == nil {
              Capsule().fill(tab.color.opacity(0.13)).matchedGeometryEffect(
                id: "tab", in: navigation)
            } else if hoveredTab == tab {
              Capsule().fill(.quaternary.opacity(0.5))
            }
          }
        }.buttonStyle(CareRowStyle()).help(tab.title + (tab.shortcut.map { " (⌘\($0))" } ?? ""))
          .accessibilityLabel(tab.title)
          .onHover { hoveredTab = $0 ? tab : nil }
      }
    }.padding(4).modifier(NavigationGlass())
  }
  private var footer: some View {
    HStack {
      Text("\(model.snapshot.groups.count)个App  ·  \(model.snapshot.processes.count)个进程")
      if model.paused { Text("采样已暂停").foregroundStyle(.orange) }
      Spacer()
      if model.snapshot.unmeasured > 0 {
        Button { showProcessAccess.toggle() } label: {
          Label("\(model.snapshot.unmeasured)个进程的详细指标受系统限制", systemImage: "info.circle")
        }.buttonStyle(.plain).lineLimit(1).help("查看测量范围及受限进程；整机统计仍包含这些进程")
          .popover(isPresented: $showProcessAccess, arrowEdge: .top) { ProcessAccessView(snapshot: model.snapshot) }
      }
    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
  }
}

struct WindowConfigurator: NSViewRepresentable {
  let model: MonitorModel, delegate: AppDelegate
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    DispatchQueue.main.async {
      if let w = v.window {
        w.identifier = NSUserInterfaceItemIdentifier("replica-main")
        w.title = "澄观"
        w.toolbarStyle = .unified
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 1120, height: 690)
        w.setFrameAutosaveName("VitalsReplicaMain")
        if UserDefaults.standard.integer(forKey:"uiGeometryVersion")<2 {
          var frame=w.frame;frame.size=NSSize(width:1300,height:800);w.setFrame(frame,display:true)
          UserDefaults.standard.set(2,forKey:"uiGeometryVersion")
        }
        w.isMovableByWindowBackground = true
        w.level = UserDefaults.standard.bool(forKey: "floating") ? .floating : .normal
        delegate.configure(model: model, window: w)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    return v
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var status: NSStatusItem?
  private var popover: NSPopover?
  private var quickWindow: NSPanel?
  private var lastStatusRender: MenuBarRenderKey?
  private var hoverPresenter: MenuHoverPresenter?
  private weak var mainWindow: NSWindow?
  private weak var model: MonitorModel?
  func applicationWillTerminate(_ notification: Notification) { StorageSpeedStore.shared.cancel(); AppAudioMixer.shared.reset(); LiveActivity.shared.end(); CableMonitor.shared.stop(); ExternalStorageMonitor.shared.stop(); NASMonitor.shared.stop(); LegacyNASMonitor.shared.stop(); ServerMonitor.shared.stop(); MacProxyMonitor.shared.stop(); ServerConnectionDiagnostics.shared.clear() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard StorageFormatStore.shared.running else { return .terminateNow }
    let alert = NSAlert(); alert.messageText = "格式化正在进行"
    alert.informativeText = "请保持存储连接，格式化完成后再退出澄观。"; alert.addButton(withTitle: "好"); alert.runModal()
    return .terminateCancel
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func configure(model: MonitorModel, window: NSWindow) {
    // Refresh stale Dock/LaunchServices icons using the user's compiled Icon Composer asset.
    if let icon = Bundle.main.url(forResource: "ChengguanUserIcon", withExtension: "icns"), let data = try? Data(contentsOf: icon), let image = NSImage(data: data) {
      NSImage(named: NSImage.applicationIconName)?.setName(nil)
      image.setName(NSImage.applicationIconName)
      NSApp.applicationIconImage = image
    }
    mainWindow = window
    self.model = model
    DispatchQueue.main.async {
      LiveActivity.shared.start(model: model)
      CableMonitor.shared.start()
      ExternalStorageMonitor.shared.start()
      NASMonitor.shared.start()
      LegacyNASMonitor.shared.start()
      ServerMonitor.shared.start()
      // Mode memory must run while the app lives in the menu bar, even when its
      // display page has never been opened during this launch.
      _ = DisplayControlStore.shared
      LiveActivity.shared.onChange = { [weak owner = self, weak monitor = model] in
        if let monitor { owner?.updateStatus(monitor.snapshot) }
      }
    }
    model.onShowMain = { [weak self] in self?.showMain() }
    guard status == nil else { return }
    UNUserNotificationCenter.current().delegate = self
    if UserDefaults.standard.bool(forKey: "runAudioSmokeOnce") {
      UserDefaults.standard.removeObject(forKey: "runAudioSmokeOnce")
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chengguan", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      DispatchQueue.global(qos: .userInitiated).async {
        AudioSmoke.run(reportURL: directory.appendingPathComponent("audio-diagnostic.json"))
      }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status = item
    item.button?.target = self
    item.button?.action = #selector(togglePopover)
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.button?.image = NSImage(
      systemSymbolName: "waveform.path.ecg", accessibilityDescription: "澄观")
    item.button?.imagePosition = .imageLeading
    item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    item.button?.contentTintColor = .white
    DispatchQueue.main.async { [weak self, weak model] in
      if let model { self?.updateStatus(model.snapshot) }
    }
    let p = NSPopover()
    p.behavior = .transient
    p.contentSize = NSSize(width: 426, height: MenuPanel.height)
    p.contentViewController = NSHostingController(
      rootView: MenuPanel(model: model, open: { [weak self] in self?.showMain() }, pin: { [weak self] in self?.showQuickView() }))
    popover = p
    if let button = item.button { hoverPresenter = MenuHoverPresenter(button: button, popover: p) }
    model.onSnapshot = { [weak self] s in DispatchQueue.main.async { self?.updateStatus(s) } }
    model.updateInterval(UserDefaults.standard.object(forKey: "interval") as? Double ?? 2)
    if let title = UserDefaults.standard.string(forKey: "initialTab"),
      let tab = MonitorTab.visibleTabs.first(where: { $0.title == title })
    {
      model.select(tab)
    }
    if UserDefaults.standard.object(forKey: "openWindowAtLaunch") as? Bool == false {
      window.orderOut(nil)
    }
  }
  @MainActor private func updateStatus(_ s: MonitorSnapshot) {
    let privacy = LiveActivity.shared.activities.filter { $0.active && ["microphone", "camera"].contains($0.id) }
    status?.button?.toolTip = (["澄观"] + privacy.map { $0.title + " · " + $0.detail }).joined(separator: "\n")
    let presentation = MenuBarPresentation.make(snapshot: s, providers: AIUsageStore.shared.providers,
      nas: NASMonitor.shared.snapshot, nasCurrent: NASMonitor.shared.current, activities: LiveActivity.shared.activities)
    if let button = status?.button {
      button.setAccessibilityLabel(presentation.accessibility.joined(separator: "，"))
      guard presentation.renderKey != lastStatusRender else { return }
      lastStatusRender = presentation.renderKey
      button.attributedTitle = NSAttributedString(string: "")
      button.attributedAlternateTitle = NSAttributedString(string: "")
      button.contentTintColor = nil
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleNone
      button.image = presentation.image
    }
  }
  @objc func togglePopover() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      let menu = NSMenu()
      let open = menu.addItem(withTitle: "打开澄观", action: #selector(openMainFromMenu), keyEquivalent: "")
      open.target = self
      menu.addItem(.separator())
      for tab in MonitorTab.visibleTabs {
        let entry = menu.addItem(withTitle: tab.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = tab.rawValue
        entry.image = tab == .agents ? VisualResources.image("bot") : NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        entry.image?.size = NSSize(width: 15, height: 15)
      }
      menu.addItem(.separator())
      let care = menu.addItem(withTitle: "整理空间…", action: #selector(openCareFromMenu), keyEquivalent: "")
      care.target = self
      care.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
      menu.addItem(.separator())
      let quit = menu.addItem(withTitle: "退出澄观", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      quit.target = NSApp
      if let button = status?.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
      return
    }
    guard let b = status?.button, let p = popover else { return }
    if hoverPresenter?.pinIfPreviewing() == true { return }
    hoverPresenter?.clicked()
    if p.isShown {
      p.performClose(nil)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
      p.contentViewController?.view.window?.makeKey()
    }
  }
  func showQuickView() {
    guard let model else { return }
    popover?.performClose(nil)
    if quickWindow == nil {
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 426, height: MenuPanel.height),
        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
      panel.title = "澄观 · 速览"
      panel.isReleasedWhenClosed = false
      panel.level = .floating
      panel.contentViewController = NSHostingController(
        rootView: MenuPanel(model: model, open: { [weak self] in self?.showMain() }))
      panel.center()
      quickWindow = panel
    }
    quickWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func openMainFromMenu() { showMain() }
  @objc private func openCareFromMenu() { model?.presentCare(.clean) }
  @objc private func selectFromMenu(_ item: NSMenuItem) {
    if let raw = item.representedObject as? String, let tab = MonitorTab(rawValue: raw) { model?.select(tab) }
    showMain()
  }
  private func showMain() {
    popover?.performClose(nil)
    quickWindow?.orderOut(nil)
    mainWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list])
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    DispatchQueue.main.async { [weak self] in
      if info["usage"] as? Bool == true { self?.model?.select(.agents) }
      if let raw = info["target"] as? String, let target = AIReport.Target(rawValue: raw), let tab = target.tab {
        self?.model?.select(tab)
      }
      if let appID = info["appID"] as? String, !appID.isEmpty { self?.model?.selection = appID }
      self?.showMain()
      completionHandler()
    }
  }
}
