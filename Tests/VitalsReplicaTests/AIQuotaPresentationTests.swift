import XCTest
@testable import VitalsReplica

final class AIQuotaPresentationTests: XCTestCase {
  func testSevenDaySeriesCrossesWeekBoundaryAndDeduplicatesFiles() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let now = try XCTUnwrap(UsageLogParser.date("2026-10-26T12:00:00Z"))
    let today = calendar.startOfDay(for: now)
    func entry(_ daysAgo: Int, _ tokens: Int64, _ key: String) -> UsageEntry {
      UsageEntry(key: key, provider: "Codex", time: calendar.date(byAdding: .day, value: -daysAgo, to: today)!, input: tokens, output: 0, cached: 0)
    }
    var file = UsageFile()
    file.entries = [entry(0, 100, "today"), entry(1, 200, "sunday"), entry(6, 300, "tuesday"), entry(7, 900, "too-old"), entry(-1, 500, "future")]
    let provider = try XCTUnwrap(UsageLogParser.summarize([file, file], now: now, calendar: calendar).first)
    XCTAssertEqual(provider.today, 100)
    XCTAssertEqual(provider.week, 100)
    XCTAssertEqual(provider.last7Days, 600)
    XCTAssertEqual(provider.daily.count, 7)
    XCTAssertEqual(provider.daily.map(\.tokens), [300, 0, 0, 0, 0, 200, 100])
    XCTAssertEqual(provider.daily.last?.date, today)
  }
  func testResetCountdownDoesNotPretendTheQuotaHasRefreshed() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(AIQuotaPresentation.countdown(to: now.addingTimeInterval(3661), now: now), "1小时2分")
    XCTAssertEqual(AIQuotaPresentation.countdown(to: now.addingTimeInterval(90000), now: now), "1天1小时0分")
    XCTAssertEqual(AIQuotaPresentation.countdown(to: now, now: now), "等待更新")
    XCTAssertEqual(AIQuotaPresentation.countdown(to: now, now: now, trial: true), "标注时间已到")
    XCTAssertEqual(AIQuotaPresentation.provider(for: "Claude Code"), "Claude")
    XCTAssertEqual(AIQuotaPresentation.provider(for: "Codex"), "Codex")
    XCTAssertEqual(AIQuotaPresentation.provider(for: "OpenCode"), "OpenCode")
  }
  func testOverviewUsesTheSameWeeklyQuotaAsDetailAndDoesNotInventMissingQuota() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = UsageWindow(used: 80, minutes: 300, resets: now.addingTimeInterval(3600))
    let weekly = UsageWindow(used: 28, minutes: 10080, resets: now.addingTimeInterval(90000))
    var provider = ProviderUsage(id: "Codex", limits: [UsageLimit(provider: "Codex", name: "main", time: now, windows: [session, weekly])])
    XCTAssertEqual(AIQuotaOverviewData.primaryWindow(provider), weekly)
    XCTAssertEqual(AIQuotaOverviewData.remaining(AIQuotaOverviewData.primaryWindow(provider)), 72)
    XCTAssertEqual(AIQuotaOverviewData.countdown(to: weekly.resets!, now: now), "1天1小时")
    provider.limits = []
    XCTAssertNil(AIQuotaOverviewData.primaryWindow(provider))
    XCTAssertNil(AIQuotaOverviewData.remaining(nil))
    XCTAssertNil(AIQuotaOverviewData.remaining(UsageWindow(used: .nan, minutes: 10080)))
    XCTAssertNil(AIQuotaOverviewData.remaining(UsageWindow(used: .infinity, minutes: 10080)))
    XCTAssertEqual(AIQuotaOverviewData.remaining(UsageWindow(used: 110, minutes: 10080)), 0)
    XCTAssertEqual(AIQuotaOverviewData.remaining(UsageWindow(used: -5, minutes: 10080)), 100)
    XCTAssertEqual(AIQuotaOverviewData.countdown(to: now, now: now), "等待更新")
    XCTAssertEqual(AIQuotaOverviewData.countdown(to: now.addingTimeInterval(1), now: now), "1分钟")
  }
  func testSessionOverviewDoesNotCallUnknownSessionsIdleOrDoubleCountSharedProcesses() {
    let process = ProcessSample(pid: 123, ppid: 1, uid: 501, start: 1, name: "app-server", path: "/test", cpu: 8, memory: 500_000_000, measured: true)
    let other = ProcessSample(pid: 456, ppid: 1, uid: 501, start: 1, name: "claude", path: "/test", cpu: 2, memory: 100_000_000, measured: true)
    let result = AISessionOverviewData([
      AIRuntimeSession(id: "a", provider: "Codex", title: "A", process: process, phase: .working, sharedResources: true),
      AIRuntimeSession(id: "b", provider: "Codex", title: "B", process: process, phase: .unknown, sharedResources: true),
      AIRuntimeSession(id: "c", provider: "Claude", title: "C", process: other, phase: .activeProcess),
    ])
    XCTAssertEqual(result.total, 3)
    XCTAssertEqual(result.working, 1)
    XCTAssertEqual(result.active, 1)
    XCTAssertEqual(result.unknown, 1)
    XCTAssertEqual(result.ended, 0)
    XCTAssertEqual(result.memory, 600_000_000)
    XCTAssertEqual(result.cpu, 10)
  }
}
