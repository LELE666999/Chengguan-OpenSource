import SwiftUI
import AppKit

struct CableWorkspace: View {
  @Binding var selected: String?
  @ObservedObject private var cables = CableMonitor.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var port: CablePort? { cables.snapshot.ports.first { $0.id == selected } ?? cables.snapshot.ports.first }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 7) {
            Text(port?.cableName ?? "线缆").font(.system(size: 28, weight: .semibold))
            HStack(spacing: 7) {
              Circle().fill(port?.liquidDetected == true ? .orange : .green).frame(width: 6, height: 6)
              Text(port.map { "当前连接 · \($0.title)" } ?? cables.snapshot.summary).foregroundStyle(.secondary)
            }.font(.system(size: 12))
          }
          Spacer(minLength: 20)
          CablePortPicker(ports: cables.snapshot.ports, selected: port?.id, compact: false, choose: choose)
        }
        if let port {
          HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
              ZStack {
                RoundedRectangle(cornerRadius: 24).fill(Theme.panel)
                CableVisual().padding(.horizontal, 12).padding(.vertical, 20)
                VStack {
                  HStack {
                    Text(port.identity.map { $0.active ? "ACTIVE" : "PASSIVE" } ?? "USB-C")
                    Spacer()
                    Image(systemName: "rotate.3d")
                  }
                  Spacer()
                  HStack { Text("线缆示意"); Spacer(); Text("拖动查看") }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(18).allowsHitTesting(false)
              }.frame(height: 315)
              CableIdentitySection(port: port)
            }.frame(width: 290)
            VStack(alignment: .leading, spacing: 24) {
              CableCapabilities(port: port)
              CableConnectionSection(port: port)
              CableSpeedSection(port: port)
              CableSuitabilitySection(port: port)
              CableHistorySection(port: port, log: cables.observations)
              CableTechnicalSection(port: port)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.id(port.id).transition(.opacity)
          Text("每 3 秒更新 · 额定能力与供电档位不代表实时功耗或实测速率。接口编号由 macOS 提供。")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else { CableEmptyState(snapshot: cables.snapshot, checked: cables.checked).frame(minHeight: 430) }
      }.padding(28).frame(maxWidth: 1320, alignment: .leading).frame(maxWidth: .infinity)
    }.onAppear { cables.refresh() }
  }
  private func choose(_ id: String) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selected = id } }
}

/// Its port selection stays local; opening the window is the only cross-surface navigation.
struct CableMenuPage: View {
  let open: (String?) -> Void
  @ObservedObject private var cables = CableMonitor.shared
  @State private var selected: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var port: CablePort? { cables.snapshot.ports.first { $0.id == selected } ?? cables.snapshot.ports.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      CablePortPicker(ports: cables.snapshot.ports, selected: port?.id, compact: true) { id in
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selected = id }
      }
      if let port {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
              Text(port.identity?.power ?? "USB-C").font(Theme.number(28, .semibold))
              Text(port.identity == nil ? "线缆规格待确认" : port.identity!.active ? "主动线缆" : "被动线缆")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.leading, 16)
            CableVisual(compact: true).frame(maxWidth: .infinity).frame(height: 146).allowsHitTesting(false)
          }
          CableCapabilities(port: port, compact: true).padding(.horizontal, 16).padding(.bottom, 14)
        }.background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 18))
        CableConnectionSection(port: port, compact: true)
        CableSpeedSection(port: port, compact: true)
        CableDisclosure(title: "适用场景", symbol: "checkmark.circle") { CableSuitabilitySection(port: port, compact: true, heading: false) }
        CableDisclosure(title: "接口记录", symbol: "clock") { CableHistorySection(port: port, log: cables.observations, compact: true, heading: false) }
        CableDisclosure(title: "芯片详情", symbol: "cpu") { CableIdentitySection(port: port, compact: true) }
        Text("额定能力 ≠ 当前功耗 / 实测速率").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 12)
      } else { CableEmptyState(snapshot: cables.snapshot, checked: cables.checked).frame(minHeight: 250) }
      Button { open(port?.id) } label: {
        HStack { Text("在窗口中查看"); Spacer(); Image(systemName: "arrow.up.right") }
          .font(.system(size: 12, weight: .medium)).padding(12).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 12))
      }.buttonStyle(CareRowStyle()).foregroundStyle(Theme.accent)
        .background(Theme.menuCard, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("cables-open-window")
    }.onAppear { cables.refresh() }
  }
}

