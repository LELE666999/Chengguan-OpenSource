import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum DisplayInspector: String, Identifiable {
  case image = "图像与色彩", device = "设备控制", layout = "排列与旋转", scenes = "场景", advanced = "高级", details = "显示器详情"
  case colorMode = "色彩模式", streaming = "画中画与串流", protection = "配置保护", management = "管理显示器"
  var id: String { rawValue }
  var symbol: String {
    switch self { case .image: "slider.horizontal.3"; case .device: "switch.2"; case .layout: "rectangle.3.group"; case .scenes: "square.stack"; case .advanced: "square.3.layers.3d"; case .details: "info.circle"; case .colorMode: "circle.lefthalf.filled"; case .streaming: "pip"; case .protection: "shield.lefthalf.filled"; case .management: "display.2" }
  }
}
struct DisplayWorkspace: View {
  @ObservedObject private var store = DisplayControlStore.shared
  @State private var showDetails = false
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let device = store.current {
            HStack {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                  Text(device.name).font(.system(size: 25, weight: .semibold))
                  Label("已连接", systemImage: "circle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.green.opacity(0.09), in: Capsule())
                }
                Text(displaySubtitle(device)).font(.system(size: 12)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              DisplayPicker(selection: Binding(get: { device.id }, set: { store.selected = $0 }), compact: false)
              Button("识别") { store.identify(device) }.buttonStyle(DisplayButtonStyle())
              Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 34, height: 34) }
                .buttonStyle(GlassCircleButtonStyle()).disabled(store.loading).help("刷新显示器")
              Button { withAnimation { showDetails.toggle(); if showDetails { proxy.scrollTo("display-details", anchor: .top) } } } label: { Image(systemName: "info.circle").frame(width: 34, height: 34) }
                .buttonStyle(GlassCircleButtonStyle()).help("显示器详情")
            }
            DisplayFeedback(store: store)
            HStack(alignment: .center, spacing: 28) {
              DisplayIllustration(device: device).frame(width: 245)
              VStack(spacing: 16) {
                DisplayLevels(device: device, store: store, embedded: true)
                Divider()
                DisplayModeControls(device: device, store: store, focused: true)
              }.frame(maxWidth: .infinity)
            }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
            HStack(alignment: .top, spacing: 16) {
              DisplayQuickPicture(device: device, store: store)
              DisplayQuickLayout(device: device, store: store)
            }.fixedSize(horizontal: false, vertical: true)
            DisplayDisclosure("更多控制") {
              VStack(spacing: 12) {
                ForEach([DisplayInspector.image, .device, .layout, .colorMode, .streaming, .protection, .scenes, .management, .advanced]) { section in
                  DisplayInlineGroup(device: device, section: section, compact: false)
                }
              }
            }
            if showDetails { DisplayInlineGroup(device: device, section: .details, compact: false, collapsible: false).id("display-details") }
          } else { ContentUnavailableView("尚未发现显示器", systemImage: "display", description: Text("连接显示器后会自动出现")) }
        }.padding(26).frame(maxWidth: 1180).frame(maxWidth: .infinity)
      }.onAppear { store.refresh() }
    }
  }
}
struct DisplayMenuPage: View {
  let open: (String?) -> Void
  @ObservedObject private var store = DisplayControlStore.shared
  @State private var selected: String?
  @State private var showDetails = false
  private var device: DisplayDevice? { store.displays.first { $0.id == selected } ?? store.displays.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let device {
        DisplayPicker(selection: Binding(get: { device.id }, set: { selected = $0 }), compact: true)
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            if store.displays.count == 1 { Text(device.shortName).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
            Text((device.builtin ? device.output : device.resolutionName) + " · " + (device.current?.rateLabel ?? "—") + (device.main ? " · 主显示器" : ""))
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Button { store.identify(device) } label: { Image(systemName: "scope").frame(width: 32, height: 32) }.buttonStyle(GlassCircleButtonStyle()).help("识别显示器")
          Button { withAnimation { showDetails.toggle() } } label: { Image(systemName: "info.circle").frame(width: 32, height: 32) }.buttonStyle(GlassCircleButtonStyle()).help("显示器详情")
        }.padding(.horizontal, 10).padding(.vertical, 2)
        DisplayFeedback(store: store, compact: true)
        VStack(spacing: 16) {
          DisplayLevels(device: device, store: store, compact: true, embedded: true)
          Divider()
          DisplayModeControls(device: device, store: store, compact: true, focused: true)
        }.padding(17).background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 18))
          .id(device.id)
        ForEach([DisplayInspector.image, .device, .layout, .colorMode, .streaming, .protection, .scenes, .management, .advanced]) { item in
          DisplayInlineGroup(device: device, section: item, compact: true)
        }
        if showDetails { DisplayInlineGroup(device: device, section: .details, compact: true, collapsible: false) }
        Button { open(device.id) } label: { HStack { Text("在窗口中查看"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 12, weight: .medium)).padding(12).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 12)) }
          .buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent).background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 12))
      } else { ContentUnavailableView("未发现显示器", systemImage: "display") }
    }.onAppear { store.refresh() }
      .onChange(of: device?.id) { _, _ in showDetails = false }
  }
}
private struct DisplayInlineGroup: View {
  let device: DisplayDevice
  let section: DisplayInspector
  var compact: Bool
  var collapsible = true
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var isOpen: Bool { !collapsible || expanded }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if collapsible {
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
        } label: { header.padding(compact ? 14 : 18).contentShape(RoundedRectangle(cornerRadius: 16)) }
          .buttonStyle(CareRowStyle()).accessibilityLabel(section.rawValue).accessibilityValue(expanded ? "已展开" : "已收起")
      } else { header.padding(18) }
      if isOpen {
        DisplaySectionContent(device: device, initial: section, compact: compact)
          .padding(.horizontal, compact ? 0 : 2).padding(.bottom, 12)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }.background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 16 : 22))
      .clipped().id(device.id + section.id)
  }
  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: section.symbol).foregroundStyle(Theme.accent)
      Text(section.rawValue).font(.system(size: compact ? 12 : 14, weight: .semibold))
      Spacer(minLength: 8)
      if collapsible { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(isOpen ? 180 : 0)) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
