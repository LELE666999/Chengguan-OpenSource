import SwiftUI

/// NAS inventories are small. Eager rows keep accessibility scroll actions out
/// of SwiftUI's lazy collection synchronization while live readings update.
struct NASMatrix<Item: Identifiable, Content: View>: View {
  let items: [Item]
  let columns: Int
  var spacing: CGFloat = 12
  @ViewBuilder let content: (Item) -> Content

  var body: some View {
    let count = max(1, columns)
    VStack(spacing: spacing) {
      ForEach(0..<((items.count + count - 1) / count), id: \.self) { row in
        HStack(alignment: .top, spacing: spacing) {
          ForEach(Array(items.dropFirst(row * count).prefix(count))) { item in
            content(item).frame(maxWidth: .infinity)
          }
          ForEach(0..<max(0, count - min(count, items.count - row * count)), id: \.self) { _ in
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
          }
        }
      }
    }
  }
}

enum NASPalette {
  static let cpu = Theme.adaptive(light: .init(srgbRed: 0.05, green: 0.39, blue: 0.92, alpha: 1), dark: .init(srgbRed: 0.39, green: 0.65, blue: 1, alpha: 1))
  static let memory = Theme.adaptive(light: .init(srgbRed: 0.46, green: 0.24, blue: 0.84, alpha: 1), dark: .init(srgbRed: 0.76, green: 0.57, blue: 1, alpha: 1))
  static let network = Theme.adaptive(light: .init(srgbRed: 0, green: 0.48, blue: 0.43, alpha: 1), dark: .init(srgbRed: 0.28, green: 0.87, blue: 0.72, alpha: 1))
  static let storage = Theme.adaptive(light: .init(srgbRed: 0.72, green: 0.39, blue: 0.02, alpha: 1), dark: .init(srgbRed: 1, green: 0.76, blue: 0.32, alpha: 1))
  static let fan = Theme.adaptive(light: .init(srgbRed: 0, green: 0.47, blue: 0.66, alpha: 1), dark: .init(srgbRed: 0.29, green: 0.79, blue: 0.96, alpha: 1))
}

/// Visual slowdown keeps individual blades readable. The actual RPM stays in
/// the adjacent number. Unknown, stopped, stale and reduced-motion rotors stop.
enum NASFanMotion {
  static func turnsPerSecond(rpm: Double?, live: Bool, reduced: Bool) -> Double {
    guard live, !reduced, let rpm, rpm.isFinite, rpm > 0 else { return 0 }
    return min(2.2, max(0.15, rpm / 1100))
  }
}

/// Simplified 3D hardware icons from the approved C mockup (not product photos).
/// Pools and physical drives use distinct artwork in both window and menu.
struct NASHardwareArtwork: View {
  let resource: String
  var compact = false
  var body: some View {
    Image(nsImage: VisualResources.image(resource))
      .resizable().interpolation(.high).scaledToFit()
      .frame(width: compact ? 44 : 58, height: compact ? 44 : 58)
      .accessibilityHidden(true)
  }
}

struct NASFanRotor: View {
  let rpm: Double?
  let live: Bool
  var size: CGFloat = 66
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var epoch = Date()
  @State private var phase = 0.0
  private var speed: Double { NASFanMotion.turnsPerSecond(rpm: rpm, live: live, reduced: reduceMotion) }
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: speed == 0)) { tick in
      let turns = phase + max(0, tick.date.timeIntervalSince(epoch)) * speed
      ZStack {
        Circle().strokeBorder(NASPalette.fan.opacity(0.17), lineWidth: 2)
        Circle().trim(from: 0.04, to: 0.32).stroke(NASPalette.fan.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-100))
        Image(systemName: "fanblades.fill").resizable().scaledToFit().foregroundStyle(NASPalette.fan)
          .padding(size * 0.13).rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
        Circle().fill(Theme.panel).frame(width: size * 0.17, height: size * 0.17)
          .overlay(Circle().strokeBorder(NASPalette.fan.opacity(0.45), lineWidth: 1))
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
      .onChange(of: speed) { old, _ in
        let now = Date()
        phase = (phase + max(0, now.timeIntervalSince(epoch)) * old).truncatingRemainder(dividingBy: 1)
        epoch = now
      }
  }
}