private struct CablePortPicker: View {
  let ports: [CablePort]
  let selected: String?
  let compact: Bool
  let choose: (String) -> Void
  var body: some View {
    HStack(spacing: 5) {
      ForEach(ports) { port in
        Button { choose(port.id) } label: {
          HStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal").font(.system(size: compact ? 12 : 15))
            VStack(alignment: .leading, spacing: 3) {
              Text(port.title).font(.system(size: compact ? 11 : 12, weight: .semibold))
              if !compact { Text(port.identity?.power ?? "规格未知").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if port.liquidDetected { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
          }.padding(.horizontal, compact ? 12 : 16).frame(minHeight: compact ? 36 : 50)
            .frame(maxWidth: compact ? .infinity : nil)
            .background(selected == port.id ? Theme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(selected == port.id ? Theme.accent : .secondary)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(CareRowStyle()).help(port.subtitle)
          .accessibilityLabel(port.title).accessibilityValue(selected == port.id ? "已选择" : "")
          .accessibilityIdentifier("cable-select-\(port.number)")
      }
    }
  }
}

private struct CableCapabilities: View {
  let port: CablePort
  var compact = false
  private var speedRange: (Double?, Double?) {
    switch port.identity?.speedCode {
    case 0: (0.025, nil)
    case 1: (0.2, nil)
    case 2: (0.4, nil)
    case 3: (0.6, 0.8)
    case 4: (1, nil)
    default: (nil, nil)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 14 : 20) {
      if !compact { CableSectionHeading(title: "能力", symbol: "chart.bar.xaxis", detail: "线缆芯片声明") }
      CableCapabilityRow(title: "功率", symbol: "bolt", value: port.identity?.power ?? "未知", fraction: port.identity?.ratedWatts.map { Double($0) / 240 },
        ticks: [(0.25,"60 W"),(100.0 / 240,"100 W"),(1,"240 W")], compact: compact)
      CableCapabilityRow(title: "数据", symbol: "arrow.left.arrow.right", value: port.identity?.speed.replacingOccurrences(of: "USB4 · ", with: "") ?? "未知",
        fraction: speedRange.0, rangeEnd: speedRange.1,
        ticks: [(0,"480M"),(0.2,"5G"),(0.4,"10G"),(0.6,"20G"),(0.8,"40G"),(1,"80G")], compact: compact)
      HStack(spacing: 10) {
        Label("视频", systemImage: "display").foregroundStyle(.secondary).frame(width: compact ? 46 : 66, alignment: .leading)
        Text(port.display != nil ? "正在输出" : "尚未确认").fontWeight(.medium)
        Spacer()
        Image(systemName: port.display != nil ? "checkmark.circle.fill" : "questionmark.circle")
          .foregroundStyle(port.display != nil ? Theme.accent : Color.secondary)
      }.font(.system(size: compact ? 11 : 12))
      if !compact, let warning = port.identity?.warning { Label(warning, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange) }
    }
  }
}

private struct CableCapabilityRow: View {
  let title: String, symbol: String, value: String
  let fraction: Double?
  var rangeEnd: Double? = nil
  let ticks: [(Double, String)]
  let compact: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Label(title, systemImage: symbol).foregroundStyle(.secondary).frame(width: compact ? 46 : 66, alignment: .leading).padding(.top, 1)
      VStack(alignment: .leading, spacing: 9) {
        if compact { HStack { Text(value).fontWeight(.semibold); Spacer() } }
        GeometryReader { proxy in
          let width = proxy.size.width
          ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.065))
            if let fraction {
              Capsule().fill(Theme.accent).frame(width: max(5,width * min(1,max(0,fraction))))
              if let end = rangeEnd {
                Capsule().fill(Theme.accent.opacity(0.3)).frame(width: width * max(0,end - fraction) + 4).offset(x: width * fraction - 3)
              }
            }
          }.frame(height: compact ? 5 : 7)
          if !compact {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
              Text(tick.1).font(.system(size: 10)).foregroundStyle(.tertiary)
                .position(x: min(max(16,width * tick.0),width - 17), y: 24)
            }
          }
        }.frame(height: compact ? 5 : 33)
      }.padding(.top, compact ? 0 : 5)
      if !compact { Text(value).font(Theme.number(14)).foregroundStyle(fraction == nil ? Color.secondary : Theme.accent).frame(width: 134, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8) }
    }.font(.system(size: compact ? 11 : 12))
      .accessibilityElement(children: .ignore).accessibilityLabel(title + " · " + value)
  }
}

