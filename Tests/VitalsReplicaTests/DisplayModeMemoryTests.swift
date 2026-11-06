import XCTest
@testable import VitalsReplica

@MainActor final class DisplayModeMemoryTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!
  override func setUp() {
    super.setUp(); suite = "DisplayModeMemoryTests." + UUID().uuidString
    defaults = UserDefaults(suiteName: suite)!
  }
  override func tearDown() { defaults.removePersistentDomain(forName: suite); defaults = nil; super.tearDown() }
  private func mode(_ id: Int32 = 1, width: Int = 2048, pixels: Int = 4096, refresh: Double = 60) -> DisplayModeChoice {
    .init(id: id, width: width, height: width * 9 / 16, pixelWidth: pixels, pixelHeight: pixels * 9 / 16, refresh: refresh)
  }
  private func device(_ uuid: String = "external", id: UInt32 = 3, builtin: Bool = false, current: DisplayModeChoice? = nil, modes: [DisplayModeChoice]? = nil) -> DisplayDevice {
    let active = current ?? mode()
    return .init(id: uuid, displayID: id, name: builtin ? "Built-in Retina Display" : "Same model", builtin: builtin, main: !builtin, virtual: false,
      width: 5120, height: 2880, millimetersWidth: 600, millimetersHeight: 340, rotation: 0, originX: 0, originY: 0, mirror: 0,
      vendor: 1, model: 2, serial: 3, manufactured: nil, hdrPotential: false, edr: 1, current: active, modes: modes ?? [active])
  }
  func testTwoScreensPersistIndependentlyAcrossProcessAndTransientIDs() throws {
    let internalMode = mode(54, width: 1512, pixels: 3024, refresh: 120)
    let system = MemorySystem([device(), device("builtin", id: 1, builtin: true, current: internalMode)])
    let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices)
    let reloaded = DisplayModeMemoryController(defaults: defaults, system: system)
    XCTAssertEqual(reloaded.profiles.count, 2)
    XCTAssertEqual(reloaded.profiles["builtin"]?.mode.signature, internalMode.signature)
    let newID = mode(95)
    system.devices[0].displayID = 67
    system.devices[0].current = mode(1, width: 1920, pixels: 3840)
    system.devices[0].modes = [system.devices[0].current!, newID]
    let start = Date(); reloaded.resume(schedule: false, now: start)
    reloaded.tick(now: start.addingTimeInterval(1)); reloaded.tick(now: start.addingTimeInterval(2))
    XCTAssertEqual(system.writes.count, 1)
    XCTAssertEqual(system.writes.first?.0, "external")
    XCTAssertEqual(system.writes.first?.1.id, 95)
    XCTAssertEqual(system.devices[0].displayID, 67)
    reloaded.tick(now: start.addingTimeInterval(3))
    reloaded.tick(now: start.addingTimeInterval(4))
    XCTAssertEqual(reloaded.status["external"], "已自动恢复")
  }
  func testMasterSwitchBlocksWakeAndManualRestoreAndRetainsPreferences() {
    let system = MemorySystem([device()]); let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices); let saved = memory.profiles
    system.devices[0].current = mode(6, width: 1920, pixels: 3840)
    memory.resume(schedule: false); memory.setControlEnabled(false)
    memory.resume(schedule: false); memory.tick(); memory.tick(); memory.restoreNow(system.devices[0]); memory.remember(system.devices[0])
    XCTAssertTrue(system.writes.isEmpty); XCTAssertFalse(memory.recovering); XCTAssertEqual(memory.profiles, saved)
    memory.setControlEnabled(true)
    memory.restoreNow(system.devices[0]); memory.pause()
    XCTAssertEqual(system.writes.count, 1)
    XCTAssertFalse(MonitorTab.available(displayEnabled: false).contains(.displays))
    XCTAssertTrue(MonitorTab.available(displayEnabled: false).contains(.server))
  }
  func testWakeWaitsForStableSnapshotAndDoesNotLearnTemporaryMode() {
    let system = MemorySystem([device()]); let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices)
    let preferred = memory.profiles["external"]!.mode
    let start = Date(); memory.resume(schedule: false, now: start)
    system.devices[0].current = mode(2, width: 1280, pixels: 2560)
    memory.tick(now: start.addingTimeInterval(1))
    system.devices[0].current = mode(3, width: 1920, pixels: 3840)
    memory.tick(now: start.addingTimeInterval(2))
    XCTAssertTrue(system.writes.isEmpty)
    memory.tick(now: start.addingTimeInterval(3))
    XCTAssertEqual(system.writes.count, 1)
    XCTAssertEqual(memory.profiles["external"]?.mode, preferred)
  }
  func testUnconfirmedModeCannotReplaceSavedPreferenceOrBeFoughtByWakeRecovery() {
    let system = MemorySystem([device()]); let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices); let old = memory.profiles["external"]!.mode
    memory.beginManualChange("external")
    system.devices[0].current = mode(9, width: 1920, pixels: 3840)
    memory.remember(system.devices[0])
    XCTAssertEqual(memory.profiles["external"]?.mode, old)
    let start = Date(); memory.resume(schedule: false, now: start)
    memory.tick(now: start.addingTimeInterval(1)); memory.tick(now: start.addingTimeInterval(2))
    XCTAssertTrue(system.writes.isEmpty)
    XCTAssertEqual(memory.profiles["external"]?.mode, old)
    memory.endManualChange(nil, uuid: "external", keep: false)
    XCTAssertEqual(memory.profiles["external"]?.mode, old)
    memory.beginManualChange("external")
    memory.endManualChange(system.devices[0], uuid: "external", keep: true)
    XCTAssertEqual(memory.profiles["external"]?.mode.signature, system.devices[0].current?.signature)
  }
  func testNoFallbackToWrongHiDPIOrRefreshAndLateModeAvailabilityRecovers() {
    let system = MemorySystem([device()]); let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices)
    let original = memory.profiles["external"]!.mode
    system.devices[0].current = mode(1, width: 1920, pixels: 3840)
    system.devices[0].modes = [mode(1, pixels: 2048), mode(9, refresh: 120)]
    let start = Date(); memory.resume(schedule: false, now: start)
    memory.tick(now: start.addingTimeInterval(1)); memory.tick(now: start.addingTimeInterval(2))
    XCTAssertTrue(system.writes.isEmpty)
    XCTAssertEqual(memory.profiles["external"]?.mode, original)
    system.devices[0].modes.append(mode(99))
    memory.tick(now: start.addingTimeInterval(3))
    XCTAssertEqual(system.writes.first?.1.id, 99)
  }
  func testSleepingMirroredAndDisabledScreensAreNeverWritten() {
    let system = MemorySystem([device(), device("other", id: 7)])
    let memory = DisplayModeMemoryController(defaults: defaults, system: system); memory.seed(system.devices)
    memory.setEnabled(false, on: system.devices[1])
    system.devices[0].mirror = 7
    system.devices[0].current = mode(2, width: 1920, pixels: 3840)
    system.devices[1].current = mode(2, width: 1920, pixels: 3840)
    let start = Date(); memory.resume(schedule: false, now: start)
    memory.tick(now: start.addingTimeInterval(1)); memory.tick(now: start.addingTimeInterval(2))
    XCTAssertTrue(system.writes.isEmpty)
    system.devices[0].mirror = 0; system.unusable.insert("external")
    memory.tick(now: start.addingTimeInterval(3)); memory.tick(now: start.addingTimeInterval(4))
    XCTAssertTrue(system.writes.isEmpty)
    memory.pause(); system.unusable = []
    memory.tick(now: start.addingTimeInterval(5)); XCTAssertTrue(system.writes.isEmpty)
    XCTAssertEqual(DisplayModeMemoryController(defaults: defaults, system: system).profiles["other"]?.enabled, false)
  }
  func testRetryBudgetAndLifecycleDeadlinePreventPermanentModeFight() {
    let system = MemorySystem([device()]); system.acceptWrites = false
    let memory = DisplayModeMemoryController(defaults: defaults, system: system); memory.seed(system.devices)
    system.devices[0].current = mode(2, width: 1920, pixels: 3840)
    let start = Date(); memory.resume(schedule: false, now: start)
    for t in 1...25 { memory.tick(now: start.addingTimeInterval(Double(t))) }
    XCTAssertEqual(system.writes.count, 2)
    XCTAssertFalse(memory.recovering)
    XCTAssertEqual(memory.profiles["external"]?.mode.signature, mode().signature)
  }
  func testCorrectModeAndDisconnectedDeviceDoNotCauseWrites() {
    let system = MemorySystem([device()]); let memory = DisplayModeMemoryController(defaults: defaults, system: system)
    memory.seed(system.devices)
    let start = Date(); memory.resume(schedule: false, now: start)
    memory.tick(now: start.addingTimeInterval(1)); memory.tick(now: start.addingTimeInterval(2))
    XCTAssertTrue(system.writes.isEmpty)
    system.devices = []
    memory.tick(now: start.addingTimeInterval(3)); memory.finishRecovery()
    XCTAssertTrue(system.writes.isEmpty)
    XCTAssertNotNil(memory.profiles["external"])
  }
  func testDualDisplayWakeRestoresEachOwnScalingAndRefresh() {
    let internalMode = mode(54, width: 1512, pixels: 3024, refresh: 120)
    let system = MemorySystem([device(), device("builtin", id: 1, builtin: true, current: internalMode)])
    let memory = DisplayModeMemoryController(defaults: defaults, system: system); memory.seed(system.devices)
    system.devices[0].current = mode(2, width: 1920, pixels: 3840)
    system.devices[1].current = mode(3, width: 1728, pixels: 3456, refresh: 60)
    let start = Date(); memory.resume(schedule: false, now: start)
    memory.tick(now: start.addingTimeInterval(1)); memory.tick(now: start.addingTimeInterval(2))
    XCTAssertEqual(system.writes.map(\.0), ["external", "builtin"])
    XCTAssertEqual(system.devices[0].current?.signature, mode().signature)
    XCTAssertEqual(system.devices[1].current?.signature, internalMode.signature)
  }
}

@MainActor private final class MemorySystem: DisplayModeMemorySystem {
  var devices: [DisplayDevice]
  var writes: [(String, DisplayModeChoice)] = []
  var unusable = Set<String>()
  var acceptWrites = true
  init(_ devices: [DisplayDevice]) { self.devices = devices }
  func read() -> [DisplayDevice] { devices }
  func usable(_ device: DisplayDevice) -> Bool { !device.virtual && device.mirror == 0 && !unusable.contains(device.id) }
  func apply(_ mode: DisplayModeChoice, to device: DisplayDevice) -> Bool {
    writes.append((device.id, mode))
    if acceptWrites, let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].current = mode }
    return acceptWrites
  }
}
