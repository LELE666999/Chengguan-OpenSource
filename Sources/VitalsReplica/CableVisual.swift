import AppKit
import SceneKit
import SwiftUI
import simd

/// Original generic USB-C geometry; it is an illustration, not a photo of the attached cable.
private final class CableScene {
  let scene = SCNScene()
  let camera = SCNNode()
  let assembly = SCNNode()
  init(dark: Bool) {
    scene.background.contents = NSColor.clear
    scene.rootNode.addChildNode(assembly)
    camera.camera = SCNCamera()
    camera.camera?.usesOrthographicProjection = true
    camera.camera?.orthographicScale = 1.72
    camera.camera?.wantsHDR = true
    camera.camera?.wantsExposureAdaptation = false
    camera.camera?.exposureOffset = -0.3
    camera.position = SCNVector3(0, 0.02, 7)
    camera.look(at: SCNVector3(0, 0.02, 0))
    scene.rootNode.addChildNode(camera)
    let environment = NSImage(size: NSSize(width: 1024, height: 512), flipped: false) { rect in
      NSColor(white: 0.23, alpha: 1).setFill(); rect.fill()
      NSColor(white: 0.95, alpha: 1).setFill()
      NSBezierPath(roundedRect: NSRect(x: 130, y: 220, width: 200, height: 260), xRadius: 35, yRadius: 35).fill()
      NSColor(white: 0.65, alpha: 1).setFill()
      NSBezierPath(roundedRect: NSRect(x: 680, y: 100, width: 100, height: 300), xRadius: 30, yRadius: 30).fill()
      return true
    }
    scene.lightingEnvironment.contents = environment
    scene.lightingEnvironment.intensity = 0.75
    light(.ambient, at: SCNVector3(0, 0, 3), intensity: 180)
    light(.omni, at: SCNVector3(-3, 4, 4), intensity: 420)
    light(.omni, at: SCNVector3(4, -1, 2), intensity: 230)
    let rubber = material(NSColor(white: dark ? 0.075 : 0.045, alpha: 1), metal: 0, roughness: 0.64)
    let casing = material(NSColor(white: 0.065, alpha: 1), metal: 0.15, roughness: 0.47)
    let alloy = material(NSColor(white: 0.44, alpha: 1), metal: 0.85, roughness: 0.3)
    let inside = material(NSColor(white: 0.025, alpha: 1), metal: 0.15, roughness: 0.45)
    let contacts = material(NSColor(calibratedRed: 0.75, green: 0.57, blue: 0.24, alpha: 1), metal: 0.7, roughness: 0.3)
    var points: [SIMD3<Float>] = [SIMD3(-0.95, -0.12, 0)]
    func curve(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
      let start = points.last!
      for index in 1...56 {
        let t = Float(index) / 56, u = 1 - t
        points.append(u*u*u*start + 3*u*u*t*a + 3*u*t*t*b + t*t*t*c)
      }
    }
    curve(SIMD3(-0.62,-0.12,0), SIMD3(-0.64,1.18,0), SIMD3(-0.32,1.16,0))
    curve(SIMD3(0.01,1.15,0), SIMD3(0.07,0.36,0), SIMD3(0.12,-0.22,0))
    curve(SIMD3(0.37,-1.27,0), SIMD3(-0.35,-1.47,0.02), SIMD3(-0.37,-0.78,0.04))
    curve(SIMD3(-0.48,-0.13,0.13), SIMD3(-0.09,1.02,0.14), SIMD3(0.22,0.69,0.14))
    curve(SIMD3(0.57,0.4,0.12), SIMD3(0.40,-0.07,0.1), SIMD3(0.95,-0.07,0.1))
    let tube = SCNNode(geometry: tube(points, radius: 0.048))
    tube.geometry?.firstMaterial = rubber; assembly.addChildNode(tube)
    for left in [true, false] {
      let end = SCNNode()
      end.position = left ? SCNVector3(-1.07,-0.12,0) : SCNVector3(1.07,-0.07,0.1)
      if left { end.eulerAngles.z = .pi }
      assembly.addChildNode(end)
      func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ r: CGFloat, _ x: Double, _ material: SCNMaterial) -> SCNNode {
        let shape = SCNBox(width: w, height: h, length: d, chamferRadius: r)
        shape.chamferSegmentCount = 8; shape.firstMaterial = material
        let n = SCNNode(geometry: shape); n.position.x = CGFloat(x); end.addChildNode(n); return n
      }
      _ = box(0.33,0.17,0.11,0.045,0,casing)
      _ = box(0.10,0.10,0.08,0.024,-0.18,rubber)
      _ = box(0.24,0.128,0.075,0.033,0.265,alloy)
      // A recessed socket and central tongue give the tip real depth on rotation.
      let opening = box(0.003,0.098,0.049,0.001,0.387,inside)
      opening.geometry?.firstMaterial?.isDoubleSided = true
      _ = box(0.004,0.066,0.011,0.001,0.39,alloy)
      for index in 0..<6 {
        let pin = box(0.005,0.004,0.003,0.001,0.393,contacts)
        pin.position.y = CGFloat(index) * 0.009 - 0.023; pin.position.z = 0.008
      }
    }
    pose(x: 0, y: 0)
  }
  func pose(x: Double, y: Double) {
    assembly.eulerAngles = SCNVector3(-0.18 + y, -0.15 + x, -0.055)
  }
  private func material(_ color: NSColor, metal: CGFloat, roughness: CGFloat) -> SCNMaterial {
    let value = SCNMaterial(); value.lightingModel = .physicallyBased
    value.diffuse.contents = color; value.metalness.contents = metal; value.roughness.contents = roughness
    return value
  }
  private func light(_ type: SCNLight.LightType, at position: SCNVector3, intensity: CGFloat) {
    let n = SCNNode(); n.light = SCNLight(); n.light?.type = type
    n.light?.intensity = intensity; n.light?.castsShadow = false; n.position = position
    scene.rootNode.addChildNode(n)
  }
  private func tube(_ points: [SIMD3<Float>], radius: Float) -> SCNGeometry {
    let sides = 16
    var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
    for i in points.indices {
      let tangent = simd_normalize(points[min(i + 1, points.count - 1)] - points[max(i - 1, 0)])
      let normal = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 0, 1)))
      let binormal = simd_cross(tangent, normal)
      for j in 0..<sides {
        let angle = Float(j) * 2 * .pi / Float(sides)
        let n = normal * cos(angle) + binormal * sin(angle)
        let p = points[i] + n * radius
        vertices.append(SCNVector3(p.x,p.y,p.z)); normals.append(SCNVector3(n.x,n.y,n.z))
        if i + 1 < points.count {
          let a = UInt32(i * sides + j), b = UInt32(i * sides + (j + 1) % sides)
          let c = a + UInt32(sides), d = b + UInt32(sides)
          indices += [a,b,c,b,d,c]
        }
      }
    }
    return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                       elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
  }
}

