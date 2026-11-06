import Foundation
import SQLite3

/// Reuses only Cursor's own current login against two fixed, read-only account endpoints.
/// No browser-cookie import, credential refresh, disk copy, logging, or redirects.
enum CursorQuota {
  static func sessionHeader(token: String, now: Date) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, token.count < 16_000,
      token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }) else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = json["exp"] as? Double, exp > now.timeIntervalSince1970 + 60,
      let subject = json["sub"] as? String, let id = subject.split(separator: "|").last, !id.isEmpty,
      id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }) else { return nil }
    return "WorkosCursorSessionToken=\(id)%3A%3A\(token)"
  }
  private static func header(home: URL, now: Date) -> String? {
    let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if db != nil { sqlite3_close(db) }; return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
    return sessionHeader(token: String(cString: text), now: now)
  }
  private final class ResultBox: @unchecked Sendable {
    let lock = NSLock()
    var value: [String: Any]?
    func set(_ value: [String: Any]) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
  }
  private static func read(_ endpoint: String, header: String, session: URLSession) -> [String: Any]? {
    var request = URLRequest(url: URL(string: "https://cursor.com" + endpoint)!)
    request.setValue(header, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let result = ResultBox(), done = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
      defer { done.signal() }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        let data, data.count < 1_000_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
      result.set(json)
    }
    task.resume()
    guard done.wait(timeout: .now() + 9) == .success else { task.cancel(); return nil }
    return result.get()
  }
  /// Called on the existing serial utility queue, never on the UI thread.
  static func fetch(home: URL, now: Date = Date()) -> ProviderUsage {
    let unavailable = ProviderUsage(id: "Cursor", tokenCountsAvailable: false, source: "Cursor 账户",
      unavailable: "在 Cursor 登录后自动读取额度")
    guard let header = header(home: home, now: now) else { return unavailable }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 7; configuration.timeoutIntervalForResource = 8
    let session = URLSession(configuration: configuration, delegate: AINoRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let quota = read("/api/usage-summary", header: header, session: session)
    let billing = read("/api/auth/stripe", header: header, session: session)
    var value = quota.flatMap { parse($0, now: now) } ?? unavailable
    if value.updated == nil { value.unavailable = "额度暂不可用 · 打开 Cursor 检查账户" }
    value.subscription = billing.flatMap(parseSubscription)
    return value
  }
  /// Cursor's own pending-cancellation date is an end date. Its quota billingCycleEnd
  /// can be a weekly reset on unified plans, so it must never become a subscription date.
  static func parseSubscription(_ json: [String: Any]) -> AISubscriptionDate? {
    let raw = json["pendingCancellationDate"]
    let date: Date?
    if let text = raw as? String { date = UsageLogParser.date(text) }
    else if let ms = UsageNumeric.value(raw), ms > 946_684_800_000, ms < 4_102_444_800_000 {
      date = Date(timeIntervalSince1970: ms / 1000)
    } else { date = nil }
    return date.map { AISubscriptionDate(date: $0, kind: .expires, source: "Cursor 账户") }
  }
  static func parse(_ json: [String: Any], now: Date) -> ProviderUsage? {
    if json["isUnlimited"] as? Bool == true {
      return ProviderUsage(id: "Cursor", updated: now, tokenCountsAvailable: false, source: "Cursor 账户", unavailable: "当前套餐未设统一额度上限")
    }
    let individual = json["individualUsage"] as? [String: Any]
    let plan = individual?["plan"] as? [String: Any]
    let overall = individual?["overall"] as? [String: Any]
    var percent: Double?
    if let value = UsageNumeric.value(plan?["totalPercentUsed"]), value >= 0 { percent = value }
    if percent == nil {
      for source in [plan, overall].compactMap({ $0 }) {
        if let used = UsageNumeric.value(source["used"]), let limit = UsageNumeric.value(source["limit"]),
          used >= 0, limit > 0 { percent = used / limit * 100; break }
      }
    }
    guard let percent, percent.isFinite else { return nil }
    let reset = UsageLogParser.date(json["billingCycleEnd"] as? String)
    let window = UsageWindow(used: min(100, percent), minutes: 0, resets: reset, label: "当前账期额度")
    return ProviderUsage(id: "Cursor", limits: [UsageLimit(provider: "Cursor", name: "Cursor", time: now, windows: [window])],
      updated: now, tokenCountsAvailable: false, source: "Cursor 账户额度", expires: now.addingTimeInterval(600))
  }
}
