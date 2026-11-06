import SwiftUI

struct BluetoothBatteryLabel: View {
  var batteries: [BluetoothBattery]
  var compact = false
  var body: some View {
    if batteries.isEmpty {
      Text("未报告电量").font(.system(size: 10)).foregroundStyle(.tertiary)
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { values }
        VStack(alignment: .trailing, spacing: 5) { values }
      }
    }
  }
  private var values: some View {
    ForEach(batteries) { battery in
      HStack(spacing: 4) {
        if battery.id == "main" { Image(systemName: battery.percent <= 20 ? "battery.25percent" : "battery.75percent") }
        else { Text(battery.title).foregroundStyle(.secondary) }
        Text("\(battery.percent)%").monospacedDigit()
      }.font(.system(size: compact ? 10 : 11, weight: .medium))
        .foregroundStyle(battery.percent <= 20 ? Color.orange : Color.primary)
        .fixedSize().accessibilityLabel("\(battery.title)，百分之\(battery.percent)")
    }
  }
}