private struct CableConnectionSection: View {
  let port: CablePort
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      CableSectionHeading(title: "当前连接", symbol: "point.topleft.down.to.point.bottomright.curvepath", detail: compact ? nil : "macOS 实时报告")
      if port.liquidDetected { Label("检测到液体 · 请断开并检查接口", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12)) }
      if !port.devices.isEmpty { Text(port.devices.joined(separator: " · ")).font(.system(size: compact ? 12 : 14, weight: .medium)).textSelection(.enabled) }
      CableValueRow(label: "数据链路", value: port.link ?? "未报告", compact: compact)
      CableValueRow(label: "视频", value: port.display != nil ? (port.videoDetail.isEmpty ? "正在输出" : port.videoDetail) : "未检测到输出", compact: compact)
      CableValueRow(label: "供电档位", value: port.supplyWatts.map { "\($0) W" } ?? "未报告", compact: compact)
      if !compact, let v = port.supplyVolts, let a = port.supplyAmps {
        CableValueRow(label: "档位电压 / 电流", value: String(format: "%g V / %g A", v,a))
      }
      if !compact && !port.powerProfiles.isEmpty {
        CableDisclosure(title: "电源提供的档位", symbol: "bolt.horizontal") {
          ForEach(Array(port.powerProfiles.enumerated()), id: \.offset) { _, profile in
            CableValueRow(label: profile.label, value: "\(profile.watts) W")
          }
        }
      }
    }.padding(compact ? 12 : 18).background(Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 20))
  }
}

private struct CableIdentitySection: View {
  let port: CablePort
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      if !compact { CableSectionHeading(title: "身份", symbol: "cpu", detail: port.identity == nil ? "待识别" : "e-marker") }
      if let identity = port.identity {
        CableValueRow(label: "类型", value: identity.active ? "主动线缆" : "被动线缆", compact: compact)
        CableValueRow(label: "芯片耐压", value: identity.ratedVolts.map { "\($0) V" } ?? "未知", compact: compact)
        CableValueRow(label: "额定电流", value: identity.currentAmps.map { "\($0) A" } ?? "未知", compact: compact)
        CableValueRow(label: "EPR", value: identity.epr ? "芯片声明支持" : "未确认支持", compact: compact)
        Divider()
        CableValueRow(label: "厂商 ID", value: identity.vendor, compact: compact)
        CableValueRow(label: "产品 ID", value: identity.productID == 0 ? "未提供" : String(format: "0x%04X",identity.productID), compact: compact)
        CableValueRow(label: "报告 TID", value: identity.certificationID.map { String($0) } ?? "未提供", compact: compact)
        if identity.certificationID != nil { Text("TID 来自芯片，未核验认证真伪。").font(.system(size: 10)).foregroundStyle(.tertiary) }
      } else {
        Text("未读到线缆芯片").font(.system(size: 13, weight: .medium))
        Text("可能没有 e-marker，或系统尚未提供。充电、数据与视频仍可正常工作。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(compact ? 4 : 6)
  }
}

private struct CableSuitabilitySection: View {
  let port: CablePort
  var compact = false
  var heading = true
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
      if heading { CableSectionHeading(title: "适用场景", symbol: "checkmark.circle", detail: "按已知能力判断") }
      ForEach(CableUseCase.evaluate(port)) { item in
        HStack(spacing: 12) {
          Image(systemName: item.symbol).font(.system(size: compact ? 13 : 17)).foregroundStyle(.secondary).frame(width: compact ? 18 : 24)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: compact ? 11 : 12, weight: .medium))
            Text(item.detail).font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 6)
          Image(systemName: item.verdict == .supported ? "checkmark.circle.fill" : item.verdict == .limited ? "minus.circle" : "questionmark.circle")
            .foregroundStyle(item.verdict == .supported ? Theme.accent : item.verdict == .limited ? Color.orange : Color.secondary)
            .help(item.verdict == .supported ? "有已知能力支持；实际表现取决于整条连接" : item.verdict == .limited ? "已知规格有限制" : "证据不足，不能确认")
        }
      }
    }.padding(.horizontal, compact ? 3 : 4)
  }
}

