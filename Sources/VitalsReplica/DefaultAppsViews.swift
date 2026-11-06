import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DefaultAppsWorkspace: View {
  var embedded = false
  @ObservedObject private var store = DefaultAppsStore.shared
  @State private var category = "全部"
  @State private var search = ""
  @State private var showAdd = false
  @State private var extensionText = ""
  @State private var addError: String?
  private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
  private let categories = ["全部", "文档", "媒体", "代码", "压缩包", "自定"]
  private var filtered: [DefaultOpenItem] {
    store.items.filter {
      $0.category != "常用" && (category == "全部" || $0.category == category) &&
        (search.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(search))
    }
  }
  var body: some View {
    Group {
      if embedded { content }
      else { ScrollView { content.padding(26).frame(maxWidth: 1180).frame(maxWidth: .infinity) } }
    }.onAppear { store.refresh(force: true) }
      .onReceive(refresh) { _ in store.refresh() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh(force: true) }
      .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in store.refresh(force: true) }
      .sheet(isPresented: $showAdd) { addSheet }
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("默认打开").font(.system(size: 25, weight: .semibold))
          Text("与 macOS 同步").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 34, height: 34) }
          .buttonStyle(GlassCircleButtonStyle()).disabled(store.refreshing).help("重新读取系统关联")
        Menu {
          Button("输入扩展名…") { extensionText = ""; addError = nil; showAdd = true }
          Button("选取文件…") { chooseFile() }
        } label: { Label("添加格式", systemImage: "plus").frame(minHeight: 22) }
          .menuStyle(.button).menuIndicator(.hidden).buttonStyle(DisplayButtonStyle())
      }
      if store.changing != nil {
        Label("请在 macOS 弹窗中确认", systemImage: "macwindow").font(.system(size: 12)).foregroundStyle(Theme.accent)
      }
      if let error = store.error { feedback(error, error: true) }
      else if let message = store.message { feedback(message, error: false) }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 3), spacing: 14) {
        ForEach(store.items.filter { $0.category == "常用" }) { item in DefaultOpenRow(item: item, prominent: true) }
      }
      HStack(spacing: 12) {
        ScrollView(.horizontal) { SettingsGlassSegments(selection: $category, options: categories, compact: true) }.scrollIndicators(.hidden)
        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("搜索格式", text: $search).textFieldStyle(.plain)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(width: embedded ? 140 : 185, height: 36)
          .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
      }
      if filtered.isEmpty {
        ContentUnavailableView(search.isEmpty ? "还没有格式" : "没有匹配的格式", systemImage: "doc.badge.plus", description: Text("添加扩展名或选取一个文件"))
          .frame(maxWidth: .infinity, minHeight: 170)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: embedded ? 280 : 400), spacing: 14)], spacing: 12) {
          ForEach(filtered) { item in DefaultOpenRow(item: item) }
        }
      }
      Text("修改会应用到同类文件；已有文件的单独指定仍以 Finder 为准。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func feedback(_ text: String, error: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: error ? "exclamationmark.circle" : "checkmark.circle")
      Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button { store.error = nil; store.message = nil } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }.buttonStyle(GlassCircleButtonStyle())
    }.foregroundStyle(error ? Color.orange : Theme.accent).padding(12)
      .background((error ? Color.orange : Theme.accent).opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
  }
  private var addSheet: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("添加格式").font(.system(size: 20, weight: .semibold))
      TextField("扩展名，例如 psd", text: $extensionText).textFieldStyle(.roundedBorder).onSubmit { addExtension() }
      if let item = DefaultAppsStore.item(for: extensionText) {
        Label(item.detail, systemImage: "doc").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
      }
      if let addError { Text(addError).font(.system(size: 12)).foregroundStyle(.orange) }
      HStack { Button("选取文件…") { showAdd = false; chooseFile() }.buttonStyle(DisplayButtonStyle(compact: true)); Spacer(); Button("取消") { showAdd = false }.buttonStyle(DisplayButtonStyle(compact: true)); Button("添加") { addExtension() }.buttonStyle(DisplayButtonStyle(compact: true)).keyboardShortcut(.defaultAction).disabled(extensionText.trimmingCharacters(in: .whitespaces).isEmpty) }
    }.padding(24).frame(width: 410).tint(Theme.accent)
  }
  private func addExtension() {
    if store.add(extensionText) != nil { category = "全部"; search = ""; showAdd = false }
    else { addError = store.error; store.error = nil }
  }
  private func chooseFile() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    panel.message = "只读取文件格式，不会打开或修改文件。"; panel.prompt = "添加此格式"
    if panel.runModal() == .OK, let url = panel.url {
      guard !url.pathExtension.isEmpty else { store.error = "这个文件没有扩展名，请输入要设置的格式。"; return }
      if store.add(url.pathExtension) != nil { category = "全部"; search = "" }
    }
  }
}

