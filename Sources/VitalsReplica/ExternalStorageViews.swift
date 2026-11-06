import AppKit
import SwiftUI

/// Same grid slot as the built-in metrics; additional information stays behind the info button.
struct ExternalStorageCard: View {
  let volume: ExternalVolume
  var compact = false
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @State private var details = false
  private var tint: Color { volume.lowSpace ? .orange : Theme.accent }
  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button { storage.open(volume) } label: {
        Group {
          if compact { menuContent }
          else { windowContent }
        }.frame(maxWidth: .infinity, alignment: .leading)
          .padding(compact ? 10 : 16)
          .frame(height: compact ? 91 : 199)
          .background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
          .contentShape(RoundedRectangle(cornerRadius: compact ? 15 : 18))
      }.buttonStyle(CareRowStyle()).disabled(storage.busy.contains(volume.id))
        .help("在 Finder 打开 " + volume.name).accessibilityLabel("打开存储 " + volume.name + "，" + volume.capacityText + "，" + volume.formatDescription)
      HStack(spacing: 5) {
        Button { details.toggle() } label: {
          Label("详情", systemImage: "info.circle").font(.system(size: compact ? 10 : 11, weight: .medium))
            .padding(.horizontal, compact ? 7 : 10).frame(height: compact ? 26 : 30)
        }.buttonStyle(StorageActionButtonStyle())
          .help("存储详情").accessibilityLabel("查看存储详情 " + volume.name)
          .popover(isPresented: $details, arrowEdge: .trailing) {
            ScrollView {
              ExternalStorageRow(volume: storage.volumes.first { $0.id == volume.id } ?? volume, compact: true, initiallyExpanded: true)
                .padding(10)
            }.frame(width: 390, height: min(530, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
          }
        StorageEjectButton(volume: volume, compact: compact)
      }.padding(compact ? 5 : 8)
    }
    .alert("外接存储", isPresented: Binding(get: { storage.error != nil }, set: { if !$0 { storage.error = nil } })) {
      Button("好") { storage.error = nil }
    } message: { Text(storage.error ?? "") }
  }
  private var header: some View {
    HStack(spacing: compact ? 6 : 7) {
      Image(systemName: volume.symbol).foregroundStyle(tint)
      Text(volume.name).fontWeight(.semibold).lineLimit(1)
      Spacer(minLength: compact ? 101 : 126)
    }.font(.system(size: compact ? 11 : 13)).foregroundStyle(compact ? Color.secondary : tint)
  }
  private var menuContent: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        ValueText(text: volume.free.map(Format.bytes) ?? "—", size: 26)
        Spacer(minLength: 0)
        Text("可用").font(.system(size: 10)).foregroundStyle(.secondary)
      }.frame(height: 28)
      HStack(spacing: 2) {
        Text(volume.format.title)
        Spacer(minLength: 0)
        Text(volume.total.map { "共 " + Format.bytes($0) } ?? "可用容量未知")
      }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
      Spacer(minLength: 0)
      GaugeBar(value: volume.fraction ?? 0, color: tint, height: 6).opacity(volume.fraction == nil ? 0.3 : 1)
    }
  }
  private var windowContent: some View {
    VStack(alignment: .leading, spacing: 7) {
      header
      Text(volume.total.map { "可用，共 " + Format.bytes($0) } ?? "可用容量未知").font(.system(size: 11)).foregroundStyle(.secondary)
      ValueText(text: volume.free.map(Format.bytes) ?? "—", size: 43)
      HStack {
        Text(volume.format.title).font(.system(size: 12, weight: .medium))
        Spacer()
        if volume.readOnly == true { Label("只读", systemImage: "lock").font(.system(size: 11)) }
        else if volume.cameraFolder != nil { Image(systemName: "camera").font(.system(size: 12)).help("检测到 DCIM") }
      }.foregroundStyle(.secondary)
      Spacer(minLength: 0)
      GaugeBar(value: volume.fraction ?? 0, color: tint, height: 5).opacity(volume.fraction == nil ? 0.3 : 1).frame(height: 22)
    }.frame(height: 167, alignment: .top)
  }
}

