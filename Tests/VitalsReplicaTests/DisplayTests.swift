import XCTest
import DisplayBridge
@testable import VitalsReplica

final class DisplayTests: XCTestCase {
  func testScalingStopsPreserveActiveTimingAndChooseNearestRefresh() {
    let active = mode(7)
    let choices = DisplayRules.scalingModes([mode(1), mode(2, 1920, pixels: 3840, refresh: 30), mode(3, 1920, pixels: 3840, refresh: 60), mode(4, 1920, pixels: 1920)], current: active)
    XCTAssertEqual(choices.map(\.width), [1920, 2048])
    XCTAssertEqual(choices.map(\.id), [3, 7])
    XCTAssertEqual(DisplayRules.scalingIndex(0.6, count: 2), 1)
    XCTAssertEqual(DisplayRules.scalingIndex(-100, count: 2), 0)
    XCTAssertEqual(DisplayRules.scalingIndex(100, count: 2), 1)
    XCTAssertNil(DisplayRules.scalingIndex(.nan, count: 2))
    XCTAssertNil(DisplayRules.scalingIndex(0, count: 0))
    XCTAssertTrue(DisplayRules.scalingModes([], current: nil).isEmpty)
  }
  func testAudioAssociationRejectsAmbiguityAndSimilarModelNames() {
    let first = DisplayAudioOutput(id: "a", object: 1, name: "Kuycon G27-X", volume: nil, writable: false)
    let other = DisplayAudioOutput(id: "b", object: 2, name: "Kuycon G27-Y", volume: 50, writable: true)
    XCTAssertEqual(DisplayAudioRules.match("KUYCON G27 X", outputs: [first, other])?.id, "a")
    XCTAssertNil(DisplayAudioRules.match("Kuycon", outputs: [first, other]))
    var duplicate = first; duplicate.id = "c"
    XCTAssertNil(DisplayAudioRules.match(first.name, outputs: [first, duplicate]))
  }
  func testUnsupportedRemoteControlsNeverAppearAsEnabled() {
    XCTAssertEqual(DisplayRules.switchValue("on\n"), true)
    XCTAssertEqual(DisplayRules.switchValue("0.0"), false)
    XCTAssertNil(DisplayRules.switchValue("unavailable"))
    XCTAssertNil(DisplayRules.switchValue(""))
    XCTAssertNil(DisplayRules.switchValue("0.8"))
  }
  func testSliderDoesNotAcceptPollStartedBeforeTheLatestWrite() {
    var ledger = DisplayWriteLedger()
    let key = "screen:16"
    let beforeDrag = ledger.sent
    let first = ledger.begin(key)
    XCTAssertFalse(ledger.acceptSample(key, snapshot: beforeDrag))
    XCTAssertTrue(ledger.didSend(key, revision: first))
    let stalePoll = ledger.sent
    let last = ledger.begin(key)
    XCTAssertFalse(ledger.didSend(key, revision: first))
    XCTAssertFalse(ledger.acceptSample(key, snapshot: stalePoll))
    XCTAssertTrue(ledger.didSend(key, revision: last))
    XCTAssertFalse(ledger.acceptSample(key, snapshot: stalePoll))
    XCTAssertTrue(ledger.acceptSample(key, snapshot: ledger.sent))
    XCTAssertTrue(ledger.pending.isEmpty)
  }
  func testSliderWriteFailuresAndUnrelatedVolumePollRemainIndependent() {
    var ledger = DisplayWriteLedger()
    let old = ledger.begin("screen:16")
    let latest = ledger.begin("screen:16")
    XCTAssertFalse(ledger.fail("screen:16", revision: old))
    XCTAssertTrue(ledger.acceptSample("screen:98", snapshot: [:]))
    XCTAssertFalse(ledger.acceptSample("screen:16", snapshot: [:]))
    XCTAssertTrue(ledger.fail("screen:16", revision: latest))
    XCTAssertTrue(ledger.acceptSample("screen:16", snapshot: [:]))
  }
  private func mode(_ id: Int32, _ width: Int = 2048, pixels: Int = 4096, refresh: Double = 60) -> DisplayModeChoice {
    .init(id: id, width: width, height: width * 9 / 16, pixelWidth: pixels, pixelHeight: pixels * 9 / 16, refresh: refresh)
  }
  func testModesKeepHiDPIRenderSizeAndRefreshDistinct() {
    let active = mode(9)
    let modes = DisplayRules.uniqueModes([mode(1), mode(2, pixels: 2048), mode(3, refresh: 120)], current: active)
    XCTAssertEqual(modes.count, 3)
    XCTAssertEqual(modes.first(where: { $0.signature == active.signature })?.id, 9)
    XCTAssertEqual(modes.filter(\.hiDPI).count, 2)
    XCTAssertEqual(active.dimensions, "2048 × 1152")
    XCTAssertEqual(active.pixelWidth, 4096)
  }
  func testRollbackMatchesTimingInsteadOfReusedModeID() {
    let original = mode(9)
    let unrelatedReusedID = mode(9, 1920, pixels: 3840)
    let reconnected = mode(82)
    XCTAssertEqual(DisplayRules.restoredMode(original, available: [unrelatedReusedID, reconnected])?.id, 82)
    XCTAssertNil(DisplayRules.restoredMode(original, available: [unrelatedReusedID]))
  }
  func testPercentConversionNeverInventsAnUnavailableReading() {
    XCTAssertNil(DisplayRules.rawValue(percent: .nan, maximum: 100))
    XCTAssertNil(DisplayRules.rawValue(percent: .infinity, maximum: 100))
    XCTAssertNil(DisplayRules.rawValue(percent: 10, maximum: 0))
    XCTAssertEqual(DisplayRules.rawValue(percent: -10, maximum: 255), 0)
    XCTAssertEqual(DisplayRules.rawValue(percent: 120, maximum: 255), 255)
    XCTAssertEqual(DisplayRules.rawValue(percent: 50, maximum: 255), 128)
    XCTAssertNil(DisplayVCPValue(value: 120, maximum: 100).percent)
    XCTAssertNil(DisplayHardwareState(checked: true).brightness)
  }
  func testRefreshRateLabelsRemainReadableForHighRefreshDisplays() {
    XCTAssertEqual(mode(1, refresh: 120).rateLabel, "120 Hz")
    XCTAssertEqual(mode(1, refresh: 60).rateLabel, "60 Hz")
    XCTAssertEqual(mode(1, refresh: 59.94).rateLabel, "59.94 Hz")
    XCTAssertEqual(mode(1, refresh: 0).rateLabel, "可变 / 系统")
  }
  private func reply(_ code: UInt8 = 0x10) -> [UInt8] {
    var bytes: [UInt8] = [0x6e, 0x88, 0x02, 0, code, 0, 0, 100, 0, 75, 0]
    bytes[10] = bytes.prefix(10).reduce(0x50, ^)
    return bytes
  }
  private func valid(_ bytes: [UInt8], code: UInt8 = 0x10) -> Bool {
    var value: UInt16 = 0, maximum: UInt16 = 0
    return cd_ddc_validate(bytes, Int32(bytes.count), code, &value, &maximum)
  }
  func testDDCRequiresCompleteMatchingChecksumValidResponse() {
    var current: UInt16 = 0, maximum: UInt16 = 0
    XCTAssertTrue(cd_ddc_validate(reply(), 11, 0x10, &current, &maximum))
    XCTAssertEqual(current, 75); XCTAssertEqual(maximum, 100)
    XCTAssertFalse(valid(Array(reply().prefix(10))))
    XCTAssertFalse(valid(reply(0x62)))
    var corrupted = reply(); corrupted[9] = 76
    XCTAssertFalse(valid(corrupted))
    var unsupported = reply(); unsupported[3] = 1; unsupported[10] ^= 1
    XCTAssertFalse(valid(unsupported))
    XCTAssertFalse(valid([0x6e, 0x80, 0xbe, 4, 0xb5, 0xff, 0xff, 0, 0x1e, 0xd4, 0xb6, 0x40]))
  }
  func testEDIDRejectsMalformedAndIncompleteExtensions() {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
    bytes[127] = UInt8((256 - bytes.prefix(127).reduce(0, { ($0 + Int($1)) % 256 })) % 256)
    XCTAssertTrue(DisplayAdvancedValidation.edid(Data(bytes)))
    var corrupted = bytes; corrupted[40] ^= 1
    XCTAssertFalse(DisplayAdvancedValidation.edid(Data(corrupted)))
    bytes[126] = 1; bytes[127] &-= 1
    XCTAssertFalse(DisplayAdvancedValidation.edid(Data(bytes)))
    XCTAssertFalse(DisplayAdvancedValidation.edid(Data()))
  }
  func testVirtualResolutionValidationIsBoundedAndStrict() {
    XCTAssertTrue(DisplayAdvancedValidation.resolutions("1920x1080,2560x1440,3840x2160"))
    for value in ["", "1920x1080,", "0x0", "16385x1080", "1920x1080;rm", "1920x1080x2"] {
      XCTAssertFalse(DisplayAdvancedValidation.resolutions(value), value)
    }
    XCTAssertFalse(DisplayAdvancedValidation.resolutions(Array(repeating: "1920x1080", count: 33).joined(separator: ",")))
  }
}
