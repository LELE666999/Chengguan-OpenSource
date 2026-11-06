import SwiftUI

struct WorkspaceModeControl: View {
  @ObservedObject var model: MonitorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selection
  private var cleaning: Bool { model.carePage != nil }
  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 2) {
        mode("监控", clean: false)
        mode("清洁", clean: true)
      }.padding(3).modifier(NavigationGlass())
      Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
      Text("\(SystemValue.chip) · \(model.snapshot.coreUsage.count) 核 · \(Int(Double(model.snapshot.totalMemory)/pow(1024,3))) GB")
        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }.padding(.trailing, 10).frame(height: 36).fixedSize()
  }
  private func mode(_ title: String, clean: Bool) -> some View {
    let selected = cleaning == clean
    return Button { change(clean: clean) } label: {
      Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Theme.selectionForeground : .secondary)
        .padding(.horizontal, 14).frame(height: 28)
        .background { if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "mode", in: selection) } }
        .contentShape(Capsule())
    }.buttonStyle(CareRowStyle()).accessibilityLabel(title + "模式").accessibilityValue(selected ? "已选择" : "")
  }
  private func change(clean: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
      if clean { model.presentCare() } else { model.select(.overview) }
    }
  }
}
