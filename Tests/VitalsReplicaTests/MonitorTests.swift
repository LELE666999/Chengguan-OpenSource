import MonitorBridge
import XCTest

@testable import VitalsReplica

final class MonitorTests: XCTestCase {
  private func process(
    _ pid: Int32, _ ppid: Int32 = 1, _ path: String, _ uid: UInt32 = 501, _ name: String = "helper"
  ) -> ProcessSample {
    ProcessSample(
      pid: pid, ppid: ppid, uid: uid, start: 100, name: name, path: path, memory: 100,
      measured: true)
  }
  func testBluetoothInventorySeparatesConnectionsAndInvalidRSSI() throws {
    let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Test iPhone":{"device_address":"test-phone","device_rssi":"-54"}}],"device_not_connected":[{"Test Keyboard":{"device_minorType":"Keyboard","device_rssi":127}}]}]}"#
    let devices = try XCTUnwrap(BluetoothInventory.parse(Data(json.utf8)))
    XCTAssertEqual(devices.count, 2)
    XCTAssertTrue(devices[0].connected)
    XCTAssertEqual(devices[0].kind, "电话")
    XCTAssertEqual(devices[0].rssi, -54)
    XCTAssertFalse(devices[1].connected)
    XCTAssertEqual(devices[1].symbol, "keyboard")
    XCTAssertNil(devices[1].rssi)
    XCTAssertNil(BluetoothInventory.parse(Data("{}".utf8)))
    XCTAssertEqual(BluetoothInventory.parse(Data(#"{"SPBluetoothDataType":[]}"#.utf8))?.count, 0)
  }
  func testCounterRatesAndReset() {
    XCTAssertEqual(CounterMath.rate(current: 200, previous: 100, elapsed: 2), 50)
    XCTAssertEqual(CounterMath.rate(current: 200, previous: nil, elapsed: 2), 0)
    XCTAssertEqual(CounterMath.rate(current: 10, previous: 200, elapsed: 2), 0)
    XCTAssertEqual(CounterMath.rate(current: 200, previous: 100, elapsed: 0), 0)
  }
  func testNestedHelpersAndChildrenBelongToTheirApp() {
    let p = [
      process(10, 1, "/Applications/Browser.app/Contents/MacOS/Browser"),
      process(
        11, 10, "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
      process(12, 11, "/usr/local/bin/node"),
    ]
    let groups = AppGrouping.groups(p)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.id, "/Applications/Browser.app")
    XCTAssertEqual(groups.first?.processes.count, 3)
    XCTAssertEqual(groups.first?.memory, 300)
  }
  func testSystemProcessesAndStandaloneCommandsAreDistinct() {
    let p = [
      process(2, 1, "/usr/libexec/test", 0), process(3, 1, "/System/Library/foo", 501),
      process(4, 1, "/opt/homebrew/bin/node", 501, "node"),
    ]
    let groups = AppGrouping.groups(p)
    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups.first { $0.id == "system.macos" }?.processes.count, 2)
  }
  func testSystemBundleChildrenStayInMacOSGroup() {
    let owner = "/System/Library/CoreServices/Background.app"
    let p = [process(10, 1, owner + "/Contents/MacOS/Background"), process(11, 10, "/opt/helper")]
    let groups = AppGrouping.groups(p, systemBundles: [owner])
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.id, "system.macos")
    XCTAssertEqual(groups.first?.processes.count, 2)
  }
  func testUnavailableSeriesAndMemoryUnits() {
    let s = MonitorSnapshot()
    XCTAssertNil(s.point.value(.gpu))
    XCTAssertNil(s.point.value(.battery))
    XCTAssertEqual(Format.memory(UInt64(1024 * 1024 * 1024)), "1.00 GB")
    XCTAssertEqual(Format.bytes(UInt64(1_000_000_000)), "1.00 GB")
  }
  func testParentCycleAndUserBoundaryAreHandled() {
    let p = [
      process(10, 11, "/opt/a"), process(11, 10, "/opt/b"), process(12, 20, "/opt/c", 502),
      process(20, 1, "/Applications/Owner.app/Contents/MacOS/Owner"),
    ]
    let groups = AppGrouping.groups(p)
    XCTAssertEqual(groups.reduce(0) { $0 + $1.processes.count }, 4)
    XCTAssertEqual(groups.first { $0.id == "/Applications/Owner.app" }?.processes.count, 1)
  }
  func testHistoryRoundTripAndUnavailableMetricsStayNull() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(url: folder.appendingPathComponent("test.sqlite"))
    var s = MonitorSnapshot()
    s.time = Date().addingTimeInterval(-90)
    s.cpu = 12.5
    s.totalMemory = 1000
    s.appMemory = 400
    store.record(s, force: true)
    s.time = s.time.addingTimeInterval(31)
    s.cpu = 25
    store.record(s, force: true)
    let points = store.points(since: Date().addingTimeInterval(-120))
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points[0].cpu, 12.5, accuracy: 0.01)
    XCTAssertEqual(points[1].memory, 400)
    XCTAssertNil(points[0].gpu)
    XCTAssertNil(points[0].battery)
    XCTAssertTrue(HistoryStore.csv(points).contains("cpu_percent"))
    XCTAssertEqual(HistoryStore.csvField("App, \"A\""), "\"App, \"\"A\"\"\"")
  }
  func testHistoryTotalsAndAppTimeExcludeSamplingGaps() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(url: folder.appendingPathComponent("totals.sqlite"))
    let start = Date().addingTimeInterval(-600)
    var snapshot = MonitorSnapshot()
    snapshot.download = 100
    snapshot.upload = 20
    snapshot.write = 50
    snapshot.cpu = 25
    var app = process(10, 1, "/Applications/Example.app/Contents/MacOS/Example")
    app.cpu = 50
    snapshot.groups = [
      AppGroup(id: "example", name: "Example, A", bundlePath: nil, processes: [app])
    ]
    for seconds in [0.0, 30, 300, 330] {
      snapshot.time = start.addingTimeInterval(seconds)
      store.record(snapshot, force: true)
    }
    let totals = store.totals(since: start.addingTimeInterval(-1))
    XCTAssertEqual(totals.downloaded, 6000, accuracy: 0.1)
    XCTAssertEqual(totals.uploaded, 1200, accuracy: 0.1)
    XCTAssertEqual(totals.written, 3000, accuracy: 0.1)
    XCTAssertEqual(totals.cpu, 25, accuracy: 0.01)
    let apps = store.appSummary(since: start.addingTimeInterval(-1))
    XCTAssertEqual(apps.first?.cpuSeconds, 30)
    let files = store.exportFiles(since: start.addingTimeInterval(-1))
    XCTAssertEqual(files.map(\.0), ["Apps-daily.csv", "Mac-hourly.csv", "Readings-5min.csv"])
    XCTAssertTrue(files[0].1.contains("\"Example, A\""))
    XCTAssertTrue(files[1].1.contains("memory_bytes"))
  }
  func testNativeSamplingAndSignalGuards() {
    var sample = VRSystem()
    XCTAssertTrue(vr_read_system(&sample))
    XCTAssertGreaterThan(sample.core_count, 0)
    XCTAssertGreaterThan(sample.memory_total, 0)
    XCTAssertGreaterThan(vr_process_start(getpid()), 0)
    XCTAssertNotEqual(vr_process_signal(getpid(), vr_process_start(getpid()), 0), 0)
    XCTAssertNotEqual(vr_process_signal(1, 1, 0), 0)
    XCTAssertNotEqual(vr_process_signal(getpid() + 1, UInt64.max, 0), 0)
  }
  func testLocalAddressMatchesIpconfig() throws {
    let network = LocalNetworkSnapshot.read()
    XCTAssertFalse(network.addresses.contains { $0.interface == "lo0" || $0.address.hasPrefix("127.") })
    let command = Process(), pipe = Pipe()
    command.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    command.arguments = ["getifaddr", "en0"]
    command.standardOutput = pipe; command.standardError = FileHandle.nullDevice
    try command.run(); command.waitUntilExit()
    let system = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if command.terminationStatus == 0, !system.isEmpty {
      XCTAssertEqual(network.primary?.interface, "en0")
      XCTAssertEqual(network.primary?.address, system)
    } else {
      XCTAssertNil(network.addresses.first { $0.interface == "en0" })
    }
    XCTAssertNil(LocalNetworkSnapshot().primary)
  }
  func testProcessReadFailuresHaveRealSystemReasons() {
    var processes = [VRProcess](repeating: VRProcess(), count: Int(vr_process_capacity()))
    let count = Int(vr_read_processes(&processes, Int32(processes.count)))
    XCTAssertTrue(processes.prefix(count).contains { $0.pid == getpid() && $0.measured && $0.read_error == 0 })
    if let launchd = processes.prefix(count).first(where: { $0.pid == 1 }) {
      XCTAssertEqual(launchd.uid, 0)
      XCTAssertGreaterThan(launchd.start_sec, 0)
      let name = withUnsafePointer(to: launchd.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
      XCTAssertEqual(name, "launchd")
    }
    for process in processes.prefix(count) where !process.measured {
      XCTAssertNotEqual(process.read_error, 0)
      XCTAssertNotEqual(process.read_error, ESRCH, "Exited processes must not appear as permission failures")
    }
  }
  func testProcessCPUTimeMatchesGetrusageUnits() {
    func cpuSeconds() -> Double {
      var r = rusage()
      getrusage(RUSAGE_SELF, &r)
      return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(
        r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    func measuredSeconds() -> Double {
      var p = [VRProcess](repeating: VRProcess(), count: Int(vr_process_capacity()))
      let n = Int(vr_read_processes(&p, Int32(p.count)))
      return p.prefix(n).first { $0.pid == getpid() }.map { Double($0.cpu_ns) / 1e9 } ?? 0
    }
    let nativeBefore = measuredSeconds()
    let systemBefore = cpuSeconds()
    var result = 0.0
    for i in 1...2_000_000 { result += sqrt(Double(i)) }
    let systemDelta = cpuSeconds() - systemBefore
    let nativeDelta = measuredSeconds() - nativeBefore
    XCTAssertGreaterThan(result, 0)
    XCTAssertGreaterThan(systemDelta, 0.005)
    XCTAssertEqual(nativeDelta, systemDelta, accuracy: max(0.015, systemDelta * 0.2))
  }
}