private struct CableHistorySection: View {
  let port: CablePort
  let log: CableObservationLog
  var compact = false
  var heading = true
  private var events: [CableHistoryEvent] { log.events.filter { $0.portID == port.id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if heading { CableSectionHeading(title: "接口记录", symbol: "clock", detail: "本次运行期间") }
      if let record = log.records[port.id] {
        HStack(spacing: 20) {
          SmallStat(title: "观察到连接", value: "\(record.observations) 次")
          SmallStat(title: "已观察时长", value: duration(record.observedSeconds))
          SmallStat(title: "最高供电档位", value: record.peakSupplyWatts.map { "\($0) W" } ?? "—")
        }
      }
      ForEach(Array(events.prefix(3))) { event in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(event.time, style: .time).monospacedDigit().foregroundStyle(.secondary).frame(width: compact ? 54 : 70, alignment: .leading)
          VStack(alignment: .leading, spacing: 3) {
            Text(event.title).fontWeight(.medium)
            Text(event.detail).foregroundStyle(.secondary).lineLimit(2)
          }
          Spacer(minLength: 0)
        }.font(.system(size: compact ? 10 : 11))
      }
      if events.count > 3 {
        CableDisclosure(title: "更多记录", symbol: "ellipsis") {
          ForEach(events.dropFirst(3)) { event in
            CableValueRow(label: event.time.formatted(date: .omitted, time: .shortened), value: event.title, compact: compact)
          }
        }
      }
      Text("按接口记录，非同一根线缆的终身历史；不含休眠时间。").font(.system(size: 9)).foregroundStyle(.tertiary)
    }.padding(compact ? 3 : 18).background(compact ? Color.clear : Theme.panel, in: RoundedRectangle(cornerRadius: 20))
  }
  private func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return minutes < 1 ? "不足 1 分钟" : minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
  }
}

private struct CableTechnicalSection: View {
  let port: CablePort
  var body: some View {
    CableDisclosure(title: "技术详情", symbol: "slider.horizontal.3") {
      CableValueRow(label: "PD 版本", value: port.pdRevision.map { "PD \($0)" } ?? "未提供")
      CableValueRow(label: "活动通道", value: port.activeTransports.isEmpty ? "未提供" : port.activeTransports.joined(separator: " · "))
      CableValueRow(label: "线缆长度 / 品牌", value: "系统未提供")
      CableValueRow(label: "累计电量", value: "未测量")
      if !port.identityWords.isEmpty {
        Text("SOP′  " + port.identityWords.map { String(format: "%08X",$0) }.joined(separator: " "))
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
  }
}

private struct CableDisclosure<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder var content: Content
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
        HStack(spacing: 8) {
          Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
          Text(title).fontWeight(.medium)
          Spacer(minLength: 8)
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
        }.font(.system(size: 11)).padding(11).frame(maxWidth: .infinity).contentShape(RoundedRectangle(cornerRadius: 10))
      }.buttonStyle(CareRowStyle()).accessibilityLabel(title).accessibilityValue(expanded ? "已展开" : "已收起")
      if expanded {
        VStack(alignment: .leading, spacing: 11) { content }.padding(.horizontal, 11).padding(.top, 5).padding(.bottom, 11)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}

private struct CableSectionHeading: View {
  let title: String, symbol: String
  var detail: String? = nil
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer()
      if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary) }
    }
  }
}
private struct CableValueRow: View {
  let label: String, value: String
  var compact = false
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
    }.font(.system(size: compact ? 10 : 11))
  }
}
private struct CableEmptyState: View {
  let snapshot: CableSnapshot
  let checked: Bool
  var body: some View {
    VStack(spacing: 15) {
      Image(systemName: "cable.connector.horizontal").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
      Text(!checked ? "正在读取连接" : snapshot.readable ? "连接一根 USB-C 线缆" : "此 Mac 未提供线缆信息").font(.system(size: 18, weight: .medium))
      Text(snapshot.readable ? "接入设备或充电器后，信息会自动出现在这里。" : "需要 USB-C 控制器提供数据。").font(.system(size: 12)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity)
  }
}
