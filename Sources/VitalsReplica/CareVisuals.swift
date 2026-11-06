import SwiftUI
import SceneKit

struct CareStorageVisual: View {
  let scanning: Bool
  let complete: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HelixScannerView(scanning: scanning, complete: complete, reduced: reduceMotion, dark: scheme == .dark)
      .allowsHitTesting(false)
  }
}

private struct HelixScannerView: NSViewRepresentable {
  let scanning: Bool, complete: Bool, reduced: Bool, dark: Bool
  func makeCoordinator() -> Coordinator { Coordinator(dark: dark) }
  func makeNSView(context: Context) -> SCNView {
    let view = SCNView(); view.scene = context.coordinator.geometry.scene
    view.pointOfView = context.coordinator.geometry.camera; view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 60
    view.rendersContinuously = false; view.allowsCameraControl = false
    view.autoenablesDefaultLighting = false; context.coordinator.view = view
    context.coordinator.update(scanning: scanning, complete: complete, reduced: reduced, dark: dark)
    return view
  }
  func updateNSView(_ view: SCNView, context: Context) {
    context.coordinator.update(scanning: scanning, complete: complete, reduced: reduced, dark: dark)
  }
  static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
    coordinator.stop(); view.isPlaying = false; view.scene = nil
  }
  final class Coordinator {
    let geometry: CareScannerScene
    weak var view: SCNView?
    private var timer: Timer?
    private var state: (scanning: Bool, complete: Bool, reduced: Bool, dark: Bool)?
    private var activity = 0.0, completion = 0.0, entrance = 0.0, phase = 0.0
    private var clock = ProcessInfo.processInfo.systemUptime
    init(dark: Bool) { geometry = CareScannerScene(dark: dark) }
    func stop() { timer?.invalidate(); timer = nil }
    func update(scanning: Bool, complete: Bool, reduced: Bool, dark: Bool) {
      if let state, state.scanning == scanning, state.complete == complete, state.reduced == reduced, state.dark == dark { return }
      geometry.setAppearance(dark: dark, animated: state != nil && !reduced)
      state = (scanning, complete, reduced, dark); stop()
      clock = ProcessInfo.processInfo.systemUptime
      view?.isPlaying = false
      if reduced {
        geometry.pose(time: 0.3, activity: 0, completion: complete ? 1 : 0)
        view?.needsDisplay = true
      } else {
        let fps = scanning ? 60.0 : complete ? 24.0 : 30.0
        view?.preferredFramesPerSecond = Int(fps)
        tick()
        let next = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        timer = next; RunLoop.main.add(next, forMode: .common)
      }
    }
    private func tick() {
      guard let state else { return }
      let time = ProcessInfo.processInfo.systemUptime
      let dt = min(0.1, max(0, time - clock)); clock = time
      if let window = view?.window, !window.isVisible || window.isMiniaturized || !window.occlusionState.contains(.visible) { return }
      let smooth = 1 - exp(-dt * 4)
      activity += ((state.scanning ? 1 : 0) - activity) * smooth
      completion += ((state.complete ? 1 : 0) - completion) * smooth
      entrance += (1 - entrance) * (1 - exp(-dt * 7))
      phase += dt * (0.55 + activity * 0.45) * (1 - completion * 0.65)
      geometry.pose(time: phase, activity: activity, completion: completion, entrance: entrance)
      view?.needsDisplay = true
    }
    deinit { timer?.invalidate() }
  }
}

struct CareActionStyle: ButtonStyle {
  var primary = false
  func makeBody(configuration: Configuration) -> some View {
    CareActionSurface(label: configuration.label, pressed: configuration.isPressed, primary: primary)
  }
}
private struct CareActionSurface<L: View>: View {
  let label: L
  let pressed: Bool
  let primary: Bool
  @State private var hovered = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 26).frame(minHeight: 42)
      .foregroundStyle(primary ? Theme.selectionForeground : .primary)
      .background(primary ? Theme.accent.opacity(pressed ? 0.78 : hovered ? 0.9 : 1) : Color.primary.opacity(pressed ? 0.14 : hovered ? 0.09 : 0.055), in: Capsule())
      .contentShape(Capsule()).scaleEffect(pressed ? 0.97 : 1).opacity(enabled ? 1 : 0.35)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: pressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
      .onHover { hovered = $0 }
  }
}

@MainActor struct CareNavigation: View {
  @ObservedObject var model: MonitorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selection
  var body: some View {
    HStack(spacing: 2) {
      ForEach(CarePage.allCases) { page in
        Button {
          withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.88)) { model.carePage = page }
        } label: {
          Text(page.rawValue).font(.system(size: 13, weight: model.carePage == page ? .semibold : .medium))
            .foregroundStyle(model.carePage == page ? Theme.selectionForeground : .secondary)
            .padding(.horizontal, 15).frame(height: 28)
            .background {
              if model.carePage == page { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "care-page", in: selection) }
            }.contentShape(Capsule())
        }.buttonStyle(CareRowStyle())
          .help(page.rawValue)
          .accessibilityLabel(page.rawValue)
          .accessibilityValue(model.carePage == page ? "已选择" : "")
          .accessibilityIdentifier("care-tab-\(page.id)")
      }
    }.padding(4).modifier(NavigationGlass())
  }
}
@MainActor struct CareProtectionList: View {
  @ObservedObject private var store = CareStore.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("保护名单").font(.system(size: 16, weight: .semibold))
      if store.protected.isEmpty { Text("在项目右键菜单中添加保护").font(.system(size: 12)).foregroundStyle(.secondary) }
      ScrollView {
        ForEach(Array(store.protected).sorted(), id: \.self) { path in
          HStack {
            Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~", options: [.anchored])).font(.system(size: 11)).lineLimit(2)
            Spacer(); Button("移除") { store.unprotect(path) }
          }
        }
      }.frame(maxHeight: 280)
    }.padding(20).frame(width: 390).buttonStyle(AIControlButtonStyle(compact: true))
  }
}
