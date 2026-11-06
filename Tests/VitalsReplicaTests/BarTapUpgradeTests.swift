import AppKit
import Foundation
import SQLite3
import XCTest
@testable import VitalsReplica

final class ExpandedUsageTests: XCTestCase {
  private func consume(_ object: [String: Any], provider: String, state: inout UsageFile) throws {
    UsageLogParser.consume(try JSONSerialization.data(withJSONObject: object), provider: provider, state: &state)
  }
  func testCodexModelContextAppliesOnlyToFollowingUsage() throws {
    var state = UsageFile()
    try consume(["type": "turn_context", "payload": ["model": "model-a"]], provider: "Codex", state: &state)
    try consume(["type": "event_msg", "timestamp": "2026-11-05T02:00:00Z", "payload": ["type": "token_count",
      "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20]]]], provider: "Codex", state: &state)
    XCTAssertEqual(state.entries.first?.model, "model-a")
  }
  func testGeminiLegacySnapshotAndNewJSONLHaveSameUsage() throws {
    let message: [String: Any] = ["type": "gemini", "id": "m1", "timestamp": "2026-11-05T02:00:00Z", "model": "gemini-test",
      "tokens": ["input": 100, "cached": 50, "output": 20, "thoughts": 10, "total": 130]]
    var legacy = UsageFile(), current = UsageFile()
    try consume(["messages": [message]], provider: "Gemini CLI", state: &legacy)
    try consume(message, provider: "Gemini CLI", state: &current)
    try consume(message, provider: "Gemini CLI", state: &current)
    XCTAssertEqual(legacy.entries.first?.total, 130)
    XCTAssertEqual(current.entries.count, 1)
    XCTAssertEqual(current.entries.first?.total, 130)
    XCTAssertEqual(current.entries.first?.cached, 50)
  }
  func testQwenUsesResponseMetadataNotContextWindow() throws {
    var state = UsageFile()
    try consume(["type": "assistant", "id": "m", "timestamp": "2026-11-05T02:00:00Z", "contextWindowSize": 1_000_000,
      "model": "qwen-test", "usageMetadata": ["promptTokenCount": 120, "candidatesTokenCount": 30, "thoughtsTokenCount": 5, "cachedContentTokenCount": 20]],
      provider: "Qwen Code", state: &state)
    XCTAssertEqual(state.entries.first?.total, 155)
    XCTAssertEqual(state.entries.first?.model, "qwen-test")
  }
  func testKimiStatusUpdatesReplaceStepTotals() throws {
    var state = UsageFile()
    try consume(["timestamp": 1793844000, "message": ["type": "StepBegin", "payload": ["n": 1]]], provider: "Kimi Code", state: &state)
    for i in [1, 8] {
      try consume(["timestamp": 1793844000 + i, "message": ["type": "StatusUpdate", "payload": ["context_tokens": 90_000,
        "token_usage": ["input_other": 100, "input_cache_read": 40, "input_cache_creation": 10, "output": i]]]], provider: "Kimi Code", state: &state)
    }
    XCTAssertEqual(state.entries.count, 1)
    XCTAssertEqual(state.entries.first?.total, 158)
  }
  func testMonthIncludesEarlierWeeksAndDoesNotDoubleCountCacheOrReasoning() throws {
    let now = try XCTUnwrap(UsageLogParser.date("2026-11-20T12:00:00Z"))
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let earlier = UsageEntry(key: "a", provider: "Tool", time: now.addingTimeInterval(-15 * 86400), input: 100, output: 20, cached: 50, model: "m", reasoning: 10)
    let today = UsageEntry(key: "b", provider: "Tool", time: now, input: 200, output: 30, cached: 100, model: "m")
    let file = UsageFile(entries: [earlier, today])
    let result = try XCTUnwrap(UsageLogParser.summarize([file, file], now: now, calendar: calendar).first)
    XCTAssertEqual(result.today, 230); XCTAssertEqual(result.last7Days, 230)
    XCTAssertEqual(result.month, 350); XCTAssertEqual(result.models.first?.total, 350)
    XCTAssertEqual(result.monthlyDaily.count, 20)
  }
  func testOldUsageCacheStillDecodesWithOptionalModelFields() throws {
    let data = Data(#"{"key":"a","provider":"Claude","time":0,"input":1,"output":2,"cached":0}"#.utf8)
    let entry = try JSONDecoder().decode(UsageEntry.self, from: data)
    XCTAssertNil(entry.model); XCTAssertEqual(entry.total, 3)
  }
  func testReadonlyOpenCodeDatabaseCountsAssistantOnlyAndUsesItsSeparateReasoningCounter() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("opencode.db")
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = #"CREATE TABLE message(id TEXT, time_created INTEGER, data TEXT); INSERT INTO message VALUES('a',1793844000000,'{"role":"assistant","modelID":"model-x","tokens":{"input":100,"output":30,"reasoning":10,"cache":{"read":20,"write":10}}}'); INSERT INTO message VALUES('b',1793844000000,'{"role":"user","tokens":{"input":9000}}');"#
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    let usage = try XCTUnwrap(UsageDatabaseReader.read(url, provider: "OpenCode", since: .distantPast))
    XCTAssertEqual(usage.entries.count, 1); XCTAssertEqual(usage.entries.first?.total, 170)
    XCTAssertEqual(usage.entries.first?.model, "model-x")
  }
  func testSourceFiltersExcludeCredentialsAndArbitraryJSON() {
    let source = UsageSource(root: URL(fileURLWithPath: "/tmp/.gemini/tmp"), provider: "Gemini CLI")
    XCTAssertFalse(source.accepts(URL(fileURLWithPath: "/tmp/.gemini/oauth_creds.json")))
    XCTAssertTrue(source.accepts(URL(fileURLWithPath: "/tmp/.gemini/tmp/p/chats/session-a.jsonl")))
  }
}

final class PowerAndBluetoothTests: XCTestCase {
  func testPowerUnitsAndInvalidIntervals() {
    XCTAssertEqual(PowerMeasurement.watts(energy: 4_000, unit: "mJ", seconds: 2), 2)
    XCTAssertEqual(PowerMeasurement.watts(energy: 4e9, unit: "nJ", seconds: 2), 2)
    XCTAssertNil(PowerMeasurement.watts(energy: 10, unit: "unknown", seconds: 2))
    XCTAssertNil(PowerMeasurement.watts(energy: 10, unit: "J", seconds: 600))
    XCTAssertNil(PowerMeasurement.watts(energy: -1, unit: "J", seconds: 2))
    XCTAssertNil(PowerMeasurement.component("CPU Cluster Energy"))
  }
  func testSignedBatteryAmperageAndChargingArePreserved() {
    XCTAssertEqual(PowerMeasurement.batteryWatts(voltage: 12_000, current: NSNumber(value: -1000)), -12)
    XCTAssertEqual(PowerMeasurement.batteryWatts(voltage: 12_000, current: NSNumber(value: 64536)), -12)
    XCTAssertEqual(PowerMeasurement.batteryWatts(voltage: 12_000, current: NSNumber(value: 1000)), 12)
    XCTAssertNil(PowerMeasurement.batteryWatts(voltage: nil, current: 1000))
    XCTAssertNil(PowerMeasurement.valid(.infinity))
  }
  func testSplitEarphoneBatteryAndZeroAreVisibleButInvalidValuesAreNot() throws {
    let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"AirPods":{"device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"0%","device_batteryLevelRight":"80%","device_batteryLevelCase":"101%"}}]}]}"#.utf8)
    let device = try XCTUnwrap(BluetoothInventory.parse(data)?.first)
    XCTAssertEqual(device.batteries.map(\.percent), [0, 80])
    XCTAssertNil(BluetoothInventory.percentage(true))
    XCTAssertNil(BluetoothInventory.percentage("unavailable"))
  }
  func testHIDBatteryMergesByAddressWithoutReplacingSystemProfiler() {
    let device = BluetoothInfo(id: "AA-BB-CC-DD-EE-FF", name: "Mouse", connected: true, rssi: nil)
    let records: [[String: Any]] = [["DeviceAddress": "aa:bb:cc:dd:ee:ff", "BatteryPercent": 45]]
    XCTAssertEqual(BluetoothInventory.mergingHID([device], records: records).first?.batteries.first?.percent, 45)
    var existing = device; existing.batteries = [.init(id: "main", title: "电量", percent: 70)]
    XCTAssertEqual(BluetoothInventory.mergingHID([existing], records: records).first?.batteries.first?.percent, 70)
  }
}

final class MenuHoverStateTests: XCTestCase {
  @MainActor func testMenuRenderKeyIgnoresHiddenMetricsButTracksVisibleTextAndStyle() {
    let defaults = UserDefaults(suiteName: "RenderKeyTests")!
    defer { defaults.removePersistentDomain(forName: "RenderKeyTests") }
    defaults.set(false, forKey: "showMenuMemory")
    var snapshot = MonitorSnapshot(); snapshot.cpu = 25
    func presentation() -> MenuBarPresentation {
      MenuBarPresentation.make(snapshot: snapshot, providers: [], nas: NASSnapshot(), nasCurrent: false, activities: [], defaults: defaults)
    }
    let first = presentation().renderKey
    snapshot.gpu = 80
    XCTAssertEqual(presentation().renderKey, first)
    snapshot.cpu = 26
    XCTAssertNotEqual(presentation().renderKey, first)
    let second = presentation().renderKey
    defaults.set(true, forKey: "menuBold")
    XCTAssertNotEqual(presentation().renderKey, second)
  }
  func testClickPinsPreviewAndSecondClickClosesWithoutImmediateReopen() {
    var state = MenuHoverState()
    XCTAssertTrue(state.preview()); XCTAssertTrue(state.pin())
    state.clicked(); XCTAssertEqual(state.mode, .closed)
    XCTAssertFalse(state.preview())
    state.leftButton(); XCTAssertTrue(state.preview())
  }
  func testOutsideCloseSuppressesHoverUntilLeavingButton() {
    var state = MenuHoverState(); state.clicked(); state.closed()
    XCTAssertFalse(state.preview()); state.leftButton(); XCTAssertTrue(state.preview())
  }
}

final class UsageFileEventTests: XCTestCase {
  func testUnchangedRefreshSkipsDirectoryDiscoveryAndPeriodicScanRepairsEvents() {
    let events = UsageFileEvents(), now = Date()
    XCTAssertTrue(events.take(now: now, force: false).discover)
    XCTAssertFalse(events.take(now: now.addingTimeInterval(30), force: false).discover)
    XCTAssertTrue(events.take(now: now.addingTimeInterval(601), force: false).discover)
    XCTAssertTrue(events.take(now: now.addingTimeInterval(602), force: true).discover)
  }
  func testFileWriteArrivesAsAnEvent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    let queue = DispatchQueue(label: "chengguan.tests.events")
    let received = expectation(description: "changed file")
    let events = UsageFileEvents()
    queue.sync {
      events.start(roots: [directory], queue: queue)
      _ = events.take(now: Date(), force: false)
      events.onChange = {
        if events.take(now: Date(), force: false).paths.contains(file.path) {
          events.onChange = nil; received.fulfill()
        }
      }
    }
    try Data("{}\n".utf8).write(to: file)
    wait(for: [received], timeout: 8)
    queue.sync { events.stop() }
  }
}
