import AppKit

struct MenuHoverState {
  enum Mode { case closed, preview, pinned }
  private(set) var mode: Mode = .closed
  private(set) var suppressed = false
  mutating func preview() -> Bool {
    guard mode == .closed, !suppressed else { return false }
    mode = .preview; return true
  }
  mutating func pin() -> Bool {
    guard mode == .preview else { return false }
    mode = .pinned; return true
  }
  mutating func clicked() { mode = mode == .closed ? .pinned : .closed; suppressed = true }
  mutating func closed() { mode = .closed; suppressed = true }
  mutating func leftButton() { suppressed = false }
}

/// A hover preview does not activate the app; clicking it turns it into the ordinary interactive panel.
final class MenuHoverPresenter: NSObject, NSPopoverDelegate {
  private weak var button: NSStatusBarButton?
  private weak var popover: NSPopover?
  private var state = MenuHoverState()
  private var dwell: Timer?, grace: Timer?
  private var anchor = NSPoint.zero
  private var monitor: Any?
  init(button: NSStatusBarButton, popover: NSPopover) {
    self.button = button; self.popover = popover
    super.init()
    popover.delegate = self
    install(on: button, isButton: true)
    if let content = popover.contentViewController?.view { install(on: content, isButton: false) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
      if let self, event.window === self.popover?.contentViewController?.view.window { _ = self.pinIfPreviewing() }
      return event
    }
  }
  private func install(on view: NSView, isButton: Bool) {
    let tracking = MenuHoverTracking(frame: view.bounds)
    tracking.autoresizingMask = [.width, .height]
    tracking.enter = { [weak self] in
      self?.grace?.invalidate()
      if isButton { self?.schedulePreview() }
    }
    tracking.leave = { [weak self] in
      if isButton { self?.dwell?.invalidate(); self?.state.leftButton() }
      self?.scheduleClose()
    }
    tracking.move = { [weak self] in
      guard isButton, let self, hypot(NSEvent.mouseLocation.x - self.anchor.x, NSEvent.mouseLocation.y - self.anchor.y) > 6 else { return }
      self.schedulePreview()
    }
    view.addSubview(tracking)
  }
  private func schedulePreview() {
    guard UserDefaults.standard.object(forKey: "menuHoverPreview") as? Bool != false,
      state.mode == .closed, !state.suppressed else { return }
    dwell?.invalidate(); anchor = NSEvent.mouseLocation
    dwell = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
      guard let self, let button = self.button, let popover = self.popover, !popover.isShown,
        self.state.preview() else { return }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }
  private func scheduleClose() {
    grace?.invalidate()
    guard state.mode == .preview else { return }
    grace = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
      guard let self, self.state.mode == .preview else { return }
      let point = NSEvent.mouseLocation
      if let window = self.popover?.contentViewController?.view.window, window.frame.insetBy(dx: -3, dy: -3).contains(point) { return }
      if let button = self.button, let window = button.window,
        window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
      self.popover?.performClose(nil)
    }
  }
  func pinIfPreviewing() -> Bool {
    guard state.pin() else { return false }
    dwell?.invalidate(); grace?.invalidate()
    NSApp.activate(ignoringOtherApps: true)
    popover?.contentViewController?.view.window?.makeKey()
    return true
  }
  func clicked() { dwell?.invalidate(); grace?.invalidate(); state.clicked() }
  func popoverDidClose(_ notification: Notification) {
    state.closed()
    guard let button, let window = button.window else { state.leftButton(); return }
    if !window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { state.leftButton() }
  }
  deinit { dwell?.invalidate(); grace?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) } }
}

private final class MenuHoverTracking: NSView {
  var enter: (() -> Void)?, leave: (() -> Void)?, move: (() -> Void)?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { enter?() }
  override func mouseExited(with event: NSEvent) { leave?() }
  override func mouseMoved(with event: NSEvent) { move?() }
}
