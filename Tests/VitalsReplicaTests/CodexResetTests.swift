import XCTest
import SceneKit
@testable import VitalsReplica

final class CodexResetTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1792972800)
  func event(_ id: String = "123", kind: CodexResetEvent.Kind = .completed, age: Double = 60) -> CodexResetEvent {
    .init(id: id, kind: kind, time: now.addingTimeInterval(-age), scheduled: nil, expires: nil,
      text: "Codex reset will land in two hours. All paid users.", source: URL(string: "https://x.com/thsottiaux/status/" + id)!)
  }
  func row(_ id: String = "123", type: String = "regular", source: String = "x_post") -> [String: Any] {
    ["id": id, "reset_type": type, "announced_at": now.addingTimeInterval(-60).ISO8601Format(),
      "text": "Codex reset will land in two hours.", "source": ["type": source, "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/123"]]
  }
  func status(_ latest: Any = NSNull(), next: Any = NSNull(), watch: Any = NSNull(), generated: Date? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["data": ["latest_reset": latest, "scheduled_reset": next, "active_watch": watch],
      "meta": ["api_version": "v1", "generated_at": (generated ?? now).ISO8601Format()]])
  }
  func testScheduledDeadlineNeverBecomesCompletionAndBankedIsSeparate() throws {
    var next = row(type: "banked"); next["status"] = "scheduled"; next["scheduled_for"] = now.addingTimeInterval(-1).ISO8601Format()
    let snapshot = try CodexResetParser.parse(status: status(row(), next: next))
    XCTAssertEqual(snapshot.visible(at: now).first?.kind, .bankedScheduled)
    XCTAssertEqual(snapshot.events.last?.scheduled, now.addingTimeInterval(-1))
    XCTAssertTrue(snapshot.events.last!.explanation.contains("尚不代表当前账号已收到"))
    XCTAssertEqual(CodexResetParser.event(row(type: "banked"))?.kind, .banked)
  }
  func testSourceValidationRejectsImpersonationScriptsForeignAccountsAndUnexpectedURLs() {
    for url in ["http://x.com/thsottiaux/status/123", "https://evil.test/thsottiaux/status/123", "https://x.com/OpenAI/status/123",
      "https://x.com/thsottiaux/status/123?next=evil", "https://x.com/thsottiaux/status/123#x", "https://user@x.com/thsottiaux/status/123",
      "https://x.com:444/thsottiaux/status/123", "javascript:alert(1)"] {
      XCTAssertNil(CodexResetParser.source(["url": url, "type": "x_post", "author": "thsottiaux"]))
    }
    XCTAssertNil(CodexResetParser.source(["url": "https://x.com/thsottiaux/status/123", "type": "x_post", "author": "imposter"]))
    XCTAssertNil(CodexResetParser.event(row("456")))
  }
  func testCommunityObservationCannotBecomeOfficialCardOrScheduledReset() {
    XCTAssertEqual(CodexResetParser.event(row(source: "observed"))?.kind, .observed)
    XCTAssertNil(CodexResetParser.event(row(type: "banked", source: "observed")))
    XCTAssertNil(CodexResetParser.event(row(source: "observed"), scheduled: true))
  }
  func testStaleFutureAndExpiredWatchAreNotActionable() throws {
    XCTAssertFalse(CodexResetSnapshot(generatedAt: now.addingTimeInterval(-7200), events: []).fresh(at: now))
    XCTAssertFalse(CodexResetSnapshot(generatedAt: now.addingTimeInterval(600), events: []).fresh(at: now))
    let watch: [String: Any] = ["observed_at": now.addingTimeInterval(-3600).ISO8601Format(), "expires_at": now.addingTimeInterval(-60).ISO8601Format(),
      "text": "Maybe a reset", "source": ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/123"]]
    let snapshot = try CodexResetParser.parse(status: status(watch: watch))
    XCTAssertTrue(snapshot.visible(at: now).isEmpty)
    XCTAssertThrowsError(try CodexResetParser.parse(status: Data("{}".utf8)))
  }
  func testHistoryDeduplicatesAndCannotReplacePendingStatusWithACompletedRow() throws {
    var next = row(); next["status"] = "scheduled"
    let history = try JSONSerialization.data(withJSONObject: ["data": [row(), row("observed-123", source: "observed")], "meta": ["api_version": "v1", "generated_at": now.ISO8601Format()]])
    let snapshot = try CodexResetParser.parse(status: status(next: next), history: history)
    XCTAssertEqual(snapshot.events.filter { $0.id == "123" }.count, 1)
    XCTAssertEqual(snapshot.events.first?.kind, .scheduled)
  }
  @MainActor func testAnnouncementTransitionsNotifyOnceAndOptOutRemovesMessages() {
    let prefs = UserDefaults(suiteName: "chengguan-reset-test-" + UUID().uuidString)!
    prefs.set(false, forKey: "codexResetNotifications")
    let store = CodexResetStore(prefs: prefs)
    let planned = event(kind: .scheduled)
    store.ingest(.init(generatedAt: now, events: [planned]), now: now)
    XCTAssertEqual(store.changes.count, 1)
    store.ingest(.init(generatedAt: now, events: [planned]), now: now)
    XCTAssertEqual(store.changes.count, 1)
    store.ingest(.init(generatedAt: now, events: [event()]), now: now)
    XCTAssertEqual(store.changes.count, 2)
    let reopened = CodexResetStore(prefs: prefs)
    reopened.ingest(.init(generatedAt: now, events: [event()]), now: now)
    XCTAssertTrue(reopened.changes.isEmpty)
    prefs.set(false, forKey: "codexResetEnabled"); store.disabled()
    store.ingest(.init(generatedAt: now, events: [event("789")]), now: now)
    XCTAssertTrue(store.changes.isEmpty)
  }
  @MainActor func testFirstLoadDoesNotAnnounceOldHistoryOrStaleSourceAsNew() {
    let prefs = UserDefaults(suiteName: "chengguan-reset-test-" + UUID().uuidString)!
    prefs.set(false, forKey: "codexResetNotifications")
    let store = CodexResetStore(prefs: prefs)
    store.ingest(.init(generatedAt: now.addingTimeInterval(-7200), events: [event()]), now: now)
    XCTAssertNil(store.snapshot)
    store.ingest(.init(generatedAt: now, events: [event(age: 86400), event("456", kind: .observed)]), now: now)
    XCTAssertTrue(store.changes.isEmpty)
    XCTAssertEqual(store.snapshot?.events.count, 2)
  }
  func baseline(used: Double, time: Date, reset: Date, account: String = "account-a") -> CodexQuotaBaseline {
    let provider = ProviderUsage(id: "Codex", limits: [.init(provider: "Codex", name: "codex", time: time,
      windows: [.init(used: used, minutes: 300, resets: reset)])], updated: time)
    return .init(account: account, provider: provider)
  }
  func testQuotaRecoveryRequiresSameAccountFreshDataAndUnexpiredSameWindow() {
    let future = now.addingTimeInterval(3600), before = now.addingTimeInterval(-30)
    let previous = baseline(used: 90, time: before, reset: future)
    let current = baseline(used: 0, time: now, reset: future)
    XCTAssertNotNil(CodexQuotaBaseline.recovery(previous: previous, current: current, now: now))
    XCTAssertNil(CodexQuotaBaseline.recovery(previous: previous, current: baseline(used: 0, time: now, reset: future, account: "other"), now: now))
    XCTAssertNil(CodexQuotaBaseline.recovery(previous: previous, current: baseline(used: 0, time: now, reset: future.addingTimeInterval(60)), now: now))
    XCTAssertNil(CodexQuotaBaseline.recovery(previous: previous, current: baseline(used: 89, time: now, reset: future), now: now))
    XCTAssertNil(CodexQuotaBaseline.recovery(previous: previous, current: current, now: now.addingTimeInterval(600)))
    let past = now.addingTimeInterval(-1)
    XCTAssertNil(CodexQuotaBaseline.recovery(previous: baseline(used: 90, time: before, reset: past), current: baseline(used: 0, time: now, reset: past), now: now))
  }
  func testAIRequestSendsOnlyPublicAnnouncementAndCapsOutput() throws {
    let request = try CodexResetService.request(event: event(), config: .init(), key: "synthetic")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    XCTAssertEqual(body["max_completion_tokens"] as? Int, 512)
    let text = String(decoding: request.httpBody!, as: UTF8.self)
    for privateField in ["monitoring_data", "subscription", "account", "/Users/", "api_key"] { XCTAssertFalse(text.contains(privateField)) }
    XCTAssertTrue(text.contains("Codex reset will land"))
  }
  func testAIOutputCannotChangeSourceStageInventEvidenceOrClaimPersonalReceipt() throws {
    let event = event()
    func data(kind: String = "completed", summary: String = "公开预告了额度重置", evidence: String = "Codex reset") throws -> Data {
      try JSONSerialization.data(withJSONObject: ["kind": kind, "summary": summary, "evidence": evidence])
    }
    XCTAssertNoThrow(try CodexResetAnalysis.decode(data(), event: event))
    XCTAssertThrowsError(try CodexResetAnalysis.decode(data(kind: "banked"), event: event))
    XCTAssertThrowsError(try CodexResetAnalysis.decode(data(summary: "你的重置卡已到账"), event: event))
    XCTAssertThrowsError(try CodexResetAnalysis.decode(data(evidence: "not in the post"), event: event))
  }
  @MainActor func testLivePublicAPIAndScannerRenderWhenRequested() async throws {
    if ProcessInfo.processInfo.environment["CHENGGUAN_RESET_LIVE"] == "1" {
      let value = try await CodexResetService.fetch()
      XCTAssertTrue(value.fresh(at: Date())); XCTAssertFalse(value.events.isEmpty)
      XCTAssertTrue(value.events.allSatisfy { $0.source.host == "x.com" })
    }
    guard let path = ProcessInfo.processInfo.environment["CHENGGUAN_SCANNER_RENDER"] else { return }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    for dark in [false, true] {
      let geometry = CareScannerScene(dark: dark)
      geometry.scene.background.contents = NSColor(calibratedWhite: dark ? 0.12 : 1, alpha: 1)
      let renderer = SCNRenderer(device: nil, options: nil)
      renderer.scene = geometry.scene; renderer.pointOfView = geometry.camera
      var frames: [Data] = []
      for (index, time) in [0.0, 0.65, 1.3, 2.0].enumerated() {
        geometry.pose(time: time, activity: index == 3 ? 0 : 1, completion: index == 3 ? 1 : 0)
        let image = renderer.snapshot(atTime: time, with: CGSize(width: 680, height: 480), antialiasingMode: .multisampling4X)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        frames.append(png)
        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("helix-\(dark ? "dark" : "light")-\(index).png"))
      }
      XCTAssertNotEqual(frames[0], frames[1]); XCTAssertNotEqual(frames[1], frames[2])
    }
  }
}