private struct DisplayDisclosure<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
      } label: {
        HStack { Text(title).font(.system(size: 12, weight: .medium)); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(expanded ? 180 : 0)) }
          .padding(12).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 12))
      }.buttonStyle(CareRowStyle()).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityValue(expanded ? "已展开" : "已收起")
      if expanded { content.padding(.top, 10).transition(.opacity) }
    }
  }
}
private func displaySubtitle(_ d: DisplayDevice) -> String {
  (d.inches.map { String(format: "%.0f 英寸 · ", $0) } ?? "") + (d.builtin ? "内置显示器" : d.virtual ? "虚拟显示器" : "外接显示器") + (d.main ? " · 主显示器" : "")
}
private struct DisplayPicker: View {
  @Binding var selection: String
  var compact: Bool
  @ObservedObject private var store = DisplayControlStore.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered: String?
  var body: some View {
    if store.displays.count > 1 {
      if compact {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
          ForEach(store.displays) { d in
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = d.id } } label: {
              ZStack {
                Color.clear
                HStack(spacing: 9) {
                Image(systemName: d.builtin ? "laptopcomputer" : "display").font(.system(size: 20, weight: .regular))
                  .foregroundStyle(selection == d.id ? Theme.accent : .secondary).frame(width: 25)
                VStack(alignment: .leading, spacing: 5) {
                  Text(d.shortName).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                  Text(d.current?.dimensions ?? d.connectionLabel).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                }.padding(.horizontal, 12)
              }.frame(maxWidth: .infinity).frame(height: 60)
                .modifier(DisplaySelectionGlass(selected: selection == d.id))
                .background(Theme.accent.opacity(hovered == d.id ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(DisplayDeviceButtonStyle()).help(d.name + " · " + d.connectionLabel)
              .onHover { hovered = $0 ? d.id : nil }
              .accessibilityLabel(d.shortName + "，" + (d.current?.dimensions ?? ""))
              .accessibilityAddTraits(selection == d.id ? .isSelected : [])
          }
        }.padding(.horizontal, 2).padding(.top, 2)
      } else { ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(store.displays) { d in
            Button { selection = d.id } label: {
              Label(d.shortName, systemImage: d.builtin ? "laptopcomputer" : "display").font(.system(size: compact ? 11 : 12, weight: .medium))
                .padding(.horizontal, 13).frame(minHeight: compact ? 32 : 36).fixedSize()
                .foregroundStyle(selection == d.id ? Theme.selectionForeground : Color.secondary)
                .background(selection == d.id ? Theme.accent : .clear, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(CareRowStyle())
          }
        }.padding(4)
      }.scrollIndicators(.hidden).modifier(ChromeGlass()).frame(maxWidth: 420) }
    }
  }
}
private struct DisplaySelectionGlass: ViewModifier {
  var selected: Bool
  func body(content: Content) -> some View {
    content.background {
      Group {
        if #available(macOS 26.0, *) {
          RoundedRectangle(cornerRadius: 14).fill(.clear)
            .glassEffect(.regular.tint(selected ? Theme.accent.opacity(0.12) : .clear), in: .rect(cornerRadius: 14))
        } else { RoundedRectangle(cornerRadius: 14).fill(.regularMaterial) }
      }.allowsHitTesting(false)
    }.overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent.opacity(0.65) : .clear, lineWidth: 1).allowsHitTesting(false))
  }
}
private struct DisplayDeviceButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
private struct DisplayIllustration: View {
  let device: DisplayDevice
  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 0) {
        ZStack {
          RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.32))
          RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.12)).padding(6)
          VStack(spacing: 12) {
            Text(device.resolutionName).font(.system(size: 44, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent)
            Text(device.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
          }
        }.frame(width: 228, height: 142)
        Rectangle().fill(Color.secondary.opacity(0.42)).frame(width: 19, height: 22)
        Capsule().fill(Color.secondary.opacity(0.42)).frame(width: 100, height: 5)
      }.padding(.vertical, 8).accessibilityHidden(true)
      Text(displaySubtitle(device)).font(.system(size: 11)).foregroundStyle(.secondary)
      HStack(spacing: 7) {
        if device.current?.hiDPI == true { displayTag("HiDPI") }
        if device.hdrPotential { displayTag("支持 HDR") }
        displayTag(device.builtin ? "内置" : device.virtual ? "虚拟屏" : "外接")
      }
    }.frame(maxWidth: .infinity)
  }
}
// The two quick panels use the same header and three 42-point rows. Expanded controls
// live below the pair, so an unrelated panel never gains a mismatched bottom edge.
private struct DisplayQuickPicture: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("画面", systemImage: "circle.lefthalf.filled").font(.system(size: 14, weight: .semibold))
      VStack(spacing: 0) {
        DisplayQuickRow("实际输出", value: device.output)
        Divider()
        DisplayQuickRow("渲染分辨率", value: device.current.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "—")
        Divider()
        Button { chooseDisplayProfile(device, store: store) } label: {
          HStack { Text("颜色描述文件"); Spacer(); Label("导入 ICC", systemImage: "plus") }.frame(maxWidth: .infinity, minHeight: 42).contentShape(RoundedRectangle(cornerRadius: 10))
        }.font(.system(size: 12)).buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent)
      }
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
  }
}
private struct DisplayQuickLayout: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("布局", systemImage: "rectangle.3.group").font(.system(size: 14, weight: .semibold))
      VStack(spacing: 0) {
        HStack {
          Text("主显示器").foregroundStyle(.secondary); Spacer()
          if device.main { Label("当前主屏", systemImage: "checkmark").foregroundStyle(Theme.accent) }
          else { Button("设为主屏") { store.makeMain(device) }.buttonStyle(DisplayButtonStyle(compact: true)) }
        }.font(.system(size: 12)).frame(height: 42)
        Divider()
        HStack(spacing: 7) {
          Text("方向").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(minLength: 6)
          ForEach([0, 90, 180, 270], id: \.self) { angle in
            Button { store.bridge("set", device: device, arguments: ["-rotation=\(angle)"]) } label: {
              Text("\(angle)°").font(.system(size: 11, weight: .medium)).frame(minWidth: 41, minHeight: 30)
                .foregroundStyle(Int(device.rotation) == angle ? Theme.accent : .secondary)
                .background(Theme.accent.opacity(Int(device.rotation) == angle ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(CareRowStyle()).disabled(!store.bridgeEnabled || store.busy)
              .help(store.bridgeEnabled ? "旋转显示器" : "在更多控制中启用兼容引擎")
          }
        }.frame(height: 42)
        Divider()
        Button { store.openSystemSettings() } label: {
          HStack { Text("系统显示设置"); Spacer(); Image(systemName: "arrow.up.right") }.frame(maxWidth: .infinity, minHeight: 42).contentShape(RoundedRectangle(cornerRadius: 10))
        }.font(.system(size: 12)).buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent)
      }
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
  }
}
private struct DisplayQuickRow: View {
  let title: String, value: String
  init(_ title: String, value: String) { self.title = title; self.value = value }
  var body: some View {
    HStack(spacing: 12) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit() }.font(.system(size: 12)).frame(height: 42)
  }
}
@MainActor private func chooseDisplayProfile(_ device: DisplayDevice, store: DisplayControlStore) {
  let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }; panel.canChooseDirectories = false
  if panel.runModal() == .OK, let url = panel.url { store.setProfile(url, on: device) }
}
private func displayTag(_ text: String) -> some View {
  Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 5).background(Color.primary.opacity(0.045), in: Capsule())
}
private struct DisplayLevels: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  @ObservedObject private var audio = DisplayAudioStore.shared
  var compact = false
  var embedded = false
  private var hardwareVolume: Double? { store.hardware[device.id]?.volume }
  private var usesDDC: Bool { hardwareVolume != nil && audio.associations[device.id] == nil }
  var body: some View {
    VStack(spacing: embedded ? 14 : compact ? 20 : 24) {
      DisplayLevelSlider(title: "亮度", symbol: "sun.max", value: store.hardware[device.id]?.brightness) { store.setBrightness($0, on: device) }
      VStack(alignment: .leading, spacing: 9) {
        DisplayLevelSlider(title: "音量", symbol: "speaker.wave.2", value: usesDDC ? hardwareVolume : audio.output(for: device).flatMap { $0.writable ? $0.volume : nil }) { value in
          if usesDDC { store.setPercent(value, code: 0x62, on: device) }
          else if let output = audio.output(for: device) { audio.setVolume(value, output: output) }
        }
        Menu {
          Button { audio.associate(nil, with: device.id) } label: {
            if audio.associations[device.id] == nil { Label("自动匹配", systemImage: "checkmark") } else { Text("自动匹配") }
          }
          Divider()
          ForEach(audio.outputs) { output in
            Button { audio.associate(output.id, with: device.id) } label: {
              if audio.associations[device.id] == output.id { Label(output.name, systemImage: "checkmark") }
              else { Text(output.name + (output.writable ? "" : " · 无原生音量")) }
            }
          }
        } label: {
          HStack(spacing: 5) {
            Text(usesDDC ? "显示器 · DDC" : (audio.isSystemFallback(device) ? "系统输出 · " : "音频输出 · ") + (audio.output(for: device)?.name ?? "未连接"))
              .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
          }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 9).frame(minHeight: 28).contentShape(RoundedRectangle(cornerRadius: 9))
        }.menuStyle(.button).buttonStyle(CareRowStyle()).menuIndicator(.hidden)
          .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel("音量控制设备")
        if !usesDDC, let output = audio.output(for: device), !output.writable {
          Text("此输出没有原生音量；可选择扬声器或耳机。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if let error = audio.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
      }
    }.padding(embedded ? 0 : compact ? 17 : 22).background(embedded ? Color.clear : compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22)).onAppear { audio.refresh() }
  }
}
private struct DisplayLevelSlider: View {
  let title: String, symbol: String
  let value: Double?
  var range: ClosedRange<Double> = 0...100
  var suffix = "%"
  let set: (Double) -> Void
  @State private var draft = 0.0
  @State private var dragging = false
  var body: some View {
    VStack(spacing: 11) {
      HStack {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        Spacer()
        Text(value == nil ? "—" : String(format: suffix == "%" ? "%.0f%%" : "%.2f", draft) + (suffix == "%" ? "" : suffix))
          .font(Theme.number(14)).monospacedDigit().contentTransition(.numericText())
      }
      Slider(value: Binding(get: { draft }, set: { draft = $0; set($0) }), in: range, onEditingChanged: { editing in
        dragging = editing
        if !editing { set(draft); dragging = false }
      }).tint(Theme.accent).disabled(value == nil).accessibilityLabel(title)
    }.onChange(of: value) { _, v in if !dragging { draft = v ?? range.lowerBound } }
      .onAppear { draft = value ?? range.lowerBound }
  }
}
private struct DisplayModeControls: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  var compact = false
  var focused = false
  @State private var draft = 0.0
  @State private var dragging = false
  @State private var keyboardCommit: Task<Void, Never>?
  private var modes: [DisplayModeChoice] { device.modes.filter { $0.hiDPI == (device.current?.hiDPI ?? false) } }
  private var resolutions: [DisplayModeChoice] {
    DisplayRules.scalingModes(device.modes, current: device.current)
  }
  private var rates: [DisplayModeChoice] { modes.filter { $0.width == device.current?.width && $0.height == device.current?.height } }
  private var activeIndex: Int { resolutions.firstIndex { $0.signature == device.current?.signature } ?? 0 }
  private var preview: DisplayModeChoice? { DisplayRules.scalingIndex(draft, count: resolutions.count).map { resolutions[$0] } }
  var body: some View {
    VStack(alignment: .leading, spacing: focused ? 8 : 12) {
      HStack {
        Text("桌面缩放").font(.system(size: 12, weight: .semibold))
        Spacer()
        if focused {
          Text(preview?.dimensions ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.accent).padding(.horizontal, 11).frame(height: 30)
            .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
        }
        Button {
          let enabled = !(device.current?.hiDPI ?? false)
          if let current = device.current, let next = device.modes.filter({ $0.hiDPI == enabled }).min(by: { abs($0.width - current.width) < abs($1.width - current.width) }) { store.changeMode(next, on: device) }
        } label: {
          HStack(spacing: 5) { Image(systemName: device.current?.hiDPI == true ? "checkmark" : "circle"); Text("HiDPI") }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
            .foregroundStyle(device.current?.hiDPI == true ? Theme.accent : .secondary).contentShape(Capsule())
        }.buttonStyle(CareRowStyle()).background(Theme.accent.opacity(device.current?.hiDPI == true ? 0.1 : 0.03), in: Capsule())
          .disabled(store.pendingMode != nil || !device.modes.contains { $0.hiDPI != (device.current?.hiDPI ?? false) })
      }
      VStack(spacing: focused ? 6 : 11) {
        if !focused { HStack {
          Text(dragging ? "松手应用" : "看起来像").font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer()
          Text(preview?.dimensions ?? "—").font(.system(size: 14, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.accent).padding(.horizontal, 11).padding(.vertical, 7)
            .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
        } }
        Slider(value: Binding(get: { draft }, set: { value in
          draft = value
          keyboardCommit?.cancel()
          if !dragging {
            keyboardCommit = Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(250))
              guard !Task.isCancelled, !dragging else { return }; commitScaling()
            }
          }
        }), in: 0...Double(max(1, resolutions.count - 1)), step: 1, onEditingChanged: { editing in
          keyboardCommit?.cancel(); dragging = editing
          if !editing { commitScaling() }
        }).tint(Theme.accent).disabled(resolutions.count < 2 || store.pendingMode != nil)
          .accessibilityLabel("桌面缩放滑块").accessibilityValue(preview?.dimensions ?? "无可用模式")
        HStack {
          Text("更大文字"); Spacer()
          Text("当前 \(device.current?.dimensions ?? "—")").foregroundStyle(Theme.accent)
          Spacer(); Text("更多空间")
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(focused ? 0 : 13).background(Color.primary.opacity(focused ? 0 : 0.035), in: RoundedRectangle(cornerRadius: 13))
      HStack(spacing: 10) {
        Menu {
          if let current = device.current { Button {} label: { Label("当前 · " + current.dimensions, systemImage: "checkmark") }; Divider() }
          ForEach(resolutions) { choice in
            Button { store.changeMode(choice, on: device) } label: {
              if choice.dimensions == device.current?.dimensions { Label(choice.dimensions + " · 当前", systemImage: "checkmark") } else { Text(choice.dimensions) }
            }
          }
        } label: { Label("全部分辨率", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 30) }
          .menuStyle(.button).buttonStyle(DisplayButtonStyle(compact: true)).menuIndicator(.hidden).disabled(store.pendingMode != nil)
        Menu {
          ForEach(rates) { choice in Button { store.changeMode(choice, on: device) } label: {
            if choice.signature == device.current?.signature { Label(choice.rateLabel, systemImage: "checkmark") } else { Text(choice.rateLabel) }
          } }
        } label: {
          HStack { Text("刷新率").foregroundStyle(.secondary); Spacer(); Text(device.current?.rateLabel ?? "—").fontWeight(.medium); if rates.count > 1 { Image(systemName: "chevron.up.chevron.down") } }
            .font(.system(size: 11)).padding(.horizontal, 11).frame(minHeight: 38).contentShape(RoundedRectangle(cornerRadius: 10))
        }.menuStyle(.button).buttonStyle(CareRowStyle()).menuIndicator(.hidden).frame(maxWidth: .infinity).disabled(store.pendingMode != nil || rates.count < 2).accessibilityLabel("刷新率")
      }
      if !focused { HStack(spacing: 10) {
        Button { chooseProfile() } label: { Label("颜色描述文件", systemImage: "circle.lefthalf.filled").frame(maxWidth: .infinity, minHeight: 22) }.buttonStyle(DisplayButtonStyle(compact: true))
        Button { store.openSystemSettings() } label: { Label("系统显示设置", systemImage: "display").frame(maxWidth: .infinity, minHeight: 22) }.buttonStyle(DisplayButtonStyle(compact: true))
      } }
      Divider().padding(.top, 4)
      DisplayModeMemoryControl(device: device, memory: store.modeMemory).disabled(store.pendingMode != nil)
    }.padding(focused ? 0 : compact ? 16 : 20).background(focused ? Color.clear : compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 18 : 22))
      .onAppear { draft = Double(activeIndex) }
      .onChange(of: device.current?.signature) { _, _ in if !dragging { draft = Double(activeIndex) } }
      .onChange(of: device.id) { _, _ in keyboardCommit?.cancel(); dragging = false; draft = Double(activeIndex) }
      .onDisappear { keyboardCommit?.cancel() }
  }
  private func commitScaling() {
    guard let preview else { return }; store.changeMode(preview, on: device)
  }
  private func modeChoice(title: String, value: String, symbol: String) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 7) {
        Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
        Text(value).font(.system(size: compact ? 13 : 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.85)
      }
      Spacer(minLength: 4)
      Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: compact ? 64 : 70, alignment: .leading)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13)).contentShape(RoundedRectangle(cornerRadius: 13))
  }
  private func chooseProfile() {
    chooseDisplayProfile(device, store: store)
  }
}
private struct DisplayModeMemoryControl: View {
  let device: DisplayDevice
  @ObservedObject var memory: DisplayModeMemoryController
  private var profile: DisplayModeMemory? { memory.profiles[device.id] }
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").font(.system(size: 13)).foregroundStyle(Theme.accent)
      VStack(alignment: .leading, spacing: 3) {
        Text("记住缩放").font(.system(size: 11, weight: .medium))
        if let profile, profile.enabled {
          Text(profile.mode.dimensions + " · " + profile.mode.rateLabel).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 6)
      if let profile, profile.enabled, profile.mode.signature != device.current?.signature {
        Button { memory.restoreNow(device) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28) }
          .buttonStyle(GlassCircleButtonStyle()).help("恢复已记住的缩放")
      }
      Menu {
        Button("记住当前缩放") { memory.remember(device) }
        if profile?.enabled == true { Button("恢复已记住的缩放") { memory.restoreNow(device) } }
        if let status = memory.status[device.id] { Divider(); Text(status) }
      } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Circle()) }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GlassCircleButtonStyle()).help("缩放记忆选项")
      Toggle("记住缩放", isOn: Binding(get: { profile?.enabled == true }, set: { memory.setEnabled($0, on: device) }))
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
    }.padding(.top, 4).help("为这台显示器单独记住分辨率、HiDPI 和刷新率；唤醒或重连后恢复。")
  }
}
private struct DisplayFeedback: View {
  @ObservedObject var store: DisplayControlStore
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let pending = store.pendingMode {
        HStack(spacing: 10) {
          Image(systemName: "timer").foregroundStyle(.orange)
          Text("保留此模式？\(pending.seconds) 秒后恢复").font(.system(size: compact ? 11 : 12, weight: .medium))
          Spacer(minLength: 4)
          Button("恢复") { store.revertMode() }.buttonStyle(DisplayButtonStyle(compact: true))
          Button("保留") { store.keepMode() }.buttonStyle(DisplayButtonStyle(compact: true)).tint(Theme.accent)
        }.padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
      }
      if let error = store.error {
        HStack(alignment: .top) {
          Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          Button { store.error = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(GlassCircleButtonStyle()).help("关闭提示")
        }.padding(10).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
      } else if let message = store.message {
        HStack { Text(message).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button { store.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 22) }.buttonStyle(GlassCircleButtonStyle()).help("关闭提示") }
      }
    }
  }
}
struct DisplayButtonStyle: ButtonStyle {
  var compact = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: compact ? 11 : 12, weight: .medium))
      .padding(.horizontal, compact ? 11 : 14).frame(minHeight: compact ? 30 : 36)
      .modifier(DisplayButtonSurface(pressed: configuration.isPressed))
  }
}
private struct DisplayButtonSurface: ViewModifier {
  let pressed: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content.foregroundStyle(hovered ? Theme.accent : .primary).modifier(ChromeGlass())
      .background(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.045 : 0), in: Capsule()).contentShape(Capsule())
      .opacity(enabled ? 1 : 0.45).scaleEffect(pressed ? 0.97 : 1)
      .onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: pressed)
  }
}