private struct DefaultOpenRow: View {
  let item: DefaultOpenItem
  var prominent = false
  @ObservedObject private var store = DefaultAppsStore.shared
  @State private var showChooser = false
  private var status: DefaultOpenStatus? { store.statuses[item.id] }
  var body: some View {
    Button { showChooser = true } label: {
      if prominent {
        VStack(alignment: .leading, spacing: 15) {
          HStack(spacing: 9) {
            Image(systemName: item.symbol).foregroundStyle(Theme.accent)
            Text(item.title).fontWeight(.semibold)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
          }.font(.system(size: 13))
          HStack(spacing: 9) {
            if store.changing == item.id { ProgressView().controlSize(.small) }
            else if let application = status?.application {
              Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path)).resizable().frame(width: 25, height: 25)
            }
            Text(status?.application?.name ?? (store.refreshing ? "读取中" : "未指定"))
              .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if status?.mixed == true { Text("部分不同").font(.system(size: 10)).foregroundStyle(.orange).fixedSize() }
          }
        }.padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 108).contentShape(RoundedRectangle(cornerRadius: 17))
      } else {
      HStack(spacing: 12) {
        Image(systemName: item.symbol).font(.system(size: prominent ? 22 : 18, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 30)
        VStack(alignment: .leading, spacing: 5) {
          Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 12)
        if store.changing == item.id { ProgressView().controlSize(.small) }
        else {
          HStack(spacing: 8) {
            if let application = status?.application {
              Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path)).resizable().interpolation(.high).frame(width: 24, height: 24)
            }
            VStack(alignment: .trailing, spacing: 4) {
              Text(status?.application?.name ?? (store.refreshing ? "读取中" : "未指定"))
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
              if status?.mixed == true { Text("部分不同").font(.system(size: 10)).foregroundStyle(.orange) }
            }
          }.frame(maxWidth: 180, alignment: .trailing)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 17).frame(maxWidth: .infinity).frame(height: prominent ? 96 : 76)
        .contentShape(RoundedRectangle(cornerRadius: 17))
      }
    }.buttonStyle(CareRowStyle()).background(Theme.panel, in: RoundedRectangle(cornerRadius: 17))
      .disabled(store.changing != nil)
      .accessibilityLabel(item.title + "，" + (status?.application?.name ?? "未指定") + "，更改默认应用")
      .popover(isPresented: $showChooser, arrowEdge: .bottom) {
        DefaultApplicationChooser(item: item) { showChooser = false }
      }
      .contextMenu { if item.custom { Button("移除此格式") { store.remove(item) } } }
  }
}

private struct DefaultApplicationChooser: View {
  let item: DefaultOpenItem, close: () -> Void
  @ObservedObject private var store = DefaultAppsStore.shared
  @State private var search = ""
  @State private var applications: [DefaultApplication] = []
  private var current: DefaultOpenStatus? { store.statuses[item.id] }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text(item.title).font(.system(size: 15, weight: .semibold)); Spacer(); Text("默认应用").font(.system(size: 11)).foregroundStyle(.secondary) }
      if current?.mixed == true {
        VStack(spacing: 6) {
          ForEach(Array(item.targets.enumerated()), id: \.offset) { index, target in
            HStack { Text(target.name); Spacer(); Text(current?.applications[index].map { DefaultApplication(url: $0).name } ?? "未指定") }.font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
      }
      TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(applications.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { application in
            Button { close(); store.apply(application, to: item) } label: {
              HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path)).resizable().frame(width: 28, height: 28)
                Text(application.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if current?.mixed == false, DefaultAppsRules.sameApplication(current?.application?.url, application.url) { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent) }
              }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 45).contentShape(RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(CareRowStyle())
              .background(DefaultAppsRules.sameApplication(current?.application?.url, application.url) ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 11))
          }
          if applications.isEmpty { Text("没有可用应用，可手动选择。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20) }
        }
      }.frame(height: 320)
      Divider()
      Button { chooseApplication() } label: { Label("其他应用…", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 24, alignment: .leading) }.buttonStyle(DisplayButtonStyle(compact: true))
      if item.custom { Button("移除此格式") { close(); store.remove(item) }.buttonStyle(DisplayButtonStyle(compact: true)) }
    }.padding(18).frame(width: 380).tint(Theme.accent).onAppear { applications = store.applications(for: item) }
  }
  private func chooseApplication() {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "设为默认应用"; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      guard url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier != nil else { return }
      close(); store.apply(DefaultApplication(url: url), to: item)
    }
  }
}