struct ExternalStorageRow: View {
  let volume: ExternalVolume
  var compact = false
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  init(volume: ExternalVolume, compact: Bool = false, initiallyExpanded: Bool = false) {
    self.volume = volume; self.compact = compact; _expanded = State(initialValue: initiallyExpanded)
  }
  private var tint: Color { volume.lowSpace ? .orange : Theme.accent }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { storage.open(volume) } label: {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 12) {
            Image(systemName: volume.symbol).font(.system(size: compact ? 24 : 28, weight: .medium)).foregroundStyle(tint)
              .frame(width: compact ? 32 : 40)
            VStack(alignment: .leading, spacing: 5) {
              Text(volume.name).font(.system(size: compact ? 14 : 16, weight: .semibold)).lineLimit(1)
              Text(volume.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if storage.busy.contains(volume.id) { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(.secondary) }
          }
          HStack(alignment: .firstTextBaseline) {
            Text(volume.capacityText).font(Theme.number(compact ? 18 : 22, .medium)).foregroundStyle(volume.lowSpace ? .orange : .primary)
            Spacer(minLength: 2)
            if let total = volume.total { Text("共 " + Format.bytes(total)).font(.system(size: 11)).foregroundStyle(.secondary) }
          }
          if let fraction = volume.fraction { GaugeBar(value: fraction, color: tint, height: 5) }
        }.padding(compact ? 14 : 18).frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(CareRowStyle()).disabled(storage.busy.contains(volume.id))
        .help("在 Finder 打开 " + volume.name).accessibilityLabel("打开存储 " + volume.name)
      HStack(spacing: 6) {
        if volume.cameraFolder != nil {
          Label("可能包含相机素材", systemImage: "camera").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
          Button { storage.open(volume, photos: true) } label: {
            Text("照片").padding(.horizontal, 9).frame(height: 30).contentShape(Rectangle())
          }.buttonStyle(StorageActionButtonStyle()).foregroundStyle(Theme.accent).help("打开 DCIM 文件夹")
        } else {
          Text(volume.lowSpace ? "可用空间少于 10%" : volume.readOnly == true ? "当前无法写入" : "已挂载")
            .font(.system(size: 10)).foregroundStyle(volume.lowSpace ? .orange : .secondary)
          Spacer(minLength: 0)
        }
        StorageSpeedButton(volume: volume)
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
        } label: {
          HStack(spacing: 5) {
            Text(expanded ? "收起" : "详情")
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
          }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(StorageActionButtonStyle()).foregroundStyle(Theme.accent)
          .accessibilityLabel((expanded ? "收起存储详情 " : "展开存储详情 ") + volume.name)
      }.padding(.horizontal, compact ? 10 : 14).padding(.bottom, expanded ? 4 : 8)
      if expanded {
        VStack(alignment: .leading, spacing: 12) {
          Divider()
          detail("格式", volume.formatDescription)
          detail("连接", volume.transport)
          if !volume.device.isEmpty { detail("设备", volume.device) }
          detail("访问", volume.readOnly.map { $0 ? "只读" : "可读写" } ?? "未提供")
          if let used = volume.used { detail(volume.format == .apfs ? "容器已占用" : "已用", Format.bytes(used)) }
          detail("位置", volume.path)
          VStack(alignment: .leading, spacing: 6) {
            Text("适合怎么用").font(.system(size: 12, weight: .semibold))
            Text(volume.format.suitability).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if volume.isCard || volume.cameraFolder != nil {
              Text("相机卡先备份，再在相机内格式化；兼容性以相机手册为准。DCIM 仅是目录线索，不能确定相机型号。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }
          HStack(spacing: 8) {
            Button { storage.open(volume) } label: { Label("打开文件夹", systemImage: "folder").padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle()) }
              .buttonStyle(StorageActionButtonStyle()).foregroundStyle(Theme.accent)
            StorageEjectButton(volume: volume, compact: true)
            StorageFormatButton(volume: volume)
            Spacer(minLength: 0)
            Button {
              NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
            } label: { Text("磁盘工具").padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle()) }
              .buttonStyle(StorageActionButtonStyle()).foregroundStyle(Theme.accent)
          }.font(.system(size: 11))
        }.padding(.horizontal, compact ? 14 : 18).padding(.bottom, 14)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }.background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
      .clipped().accessibilityElement(children: .contain)
  }
  private func detail(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Text(title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
      Text(value).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
    }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
  }
}

struct StorageEjectButton: View {
  let volume: ExternalVolume
  var compact = false
  @ObservedObject private var storage = ExternalStorageMonitor.shared
  @ObservedObject private var speed = StorageSpeedStore.shared
  @ObservedObject private var format = StorageFormatStore.shared
  @State private var confirming = false
  var body: some View {
    Button { confirming = true } label: {
      HStack(spacing: 4) {
        if storage.ejecting.contains(volume.id) { ProgressView().controlSize(.mini) }
        else { Image(systemName: "eject.fill").font(.system(size: compact ? 9 : 10)) }
        Text(storage.ejecting.contains(volume.id) ? "推出中" : "推出")
      }.font(.system(size: compact ? 10 : 11, weight: .medium))
        .padding(.horizontal, compact ? 6 : 9).frame(height: compact ? 26 : 30).contentShape(Rectangle())
    }.buttonStyle(StorageActionButtonStyle()).foregroundStyle(Theme.accent)
      .disabled(storage.busy.contains(volume.id) || storage.ejecting.contains(volume.id) || speed.running || format.running)
      .help("安全推出 " + volume.name).accessibilityLabel("安全推出 " + volume.name)
      .alert("推出「" + volume.name + "」？", isPresented: $confirming) {
        Button("取消", role: .cancel) {}
        Button("推出") { Task { await storage.eject(volume) } }
      } message: {
        Text("请先结束文件拷贝。同一设备的其他卷也可能被卸载；成功后会提示。")
      }
  }
}