private struct DisplaySectionContent: View {
  let device: DisplayDevice
  let initial: DisplayInspector
  var compact = false
  @ObservedObject private var store = DisplayControlStore.shared
  @State private var color = DisplayColorAdjustment.identity
  @State private var sceneName = ""
  @State private var target = ""
  @State private var side = "右侧"
  @State private var input: UInt16 = 15
  @State private var showInputConfirmation = false
  @State private var showPowerConfirmation = false
  @State private var report: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if initial == .image { imageControls }
      else if initial == .device { deviceControls }
      else if initial == .layout { layoutControls }
      else if initial == .scenes { sceneControls }
      else if initial == .advanced { DisplayAdvancedControls(device: device, store: store) }
      else if [.colorMode, .streaming, .protection, .management].contains(initial) { compatibilityControls }
      else { details }
      if let report {
        DisplayDisclosure("原始报告") { Text(report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12) }
      }
    }.padding(.horizontal, initial == .advanced ? 16 : 0).tint(Theme.accent)
      .onAppear { color = store.colors[device.id] ?? .identity; target = store.displays.first { $0.id != device.id }?.id ?? "" }
      .onChange(of: store.colors[device.id]) { _, value in color = value ?? .identity }
      .confirmationDialog("切换显示器输入源？", isPresented: $showInputConfirmation) {
        Button("切换输入源") { store.setVCP(input, code: 0x60, on: device) }
        Button("取消", role: .cancel) {}
      } message: { Text("请选择已连接的信号源。切换后可能需要用显示器实体按键切回。") }
      .confirmationDialog("让显示器进入待机？", isPresented: $showPowerConfirmation) {
        Button("显示器待机") { store.setVCP(4, code: 0xd6, on: device) }
        Button("取消", role: .cancel) {}
      } message: { Text("画面会暂时关闭，可用显示器电源键唤醒。") }
  }
  private var imageControls: some View {
    VStack(alignment: .leading, spacing: 18) {
      Panel(padding: 18) {
        VStack(spacing: 18) {
          DisplayLevelSlider(title: "软件亮度", symbol: "sun.min", value: color.brightness * 100, range: 10...100) { value in color.brightness = value / 100; store.adjustColor(color, on: device) }
          DisplayLevelSlider(title: "伽马", symbol: "circle.lefthalf.filled", value: color.gamma, range: 0.4...2.5, suffix: "") { color.gamma = $0; store.adjustColor(color, on: device) }
          ForEach(["红", "绿", "蓝"], id: \.self) { channel in
            DisplayLevelSlider(title: channel + "色增益", symbol: "circle.fill", value: channel == "红" ? color.red * 100 : channel == "绿" ? color.green * 100 : color.blue * 100) { value in
              if channel == "红" { color.red = value / 100 }; if channel == "绿" { color.green = value / 100 }; if channel == "蓝" { color.blue = value / 100 }
              store.adjustColor(color, on: device)
            }
          }
          HStack {
            Button("暖色") { color.red = 1; color.green = 0.88; color.blue = 0.70; store.adjustColor(color, on: device) }.buttonStyle(DisplayButtonStyle(compact: true))
            Button("中性") { color.red = 1; color.green = 1; color.blue = 1; store.adjustColor(color, on: device) }.buttonStyle(DisplayButtonStyle(compact: true))
            Spacer()
            Button("恢复原色表") { store.resetColor(device); color = .identity }.buttonStyle(DisplayButtonStyle(compact: true))
          }
        }
      }
      Text("软件调色 · 退出恢复").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18)
      if store.bridgeEnabled {
        DisplayDisclosure("滤镜与高级色彩 · 兼容引擎") { DisplayFilterControls(device: device, store: store).padding(.top, 15) }
      }
    }
  }
  private var deviceControls: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text("DDC / CI").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); Spacer(); Button("检测控制能力") { store.probeDetails(device) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.busy) }.padding(.horizontal, 20)
      Panel(padding: 20) {
        VStack(spacing: 22) {
          ForEach([UInt8(0x12), 0x16, 0x18, 0x1a, 0x6c, 0x6e, 0x70], id: \.self) { code in
            DisplayLevelSlider(title: [UInt8(0x12): "硬件对比度", 0x16: "红色增益", 0x18: "绿色增益", 0x1a: "蓝色增益", 0x6c: "红色黑电平", 0x6e: "绿色黑电平", 0x70: "蓝色黑电平"][code]!, symbol: "slider.horizontal.3", value: store.hardware[device.id]?.values[code]?.percent) { store.setPercent($0, code: code, on: device) }
          }
        }
      }
      Panel {
        VStack(alignment: .leading, spacing: 14) {
          HStack { Text("输入源").font(.system(size: 13, weight: .medium)); Spacer(); Text(store.hardware[device.id]?.values[0x60].map { "当前编码 \($0.value)" } ?? "尚未读取").font(.system(size: 11)).foregroundStyle(.secondary) }
          HStack {
            Picker("输入源", selection: $input) {
              Text("DisplayPort 1").tag(UInt16(15)); Text("DisplayPort 2").tag(UInt16(16)); Text("HDMI 1").tag(UInt16(17)); Text("HDMI 2").tag(UInt16(18)); Text("USB-C").tag(UInt16(27))
            }.labelsHidden()
            Button("切换") { showInputConfirmation = true }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.hardware[device.id]?.values[0x60] == nil)
          }
          Text("以上为常见 VCP 编码，具体端口以显示器说明为准。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      HStack {
        Button("静音") { store.setVCP(1, code: 0x8d, on: device) }.buttonStyle(DisplayButtonStyle()).disabled(store.hardware[device.id]?.values[0x8d] == nil)
        Button("取消静音") { store.setVCP(2, code: 0x8d, on: device) }.buttonStyle(DisplayButtonStyle()).disabled(store.hardware[device.id]?.values[0x8d] == nil)
        Spacer()
        Button("显示器待机") { showPowerConfirmation = true }.buttonStyle(DisplayButtonStyle()).disabled(store.hardware[device.id]?.values[0xd6] == nil)
      }.padding(.horizontal, 20)
    }.onAppear { if store.hardware[device.id]?.values[0x12] == nil { store.probeDetails(device) } }
  }
  @ViewBuilder private var compatibilityControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !store.bridgeEnabled {
        Toggle("启用兼容引擎", isOn: $store.bridgeEnabled).disabled(!store.bridgeAvailable)
        Text("此组由本机 BetterDisplay 提供，需要在后台运行及相应授权。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("BetterDisplay 兼容引擎").font(.system(size: 10)).foregroundStyle(.secondary)
        if initial == .colorMode {
          DisplayRemoteSwitch(title: "HDR", parameter: "hdr", device: device, store: store)
          DisplayRemoteSwitch(title: "HDR / XDR 亮度扩展", parameter: "brightnessUpscaling", device: device, store: store)
          DisplayRemoteSwitch(title: "GPU 抖动", parameter: "gpuDithering", device: device, store: store)
          DisplayRemoteSwitch(title: "暂停图像调整", parameter: "suspendImageAdjustments", device: device, store: store)
        } else if initial == .streaming {
          DisplayRemoteSwitch(title: "画中画", parameter: "pip", device: device, store: store)
          DisplayRemoteSwitch(title: "屏幕串流", parameter: "stream", device: device, store: store)
          DisplayRemoteSwitch(title: "窗口串流", parameter: "contentStreamWindow", device: device, store: store)
          Text("来源和目的地沿用引擎配置；首次使用需要系统屏幕录制授权。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if initial == .protection {
          ForEach([("分辨率", "protectResolution"), ("刷新率", "protectRefreshRate"), ("HDR", "protectHDR"), ("旋转", "protectRotation"), ("主屏", "protectAsMain"), ("SDR 描述文件", "protectSDRProfile"), ("HDR 描述文件", "protectHDRProfile"), ("全部配置", "protectAll")], id: \.1) { item in
            DisplayRemoteSwitch(title: item.0, parameter: item.1, device: device, store: store)
          }
        } else {
          Button { store.bridge("perform", device: device, arguments: ["-reinitialize"]) } label: { Label("重新检测此显示器", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 28) }.buttonStyle(DisplayButtonStyle())
          Button { store.bridge("perform", device: nil, arguments: ["-connectAllDisplays"]) } label: { Label("连接全部显示器", systemImage: "display.2").frame(maxWidth: .infinity, minHeight: 28) }.buttonStyle(DisplayButtonStyle())
          Text("虚拟屏和链路诊断位于下方高级选项。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }.padding(.horizontal, 15)
  }
  private var layoutControls: some View {
    VStack(alignment: .leading, spacing: 18) {
      Panel {
        VStack(spacing: 18) {
          HStack { Label(device.main ? "当前主显示器" : "设为主显示器", systemImage: "menubar.rectangle"); Spacer(); Button("设为主屏") { store.makeMain(device) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(device.main) }
          if !others.isEmpty {
            Divider()
            Picker("相对显示器", selection: $target) { ForEach(others) { Text($0.name).tag($0.id) } }
            HStack {
              Picker("排列", selection: $side) { ForEach(["左侧", "右侧", "上方", "下方"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
              Button("排列") { if let other = others.first(where: { $0.id == target }) { store.arrange(device, relativeTo: other, side: side) } }.buttonStyle(DisplayButtonStyle(compact: true))
            }
            HStack { Text("镜像到选中显示器"); Spacer(); Button("镜像") { store.mirror(device, to: others.first { $0.id == target }) }.buttonStyle(DisplayButtonStyle(compact: true)) }
          } else { Text("连接第二台显示器后可排列和镜像").font(.system(size: 11)).foregroundStyle(.secondary) }
          if device.mirror != 0 { Button("停止镜像") { store.mirror(device, to: nil) }.buttonStyle(DisplayButtonStyle(compact: true)) }
        }.font(.system(size: 12))
      }
      Panel {
        VStack(alignment: .leading, spacing: 13) {
          HStack { Text("旋转").font(.system(size: 13, weight: .medium)); Spacer(); displayTag("当前 \(Int(device.rotation))°") }
          HStack { ForEach([0, 90, 180, 270], id: \.self) { angle in
            Button("\(angle)°") { store.bridge("set", device: device, arguments: ["-rotation=\(angle)"]) }.buttonStyle(DisplayButtonStyle()).disabled(!store.bridgeEnabled || store.busy)
          } }
          if !store.bridgeEnabled { Text("旋转可在高级中启用兼容引擎，或使用系统设置。").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
      }
      Button("打开系统显示设置") { store.openSystemSettings() }.buttonStyle(DisplayButtonStyle()).padding(.horizontal, 20)
    }
  }
  private var others: [DisplayDevice] { store.displays.filter { $0.id != device.id } }
  private var sceneControls: some View {
    VStack(alignment: .leading, spacing: 18) {
      Panel {
        VStack(alignment: .leading, spacing: 12) {
          Text("保存当前配置").font(.system(size: 14, weight: .semibold))
          HStack { TextField("场景名称", text: $sceneName).textFieldStyle(.roundedBorder); Button("保存") { store.saveScene(name: sceneName, for: device); sceneName = "" }.buttonStyle(DisplayButtonStyle()).disabled(sceneName.trimmingCharacters(in: .whitespaces).isEmpty) }
          Text("包含缩放、亮度、音量和澄观色彩调整，按显示器独立保存。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      ForEach(store.scenes.filter { $0.displayUUID == device.id }) { scene in
        HStack { Text(scene.name).font(.system(size: 13, weight: .medium)); Spacer(); Button("应用") { store.applyScene(scene, on: device) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.pendingMode != nil); Button { store.deleteScene(scene) } label: { Image(systemName: "trash").frame(width: 30, height: 30) }.buttonStyle(GlassCircleButtonStyle()).help("删除场景") }.padding(15).background(Theme.panel, in: RoundedRectangle(cornerRadius: 15))
      }
      if store.bridgeEnabled {
        Text("配置保护 · 兼容引擎").font(.system(size: 13, weight: .semibold))
        DisplayRemoteSwitch(title: "分辨率保护", parameter: "protectResolution", device: device, store: store)
        DisplayRemoteSwitch(title: "刷新率保护", parameter: "protectRefreshRate", device: device, store: store)
        DisplayRemoteSwitch(title: "全部配置保护", parameter: "protectAll", device: device, store: store)
      }
    }
  }
  private var details: some View {
    VStack(alignment: .leading, spacing: 16) {
      Panel {
        VStack(spacing: 14) {
          DisplayInfoRow("实际输出", device.output)
          DisplayInfoRow("桌面缩放", device.current?.dimensions ?? "—")
          DisplayInfoRow("渲染分辨率", device.current.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "—")
          DisplayInfoRow("刷新率", device.current.map { String(format: "%.3f Hz", $0.refresh) } ?? "—")
          DisplayInfoRow("HiDPI", device.current?.hiDPI == true ? "是" : "否")
          DisplayInfoRow("EDR 当前上限", String(format: "%.2f×", device.edr))
          DisplayInfoRow("HDR 能力", device.hdrPotential ? "当前链路支持扩展动态范围" : "当前链路未报告")
          DisplayInfoRow("尺寸", device.inches.map { String(format: "%.1f 英寸", $0) } ?? "—")
          if let manufactured = device.manufactured { DisplayInfoRow("制造日期", manufactured) }
        }
      }
      DisplayDisclosure("设备标识与模式") {
        VStack(spacing: 12) {
          DisplayInfoRow("UUID", device.id); DisplayInfoRow("供应商 / 型号", String(format: "%04X / %04X", device.vendor, device.model)); DisplayInfoRow("序列号", "\(device.serial)")
          DisplayInfoRow("可选模式", "\(device.modes.count)")
          Button("复制诊断") {
            let data = try? JSONEncoder().encode(device)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(data.flatMap { String(data: $0, encoding: .utf8) } ?? "", forType: .string); store.message = "诊断已复制"
          }.buttonStyle(DisplayButtonStyle(compact: true))
        }.padding(.top, 15)
      }
      if store.bridgeEnabled { Button("读取完整链路报告") { store.bridge(device: device, arguments: ["-displayInformation"]) { report = $0 } }.buttonStyle(DisplayButtonStyle()).disabled(store.busy) }
    }
  }
}
private struct DisplayInfoRow: View {
  let title: String, value: String
  init(_ title: String, _ value: String) { self.title = title; self.value = value }
  var body: some View { HStack(alignment: .top, spacing: 18) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 5); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
}

private struct DisplayRemoteSwitch: View {
  let title: String, parameter: String
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  @State private var status: String?
  @State private var value: Bool?
  @State private var reading = false
  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); if let status { Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) } }
      Spacer(minLength: 8)
      if reading { ProgressView().controlSize(.small) }
      else if value == nil {
        Button { read() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }.buttonStyle(GlassCircleButtonStyle()).help("重新读取")
      }
      Toggle(title, isOn: Binding(get: { value ?? false }, set: change)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        .disabled(value == nil || reading || store.busy)
    }.padding(13).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
      .task(id: device.id + ":" + parameter + ":" + String(store.bridgeEnabled)) { read() }
  }
  private func read() {
    guard store.bridgeEnabled else { return }; reading = true
    store.readBridge(parameter, device: device) { result, failure in
      reading = false; value = result.flatMap(DisplayRules.switchValue); status = failure ?? (value == nil ? "未返回状态" : nil)
    }
  }
  private func change(_ enabled: Bool) {
    store.bridge("set", device: device, arguments: ["-\(parameter)=\(enabled ? "on" : "off")"]) { _ in read() }
  }
}
private struct DisplayFilterControls: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  @State private var parameter = "saturation"
  @State private var value = "100%"
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("调整", selection: $parameter) {
        Text("饱和度").tag("saturation"); Text("色温").tag("temperature"); Text("对比度").tag("contrast"); Text("色调").tag("hue"); Text("锐度").tag("filterSharpenLuminance"); Text("阴影").tag("filterShadow"); Text("高光").tag("filterHighlight"); Text("模糊").tag("gaussianBlur")
      }
      HStack { TextField("数值或百分比", text: $value).textFieldStyle(.roundedBorder); Button("应用") { store.bridge("set", device: device, arguments: ["-\(parameter)=\(value)"]) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.busy || value.isEmpty) }
      Text(parameter == "temperature" ? "色温使用 Kelvin；例如 6500。" : "使用引擎原始数值；百分比按对应滤镜范围换算。").font(.system(size: 10)).foregroundStyle(.secondary)
      DisplayRemoteSwitch(title: "反转色彩", parameter: "inverted", device: device, store: store)
      DisplayRemoteSwitch(title: "灰度", parameter: "filterMonochrome", device: device, store: store)
      Button("重置引擎色彩调整") { store.bridge("perform", device: device, arguments: ["-resetColorAdjustments"]) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.busy)
    }
  }
}
private struct DisplayAdvancedControls: View {
  let device: DisplayDevice
  @ObservedObject var store: DisplayControlStore
  @State private var name = "澄观虚拟屏"
  @State private var resolution = "1920x1080,2560x1440,3840x2160"
  @State private var report: String?
  @State private var commandConfirmation: AdvancedAction?
  private struct AdvancedAction: Identifiable { var id = UUID(); var title: String, message: String, operation: String; var arguments: [String] }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Panel {
        VStack(alignment: .leading, spacing: 12) {
          Toggle("BetterDisplay 兼容引擎", isOn: $store.bridgeEnabled).font(.system(size: 13, weight: .semibold)).disabled(!store.bridgeAvailable)
          Text(store.bridgeAvailable ? "用于虚拟屏、HDR、画中画等高级操作。需要 BetterDisplay 在后台运行，并拥有对应授权；常用控制独立运行。" : "未找到 BetterDisplay。常用显示控制仍可使用。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      if store.bridgeEnabled {
        DisplayDisclosure("HDR 与亮度扩展") {
          VStack(spacing: 10) {
            DisplayRemoteSwitch(title: "HDR", parameter: "hdr", device: device, store: store)
            DisplayRemoteSwitch(title: "HDR / XDR 亮度扩展", parameter: "brightnessUpscaling", device: device, store: store)
          }.padding(.top, 12)
        }
        DisplayDisclosure("虚拟显示器") {
          VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("分辨率，以逗号分隔", text: $resolution).textFieldStyle(.roundedBorder)
            Button("创建虚拟屏") {
              guard DisplayAdvancedValidation.resolutions(resolution), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.error = "请输入有效名称及分辨率，如 1920x1080,2560x1440"; return }
              store.bridge("create", device: nil, arguments: ["-type=VirtualScreen", "-virtualScreenName=\(name)", "-useResolutionList=on", "-resolutionList=\(resolution)", "-virtualScreenHiDPI=on"])
            }.buttonStyle(DisplayButtonStyle())
            Text("创建后会作为独立显示器出现在顶部列表。").font(.system(size: 10)).foregroundStyle(.secondary)
          }.padding(.top, 12)
        }
        DisplayDisclosure("画中画与串流") {
          VStack(spacing: 10) {
            DisplayRemoteSwitch(title: "此屏幕画中画", parameter: "pip", device: device, store: store)
            DisplayRemoteSwitch(title: "显示器串流", parameter: "stream", device: device, store: store)
            DisplayRemoteSwitch(title: "窗口内容串流", parameter: "contentStreamWindow", device: device, store: store)
            Text("首次使用由系统确认屏幕录制权限；串流目的地与窗口来源沿用引擎配置。").font(.system(size: 10)).foregroundStyle(.secondary)
          }.padding(.top, 12)
        }
        DisplayDisclosure("连接与诊断") {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Button("链路报告") { read("displayInformation") }.buttonStyle(DisplayButtonStyle(compact: true))
              Button("EDID") { read("EDIDReport") }.buttonStyle(DisplayButtonStyle(compact: true))
              Button("DPCD") { read("DPCDReport") }.buttonStyle(DisplayButtonStyle(compact: true))
              Button("CEC") { read("CECReport") }.buttonStyle(DisplayButtonStyle(compact: true))
            }
            HStack {
              Button("重建连接") { commandConfirmation = .init(title: "重新初始化此显示器？", message: "画面可能短暂闪烁。", operation: "perform", arguments: ["-reinitialize"]) }.buttonStyle(DisplayButtonStyle(compact: true))
              Button("断开此屏幕") { commandConfirmation = .init(title: "断开此显示器？", message: "请保留另一台显示器以便重新连接。", operation: "set", arguments: ["-connected=off"]) }.buttonStyle(DisplayButtonStyle(compact: true)).disabled(store.displays.count < 2 || device.main)
              Button("连接全部显示器") { store.bridge("perform", device: nil, arguments: ["-connectAllDisplays"]) }.buttonStyle(DisplayButtonStyle(compact: true))
            }
          }.padding(.top, 12)
        }
        DisplayDisclosure("EDID 覆盖") {
          VStack(alignment: .leading, spacing: 12) {
            Text("仅接受校验通过的二进制 EDID。应用会重新配置链路，可能使画面中断。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
              Button("选择 EDID…") { chooseEDID() }.buttonStyle(DisplayButtonStyle(compact: true))
              Button("恢复出厂 EDID") { commandConfirmation = .init(title: "恢复原始 EDID？", message: "显示器连接可能短暂中断。", operation: "perform", arguments: ["-applyFactoryEDID"]) }.buttonStyle(DisplayButtonStyle(compact: true))
            }
          }.padding(.top, 12)
        }
        if let report {
          Panel { VStack(alignment: .leading, spacing: 12) { HStack { Text("诊断报告").font(.system(size: 13, weight: .semibold)); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string); store.message = "已复制" }.buttonStyle(DisplayButtonStyle(compact: true)) }; Text(report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
        }
      }
    }.disabled(store.busy)
      .confirmationDialog(commandConfirmation?.title ?? "显示器操作", isPresented: Binding(get: { commandConfirmation != nil }, set: { if !$0 { commandConfirmation = nil } })) {
        if let action = commandConfirmation { Button("继续") {
          if action.arguments.first?.hasPrefix("-customEDID=") == true {
            store.bridge("set", device: device, arguments: action.arguments) { _ in store.bridge("perform", device: device, arguments: ["-applyCustomEDID"]) }
          } else { store.bridge(action.operation, device: device, arguments: action.arguments) }
          commandConfirmation = nil
        } }
        Button("取消", role: .cancel) { commandConfirmation = nil }
      } message: { Text(commandConfirmation?.message ?? "") }
  }
  private func read(_ parameter: String) { store.bridge(device: device, arguments: ["-\(parameter)"]) { report = $0 } }
  private func chooseEDID() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), DisplayAdvancedValidation.edid(data) {
      commandConfirmation = .init(title: "应用此 EDID？", message: "这会覆盖显示器报告的能力，可能导致无画面。请保留可恢复的连接方式。", operation: "set", arguments: ["-customEDID=\(data.base64EncodedString())"])
    } else if panel.url != nil { store.error = "EDID 长度、标头或区块校验无效" }
  }
}
enum DisplayAdvancedValidation {
  static func resolutions(_ text: String) -> Bool {
    let entries = text.split(separator: ",", omittingEmptySubsequences: false)
    guard !entries.isEmpty && entries.count <= 32 else { return false }
    return entries.allSatisfy {
      let pair = $0.split(separator: "x", omittingEmptySubsequences: false)
      guard pair.count == 2, let w = Int(pair[0]), let h = Int(pair[1]) else { return false }
      return (640...16384).contains(w) && (480...16384).contains(h)
    }
  }
  static func edid(_ data: Data) -> Bool {
    guard data.count >= 128, data.count <= 4096, data.count % 128 == 0, Array(data.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0], data[126] == (data.count / 128 - 1) else { return false }
    for offset in stride(from: 0, to: data.count, by: 128) { if data[offset..<(offset + 128)].reduce(0, { ($0 + Int($1)) % 256 }) != 0 { return false } }
    return true
  }
}
