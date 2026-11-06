import XCTest
@testable import VitalsReplica

final class OverviewDiagnosticsTests: XCTestCase {
  private func frame(_ seconds: Double, apps: [(String, Double, UInt64)]) -> OverviewFrame {
    var s = MonitorSnapshot()
    s.time = Date(timeIntervalSince1970: 1000 + seconds)
    s.groups = apps.enumerated().map { index, app in
      var process = ProcessSample(pid: Int32(index + 10), ppid: 1, uid: 501, start: 1, name: app.0, path: "/Applications/\(app.0).app", memory: app.2, measured: true)
      process.cpu = app.1
      return AppGroup(id: app.0, name: app.0, bundlePath: nil, processes: [process])
    }
    return OverviewFrame(s)
  }
  func testRangeRankingIncludesAppsThatExitedAndAveragesObservedSamples() {
    let frames = [frame(0, apps: [("Editor", 80, 1000), ("Browser", 10, 2000)]), frame(2, apps: [("Browser", 40, 3000)])]
    let ranking = OverviewTimeline.ranking(frames, memory: false)
    XCTAssertEqual(ranking.map(\.name), ["Editor", "Browser"])
    XCTAssertEqual(ranking[0].cpu, 40)
    XCTAssertEqual(ranking[1].cpu, 25)
    XCTAssertEqual(OverviewTimeline.ranking(frames, memory: true).first?.name, "Browser")
  }
  func testPointSelectionDoesNotJumpOverSamplingGaps() {
    let frames = [frame(0, apps: []), frame(60, apps: [])]
    let missing = Date(timeIntervalSince1970: 1030)
    XCTAssertTrue(OverviewTimeline.frames(frames, in: missing...missing).isEmpty)
    let nearby = Date(timeIntervalSince1970: 1001)
    XCTAssertEqual(OverviewTimeline.frames(frames, in: nearby...nearby).first?.id, frames[0].id)
    XCTAssertEqual(OverviewTimeline.frames(frames, in: frames[0].id...frames[1].id).count, 2)
    XCTAssertEqual(OverviewTimeline.segments([frame(0, apps: []), frame(2, apps: []), frame(60, apps: [])]).map(\.count), [2, 1])
    XCTAssertTrue(OverviewTimeline.segments([]).isEmpty)
  }
  func testUnknownOrVirtualDisksNeverAcquireAnInventedHealthyState() throws {
    let disk = try XCTUnwrap(DeviceHealthReader.disk(["DeviceIdentifier": "disk4", "WholeDisk": true, "SMARTStatus": "Not Supported", "Internal": false]))
    XCTAssertEqual(disk.state, .unknown)
    XCTAssertNil(disk.temperature)
    XCTAssertNil(disk.wear)
    XCTAssertNil(DeviceHealthReader.disk(["DeviceIdentifier": "disk4", "WholeDisk": true, "VirtualOrPhysical": "Virtual"]))
    XCTAssertNil(DeviceHealthReader.disk(["DeviceIdentifier": "disk4s1", "WholeDisk": false]))
  }
  func testNVMeCountersUnitsAndLifetimeEstimate() throws {
    let info: [String: Any] = ["DeviceIdentifier": "disk0", "WholeDisk": true, "SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
      "TEMPERATURE": 313, "PERCENTAGE_USED": 2, "DATA_UNITS_READ_0": 100, "DATA_UNITS_READ_1": 0, "DATA_UNITS_WRITTEN_0": 200, "DATA_UNITS_WRITTEN_1": 0, "MEDIA_ERRORS_0": 0]]
    let disk = try XCTUnwrap(DeviceHealthReader.disk(info))
    XCTAssertEqual(disk.temperature ?? 0, 39.85, accuracy: 0.01)
    XCTAssertEqual(disk.readBytes, 51_200_000)
    XCTAssertEqual(disk.writtenBytes, 102_400_000)
    XCTAssertEqual(disk.wear, 2)
    XCTAssertEqual(disk.state, .good)
  }
  func testSecurityCommandFailuresAndDisabledTextAreNotHealthy() {
    XCTAssertEqual(DeviceHealthReader.securityCheck(id: "sip", title: "SIP", output: .init(text: "enabled", status: 1), enabled: ["enabled"], disabled: ["disabled"]).state, .unknown)
    XCTAssertEqual(DeviceHealthReader.securityCheck(id: "sip", title: "SIP", output: .init(text: "disabled", status: 0), enabled: ["enabled"], disabled: ["disabled"]).state, .attention)
  }
  func testLsofMultipleSocketsPerProcessAndEmptyState() {
    let text = "p123\ncBrowser\nf10\nPTCP\nn127.0.0.1:5000->1.2.3.4:443\nTST=ESTABLISHED\nf11\nPUDP\nn*:5353\np456\ncEditor\nf12\nPTCP\nn*:1234\nTST=LISTEN\n"
    let rows = NetworkDetailsReader.connections(text)
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows.filter { $0.pid == 123 }.count, 2)
    XCTAssertEqual(rows.first { $0.proto == "UDP" }?.state, "")
    XCTAssertEqual(rows.first { $0.pid == 456 }?.state, "LISTEN")
    XCTAssertTrue(NetworkDetailsReader.connections("p0\ncNoAccess\nf1\nPTCP\nn*:80").isEmpty)
  }
  func testSensorExtremaIgnoreMissingAndNonFiniteReadings() {
    var tracker = SensorExtremaTracker()
    tracker.observe([SensorSample(key: "cpu", name: "CPU", value: 40, unit: "°C")])
    tracker.observe([SensorSample(key: "cpu", name: "CPU", value: 60, unit: "°C")])
    tracker.observe([SensorSample(key: "cpu", name: "CPU", value: .nan, unit: "°C")])
    tracker.observe([])
    XCTAssertEqual(tracker.values["cpu"]?.minimum, 40)
    XCTAssertEqual(tracker.values["cpu"]?.maximum, 60)
    XCTAssertEqual(Format.percent(.nan), "—")
  }
}
