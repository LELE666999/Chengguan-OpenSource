import AppKit
import SwiftUI

@MainActor struct CareWorkspace: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var store = CareStore.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pending: [CareFile] = []
  @State private var confirm = false
  @State private var cleanReview = false
  @State private var projectsOpen = false
  private var page: CarePage { model.carePage ?? .clean }
  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch page {
        case .clean, .ai: clean
        case .software: software
        case .space: space
        case .maintain: maintenance
        case .history: history
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).id(page).transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 7)))
      if store.messageTime != nil {
        HStack(spacing: 8) {
          if store.scanning || store.processing { ProgressView().controlSize(.mini) }
          Text(store.message).lineLimit(1)
          Spacer()
          if let time = store.messageTime { Text(time.formatted(date: .omitted, time: .shortened)) }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 32)
      }
    }.buttonStyle(AIControlButtonStyle())
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: cleanReview)
      .onChange(of: store.processing) { _, processing in
        if !processing {
          if page == .software { apps.refresh() }
          if page == .space { explorer.open(explorer.path) }
        }
      }
      .alert("移到废纸篓？", isPresented: $confirm) {
        Button("取消", role: .cancel) { pending = [] }
        Button("移到废纸篓", role: .destructive) {
          store.trash(pending, title: page == .software ? "卸载应用" : "整理文件"); pending = []
        }
      } message: {
        Text("\(pending.count) 项 · \(Format.bytes(pending.reduce(0) { $0 + $1.bytes }))\n" + pending.prefix(4).map { short($0.path) }.joined(separator: "\n") + "\n可在「记录」恢复；关联 App 正在运行的项目会跳过。")
      }
  }
  private func askTrash(_ files: [CareFile]) { guard !files.isEmpty else { return }; pending = files; confirm = true }
  private func short(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~", options: [.anchored]) }
  private func heading(_ title: String, subtitle: String = "") -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.system(size: 25, weight: .semibold))
      if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
  }
  private var hasCleanResult: Bool { store.scan.completedAt != nil && store.currentAI == (page == .ai) }
  private var clean: some View {
    Group {
      if cleanReview && hasCleanResult && !store.scanning { cleanFiles }
      else { cleanLanding }
    }.disabled(store.processing)
      .onAppear { if store.currentAI != (page == .ai) { store.selection = []; cleanReview = false } }
  }
  private var cleanLanding: some View {
    VStack(spacing: 0) {
      HStack {
        Text(page == .ai ? "缓存与旧会话" : "缓存、日志、安装包与旧构建").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        if page == .clean {
          Button { projectsOpen.toggle() } label: { Label("项目目录", systemImage: "folder.badge.plus").padding(8).contentShape(Rectangle()) }
            .buttonStyle(CareRowStyle()).popover(isPresented: $projectsOpen) { projectFolders }
        }
      }.padding(.horizontal, 32).padding(.top, 18)
      Spacer(minLength: 12)
      CareStorageVisual(scanning: store.scanning, complete: hasCleanResult)
        .frame(width: 340, height: 240).accessibilityHidden(true)
      VStack(spacing: 10) {
        if store.scanning {
          Text("正在扫描").font(.system(size: 28, weight: .medium))
          Text("检查可整理内容…").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if hasCleanResult {
          Text(Format.bytes(store.totalBytes)).font(Theme.number(46, .medium)).contentTransition(.numericText())
          Text("\(store.scan.files.count) 项可审阅" + (store.scan.partial ? " · 部分扫描未完成" : ""))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
          Text(page == .ai ? "整理 AI 留下的数据" : "查看可整理空间").font(.system(size: 28, weight: .medium))
          Text("先扫描，所有内容由你选择").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }.frame(height: 94)
      HStack(spacing: 12) {
        if store.scanning {
          Button("停止扫描") { store.cancel() }.buttonStyle(CareActionStyle())
        } else if hasCleanResult && !store.scan.files.isEmpty {
          Button("查看项目") { cleanReview = true }.buttonStyle(CareActionStyle(primary: true))
          Button("重新扫描") { store.start(ai: page == .ai) }.buttonStyle(CareActionStyle())
        } else {
          Button(hasCleanResult ? "重新扫描" : "扫描 Mac") { store.start(ai: page == .ai) }.buttonStyle(CareActionStyle(primary: true))
        }
      }.padding(.top, 22)
      Spacer(minLength: 30)
      Text("移到废纸篓，可在记录中恢复").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.bottom, 24)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var projectFolders: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack { Text("项目目录").font(.system(size: 15, weight: .semibold)); Spacer(); Button("添加") { store.addProjectRoot() } }
      Text("仅检查所选目录中的旧构建与依赖").font(.system(size: 11)).foregroundStyle(.secondary)
      ForEach(store.projectRoots, id: \.path) { root in
        HStack { Text(root.lastPathComponent).lineLimit(1); Spacer(); Button("移除") { store.removeRoot(root) } }
      }
    }.padding(20).frame(width: 350).buttonStyle(AIControlButtonStyle(compact: true))
  }
  private var cleanFiles: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Button { cleanReview = false } label: { Label("扫描结果", systemImage: "chevron.left").padding(8).contentShape(Rectangle()) }.buttonStyle(CareRowStyle())
        Text(Format.bytes(store.totalBytes)).font(Theme.number(21, .medium))
        Spacer()
        TextField("搜索项目", text: $store.search).textFieldStyle(.roundedBorder).frame(width: 190)
        Button("重新扫描") { cleanReview = false; store.start(ai: page == .ai) }
      }
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(["全部"] + Array(Set(store.scan.files.map { $0.kind.rawValue })).sorted(), id: \.self) { kind in
            Button { store.filter = kind } label: {
              Text(kind).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(height: 32)
                .background(store.filter == kind ? Theme.panel : .clear, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(CareRowStyle())
          }
        }
      }.scrollIndicators(.never)
      ScrollView {
        LazyVStack(spacing: 2) { ForEach(store.visibleFiles) { file in fileRow(file, selected: store.selection.contains(file.id), action: { store.toggle(file) }) } }
      }
      HStack(spacing: 14) {
        Text(store.selection.isEmpty ? "选择要整理的项目" : "已选 \(store.selectedFiles.count) 项").font(.system(size: 12)).foregroundStyle(.secondary)
        if !store.selection.isEmpty {
          Text(Format.bytes(store.selectedBytes)).font(Theme.number(18, .medium))
          Button("取消选择") { store.selection = [] }
        }
        Spacer()
        Button("移到废纸篓…") { askTrash(store.selectedFiles) }.buttonStyle(CareActionStyle(primary: true)).disabled(store.selection.isEmpty || store.processing)
      }.padding(.top, 10)
    }.padding(24)
  }
  private func fileRow(_ file: CareFile, selected: Bool, blocked: String? = nil, action: @escaping () -> Void) -> some View {
    let reason = blocked ?? store.reviewReason(file)
    return HStack(spacing: 4) {
      Button(action: action) {
        HStack(spacing: 12) {
          Image(systemName: reason != nil ? "lock.circle" : selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected && reason == nil ? Theme.accent : .secondary)
          VStack(alignment: .leading, spacing: 5) {
            HStack { Text(file.name).fontWeight(.medium).lineLimit(1); Text(file.kind.rawValue).font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(short(file.path)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let reason { Text(reason).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1) }
            else if !file.note.isEmpty { Text(file.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
          }
          Spacer()
          Text(file.sizeText).font(Theme.number(12)).foregroundStyle(file.partial ? .orange : .primary)
        }.font(.system(size: 12)).padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
      }.buttonStyle(CareRowStyle()).disabled(reason != nil).help(reason ?? "点击整行选择")
      Menu { fileMenu(file) } label: { Image(systemName: "ellipsis").frame(width: 34, height: 36).contentShape(RoundedRectangle(cornerRadius: 10)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作").accessibilityLabel(file.name + "的更多操作")
    }.background(selected && reason == nil ? Theme.accent.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 12))
      .contextMenu { fileMenu(file) }
  }
  @ViewBuilder private func fileMenu(_ file: CareFile) -> some View {
    Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    Button("复制路径", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
    if store.protected.contains(file.path) {
      Button("取消保护", systemImage: "shield.slash") { store.unprotect(file.path) }
    } else {
      Button("保护此项", systemImage: "shield") { store.protect(file) }
    }
  }

  @ObservedObject private var apps = CareSoftwareStore.shared
  private var software: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 3) {
        ForEach(["应用", "更新", "启动项"], id: \.self) { mode in
          Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { apps.mode = mode } } label: {
            Text(mode == "应用" ? "卸载" : mode).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).frame(height: 32)
              .background(apps.mode == mode ? Theme.panel : .clear, in: Capsule()).contentShape(Capsule())
          }.buttonStyle(CareRowStyle())
        }
        Button { apps.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 32, height: 32).contentShape(Circle()) }.buttonStyle(CareRowStyle()).help("刷新软件列表").disabled(apps.loading)
        Spacer()
        if apps.mode != "启动项" {
          Picker("排序", selection: $apps.sort) { ForEach(["名称", "占用空间", "最近使用", "安装时间"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 125)
          TextField("搜索 App", text: $apps.search).textFieldStyle(.roundedBorder).frame(width: 180)
        }
      }
      HStack {
        Text(apps.mode == "启动项" ? "登录与后台项目" : "已安装 App").font(.system(size: 21, weight: .semibold))
        Text(apps.loading ? "正在读取…" : "\(apps.mode == "启动项" ? apps.startup.count : apps.visibleApps.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        if apps.mode == "启动项" { Button("系统管理") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) } }
        else if apps.mode == "更新" { Button("App Store 更新") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) } }
        else { Button("全选结果") { apps.selectVisible() }.disabled(apps.loading) }
      }.padding(.top, 4)
      if apps.loading && apps.apps.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
      else if apps.mode == "启动项" {
        ScrollView { LazyVStack(spacing: 2) {
          ForEach(apps.startup) { item in
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: {
              HStack(spacing: 12) { Image(systemName: "power"); Text(item.label); Spacer(); Text(item.user ? "当前用户" : "系统级").foregroundStyle(.secondary); Image(systemName: "arrow.up.right") }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(CareRowStyle())
          }
        } }
      } else {
        ScrollView { LazyVStack(spacing: 2) { ForEach(apps.visibleApps) { app in softwareRow(app) } } }
      }
      if apps.mode == "应用" {
        HStack(spacing: 14) {
          Text(apps.appSelection.isEmpty ? "点选 App，可多选" : "已选 \(apps.selectedApps.count) 个 App").font(.system(size: 12)).foregroundStyle(.secondary)
          if !apps.appSelection.isEmpty { Button("取消选择") { apps.appSelection = [] } }
          Spacer()
          Text("个人数据默认保留").font(.system(size: 11)).foregroundStyle(.tertiary)
          Button("审阅卸载…") { apps.review(apps.selectedApps) }.buttonStyle(CareActionStyle(primary: true)).disabled(apps.appSelection.isEmpty || store.processing)
        }.padding(.top, 10)
      }
    }.padding(28).onAppear { if apps.apps.isEmpty { apps.refresh() } }
      .sheet(isPresented: $apps.reviewOpen, onDismiss: { apps.cancelReview() }) { softwareReview }
  }
  private func softwareRow(_ app: CareApp) -> some View {
    let selected = apps.appSelection.contains(app.id)
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app.path }
    return HStack(spacing: 8) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.13)) { apps.toggleApp(app) }
      } label: {
        HStack(spacing: 14) {
          AppIcon(path: app.path, size: 36)
          VStack(alignment: .leading, spacing: 5) {
            Text(app.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
              Text(app.version)
              if let bytes = app.indexedBytes, bytes > 0 { Text("· " + Format.bytes(bytes)).help("Spotlight 索引容量；审阅时重新测量磁盘占用") }
              Text("· " + app.source)
              if running { Text("· 运行中") }
              else if apps.sort == "最近使用", let date = app.lastUsed { Text("· " + date.formatted(.relative(presentation: .named))) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if apps.mode == "更新", let update = apps.updates[app.id] { Text(update.text).font(.system(size: 11)).foregroundStyle(Theme.accent) }
          if apps.mode == "应用" {
            Image(systemName: app.protected ? "lock" : selected ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 18, weight: .light)).foregroundStyle(selected ? Theme.accent : .secondary)
          }
        }.padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity).contentShape(Rectangle())
          .background(selected && apps.mode == "应用" ? Theme.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 13))
      }.buttonStyle(CareRowStyle()).disabled(app.protected || apps.mode != "应用")
        .accessibilityLabel(app.name + (selected ? "，已选择" : ""))
      if apps.mode == "更新", app.feed != nil {
        if let url = apps.updates[app.id]?.url { Button("获取更新") { NSWorkspace.shared.open(url) } }
        else { Button(apps.checking.contains(app.id) ? "检查中" : "检查") { apps.check(app) }.disabled(apps.checking.contains(app.id)) }
      }
    }.contextMenu {
      Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
      Button("审阅卸载…") { apps.review([app]) }.disabled(app.protected)
    }
  }
  private var softwareReview: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        heading("卸载审阅", subtitle: "\(apps.reviewApps.count) 个 App")
        Spacer()
        Button(apps.reviewing ? "停止" : "完成") { apps.cancelReview(); apps.reviewOpen = false }
      }
      HStack { if apps.reviewing { ProgressView().controlSize(.small) }; Text(apps.message).font(.system(size: 12)).foregroundStyle(.secondary) }
      ScrollView { LazyVStack(spacing: 2) {
        ForEach(apps.files) { file in fileRow(file, selected: apps.selected.contains(file.id), action: { apps.toggle(file) }) }
      } }.frame(minHeight: 240, maxHeight: 420)
      HStack(spacing: 12) {
        Text("已选 \(apps.selected.count) 项").font(.system(size: 12)).foregroundStyle(.secondary)
        Text(Format.bytes(apps.reviewSelection.reduce(0) { $0 + $1.bytes })).font(Theme.number(18, .medium))
        Spacer()
        Button("移到废纸篓…") {
          let files = apps.reviewSelection
          apps.reviewOpen = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { askTrash(files) }
        }.buttonStyle(CareActionStyle(primary: true)).disabled(apps.selected.isEmpty || apps.reviewing || store.processing)
      }
    }.padding(28).frame(width: 740).background(Color(nsColor: .windowBackgroundColor)).buttonStyle(AIControlButtonStyle())
  }

  @ObservedObject private var explorer = SpaceExplorer.shared
  private var space: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        heading("空间", subtitle: explorer.message); Spacer()
        Button("选择目录") { explorer.choose() }
        if explorer.scanning { Button("停止") { explorer.cancel() } }
        else { Button { explorer.open(explorer.path) } label: { Image(systemName: "arrow.clockwise") }.help("重新扫描当前目录") }
      }
      ScrollView(.horizontal) {
        HStack(spacing: 5) {
          Button { explorer.open(URL(fileURLWithPath: "/")) } label: { Image(systemName: "internaldrive") }
          ForEach(Array(explorer.path.pathComponents.dropFirst().enumerated()), id: \.offset) { index, component in
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            Button(component) { explorer.open(URL(fileURLWithPath: "/" + explorer.path.pathComponents.dropFirst().prefix(index + 1).joined(separator: "/"))) }
          }
        }
      }.scrollIndicators(.never)
      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          SpaceMap(entries: Array(explorer.entries.prefix(24)), open: { entry in if entry.directory { explorer.open(entry.file.url) } else { explorer.selected = entry.id } }, trash: { askTrash([$0.file]) }, reason: { store.reviewReason($0.file) })
            .overlay { if explorer.scanning && explorer.entries.isEmpty { ProgressView("正在计算…").controlSize(.small) } }
          Text("面积为已扫描的前 24 项 · APFS 共享块可能重复计入").font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        ScrollView { LazyVStack(spacing: 3) {
          ForEach(explorer.entries) { entry in
            Button {
              if entry.directory { explorer.open(entry.file.url) } else { explorer.selected = entry.id }
            } label: {
              HStack(spacing: 9) {
                Image(systemName: entry.directory ? "folder" : "doc").foregroundStyle(Theme.accent)
                Text(entry.file.name).lineLimit(1).truncationMode(.middle); Spacer()
                Text(entry.file.sizeText).font(Theme.number(11)); if entry.directory { Image(systemName: "chevron.right").font(.system(size: 9)) }
              }.font(.system(size: 12)).padding(12).frame(maxWidth: .infinity).contentShape(Rectangle()).background(explorer.selected == entry.id ? Theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(CareRowStyle()).contextMenu { spaceMenu(entry) }
          }
        } }.frame(width: 360)
      }
      if let entry = explorer.entries.first(where: { $0.id == explorer.selected }) {
        HStack { Text(short(entry.file.path)).font(.system(size: 11)).lineLimit(1); Spacer(); if let reason = store.reviewReason(entry.file) { Text(reason).font(.system(size: 11)).foregroundStyle(.secondary) }; Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.file.url]) }; Button("移到废纸篓…", role: .destructive) { askTrash([entry.file]) }.disabled(store.reviewReason(entry.file) != nil) }
      }
    }.padding(24).onAppear { if explorer.entries.isEmpty && !explorer.scanning { explorer.open(explorer.path) } }
  }
  @ViewBuilder private func spaceMenu(_ entry: SpaceEntry) -> some View {
    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.file.url]) }
    Button("保护此项") { store.protect(entry.file) }
    Button("移到废纸篓…", role: .destructive) { askTrash([entry.file]) }.disabled(store.reviewReason(entry.file) != nil)
  }
  @ObservedObject private var maintenanceStore = MaintenanceStore.shared
  private var maintenance: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        heading("维护", subtitle: "选择需要检查或修复的项目")
        Spacer()
        Button(maintenanceStore.running ? "维护中…" : "运行所选") { maintenanceStore.run() }
          .buttonStyle(CareActionStyle(primary: true)).disabled(maintenanceStore.running || maintenanceStore.selection.isEmpty)
      }
      HStack(alignment: .top, spacing: 28) {
        ScrollView {
          VStack(spacing: 3) {
            ForEach(MaintenanceTask.all) { task in
              VStack(alignment: .leading, spacing: 6) {
                Button {
                  withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    if !maintenanceStore.selection.insert(task.id).inserted { maintenanceStore.selection.remove(task.id) }
                  }
                } label: {
                  HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                      Text(task.title).font(.system(size: 14, weight: .medium))
                      Text(task.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let result = maintenanceStore.results[task.id] { Text(result.components(separatedBy: "\n")[0]).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Image(systemName: maintenanceStore.selection.contains(task.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(maintenanceStore.selection.contains(task.id) ? Theme.accent : .secondary)
                  }.padding(17).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(CareRowStyle()).disabled(maintenanceStore.running)
                if let result = maintenanceStore.results[task.id], result.contains("\n") {
                  DisclosureGroup("结果") { Text(result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .disclosureGroupStyle(AIWholeRowDisclosureStyle()).padding(.horizontal, 16)
                }
                Divider().opacity(0.3).padding(.horizontal, 17)
              }
            }
          }
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 24) {
          Text("当前活动").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          LiveActivityPanel(model: model)
          Divider().opacity(0.4)
          VStack(alignment: .leading, spacing: 6) {
            Button("网络诊断") { model.showDiagnostics = true }
            Button("登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
            Button("电池设置") { NSWorkspace.shared.open(AIReport.Target.battery.settingsURL!) }
          }
          Text("风扇由 macOS 自动调节").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(width: 265).padding(.top, 16)
      }
    }.padding(30)
  }
  private var history: some View {
    VStack(alignment: .leading, spacing: 20) {
      heading("处理记录", subtitle: "保留最近 100 次 · 恢复时保留原位置已有文件")
      if store.operations.isEmpty { ContentUnavailableView("暂无记录", systemImage: "clock.arrow.circlepath") }
      ScrollView { LazyVStack(spacing: 14) {
        ForEach(store.operations) { operation in
          VStack(alignment: .leading, spacing: 12) {
            HStack { Text(operation.title).fontWeight(.medium); Spacer(); Text(operation.time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
              if operation.items.contains(where: { !$0.restored }) { Button("恢复") { store.restore(operationID: operation.id) }.disabled(store.processing) }
            }.font(.system(size: 12))
            DisclosureGroup(operation.detail.components(separatedBy: "\n")[0]) {
              Text(operation.detail).font(.system(size: 11)).textSelection(.enabled)
              ForEach(operation.items) { file in Text((file.restored ? "已恢复 · " : "") + short(file.original)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
          }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        }
      } }
    }.padding(24)
  }
}

private struct SpaceMap: View {
  let entries: [SpaceEntry]
  let open: (SpaceEntry) -> Void
  let trash: (SpaceEntry) -> Void
  let reason: (SpaceEntry) -> String?
  var body: some View {
    GeometryReader { geometry in
      let tiles = SpaceTile.layout(entries.map { Double($0.file.bytes) }, in: CGRect(origin: .zero, size: geometry.size))
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 18).fill(Theme.panel)
        ForEach(tiles) { tile in
          let entry = entries[tile.index]
          Button { open(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
              if tile.rect.width > 74 && tile.rect.height > 44 {
                Image(systemName: entry.directory ? "folder.fill" : "doc.fill").font(.system(size: 14))
                Text(entry.file.name).font(.system(size: 12, weight: .medium)).lineLimit(tile.rect.height > 100 ? 2 : 1)
                if tile.rect.height > 85 { Text(entry.file.sizeText).font(.system(size: 11)).opacity(0.7) }
              }
              Spacer(minLength: 0)
            }.padding(tile.rect.width > 74 ? 14 : 0).frame(width: max(0, tile.rect.width - 4), height: max(0, tile.rect.height - 4), alignment: .topLeading)
              .foregroundStyle(.primary).background(Theme.accent.opacity([0.14, 0.22, 0.10, 0.30][tile.index % 4]), in: RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(CareRowStyle()).offset(x: tile.rect.minX + 2, y: tile.rect.minY + 2)
            .help(entry.file.name + " · " + entry.file.sizeText)
            .accessibilityLabel(entry.file.name + "，" + entry.file.sizeText)
            .contextMenu {
              Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.file.url]) }
              Button("移到废纸篓…", role: .destructive) { trash(entry) }.disabled(reason(entry) != nil)
            }
        }
      }.clipped()
    }.frame(minHeight: 280)
  }
}
