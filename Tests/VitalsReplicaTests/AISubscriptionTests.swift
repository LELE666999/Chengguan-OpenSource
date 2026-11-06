import XCTest
@testable import VitalsReplica

final class AISubscriptionTests: XCTestCase {
  func testSubscriptionEndComesFromCancellationMetadataNotUsageResetOrCacheExpiry() throws {
    let end = "2026-11-23T06:30:00.000Z"
    let subscription = try XCTUnwrap(CursorQuota.parseSubscription(["pendingCancellationDate": end]))
    XCTAssertEqual(subscription.kind, .expires)
    XCTAssertEqual(subscription.date, UsageLogParser.date(end))
    XCTAssertFalse(subscription.dateOnly)
    XCTAssertNil(CursorQuota.parseSubscription(["billingCycleEnd": end, "expiresAtMs": 1_800_000_000_000]))
    XCTAssertNil(CursorQuota.parseSubscription(["pendingCancellationDate": NSNull(), "subscriptionStatus": "active"]))
    XCTAssertNil(CursorQuota.parseSubscription(["pendingCancellationDate": "not a date"]))
    XCTAssertNil(CursorQuota.parseSubscription(["pendingCancellationDate": true]))
    XCTAssertNil(CursorQuota.parseSubscription(["pendingCancellationDate": 0]))
    XCTAssertEqual(CursorQuota.parseSubscription(["pendingCancellationDate": 1_800_000_000_000])?.date,
      Date(timeIntervalSince1970: 1_800_000_000))
    let quota = CursorQuota.parse(["billingCycleEnd": end, "individualUsage": ["plan": ["totalPercentUsed": 5]]], now: Date())
    XCTAssertNotNil(quota?.limits.first?.windows.first?.resets)
    XCTAssertNil(quota?.subscription)
  }

  func testManualDatePersistsPerAppAndRemovalRestoresAutomaticData() throws {
    let suite = "Chengguan.SubscriptionTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AISubscriptionStore(defaults: defaults)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let automatic = AISubscriptionDate(date: date, kind: .expires, source: "Cursor 账户")
    let cursor = ProviderUsage(id: "Cursor", subscription: automatic)
    XCTAssertEqual(store.value(for: cursor), automatic)
    store.save(provider: "Cursor", date: date.addingTimeInterval(86400), kind: .renews)
    store.save(provider: "Grok Bot", date: date.addingTimeInterval(172800), kind: .trialEnds)
    let reloaded = AISubscriptionStore(defaults: defaults)
    XCTAssertEqual(reloaded.value(for: cursor)?.kind, .renews)
    XCTAssertEqual(reloaded.value(for: cursor)?.source, "手动记录")
    XCTAssertEqual(reloaded.value(for: ProviderUsage(id: "Grok Bot"))?.kind, .trialEnds)
    XCTAssertNil(reloaded.value(for: ProviderUsage(id: "Claude")))
    reloaded.remove(provider: "Cursor")
    XCTAssertEqual(reloaded.value(for: cursor), automatic)
    XCTAssertNotNil(reloaded.dates["Grok Bot"])
    XCTAssertNil(AISubscriptionStore(defaults: defaults).dates["Cursor"])
  }

  func testCountdownUsesLocalCalendarAndDoesNotClaimAnOldDateAutomaticallyRenewed() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
    let now = try XCTUnwrap(UsageLogParser.date("2026-10-23T15:59:00Z")) // 23:59 local
    var date = AISubscriptionDate(date: now.addingTimeInterval(120), kind: .renews, source: "手动记录", dateOnly: true)
    XCTAssertEqual(date.countdown(at: now, calendar: calendar), "还有 1 天")
    date.date = now.addingTimeInterval(-60)
    XCTAssertEqual(date.countdown(at: now, calendar: calendar), "今天")
    date.dateOnly = false
    XCTAssertEqual(date.countdown(at: now, calendar: calendar), "日期已过")
    date.dateOnly = true
    date.date = now.addingTimeInterval(-86400)
    XCTAssertEqual(date.countdown(at: now, calendar: calendar), "日期已过")
    XCTAssertEqual(date.kind, .renews)
    XCTAssertEqual(date.date, now.addingTimeInterval(-86400))
    date.kind = .activeUntil
    XCTAssertEqual(date.countdown(at: now, calendar: calendar), "记录待刷新")
  }

  private func token(_ claims: [String: Any]) throws -> String {
    let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "fixture.\(body).test"
  }
  func testCodexUsesSubscriptionClaimInsteadOfTokenExpiryAndRejectsCrossAccountFallback() throws {
    let end = "2026-11-23T06:30:00Z"
    let active = try token(["exp": 1_800_000_000, "https://api.openai.com/auth":
      ["chatgpt_account_id": "active", "chatgpt_subscription_active_until": end]])
    let result = CodexSubscription.parseAuth(["tokens": ["access_token": active]])
    XCTAssertEqual(result?.kind, .activeUntil)
    XCTAssertEqual(result?.date, UsageLogParser.date(end))
    let noEnd = try token(["exp": 1_800_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "different"]])
    XCTAssertNil(CodexSubscription.parseAuth(["tokens": ["access_token": noEnd, "id_token": active]]))
    XCTAssertNil(CodexSubscription.parseAuth(["auth_mode": "apikey", "tokens": ["access_token": active]]))
    XCTAssertNil(CodexSubscription.parseAuth(["tokens": ["access_token": "malformed"]]))
    XCTAssertNil(CodexSubscription.parseAuth(["tokens": ["access_token": noEnd]]))
    XCTAssertEqual(CodexSubscription.date("1800000000000"), Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(CodexSubscription.date(1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertNil(CodexSubscription.date(true))
    XCTAssertNil(CodexSubscription.date(0))
  }
  func testCockpitIndexOnlyUsesItsExplicitCurrentAccount() throws {
    let activeEnd = "2026-11-23T06:30:00Z"
    let index: [String: Any] = ["current_account_id": "active", "accounts": [
      ["id": "other", "subscription_active_until": "2027-11-23T06:30:00Z"],
      ["id": "active", "subscription_active_until": activeEnd]]]
    XCTAssertEqual(CodexSubscription.parseIndex(index)?.date, UsageLogParser.date(activeEnd))
    XCTAssertNil(CodexSubscription.parseIndex(["accounts": index["accounts"]!]))
    XCTAssertNil(CodexSubscription.parseIndex(["current_account_id": "missing", "accounts": index["accounts"]!]))
  }
  func testExistingCodexLoginWithUnknownDateDoesNotBorrowAnotherCockpitAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".cockpit_tools"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "opaque"]])
      .write(to: root.appendingPathComponent(".codex/auth.json"))
    try JSONSerialization.data(withJSONObject: ["current_account_id": "active", "accounts":
      [["id": "active", "subscription_active_until": "2026-11-23T06:30:00Z"]]])
      .write(to: root.appendingPathComponent(".cockpit_tools/codex_accounts.json"))
    XCTAssertNil(CodexSubscription.read(home: root))
    try Data("invalid json".utf8).write(to: root.appendingPathComponent(".codex/auth.json"))
    XCTAssertNil(CodexSubscription.read(home: root))
    try FileManager.default.removeItem(at: root.appendingPathComponent(".codex/auth.json"))
    XCTAssertNotNil(CodexSubscription.read(home: root))
  }
}