struct NASFanCard: View {
  let name: String, rpm: Double?
  let live: Bool
  var compact = false
  var body: some View {
    Panel(padding: compact ? 12 : 16) {
      VStack(alignment: .leading, spacing: 14) {
        Label(name, systemImage: "fanblades.fill").font(.system(size: 12, weight: .medium))
        HStack(spacing: compact ? 10 : 12) {
          NASFanRotor(rpm: rpm, live: live, size: compact ? 48 : 62)
          VStack(alignment: .leading, spacing: 2) {
            Text(rpm.map { String(format: "%.0f", $0) } ?? "—")
              .font(Theme.number(compact ? 23 : 27, .bold)).monospacedDigit().foregroundStyle(NASPalette.fan)
              .lineLimit(1).minimumScaleFactor(0.8).contentTransition(.numericText())
            Text(rpm == nil ? "未提供" : "rpm").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxWidth: .infinity, minHeight: compact ? 102 : 148, alignment: .topLeading)
    }.accessibilityElement(children: .combine).accessibilityValue(live ? "实时转速" : "上次读数，动画已暂停")
  }
}

struct NASPoolCard: View {
  let pool: NASPool
  var compact = false
  @State private var showDetails = false
  var body: some View {
    Button { showDetails = true } label: {
      VStack(alignment: .leading, spacing: compact ? 10 : 14) {
        HStack(spacing: 10) {
          NASHardwareArtwork(resource: "nas-pool", compact: compact)
          VStack(alignment: .leading, spacing: 5) {
            Text(pool.name).font(.system(size: compact ? 12 : 14, weight: .semibold)).foregroundStyle(.primary)
            Text([pool.medium, pool.level, pool.filesystem].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary).lineLimit(2)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        }
        if let fraction = pool.fraction {
          GaugeBar(value: fraction, color: fraction >= 0.9 ? .orange : NASPalette.storage, height: compact ? 10 : 12)
        } else { Capsule().fill(Color.secondary.opacity(0.12)).frame(height: compact ? 10 : 12) }
        HStack(alignment: .top, spacing: 8) {
          poolNumber("已用", pool.used, highlighted: true)
          Spacer(minLength: 0)
          poolNumber("容量", pool.total, highlighted: false)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 12 : 16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }.buttonStyle(CareRowStyle()).help("查看存储空间与容量详情")
      .popover(isPresented: $showDetails) {
        VStack(alignment: .leading, spacing: 16) {
          Text(pool.name).font(.system(size: 17, weight: .semibold))
          ForEach(pool.volumes) { v in
            VStack(alignment: .leading, spacing: 8) {
              HStack { Text(v.name).fontWeight(.medium); Spacer(); Text(v.filesystem).foregroundStyle(.secondary) }
              HStack { SmallStat(title: "文件已用", value: nasBytes(v.used)); SmallStat(title: "可用", value: nasBytes(v.available)); SmallStat(title: "卷容量", value: nasBytes(v.total)) }
            }
          }
          if pool.volumes.isEmpty { Text("未读取到存储空间容量").foregroundStyle(.secondary) }
          Divider()
          HStack { SmallStat(title: "存储池容量", value: nasBytes(pool.poolCapacity)); SmallStat(title: "未分配给卷", value: nasBytes(pool.unallocated)) }
          Text("未分配容量与卷内可用空间分别统计。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(22).frame(width: 420)
      }
  }
  private func poolNumber(_ title: String, _ value: Double?, highlighted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(nasBytes(value)).font(Theme.number(compact ? 14 : 18)).monospacedDigit()
        .foregroundStyle(highlighted ? NASPalette.storage : .primary).lineLimit(1).minimumScaleFactor(0.8)
    }
  }
}

struct NASDiskCard: View {
  let disk: NASDisk
  var compact = false
  @State private var showDetails = false
  var body: some View {
    Button { showDetails = true } label: {
      HStack(spacing: 10) {
        NASHardwareArtwork(resource: disk.name.contains("M.2") ? "nas-nvme" : "nas-hdd", compact: compact)
        VStack(alignment: .leading, spacing: 5) {
          Text(disk.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
          Text(nasBytes(disk.size)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 3)
        Text(disk.temperature.map(Format.temperature) ?? "—").font(Theme.number(compact ? 14 : 17))
          .foregroundStyle(NASPalette.network).lineLimit(1).minimumScaleFactor(0.8)
        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
      }.padding(compact ? 12 : 16).frame(maxWidth: .infinity, minHeight: compact ? 65 : 76)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16)).contentShape(RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(CareRowStyle()).help("查看硬盘详情")
      .popover(isPresented: $showDetails) {
        VStack(alignment: .leading, spacing: 14) {
          Text(disk.name).font(.system(size: 17, weight: .semibold))
          Text(disk.model).font(.system(size: 12)).textSelection(.enabled)
          HStack { SmallStat(title: "容量", value: nasBytes(disk.size)); SmallStat(title: "温度", value: disk.temperature.map(Format.temperature) ?? "—") }
          Text(disk.status).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(22).frame(width: 340)
      }
  }
}