struct CableVisual: View {
  var compact = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var tilt = CGSize.zero
  @State private var entered = false
  var body: some View {
    CableSceneView(dark: scheme == .dark, x: reduceMotion ? 0 : Double(tilt.width) / 500,
                   y: reduceMotion ? 0 : Double(tilt.height) / 650)
      .id(scheme).scaleEffect(entered || reduceMotion ? 1 : 0.96)
      .opacity(entered || reduceMotion ? 1 : 0)
      .gesture(DragGesture(minimumDistance: 3).onChanged { value in
        tilt = CGSize(width: max(-100,min(100,value.translation.width)), height: max(-75,min(75,value.translation.height)))
      }.onEnded { _ in tilt = .zero })
      .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { entered = true } }
      .accessibilityLabel("USB-C 线缆立体示意")
      .help(compact ? "USB-C 线缆示意" : "拖动查看 · 外观为示意，不代表实物")
  }
}

private struct CableSceneView: NSViewRepresentable {
  let dark: Bool
  let x: Double
  let y: Double
  func makeCoordinator() -> Coordinator { Coordinator(dark: dark) }
  func makeNSView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = context.coordinator.model.scene; view.pointOfView = context.coordinator.model.camera
    view.backgroundColor = .clear; view.antialiasingMode = .multisampling4X
    view.rendersContinuously = false; view.isPlaying = false; view.preferredFramesPerSecond = 30
    return view
  }
  func updateNSView(_ view: SCNView, context: Context) {
    guard context.coordinator.x != x || context.coordinator.y != y else { return }
    context.coordinator.x = x; context.coordinator.y = y
    // On-demand frames only. No perpetual display link or idle rotation.
    SCNTransaction.begin(); SCNTransaction.animationDuration = x == 0 && y == 0 ? 0.28 : 0.08
    context.coordinator.model.pose(x: x, y: y); SCNTransaction.commit()
    view.needsDisplay = true
  }
  static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) { view.scene = nil }
  final class Coordinator {
    let model: CableScene
    var x = 0.0, y = 0.0
    init(dark: Bool) { model = CableScene(dark: dark) }
  }
}
