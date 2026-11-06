import XCTest
@testable import VitalsReplica

final class AIUsageMessagesTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func quota(used: Double = 94.8, readAt: Date? = nil) -> [String: Any] {
    ["schemaVersion": 2, "value": ["kind": "present", "reading": ["readAtMs": (readAt ?? now).timeIntervalSince1970 * 1000,
      "usage": ["percentUsed": used, "nextResetMs": now.addingTimeInterval(3600).timeIntervalSince1970 * 1000,
                "isSandTrial": true, "hasNonZeroIncludedLimit": false]], "expiresAtMs": now.addingTimeInterval(300).timeIntervalSince1970 * 1000]]
  }
  func testGrokBotReadsRealTrialPercentageWithoutInventingTokens() throws {
    let result = try XCTUnwrap(GrokBotUsageCache.parse(quota(), now: now))
    XCTAssertEqual(result.limits.first?.windows.first?.used, 94.8)
    XCTAssertEqual(result.limits.first?.windows.first?.label, "试用额度")
    XCTAssertFalse(result.tokenCountsAvailable)
    XCTAssertFalse(result.stale(at: now))
    XCTAssertTrue(result.stale(at: now.addingTimeInterval(301)))
    XCTAssertNil(GrokBotUsageCache.parse(quota(used: -.infinity), now: now))
    XCTAssertNil(GrokBotUsageCache.parse(quota(used: -1), now: now))
    XCTAssertNil(GrokBotUsageCache.parse(quota(readAt: now.addingTimeInterval(120)), now: now))
    XCTAssertNil(GrokBotUsageCache.parse(["value": ["kind": "missing"]], now: now))
    XCTAssertNil(UsageNumeric.value(true))
    XCTAssertEqual(GrokBotUsageCache.parse(quota(used: 0), now: now)?.limits.first?.windows.first?.used, 0)
  }
  private func encoded(_ key: String) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var bits: UInt32 = 0, count = 0, output = ""
    for byte in key.utf8 {
      bits = ((bits << 8) | UInt32(byte)) & 0xffff; count += 8
      while count >= 5 { count -= 5; output.append(alphabet[Int((bits >> count) & 31)]) }
    }
    if count > 0 { output.append(alphabet[Int((bits << (5 - count)) & 31)]) }
    return output
  }
  func testGrokBotOnlyReadsActiveAccountQuotaAndNeverTranscripts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ key: String, _ json: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent(encoded(key) + ".blob"))
    }
    try write("sand.client.slice.client-meta.account-slot", ["value": "google-oauth2|active"])
    try write("sand.client.slice.account.google-oauth2%7Cactive.weekly-usage.cache", quota(used: 12))
    try write("sand.client.slice.account.other.weekly-usage.cache", quota(used: 99))
    try write("sand.client.slice.account.google-oauth2%7Cactive.transcript.replicas", quota(used: 77))
    XCTAssertEqual(GrokBotUsageCache.read(folder: root, now: now)?.limits.first?.windows.first?.used, 12)
    try write("sand.client.slice.client-meta.account-slot", ["value": "signed-out"])
    XCTAssertNil(GrokBotUsageCache.read(folder: root, now: now))
  }
  func testDiscoveryDoesNotTreatUnknownAppOrUnavailableQuotaAsZero() {
    XCTAssertEqual(AIAppDiscovery.identify("Grok Bot.app"), "Grok Bot")
    XCTAssertEqual(AIAppDiscovery.identify("Trae CN.app"), "Trae")
    XCTAssertNil(AIAppDiscovery.identify("Safari.app"))
    let result = AIAppDiscovery.merge(usage: [ProviderUsage(id: "Codex", today: 50)],
      installed: [InstalledAIApp(name: "Cursor", path: "/Applications/Cursor.app")], home: URL(fileURLWithPath: "/nonexistent"), now: now)
    let cursor = result.first { $0.id == "Cursor" }
    XCTAssertNotNil(cursor?.unavailable)
    XCTAssertTrue(cursor?.limits.isEmpty == true)
    XCTAssertFalse(cursor?.tokenCountsAvailable == true)
    XCTAssertEqual(result.first { $0.id == "Codex" }?.today, 50)
  }
  func testLatestRecoveryAndAddressChangeAppearInsteadOfGenericNormal() {
    let issue = AIMonitorEvent(id: UUID(), time: now.addingTimeInterval(-20), kind: .network, title: "网络中断", detail: "offline", target: .network, urgent: true)
    let recovery = AIMonitorEvent(id: UUID(), time: now.addingTimeInterval(-10), kind: .network, title: "网络已恢复", detail: "online", target: .network, resolved: true)
    let address = AIMonitorEvent(id: UUID(), time: now, kind: .address, title: "局域网地址已变化", detail: "192.0.2.2", target: .network)
    let result = AIMessageFeed.messages(events: [issue, recovery, address], runs: [], now: now)
    XCTAssertEqual(result.map(\.title), [address.title, recovery.title, issue.title])
    XCTAssertEqual(result[1].symbol, "checkmark.circle")
    XCTAssertTrue(AIMessageFeed.messages(events: [issue], runs: [], now: now.addingTimeInterval(86400)).isEmpty)
  }
  func testProgressFailuresAndQuotaWarningsAreVisibleWithoutCreatingNewAlertsFromOldData() throws {
    let fresh = try XCTUnwrap(GrokBotUsageCache.parse(quota(), now: now))
    let result = AIMessageFeed.messages(events: [], runs: [], providers: [fresh], error: "HTTP 401", messageTime: now, now: now)
    XCTAssertEqual(result.first?.id, "ai-error")
    XCTAssertTrue(result.contains { $0.title.contains("5.2%") && $0.usage })
    let busy = AIMessageFeed.messages(events: [], runs: [], error: "old", activity: "正在分析…", now: now)
    XCTAssertEqual(busy.first?.id, "ai-activity")
    XCTAssertFalse(busy.contains { $0.id == "ai-error" })
    XCTAssertTrue(AIMessageFeed.messages(events: [], runs: [], providers: [fresh], now: now.addingTimeInterval(301)).isEmpty)
  }
  func testActionResultUsesCompletionTimeRatherThanOriginalStart() {
    var sample = MonitorSnapshot(); sample.time = now.addingTimeInterval(-100)
    let action = AdvisorAction.simple(.copyAddress, "复制新地址", snapshot: sample)
    let run = ActionRun(id: UUID(), action: action, time: sample.time, state: .completed, detail: "已复制", updatedAt: now)
    let result = AIMessageFeed.messages(events: [], runs: [run], now: now)
    XCTAssertEqual(result.first?.time, now)
    XCTAssertTrue(result.first?.title.contains("已完成") == true)
    XCTAssertTrue(AIMessageFeed.messages(events: [], runs: [run], now: now.addingTimeInterval(1801)).isEmpty)
  }
  func testCursorPercentUnitsAndMissingCapsRemainUnknown() throws {
    let fractional = try XCTUnwrap(CursorQuota.parse(["individualUsage": ["plan": ["totalPercentUsed": 0.36]]], now: now))
    XCTAssertEqual(fractional.limits.first?.windows.first?.used, 0.36)
    let cap = CursorQuota.parse(["individualUsage": ["overall": ["used": 250, "limit": 1000]]], now: now)
    XCTAssertEqual(cap?.limits.first?.windows.first?.used, 25)
    XCTAssertNil(CursorQuota.parse(["individualUsage": ["plan": ["used": 250]]], now: now))
    XCTAssertNil(CursorQuota.parse(["individualUsage": ["plan": ["used": 0, "limit": 0]]], now: now))
    XCTAssertFalse(fractional.tokenCountsAvailable)
    XCTAssertTrue(fractional.stale(at: now.addingTimeInterval(601)))
  }
  func testCursorSessionHeaderRejectsExpiredOrMalformedCredentials() throws {
    func token(_ subject: String, expires: Date) throws -> String {
      let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expires.timeIntervalSince1970])
      let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      return "fixture.\(payload).test"
    }
    let valid = try token("auth|test-user", expires: now.addingTimeInterval(3600))
    XCTAssertTrue(CursorQuota.sessionHeader(token: valid, now: now)?.hasPrefix("WorkosCursorSessionToken=test-user%3A%3A") == true)
    XCTAssertNil(CursorQuota.sessionHeader(token: try token("auth|test-user", expires: now), now: now))
    XCTAssertNil(CursorQuota.sessionHeader(token: try token("auth|bad;user", expires: now.addingTimeInterval(3600)), now: now))
    XCTAssertNil(CursorQuota.sessionHeader(token: valid + "\r\nCookie:x", now: now))
  }
  func testDelayedCloudConclusionDoesNotCoverNewerLocalRecovery() {
    let recovery = AIMonitorEvent(id: UUID(), time: now.addingTimeInterval(-5), kind: .recovery, title: "CPU 已回落", detail: "当前 10%", target: .cpu, resolved: true)
    let record = AIAnalysisRecord(id: UUID(), createdAt: now, sampledAt: now.addingTimeInterval(-60), mode: .overview,
      provider: "Fixture", model: "test", requestedMinutes: 5, sampleCount: 10, observedSeconds: 20, appLabels: [:],
      report: AIReport(status: .attention, summary: "CPU 持续高占用", findings: [], limitations: [], nextChecks: []), usage: nil, duration: 1)
    let result = AIMessageFeed.messages(events: [recovery], runs: [], record: record, now: now)
    XCTAssertEqual(result.first?.title, "CPU 已回落")
    XCTAssertEqual(result.last?.title, "变化前的 AI 结论")
  }
}
