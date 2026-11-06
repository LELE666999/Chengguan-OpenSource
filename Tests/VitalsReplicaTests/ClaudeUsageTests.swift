import Foundation
import XCTest
@testable import VitalsReplica

final class ClaudeUsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_167_200)

  func testAccountQuotaHasIndependentSessionAndWeeklyResets() throws {
    let quota = try XCTUnwrap(ClaudeQuota.parse([
      "five_hour": ["utilization": 8, "resets_at": "2026-10-28T11:10:00Z"],
      "seven_day": ["utilization": 2, "resets_at": "2026-10-31T21:00:00Z"],
      "seven_day_sonnet": NSNull(),
    ], now: now))
    let windows = try XCTUnwrap(quota.limits.first?.windows)
    XCTAssertEqual(windows.map(\.used), [8, 2])
    XCTAssertEqual(windows.map(\.minutes), [300, 10080])
    XCTAssertEqual(windows.first?.resets, UsageLogParser.date("2026-10-28T11:10:00Z"))
    XCTAssertFalse(quota.tokenCountsAvailable)
    XCTAssertNil(quota.subscription, "A reset date must never become a subscription expiration")
    XCTAssertTrue(quota.stale(at: now.addingTimeInterval(601)))
  }

  func testMissingAndMalformedQuotaDoesNotBecomeOneHundredPercentRemaining() {
    XCTAssertNil(ClaudeQuota.parse([:], now: now))
    XCTAssertNil(ClaudeQuota.parse(["five_hour": ["utilization": true]], now: now))
    XCTAssertNil(ClaudeQuota.parse(["seven_day": ["utilization": -1]], now: now))
    XCTAssertNil(ClaudeQuota.parse(["seven_day": ["utilization": 101]], now: now))
    let quota = ClaudeQuota.parse(["seven_day": ["utilization": 0]], now: now)
    XCTAssertEqual(quota?.limits.first?.windows.count, 1)
    XCTAssertEqual(quota?.limits.first?.windows.first?.used, 0)
  }

  func testDesktopCookieDecryptionChecksDomainAndRejectsUnsupportedEncryption() throws {
    // Static synthetic fixture, generated independently using OpenSSL AES-128-CBC.
    let bytes = try XCTUnwrap(Data(base64Encoded: "djEwV2fn7kSipY/3qyGOqF2yOxxeSSV4GAxSSBAoEUMeVYNfcIVCFz83zzveIVIPCldbmHUdyGt0lgwWPJbpsCa3UA=="))
    let password = Data("fixture-password".utf8)
    XCTAssertEqual(ClaudeQuota.decryptCookie(bytes, password: password, host: ".claude.ai"), "fixture-session-only")
    XCTAssertNil(ClaudeQuota.decryptCookie(bytes, password: password, host: ".example.com"))
    XCTAssertNil(ClaudeQuota.decryptCookie(bytes, password: Data("wrong".utf8), host: ".claude.ai"))
    XCTAssertNil(ClaudeQuota.decryptCookie(Data("v20bad".utf8), password: password, host: ".claude.ai"))
    XCTAssertFalse(ClaudeQuota.validSession("fixture\r\nInjected: value"))
    XCTAssertFalse(ClaudeQuota.validSession("fixture;other=value"))
  }

  func testDesktopLogRootsIncludeSharedAndNestedProjectsButExcludeOutputsAndSymlinks() throws {
    let fm = FileManager.default, home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: home) }
    let base = home.appendingPathComponent("Library/Application Support/Claude")
    let shared = base.appendingPathComponent("claude-code-sessions/account/org/.claude/projects")
    let nested = base.appendingPathComponent("local-agent-mode-sessions/account/org/session/.claude/projects")
    let excluded = base.appendingPathComponent("local-agent-mode-sessions/account/outputs/.claude/projects")
    let audit = base.appendingPathComponent("local-agent-mode-sessions/account/org/session/audit.jsonl")
    for path in [shared, nested, excluded] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
    try Data().write(to: audit)
    try fm.createSymbolicLink(at: base.appendingPathComponent("claude-code-sessions/link"), withDestinationURL: nested.deletingLastPathComponent().deletingLastPathComponent())
    let roots = Set(ClaudeUsageSources.roots(home: home).map(\.path))
    XCTAssertTrue(roots.contains(shared.path)); XCTAssertTrue(roots.contains(nested.path)); XCTAssertTrue(roots.contains(audit.path))
    XCTAssertFalse(roots.contains(excluded.path)); XCTAssertFalse(roots.contains { $0.contains("/link/") })
  }

  func testDesktopAuditAndNativeTranscriptShareUsageIdentity() throws {
    func event(snake: Bool, session: String, output: Int) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": "2026-10-28T06:00:00Z",
        snake ? "request_id" : "requestId": "req", snake ? "session_id" : "sessionId": session,
        "message": ["id": "msg", "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 20]]])
    }
    var audit = UsageFile(), native = UsageFile()
    UsageLogParser.consume(try event(snake: true, session: "one", output: 2), provider: "Claude", state: &audit)
    UsageLogParser.consume(try event(snake: false, session: "one", output: 4), provider: "Claude", state: &native)
    UsageLogParser.consume(try event(snake: true, session: "two", output: 6), provider: "Claude", state: &audit)
    let summary = UsageLogParser.summarize([audit, native], now: now)
    XCTAssertEqual(summary.first?.today, 70)
    XCTAssertEqual(summary.first?.cached, 40)
    XCTAssertEqual(AIAppDiscovery.identify("Claude Code.app"), "Claude")
  }
}
