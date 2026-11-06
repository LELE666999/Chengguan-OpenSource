import XCTest
@testable import VitalsReplica

final class ServerHistoryTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return value
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func snapshot(_ time: Date, counter: Double?, reset: Double? = 1_900_000_000) throws -> ServerSnapshot {
    var fields: [String: Any] = ["error": 0, "ve_status": "Running", "plan_ram": 1_073_741_824, "mem_available_kb": 524288, "load_average": "0.02 0.01 0.01"]
    if let counter { fields["data_counter"] = counter }
    if let reset { fields["data_next_reset"] = reset }
    return try .parse(JSONSerialization.data(withJSONObject: fields), now: time)
  }
  func testInitialCounterIsOnlyBaselineAndUnknownDaysStayUnknown() throws {
    let start = date("2026-11-06T05:00:00Z")
    var history = ServerHistory()
    history.record(try snapshot(start, counter: 8_000_000), calendar: calendar)
    XCTAssertTrue(history.days.isEmpty)
    XCTAssertTrue(history.week(ending: start, calendar: calendar).allSatisfy { $0.bytes == nil })
    XCTAssertEqual(history.samples.first?.memory, 536_870_912)
    history.record(try snapshot(start.addingTimeInterval(60), counter: 8_001_000), calendar: calendar)
    XCTAssertEqual(history.days.first?.bytes, 1000)
    history.record(try snapshot(start.addingTimeInterval(120), counter: 8_001_000), calendar: calendar)
    XCTAssertEqual(history.days.first?.intervals, 2)
    XCTAssertEqual(history.days.first?.bytes, 1000)
  }
  func testBillingResetAndCounterRollbackNeverProduceSpikes() throws {
    let start = date("2026-11-06T05:00:00Z")
    var history = ServerHistory()
    for (seconds, counter, reset) in [(0.0, 9000.0, 1_900_000_000.0), (60, 20, 1_900_000_000), (120, 30, 1_900_000_000), (180, 2000, 1_910_000_000), (240, 2030, 1_910_000_000)] {
      history.record(try snapshot(start.addingTimeInterval(seconds), counter: counter, reset: reset), calendar: calendar)
    }
    XCTAssertEqual(history.days.first?.bytes, 40)
    XCTAssertEqual(history.days.first?.intervals, 2)
  }
  func testMidnightDeltaIsNotInventedAndNextIntervalStartsNewDay() throws {
    let start = date("2026-11-06T15:59:00Z") // 23:59 in Shanghai.
    var history = ServerHistory()
    history.record(try snapshot(start, counter: 100), calendar: calendar)
    history.record(try snapshot(start.addingTimeInterval(120), counter: 10000), calendar: calendar)
    XCTAssertTrue(history.days.isEmpty)
    history.record(try snapshot(start.addingTimeInterval(180), counter: 10050), calendar: calendar)
    XCTAssertEqual(history.days.first?.date, calendar.startOfDay(for: start.addingTimeInterval(180)))
    XCTAssertEqual(history.days.first?.bytes, 50)
  }
  func testMissingCounterAndDuplicateOrOutOfOrderReadingsDoNotCorruptBaseline() throws {
    let start = date("2026-11-06T05:00:00Z")
    var history = ServerHistory()
    history.record(try snapshot(start, counter: 100), calendar: calendar)
    history.record(try snapshot(start, counter: 1000), calendar: calendar)
    history.record(try snapshot(start.addingTimeInterval(-60), counter: 5000), calendar: calendar)
    history.record(try snapshot(start.addingTimeInterval(60), counter: nil), calendar: calendar)
    history.record(try snapshot(start.addingTimeInterval(120), counter: 140), calendar: calendar)
    XCTAssertEqual(history.samples.count, 3)
    XCTAssertEqual(history.days.first?.bytes, 40)
  }
  func testHistorySurvivesReloadAndIsIsolatedByServer() throws {
    let suite = "ServerHistoryTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = date("2026-11-06T05:00:00Z"), end = start.addingTimeInterval(60)
    var history = ServerHistory()
    history.record(try snapshot(start, counter: 100), calendar: calendar)
    history.record(try snapshot(end, counter: 400), calendar: calendar)
    history.save(veid: "123", defaults: defaults)
    XCTAssertEqual(ServerHistory.load(veid: "123", defaults: defaults, now: end, calendar: calendar), history)
    XCTAssertEqual(ServerHistory.load(veid: "456", defaults: defaults, now: end, calendar: calendar), ServerHistory())
    let encoded = String(decoding: defaults.data(forKey: ServerHistory.key("123"))!, as: UTF8.self)
    XCTAssertFalse(encoded.contains("api_key")); XCTAssertFalse(encoded.contains("hostname"))
  }
  func testRetentionBoundsAndFutureClockRecovery() throws {
    let start = date("2026-11-06T05:00:00Z")
    var history = ServerHistory()
    for minute in 0..<1500 { history.record(try snapshot(start.addingTimeInterval(Double(minute * 60)), counter: Double(minute * 100)), calendar: calendar) }
    XCTAssertLessThanOrEqual(history.samples.count, 1440)
    XCTAssertEqual(history.samples.last?.time, start.addingTimeInterval(1499 * 60))
    history.prune(now: start, calendar: calendar)
    XCTAssertNil(history.latest); XCTAssertNil(history.baseline)
    history.record(try snapshot(start.addingTimeInterval(60), counter: 1000), calendar: calendar)
    XCTAssertEqual(history.samples.last?.time, start.addingTimeInterval(60))
  }
}
