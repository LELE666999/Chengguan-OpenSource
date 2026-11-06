import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct ReplicaSettings: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var displayControl = DisplayControlStore.shared
  @State private var showServerConnection = false
  @AppStorage("appearance") private var appearance = "auto"
  @AppStorage("numberFont") private var numberFont = "rounded"
  @AppStorage("numberWeight") private var numberWeight = 0.8
  @AppStorage("palette") private var palette = "Vitals"
  @AppStorage("compact") private var compact = false
  @AppStorage("interval") private var interval = 2.0
  @ObservedObject private var watch = AISentinel.shared
  @AppStorage("floating") private var floating = false
  @AppStorage("dockVisible") private var dockVisible = true
  @AppStorage("openWindowAtLaunch") private var openAtLaunch = true
  @AppStorage("initialTab") private var initialTab = "概览"
  @AppStorage("temperatureUnit") private var temperatureUnit = "auto"
  @AppStorage("networkBits") private var networkBits = false
  @AppStorage("wholeMachineCPU") private var wholeMachineCPU = false
  @AppStorage("showMacOS") private var showMacOS = true
  @AppStorage("retentionDays") private var retentionDays = 30
  @AppStorage("graphMinutes") private var graphMinutes = 5
  @AppStorage("exportBackground") private var exportBackground = "跟随窗口"
  @AppStorage("exportBrand") private var exportBrand = true
  @AppStorage("showMenuCPU") private var showMenuCPU = true
  @AppStorage("showMenuMemory") private var showMenuMemory = true
  @AppStorage("menuExtraMetrics") private var menuExtraMetrics = "[]"
  @AppStorage("menuQuotaSelection") private var menuQuotaSelection = "[]"
  @AppStorage("menuShowActivity") private var menuShowActivity = true
  @AppStorage("menuShowQuickTools") private var menuShowQuickTools = true
  @ObservedObject private var menuUsage = AIUsageStore.shared
  @ObservedObject private var menuNAS = NASMonitor.shared
  @ObservedObject private var menuActivity = LiveActivity.shared
  @AppStorage("aiUsageEnabled") private var aiUsageEnabled = false
  @AppStorage("codexResetEnabled") private var codexResetEnabled = true
  @AppStorage("codexResetAI") private var codexResetAI = true
  @AppStorage("codexResetNotifications") private var codexResetNotifications = true
  @AppStorage("codexResetSound") private var codexResetSound = false
  @AppStorage("settingsSection") private var section = "通用"
  @State private var login = SMAppService.mainApp.status == .enabled
  @State private var layoutTab = "菜单栏"
  @AppStorage("menuSize") private var menuSize = "常规"
  @AppStorage("menuColor") private var menuColor = false
  @AppStorage("menuBold") private var menuBold = false
  @AppStorage("menuHoverPreview") private var menuHoverPreview = true
  @AppStorage("highLoadRed") private var highLoadRed = false
  @State private var notificationStatus = "关闭"
  @State private var error: String?
  @State private var showProcessAccess = false
  private let sections: [(String, String, Color)] = [
    ("通用", "gearshape.fill", .gray), ("自定", "paintpalette.fill", .pink),
    ("布局", "rectangle.3.group.fill", .blue),
    ("默认打开", "app.badge.checkmark", .teal),
    ("集成", "point.3.connected.trianglepath.dotted", .purple), ("AI 分析", "sparkles", .blue), ("洞察", "lightbulb.fill", .orange),
    ("权限", "hand.raised.fill", .red), ("许可证", "key.fill", .yellow), ("关于", "info", .blue),
  ]
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, item in
          if item.0 == "AI 分析" || item.0 == "许可证" {
            Text(item.0 == "AI 分析" ? "监测" : "App").font(.system(size: 11, weight: .medium))
              .foregroundStyle(.tertiary).padding(.leading, 18).padding(.top, 18).padding(
                .bottom, 6)
          }
          Button {
            section = item.0
          } label: {
            HStack(spacing: 12) {
              Image(systemName: item.1).font(.system(size: 16, weight: .bold)).foregroundStyle(
                .white
              ).frame(width: 24, height: 24).background(
                item.2,
                in: RoundedRectangle(cornerRadius: 7)
              )
              Text(item.0 == "AI 分析" ? "AI" : item.0).font(.system(size: 13, weight: section == item.0 ? .semibold : .medium))
              Spacer()
            }.padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 38).background(
              section == item.0 ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 11)
            ).contentShape(RoundedRectangle(cornerRadius: 11)).foregroundStyle(section == item.0 ? Theme.selectionForeground : .primary)
          }.buttonStyle(.plain).padding(.horizontal, 8).accessibilityLabel(item.0)
        }
        Spacer()
      }.padding(.top, 51).frame(width: 210).background(Theme.panel.opacity(0.8))
      Divider()
      VStack(spacing: 0) {
        HStack {
          Color.clear.frame(width:1,height:1)
          Spacer()
        }.padding(.horizontal, 20).frame(height: 51)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 28) {
            switch section {
            case "通用": general
            case "自定": custom
            case "布局": layout
            case "默认打开": DefaultAppsWorkspace(embedded: true)
            case "集成": integrations
            case "AI 分析": AIAnalysisSettings(model: model)
            case "洞察": insights
            case "权限": permissions
            case "许可证": licence
            default: about
            }
            if let error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
          }.padding(.horizontal, 20).padding(.vertical, 24).frame(
            maxWidth: .infinity, alignment: .leading)
        }.id(section)
      }.background(Color(nsColor: .windowBackgroundColor))
    }.frame(width: 940, height: 672).ignoresSafeArea(.container, edges: .top).padding(.bottom, -52).font(
      .system(size: 13)
    ).toolbar { settingsToolbar }.toolbar(removing: .title).toolbarBackground(.hidden,for:.windowToolbar).background(SettingsWindowConfiguration()).preferredColorScheme(
      appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
      .tint(Theme.accent)
  }
  @ToolbarContentBuilder private var settingsToolbar:some ToolbarContent {
    if #available(macOS 26.0,*) {
      ToolbarItem(placement:.navigation) { Text(section == "AI 分析" ? "AI" : section).font(.system(size:14,weight:.bold)).padding(.leading,134) }.sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement:.navigation) { Text(section == "AI 分析" ? "AI" : section).font(.system(size:14,weight:.bold)).padding(.leading,134) }
    }
  }
  private var general: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        block {
          row("语言") {
            Text("简体中文").foregroundStyle(.secondary)
            Button("打开“语言与地区”…") {
              openSettings("x-apple.systempreferences:com.apple.Localization-Settings.extension")
            }
          }
        }
        caption("若要仅为澄观使用其他语言，请在“语言与地区”的“应用程序”下方添加澄观。")
      }
      sectionBlock("启动") {
        toggle("在程序坞中显示", isOn: $dockVisible).onChange(of: dockVisible) { _, v in
          NSApp.setActivationPolicy(v ? .regular : .accessory)
        }
        toggle("登录时打开", isOn: $login).onChange(of: login) { _, v in
          do {
            if v {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
          } catch {
            self.error = error.localizedDescription
            login = SMAppService.mainApp.status == .enabled
          }
        }
        toggle("启动时打开窗口", isOn: $openAtLaunch)
        row("打开窗口时显示") {
          Picker("打开窗口时显示", selection: $initialTab) {
            ForEach(MonitorTab.visibleTabs) { Text($0.title).tag($0.title) }
          }.labelsHidden().frame(width: 120)
        }
      }
      sectionBlock("键盘快捷键") {
        row("打开下拉面板") {
          Text("⇧⌘M").font(.system(size: 12)).foregroundStyle(.secondary)
          Button("录制快捷键") { error = "当前快捷键为 ⇧⌘M；自定义全局快捷键尚未实现。" }
        }
        row("打开窗口") { Button("录制快捷键") { error = "自定义全局快捷键尚未实现。可以从菜单栏图标打开窗口。" } }
      }
      sectionBlock("单位") {
        row("温度") {
          Picker("温度", selection: $temperatureUnit) {
            Text("自动").tag("auto")
            Text("°C").tag("c")
            Text("°F").tag("f")
          }.pickerStyle(.segmented).labelsHidden().frame(width: 175)
        }
        row("网络速度") {
          Picker("网络速度", selection: $networkBits) {
            Text("字节（MB/s）").tag(false)
            Text("位（Mb/s）").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
        }
        row("每个App的CPU") {
          Picker("每个App的CPU", selection: $wholeMachineCPU) {
            Text("一个内核").tag(false)
            Text("整台Mac").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
        }
      }
      block {
        row("更新频率") {
          Picker("更新频率", selection: $interval) {
            Text("1秒").tag(1.0)
            Text("2秒").tag(2.0)
            Text("5秒").tag(5.0)
            Text("10秒").tag(10.0)
          }.labelsHidden().frame(width: 100).onChange(of: interval) { _, v in
            model.updateInterval(v)
          }
        }
        toggle("在列表中显示 macOS", isOn: $showMacOS)
      }
      block {
        row("历史记录保留时间") {
          Picker("历史记录保留时间", selection: $retentionDays) {
            Text("7天").tag(7)
            Text("30天").tag(30)
            Text("90天").tag(90)
          }.labelsHidden().frame(width: 100)
        }
        row("从首次运行开始记录") {
          Button("导出CSV") { model.exportHistoryBundle(range: Double(retentionDays) * 86400) }
          Button("显示历史记录") { showData() }
        }
      }
    }
  }
  private var custom: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
          appearancePreview(memory: false)
          appearancePreview(memory: true)
        }
        caption("卡片在下方选项下的外观。")
      }
      block {
        row("外观") {
          Picker("外观", selection: $appearance) {
            Text("自动").tag("auto")
            Text("浅色").tag("light")
            Text("深色").tag("dark")
          }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
        }
        row("颜色", height: 74) {
          HStack(spacing: 10) {
            ForEach(["Vitals", "单色", "辅助功能"], id: \.self) { name in
              choice(name == "Vitals" ? "默认" : name, selected: palette == name) {
                HStack(spacing: 4) {
                  ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 3).fill(paletteColors(name)[i]).frame(
                      width: 12, height: 20)
                  }
                }.padding(8)
              } action: {
                palette = name
              }
            }
          }
        }
        row("密度", height: 70) {
          ForEach([false, true], id: \.self) { dense in
            choice(dense ? "紧凑" : "宽松", selected: compact == dense) {
              VStack(alignment: .leading, spacing: dense ? 2 : 4) {
                ForEach(0..<3) { i in
                  HStack(spacing: 12) {
                    Capsule().fill(.gray.opacity(0.5)).frame(width: i == 1 ? 18 : 24, height: 3)
                    Capsule().fill(.gray.opacity(0.35)).frame(width: 8, height: 3)
                  }
                }
              }.padding(10)
            } action: {
              compact = dense
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        sectionBlock("数字") {
          row("字体", height: 74) {
            HStack(spacing: 8) {
              ForEach(
                [
                  ("rounded", "圆体"), ("system", "San Francisco"), ("mono", "SF Mono"),
                  ("serif", "New York"), ("other", "其他…"),
                ], id: \.0
              ) { key, name in
                choice(name, selected: numberFont == key) {
                  HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("12.43").font(
                      .system(
                        size: 20, weight: .bold,
                        design: key == "mono"
                          ? .monospaced
                          : key == "serif" ? .serif : key == "system" ? .default : .rounded))
                    Text("GB").font(.system(size: 9, weight: .semibold))
                  }.foregroundStyle(.secondary).padding(9)
                } action: {
                  if key == "other" {
                    NSFontManager.shared.orderFrontFontPanel(nil)
                  } else {
                    numberFont = key
                  }
                }
              }
            }
          }
          row("粗细") {
            Text("细").foregroundStyle(.tertiary)
            Slider(value: $numberWeight, in: 0...1).frame(width: 325)
            Text("粗").foregroundStyle(.tertiary)
          }
        }
        caption("适用于澄观中的所有数字：大数字、卡片和表格中的数值，以及导出的图片。菜单栏保留系统字体。")
      }
      sectionBlock("窗口") {
        row("图表显示") {
          Picker("图表显示", selection: $graphMinutes) {
            Text("5 分钟").tag(5)
            Text("15 分钟").tag(15)
            Text("30 分钟").tag(30)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
        toggle("浮动在最上层", isOn: $floating).onChange(of: floating) { _, v in
          NSApp.windows.first { $0.identifier?.rawValue == "replica-main" }?.level =
            v ? .floating : .normal
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        sectionBlock("导出") {
          row("背景") {
            Picker("背景", selection: $exportBackground) {
              ForEach(["跟随窗口", "浅色", "深色", "透明"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
          }
          toggle("澄观图标和名称", isOn: $exportBrand)
        }
        caption("用于“概览”中“导出”生成的分享卡片和仪表板。数字采用上方的字体。")
      }
    }
  }
  private var layout: some View {
    Group {
      SettingsGlassSegments(selection: $layoutTab, options: ["菜单栏", "下拉面板", "窗口"])
      if layoutTab == "菜单栏" {
        sectionBlock("实时预览") {
          menuBarPreview
          row("大小") {
            SettingsGlassSegments(selection: $menuSize, options: ["紧凑", "常规", "大"], compact: true)
          }
          toggle("蓝色图标", isOn: $menuColor)
          toggle("粗体", isOn: $menuBold)
          toggle("高负载图标变红", isOn: $highLoadRed)
          toggle("悬停预览", isOn: $menuHoverPreview)
        }
        sectionBlock("显示内容") {
          toggle("CPU", isOn: $showMenuCPU)
          toggle("内存", isOn: $showMenuMemory)
          ForEach(MenuBarMetric.allCases) { metric in
            toggle(metric.title, isOn: Binding(
              get: { MenuBarSelection.parse(menuExtraMetrics).contains(metric.rawValue) },
              set: { value in
                if value != MenuBarSelection.parse(menuExtraMetrics).contains(metric.rawValue) {
                  menuExtraMetrics = MenuBarSelection.toggle(metric.rawValue, in: menuExtraMetrics)
                }
              }))
          }
        }
        caption("选择过多项目可能占用菜单栏空间；亮度或 NAS 数据不可读取时显示 —。")
        sectionBlock("AI 额度") {
          if menuUsage.providers.flatMap(\.limits).allSatisfy({ $0.windows.isEmpty }) {
            row("暂无可显示的额度") {
              Button("打开集成") { section = "集成" }.buttonStyle(AIControlButtonStyle(compact: true))
            }
          } else {
            ForEach(menuUsage.providers) { provider in
              ForEach(Array(provider.limits.enumerated()), id: \.offset) { _, limit in
                ForEach(Array(limit.windows.enumerated()), id: \.offset) { index, window in
                  let id = MenuBarSelection.quotaID(provider: provider, limit: limit, window: window, index: index)
                  toggle(provider.id + " · " + MenuBarSelection.quotaName(window), isOn: Binding(
                    get: { MenuBarSelection.parse(menuQuotaSelection).contains(id) },
                    set: { value in
                      if value != MenuBarSelection.parse(menuQuotaSelection).contains(id) {
                        menuQuotaSelection = MenuBarSelection.toggle(id, in: menuQuotaSelection)
                      }
                    }))
                }
              }
            }
          }
          if !MenuBarSelection.parse(menuQuotaSelection).isEmpty {
            row("已选额度") { Button("清除") { menuQuotaSelection = "[]" }.buttonStyle(AIControlButtonStyle(compact: true)) }
          }
        }
      } else if layoutTab == "下拉面板" {
        sectionBlock("下拉面板") {
          toggle("显示设备活动", isOn: $menuShowActivity)
          toggle("显示快捷工具", isOn: $menuShowQuickTools)
          row("快捷键") { Text("⇧⌘M").foregroundStyle(.secondary) }
        }
        caption("AI 用量页面专注额度与重置时间，设备变化仍显示在底部消息中。")
      } else {
        sectionBlock("概览") {
          OverviewSettingsToggle(title: "摘要", key: "overviewSummary", initial: true)
          OverviewSettingsToggle(title: "此刻", key: "overviewNow", initial: true)
          OverviewSettingsToggle(title: "硬件", key: "overviewHardware", initial: true)
          OverviewSettingsToggle(title: "随时间变化", key: "overviewHistory", initial: true)
        }
      }
    }
  }
  private var menuBarPreview: some View {
    let _ = (showMenuCPU, showMenuMemory, menuSize, menuColor, menuBold, highLoadRed, menuExtraMetrics, menuQuotaSelection, aiUsageEnabled)
    let preview = MenuBarPresentation.make(snapshot: model.snapshot, providers: menuUsage.providers,
      nas: menuNAS.snapshot, nasCurrent: menuNAS.current, activities: menuActivity.activities)
    return ScrollView(.horizontal) {
      Image(nsImage: preview.image).interpolation(.high).fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.72), in: Capsule())
        .accessibilityLabel("菜单栏实时预览：" + preview.accessibility.joined(separator: "，"))
    }.scrollIndicators(.never).frame(maxWidth: .infinity, alignment: .leading).padding(14)
  }
  private var integrations: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        block {
          toggle("显示器控制", isOn: Binding(get: { displayControl.enabled }, set: { displayControl.setEnabled($0) }))
          row("搬瓦工服务器") { Button("连接设置…") { showServerConnection = true }.buttonStyle(AIControlButtonStyle()) }
        }
        caption("关闭显示器控制后，隐藏相关栏目，暂停亮度、音量控制和分辨率自动恢复。")
      }.sheet(isPresented: $showServerConnection) { ServerConnectionView() }
      block {
        row("AI 设备分析") { Button("配置 MiMo / DeepSeek…") { section = "AI 分析" } }
      }
      VStack(alignment: .leading, spacing: 8) {
        block { unavailableToggle("允许AI助手查询") }
        caption("通过本机MCP服务器，让AI助手读取Mac的资源使用情况。当前开发版尚未实现MCP服务。")
      }
      VStack(alignment: .leading, spacing: 8) {
        block { toggle("显示你的AI套餐用量限额", isOn: $aiUsageEnabled) }
        caption("从Codex和Claude Code的本机日志统计今天与本周的Token，并显示工具记录的套餐限额和重置时间。只缓存数值，不读取登录凭据。限额数据的更新时间取决于原工具。")
      }
      VStack(alignment: .leading, spacing: 8) {
        block {
          toggle("Codex 特别重置提醒", isOn: $codexResetEnabled)
          toggle("AI 解读公开预告", isOn: $codexResetAI)
          toggle("新预告与额度恢复通知", isOn: $codexResetNotifications)
          toggle("提醒声音", isOn: $codexResetSound)
        }
        caption("每 15 分钟检查 Tibo 公开公告。AI 仅解读新内容，使用已连接模型；公开发放不代表个人到账。")
      }.onChange(of: codexResetEnabled) { _, value in if value { CodexResetStore.shared.refresh(force: true) } else { CodexResetStore.shared.disabled() } }
      sectionBlock("助手") {
        ForEach(
          [
            ("Claude Desktop", "配置"), ("Claude Code", "~/.claude.json"),
            ("Codex", "~/.codex/config.toml"), ("Cursor", "~/.cursor/mcp.json"), ("其他", "拷贝配置"),
          ], id: \.0
        ) { name, path in row(name) { Button(path) {}.disabled(true) } }
      }.disabled(true)
      sectionBlock("终端") {
        row("命令行工具") { Button("安装 vitals…") {}.disabled(true) }
        row("使用") {
          Text("Chengguan --sample-json").font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }
      }
      sectionBlock("共享的数据") {
        ForEach(["系统指标", "App和进程", "项目和端口", "历史记录", "仅共享项目文件夹名称"], id: \.self) { title in
          row(title) { Toggle(title, isOn: .constant(false)).labelsHidden().disabled(true) }
        }
      }.disabled(true)
      sectionBlock("操作") {
        unavailableToggle("允许助手退出App")
        row("安全的文件夹") { Button("添加…") {}.disabled(true) }
      }.disabled(true)
    }
  }
  private var insights: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        block {
          toggle("发送通知", isOn: $watch.notifications)
        }
        caption("洞察始终显示在概览中。同类提醒会合并，避免重复打扰。")
      }
      sectionBlock("App") {
        row("CPU持续高占用") { Text("85% · 持续12秒").foregroundStyle(.secondary) }
        row("内存压力") { Text("升高时提醒").foregroundStyle(.secondary) }
        row("磁盘可用空间") { Text("低于10%").foregroundStyle(.secondary) }
      }
      sectionBlock("Mac") { row("CPU温度") { Text("90 °C").foregroundStyle(.secondary) } }
      sectionBlock("历史记录") {
        row("保留的洞察") {
          Text("\(model.insights.count)").foregroundStyle(.secondary)
          Button("清除历史记录") { model.insights = [] }
        }
      }
    }
  }
  private var permissions: some View {
    Group {
      permission(
        "进程指标", symbol: "info.circle", description: "当前可读取 \(model.snapshot.processes.count - model.snapshot.unmeasured) 个进程。macOS 限制部分进程的详细读数，整机统计仍包含它们。", action: "查看范围…", status: model.snapshot.unmeasured == 0 ? "正在测量" : "部分受限"
      ) { showProcessAccess = true }
        .popover(isPresented: $showProcessAccess) { ProcessAccessView(snapshot: model.snapshot) }
      permission("通知", symbol: "bell", description: "允许澄观在App或Mac出现资源问题时提醒你。", action: "打开设置…")
      { openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
      permission("文件与文件夹", symbol: "folder", description: "允许读取项目文件夹，以便按项目整理开发进程。", action: "允许…") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
          error = "已选择 \(url.lastPathComponent)。项目发现仍以可读取的本机进程为准。"
        }
      }
    }
  }
  private var licence: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("本机开发版").font(.system(size: 24, weight: .bold))
      Text("澄观 使用独立的App标识，不连接原版的许可证或付费服务。").foregroundStyle(.secondary)
      sectionBlock("第三方组件") {
        row("Stats · SMC读取") {
          Link(
            "MIT许可证",
            destination: URL(string: "https://github.com/exelban/stats/blob/master/LICENSE")!)
        }
      }
      Text(
        "界面参考与本机提取的图像来自 Fore Studio Vitals 1.8.1，权利归原作者；Stats部分保留原始MIT许可。详情见项目中的 THIRD_PARTY_NOTICES.md。"
      ).font(.system(size: 12)).foregroundStyle(.secondary)
    }
  }
  private var appVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return build.map { "\(version)（\($0)）" } ?? version
  }
  private var about: some View {
    Group {
      VStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
        Text("澄观").font(.system(size: 26, weight: .bold))
        Text("版本 \(appVersion)").foregroundStyle(.secondary)
        Text("以App和项目为单位的活动监视器。").foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity).padding(.vertical, 8)
      sectionBlock("更新") {
        row("澄观 \(appVersion)") { Button("检查更新…") { error = "当前为本机构建版本，更新请重新运行项目的构建脚本。" } }
        row("参考版本") { Text("Vitals 1.8.1（449）").foregroundStyle(.secondary) }
      }
      sectionBlock("帮助") {
        row("诊断报告") {
          Button("拷贝报告") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
              "澄观 \(appVersion)\n\(SystemValue.chip)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n\(model.snapshot.processes.count) processes; \(model.snapshot.unmeasured) unmeasured",
              forType: .string)
          }
        }
        row("使用数据") { Button("在访达中显示") { showData() } }
        row("实现范围") { Text("原生监测、本地历史、系统音量、设备与项目").foregroundStyle(.secondary) }
      }
      caption("尚未完成：完整系统指标辅助服务、蓝牙电量、AI账户主动刷新和MCP、全局快捷键自定义，以及所有动效的逐帧对齐。")
      HStack {
        Link("原版网站", destination: URL(string: "https://vitalsmac.com/zh-hans")!)
        Link("Stats", destination: URL(string: "https://github.com/exelban/stats")!)
        Spacer()
        Text("本机独立实现").foregroundStyle(.secondary)
      }.font(.system(size: 12))
    }
  }
  private func appearancePreview(memory: Bool) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        Label(memory ? "内存" : "CPU", systemImage: memory ? "memorychip.fill" : "cpu.fill").font(
          .system(size: 12, weight: .semibold)
        ).foregroundStyle(memory ? MonitorTab.memory.color : Theme.accent)
        ValueText(text: memory ? "12.4 GB" : "34 %", size: 32)
        if memory {
          GeometryReader { g in
            HStack(spacing: 2) {
              Color.blue.frame(width: g.size.width * 0.38)
              Color.orange.frame(width: g.size.width * 0.13)
              Color.green.frame(width: g.size.width * 0.08)
              Color.gray.opacity(0.2)
            }.clipShape(Capsule())
          }.frame(height: 6)
          HStack(spacing: 12) {
            ForEach([(Color.blue, "6.2 GB"), (.orange, "2.1 GB"), (.green, "1.3 GB")], id: \.1) {
              color, label in
              HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(Theme.number(11))
              }
            }
          }
        } else {
          HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<42) { i in
              ZStack(alignment: .bottom) {
                Capsule().fill(Theme.accent.opacity(0.16))
                Capsule().fill(Theme.accent).frame(height: 8 + 12 * (sin(Double(i) / 4) + 1) / 2)
              }
            }
          }.frame(height: 30)
        }
      }.frame(height: 97, alignment: .top)
    }
  }
  private func paletteColors(_ name: String) -> [Color] {
    name == "单色"
      ? [.black, .gray, .gray.opacity(0.7), .gray.opacity(0.9), .gray.opacity(0.8)]
      : name == "辅助功能"
        ? [.blue, .purple, .yellow, .teal, .green] : [.blue, .purple, .orange, .mint, .green]
  }
  private func choice<V: View>(
    _ title: String, selected: Bool, @ViewBuilder content: () -> V, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: 5) {
        content().background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
          .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(
              selected ? Theme.accent : .clear, lineWidth: 1.8))
        Text(title).font(.system(size: 10)).foregroundStyle(selected ? .primary : .secondary)
      }
    }.buttonStyle(.plain)
  }
  private func block<V: View>(@ViewBuilder content: () -> V) -> some View {
    VStack(spacing: 0, content: content).background(
      Theme.panel, in: RoundedRectangle(cornerRadius: 12)
    ).clipShape(RoundedRectangle(cornerRadius: 12))
  }
  private func sectionBlock<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.system(size: 13, weight: .bold)).padding(.leading, 10)
      block(content: content)
    }
  }
  private func row<V: View>(_ title: String, height: CGFloat = 38, @ViewBuilder trailing: () -> V)
    -> some View
  {
    HStack(alignment: .center, spacing: 10) {
      if !title.isEmpty { Text(title) }
      Spacer(minLength: 12)
      trailing()
    }.padding(.horizontal, 10).frame(minHeight: height).overlay(alignment: .bottom) {
      Divider().opacity(0.3).padding(.horizontal, 10)
    }
  }
  private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) { Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
      .toggleStyle(.switch).controlSize(.small).padding(.horizontal, 10).frame(minHeight: 42)
      .overlay(alignment: .bottom) { Divider().opacity(0.3).padding(.horizontal, 10) }
  }
  private func unavailableToggle(_ title: String) -> some View {
    row(title) {
      Toggle(title, isOn: Binding(get: { false }, set: { _ in error = "此集成尚未实现。" })).labelsHidden()
        .toggleStyle(.switch).controlSize(.small)
    }
  }
  private func caption(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
      horizontal: false, vertical: true
    ).padding(.horizontal, 10)
  }
  private func permission(
    _ title: String, symbol: String, description: String, action: String, status: String? = nil,
    handler: @escaping () -> Void
  ) -> some View {
    block {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary).frame(
          width: 35)
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text(title).fontWeight(.semibold)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button(action, action: handler)
          }
          Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }.padding(16)
    }
  }
  private func openSettings(_ value: String) {
    if let url = URL(string: value) { NSWorkspace.shared.open(url) }
  }
  private func showData() {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VitalsReplica")
    NSWorkspace.shared.open(url)
  }
}
struct OverviewSettingsToggle: View {
  let title: String
  @AppStorage var value: Bool
  init(title: String, key: String, initial: Bool) {
    self.title = title
    _value = AppStorage(wrappedValue: initial, key)
  }
  var body: some View {
    Toggle(title, isOn: $value).toggleStyle(.switch).controlSize(.small).padding(10)
  }
}
struct SettingsWindowConfiguration: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentMinSize=NSSize(width:940,height:620)
        var frame=window.frame;frame.size=NSSize(width:940,height:672);window.setFrame(frame,display:true)
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
      }
    }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
}
