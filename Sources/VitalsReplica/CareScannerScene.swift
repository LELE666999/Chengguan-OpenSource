import AppKit
import SceneKit

/// Native interpretation of UI Ball's Helix: six opposing pairs orbit in depth.
/// Flat ink keeps the light appearance crisp; only foreground dots emit a soft dark-mode halo.
final class CareScannerScene {
  let scene = SCNScene()
  let camera = SCNNode()
  private let assembly = SCNNode()
  private var dots: [SCNNode] = []
  private var halos: [SCNNode] = []
  private var dark: Bool
  private let material = SCNMaterial()
  private let haloMaterial = SCNMaterial()

  init(dark: Bool) {
    self.dark = dark
    scene.background.contents = NSColor.clear
    camera.camera = SCNCamera()
    camera.camera?.usesOrthographicProjection = true
    camera.camera?.orthographicScale = 1.45
    camera.camera?.zNear = 0.1
    camera.position = SCNVector3(0, 0, 6)
    scene.rootNode.addChildNode(camera)
    scene.rootNode.addChildNode(assembly)

    material.lightingModel = .constant
    let sphere = SCNSphere(radius: 0.11)
    sphere.segmentCount = 32
    sphere.firstMaterial = material

    haloMaterial.lightingModel = .constant
    haloMaterial.diffuse.contents = Self.haloTexture()
    haloMaterial.blendMode = .add
    haloMaterial.readsFromDepthBuffer = false
    haloMaterial.writesToDepthBuffer = false
    let halo = SCNPlane(width: 0.52, height: 0.52)
    halo.firstMaterial = haloMaterial

    for _ in 0..<12 {
      let dot = SCNNode(geometry: sphere)
      let glow = SCNNode(geometry: halo)
      // Halo sprites draw before the opaque circular cores, leaving the silhouette clean.
      glow.renderingOrder = -1
      dots.append(dot); halos.append(glow)
      assembly.addChildNode(glow); assembly.addChildNode(dot)
    }
    setAppearance(dark: dark, animated: false)
    pose(time: 0, activity: 0, completion: 0)
  }

  func setAppearance(dark: Bool, animated: Bool) {
    self.dark = dark
    SCNTransaction.begin()
    SCNTransaction.animationDuration = animated ? 0.25 : 0
    material.diffuse.contents = dark
      ? NSColor(calibratedRed: 0.43, green: 0.83, blue: 1, alpha: 1)
      : NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.88, alpha: 1)
    haloMaterial.multiply.contents = NSColor(calibratedRed: 0.25, green: 0.71, blue: 1, alpha: 1)
    for halo in halos { halo.isHidden = !dark }
    SCNTransaction.commit()
  }

  /// A smooth radial light sprite, generated locally once; no shadows, textures on the dots or bloom pass.
  private static func haloTexture() -> NSImage {
    NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
      let colors = [NSColor.white.withAlphaComponent(0.72), .white.withAlphaComponent(0.28),
                    .white.withAlphaComponent(0.035), .clear]
      let gradient = NSGradient(colorsAndLocations: (colors[0], 0), (colors[1], 0.30), (colors[2], 0.70), (colors[3], 1))!
      let center = NSPoint(x: rect.midX, y: rect.midY)
      gradient.draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width / 2, options: [])
      return true
    }
  }

  func pose(time: Double, activity: Double, completion: Double, entrance: Double = 1) {
    SCNTransaction.begin(); SCNTransaction.disableActions = true
    let activity = min(1, max(0, activity)), completion = min(1, max(0, completion))
    let entrance = min(1, max(0, entrance))
    assembly.opacity = entrance
    assembly.position.y = -0.045 * (1 - entrance)
    let settled = 1 - completion * 0.055
    assembly.scale = SCNVector3(settled, settled, settled)

    for row in 0..<6 {
      // The six slices are one sixth of a revolution apart, as in the selected reference.
      let turn = time * (.pi * 2 / 3.2) - Double(row) * .pi / 3
      let distance = sin((time * 0.26 - Double(row) / 6) * .pi)
      let highlight = exp(-distance * distance * 20) * activity * (1 - completion)
      let taper = 0.94 + 0.06 * sin(Double(row) / 5 * .pi)
      for strand in 0..<2 {
        let index = row * 2 + strand, angle = turn + Double(strand) * .pi
        let front = (sin(angle) + 1) / 2
        let scale = (0.49 + 0.51 * front) * taper * (1 + highlight * front * 0.045)
        let point = SCNVector3(cos(angle) * 0.56, (2.5 - Double(row)) * 0.28, sin(angle) * 0.38)
        let dot = dots[index]
        dot.position = point
        dot.scale = SCNVector3(scale, scale, scale)
        dot.opacity = (0.30 + 0.70 * front) * (0.92 + highlight * 0.08)
        let halo = halos[index]
        halo.position = point
        halo.scale = SCNVector3(scale, scale, scale)
        halo.opacity = dark ? pow(front, 2) * (0.26 + activity * 0.12 + highlight * 0.20) : 0
      }
    }
    SCNTransaction.commit()
  }
}
