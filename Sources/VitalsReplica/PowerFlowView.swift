import SwiftUI

struct PowerFlowView: View {
  var power: PowerSample
  var compact = false
  var groups: [AppGroup] = []
  private var consumers: [AppGroup] {
    Array(groups.filter { ($0.powerWatts ?? 0) >= 0.005 }.sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }.prefix(compact ? 3 : 5))
  }
  private var batteryTitle: String {
    guard let watts = power.battery else { return "电池" }
    return watts > 0.1 ? "充入电池" : watts < -0.1 ? "电池供电" : "电池待机"
  }
  private var components: [PowerComponent] {
    power.components + (power.display.map { [PowerComponent(id: "内置屏幕", watts: $0)] } ?? [])
  }
  var body: some View {
    Panel(padding: compact ? 14 : 18) {
      if compact {
        VStack(alignment: .leading, spacing: 14) {
          flow
          Divider().opacity(0.5)
          componentReadings
          if !consumers.isEmpty { Divider().opacity(0.5); appReadings }
        }
      } else {
        HStack(alignment: .top, spacing: 24) {
          flow.frame(maxWidth: .infinity)
          Divider()
          componentReadings.frame(maxWidth: .infinity)
          if !consumers.isEmpty { Divider(); appReadings.frame(maxWidth: .infinity) }
        }.fixedSize(horizontal: false, vertical: true)
      }
    }.help("整机与适配器是 SMC 实时读数；电池按电流和电压计算。芯片与 App 功率为能量采样估算，各项不等于整机功率。未报告的数据不作推算。")
  }
  private var flow: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("功率", systemImage: "bolt.fill").font(.system(size: 12, weight: .semibold))
        Spacer(); Text("W").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      HStack(spacing: compact ? 12 : 20) {
        reading("适配器", value: power.adapter, symbol: "powerplug", tint: .orange)
        reading("整机", value: power.system, symbol: "laptopcomputer", tint: Theme.accent)
        reading(batteryTitle, value: power.battery.map(abs), symbol: "battery.75percent", tint: .green)
      }
    }
  }
  private var componentReadings: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("部件功率").font(.system(size: 11, weight: .medium))
      let largest = max(1, components.map(\.watts).max() ?? 1)
      ForEach(components) { component in
        HStack(spacing: 10) {
          Text(component.id).frame(width: compact ? 58 : 64, alignment: .leading)
          GeometryReader { geometry in
            Capsule().fill(Theme.accent.opacity(0.09))
            Capsule().fill(Theme.accent.opacity(0.7)).frame(width: max(2, geometry.size.width * component.watts / largest))
          }.frame(height: 5)
          Text(String(format: "%.2f W", component.watts)).monospacedDigit().frame(width: 58, alignment: .trailing)
        }.font(.system(size: 11))
      }
      if !power.components.contains(where: { $0.id == "CPU" }) {
        Text("CPU 功率未报告").font(.system(size: 10)).foregroundStyle(.tertiary)
      }
    }
  }
  private var appReadings: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("App 功率估算").font(.system(size: 11, weight: .medium))
      ForEach(consumers) { app in
        HStack {
          Text(app.name).lineLimit(1)
          Spacer(minLength: 12)
          Text(String(format: "%.2f W", app.powerWatts ?? 0)).monospacedDigit().fixedSize()
        }.font(.system(size: 11))
          .help("仅含本机允许读取能量计数的进程；不代表墙上插座功率。")
      }
    }
  }
  private func reading(_ title: String, value: Double?, symbol: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(value.map { String(format: "%.1f", $0) } ?? "—")
        .font(Theme.number(compact ? 22 : 26)).monospacedDigit().foregroundStyle(tint)
        .lineLimit(1).minimumScaleFactor(0.8)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
