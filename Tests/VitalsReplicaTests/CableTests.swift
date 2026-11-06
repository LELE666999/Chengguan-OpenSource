import XCTest
@testable import VitalsReplica

final class CableTests: XCTestCase {
  private func words(_ vdo: UInt32, type: UInt32 = 3, extra: UInt32? = nil) -> [UInt32] {
    var values: [UInt32] = [(type << 27) | 0x05ac, 2549, 0x12340001, vdo]
    if let extra { values.append(extra) }
    return values
  }
  private func bytes(_ values: [UInt32]) -> [Data] {
    values.map { v in Data((0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
  }
  private func port(active: Bool = true, identity: [UInt32]? = nil, number: Int = 1) -> [String: Any] {
    let cable: [String: Any] = ["RegistryName": "SOP'", "Specification Revision": 3, "Metadata": ["VDOs": bytes(identity ?? words(0x000a2643))]]
    return ["PortTypeDescription": "USB-C", "ConnectionActive": active, "RegistryID": number, "PortNumber": number,
      "Children": [["RegistryName": "CC", "Children": [cable]],
        ["RegistryName": "USB3", "Active": true, "Product": "USB Hub", "DataRateDescription": "10 Gbps"],
        ["RegistryName": "DisplayPort", "Active": true, "ProductName": "External Display"],
        ["RegistryName": "Power In", "Children": [["RegistryName": "USB-PD [*]", "WinningPowerSourceOption": ["Max Power (mW)": 100000, "Voltage (mV)": 20000, "Max Current (mA)": 5000]]]]]]
  }
  func testLittleEndianIdentityAndMalformedData() {
    XCTAssertEqual(CableReader.words([Data([0x43, 0x26, 0x0a, 0x00])]), [0xa2643])
    XCTAssertTrue(CableReader.words([Data([0x43, 0x26])]).isEmpty)
    XCTAssertTrue(CableReader.words([UInt32(0xa2643)]).isEmpty)
    XCTAssertTrue(CableReader.words(Array(repeating: Data([0,0,0,0]), count: 100)).isEmpty)
  }
  func testEPRClampsTo240Not250Watts() throws {
    let cable = try XCTUnwrap(CableIdentity.decode(words(0x000a2643), revision: 3))
    XCTAssertEqual(cable.ratedWatts, 240)
    XCTAssertEqual(cable.ratedVolts, 50)
    XCTAssertEqual(cable.currentAmps, 5)
    XCTAssertTrue(cable.epr)
    XCTAssertEqual(cable.speed, "USB4 · 20–40 Gbps")
    XCTAssertEqual(cable.certificationID, 2549)
    XCTAssertEqual(cable.productID, 0x1234)
  }
  func testSPRAndDeprecatedVoltageFieldsDoNotBecomeEPR() {
    for voltage: UInt32 in 0...2 {
      let cable = CableIdentity.decode(words(2 << 5 | voltage << 9), revision: 3)
      XCTAssertEqual(cable?.ratedWatts, 100)
      XCTAssertEqual(cable?.ratedVolts, 20)
      XCTAssertEqual(cable?.speed, "480 Mbps")
      XCTAssertEqual(cable?.epr, false)
    }
    // Voltage insulation alone is not an EPR claim.
    XCTAssertEqual(CableIdentity.decode(words(2 << 5 | 3 << 9), revision: 3)?.ratedWatts, 100)
  }
  func testNoDefaultRatingForReservedOrMissingCurrent() {
    for current: UInt32 in [0, 3] {
      let cable = CableIdentity.decode(words(current << 5 | 7), revision: 3)
      XCTAssertNil(cable?.ratedWatts)
      XCTAssertNil(cable?.currentAmps)
      XCTAssertEqual(cable?.speed, "数据能力未知")
      XCTAssertNotNil(cable?.warning)
    }
  }
  func testUnsupportedFormatAndPD2DoNotInventCapabilities() {
    XCTAssertNil(CableIdentity.decode([], revision: 3))
    XCTAssertNil(CableIdentity.decode(words(2 << 5, type: 1), revision: 3))
    let future = CableIdentity.decode(words(1 << 21 | 2 << 5 | 4), revision: 3)
    XCTAssertNil(future?.ratedWatts)
    XCTAssertEqual(future?.speed, "数据能力未知")
    XCTAssertNotNil(future?.warning)
    let old = CableIdentity.decode(words(2 << 5 | 3 << 9 | 1 << 17 | 4), revision: 2)
    XCTAssertEqual(old?.ratedWatts, 100)
    XCTAssertEqual(old?.speed, "数据能力未知")
    XCTAssertEqual(old?.epr, false)
  }
  func testActiveCableNeedsPowerAndProtocolDeclarations() {
    let v: UInt32 = 3 << 21 | 2 << 5 | 4
    let noVBUS = CableIdentity.decode(words(v, type: 4, extra: 0), revision: 3)
    XCTAssertNil(noVBUS?.ratedWatts)
    XCTAssertEqual(noVBUS?.speed, "80 Gbps")
    let disabled = CableIdentity.decode(words(v | 1 << 4, type: 4, extra: 1 << 8), revision: 3)
    XCTAssertEqual(disabled?.ratedWatts, 100)
    XCTAssertEqual(disabled?.speed, "数据能力未知")
    XCTAssertEqual(CableIdentity.decode(words(v, type: 4), revision: 3)?.speed, "数据能力未知")
    let activeHighVoltage = CableIdentity.decode(words(v | 3 << 9 | 1 << 17 | 1 << 4, type: 4, extra: 0), revision: 3)
    XCTAssertEqual(activeHighVoltage?.epr, false)
    XCTAssertEqual(activeHighVoltage?.ratedWatts, 100)
    XCTAssertNotNil(activeHighVoltage?.warning)
  }
  func testPortJoinsLocalChildrenWithoutConfusingRatingsAndLiveLink() throws {
    let result = CableReader.parse([port()])
    let p = try XCTUnwrap(result.ports.first)
    XCTAssertTrue(result.readable)
    XCTAssertEqual(result.identified, 1)
    XCTAssertEqual(p.identity?.ratedWatts, 240)
    XCTAssertEqual(p.link, "10 Gbps")
    XCTAssertEqual(p.supplyWatts, 100)
    XCTAssertEqual(p.supplyVolts, 20)
    XCTAssertEqual(p.supplyAmps, 5)
    XCTAssertEqual(p.devices, ["External Display", "USB Hub"])
  }
  func testDisconnectDropsStaleChildrenAndCachedPowerOptions() {
    let result = CableReader.parse([port(active: false)])
    XCTAssertTrue(result.readable)
    XCTAssertEqual(result.portCount, 1)
    XCTAssertTrue(result.ports.isEmpty)
    XCTAssertEqual(result.summary, "未连接 USB-C 线缆")
  }
  func testOnlyWinningLivePowerSourceIsReported() {
    var p = port()
    p["Children"] = [["RegistryName": "USB-PD", "WinningPowerSourceOption": ["Max Power (mW)": 240000]]]
    XCTAssertNil(CableReader.parse([p]).ports.first?.supplyWatts)
  }
  func testSOPPartnerIsNeverDecodedAsCableAndMissingIdentityRemainsVisible() throws {
    var p = port()
    p["Children"] = [["RegistryName": "SOP", "Specification Revision": 3, "Metadata": ["VDOs": bytes(words(0xa2643))]]]
    let result = CableReader.parse([p])
    XCTAssertEqual(result.ports.count, 1)
    XCTAssertNil(result.ports.first?.identity)
    XCTAssertEqual(result.ports.first?.summary, "芯片未读到")
  }
  func testUnsupportedAndEmptyControllersStayDistinct() {
    XCTAssertFalse(CableReader.parse([]).readable)
    XCTAssertFalse(CableReader.parse([["PortTypeDescription": "MagSafe 3"]]).readable)
    XCTAssertTrue(CableReader.parse([port(active: false)]).readable)
  }
  @MainActor func testConnectionChangesDoNotRepeatAndDelayedIdentityIsAnnounced() {
    let store = CableMonitor(), now = Date()
    let empty = CableReader.parse([port(active: false)])
    let full = CableReader.parse([port()])
    store.apply(empty, now: now)
    XCTAssertTrue(store.changes.isEmpty)
    store.apply(full, now: now)
    XCTAssertEqual(store.changes.count, 1)
    XCTAssertEqual(store.changes.first?.title, "USB-C 1 已连接")
    XCTAssertEqual(store.changes.first?.cables, true)
    store.apply(full, now: now)
    XCTAssertEqual(store.changes.count, 1)
    store.apply(empty, now: now)
    XCTAssertEqual(store.changes.count, 2)
    XCTAssertEqual(store.changes.first?.title, "USB-C 1 已断开")
  }
  @MainActor func testDelayedIdentityAndLiquidWarningAreLocalEvents() {
    let full = CableReader.parse([port()])
    var p = port(); p["Children"] = []
    let waiting = CableReader.parse([p])
    let events = CableMonitor.diff(waiting, full, now: Date())
    XCTAssertEqual(events.first?.title, "USB-C 1 线缆已识别")
    p = port(); p["LDCM_LiquidDetected"] = true
    let wet = CableReader.parse([p])
    let warnings = CableMonitor.diff(full, wet, now: Date())
    XCTAssertEqual(warnings.first?.priority, 1)
    XCTAssertTrue(warnings.first?.title.contains("液体") == true)
  }
  func testUnknownCableDoesNotFailChargingOrVideoThatIsActuallyActive() throws {
    var tree = port()
    tree["Children"] = [["RegistryName": "DisplayPort", "Active": true, "ProductName": "Display", "LaneCount": 4, "LinkRateDescription": "8.1 Gbps (HBR3)"]]
    let p = try XCTUnwrap(CableReader.parse([tree]).ports.first)
    let uses = CableUseCase.evaluate(p)
    XCTAssertEqual(uses.first { $0.id == "charging" }?.verdict, .unknown)
    XCTAssertEqual(uses.first { $0.id == "storage" }?.verdict, .unknown)
    XCTAssertEqual(uses.first { $0.id == "display" }?.verdict, .supported)
    XCTAssertEqual(p.videoDetail, "4 通道 · 8.1 Gbps (HBR3) / 通道")
  }
  func testUSB2CableIsLimitedForFastStorageButMissingDisplayIsUnknown() throws {
    var tree = port(identity: words(2 << 5))
    tree["Children"] = [["RegistryName": "SOP'", "Specification Revision": 3, "Metadata": ["VDOs": bytes(words(2 << 5))]]]
    let p = try XCTUnwrap(CableReader.parse([tree]).ports.first)
    let uses = CableUseCase.evaluate(p)
    XCTAssertEqual(uses.first { $0.id == "charging" }?.verdict, .supported)
    XCTAssertEqual(uses.first { $0.id == "storage" }?.verdict, .limited)
    XCTAssertEqual(uses.first { $0.id == "display" }?.verdict, .unknown)
    XCTAssertEqual(uses.first { $0.id == "dock" }?.verdict, .limited)
  }
  func testActiveUSB4DoesNotPromiseUSB3FallbackOrThunderboltCertification() throws {
    let p = try XCTUnwrap(CableReader.parse([port(identity: words(3 << 21 | 2 << 5 | 1 << 4 | 3, type: 4, extra: 1 << 4))]).ports.first)
    let uses = CableUseCase.evaluate(p)
    XCTAssertEqual(uses.first { $0.id == "dock" }?.verdict, .supported)
    XCTAssertEqual(uses.first { $0.id == "storage" }?.verdict, .unknown)
    XCTAssertTrue(uses.first { $0.id == "dock" }?.detail.contains("非雷雳认证") == true)
  }
  func testOnlyCurrentSelectedSourceOffersBoundedPowerProfiles() throws {
    var tree = port()
    tree["Children"] = [["RegistryName": "USB-PD [*]", "PowerSourceOptions": [
      ["Class": "IOPortFeaturePowerSourceOptionFixed", "Voltage (mV)": 20000, "Max Current (mA)": 5000, "Max Power (mW)": 100000],
      ["Class": "IOPortFeaturePowerSourceOptionFixed", "Voltage (mV)": 5000, "Max Current (mA)": 3000, "Max Power (mW)": 15000],
      ["Class": "IOPortFeaturePowerSourceOptionFixed", "Voltage (mV)": 999999, "Max Current (mA)": 5000, "Max Power (mW)": 999999]]]]
    let p = try XCTUnwrap(CableReader.parse([tree]).ports.first)
    XCTAssertEqual(p.powerProfiles.map(\.watts), [15, 100])
    XCTAssertEqual(p.powerProfiles.first?.label, "5 V · 3 A")
    var setTree = tree
    var source = (tree["Children"] as! [[String: Any]])[0]
    source["PowerSourceOptions"] = NSSet(array: source["PowerSourceOptions"] as! [Any])
    setTree["Children"] = [source]
    XCTAssertEqual(CableReader.parse([setTree]).ports.first?.powerProfiles.map(\.watts), [15, 100])
    tree["ConnectionActive"] = false
    XCTAssertTrue(CableReader.parse([tree]).ports.isEmpty)
  }
  func testPortObservationTimeExcludesSleepAndDisconnectedGaps() {
    let start = Date(timeIntervalSince1970: 100)
    let connected = CableReader.parse([port()]), empty = CableReader.parse([port(active: false)])
    var log = CableObservationLog()
    log.observe(connected, at: start)
    log.observe(connected, at: start.addingTimeInterval(3))
    log.observe(connected, at: start.addingTimeInterval(3600))
    XCTAssertEqual(log.records["1"]?.observedSeconds, 3)
    XCTAssertEqual(log.records["1"]?.observations, 1)
    XCTAssertEqual(log.events.count, 1)
    log.observe(empty, at: start.addingTimeInterval(3603))
    log.observe(connected, at: start.addingTimeInterval(7200))
    XCTAssertEqual(log.records["1"]?.observedSeconds, 3)
    XCTAssertEqual(log.records["1"]?.observations, 2)
    XCTAssertEqual(log.events.first?.title, "已连接")
    XCTAssertEqual(log.records["1"]?.peakSupplyWatts, 100)
  }
  func testCablePagePreservesExistingNavigationShortcuts() {
    XCTAssertEqual(MonitorTab.cpu.shortcut, "2")
    XCTAssertEqual(MonitorTab.projects.shortcut, "0")
    XCTAssertNil(MonitorTab.cables.shortcut)
    XCTAssertFalse(MonitorTab.cables.isProcessTab)
  }

}
