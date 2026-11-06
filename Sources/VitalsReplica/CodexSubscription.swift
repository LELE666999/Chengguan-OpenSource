import Foundation
import CryptoKit

/// Reads subscription metadata only. Login tokens remain in memory and are never
/// transmitted, refreshed, copied to our cache, or exposed in diagnostics.
enum CodexSubscription {
  static func date(_ raw: Any?) -> Date? {
    if let text = raw as? String, let date = UsageLogParser.date(text) { return date }
    let number: Double?
    if let text = raw as? String { number = Double(text) }
    else { number = UsageNumeric.value(raw) }
    guard var seconds = number, seconds.isFinite else { return nil }
    if seconds > 100_000_000_000 { seconds /= 1000 }
    guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }
  private static func object(_ url: URL, maxSize: Int = 128_000) -> [String: Any]? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxSize,
      let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object
  }
  static func payload(_ token: String) -> [String: Any]? {
    guard token.utf8.count < 32_000 else { return nil }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[1].isEmpty else { return nil }
    var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    body += String(repeating: "=", count: (4 - body.count % 4) % 4)
    guard let data = Data(base64Encoded: body) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
  static func parseAuth(_ object: [String: Any]) -> AISubscriptionDate? {
    guard object["auth_mode"] as? String != "apikey", object["auth_mode"] as? String != "api_key",
      let tokens = object["tokens"] as? [String: Any] else { return nil }
    // The access token describes the active account; do not fall back to a different
    // account in an older ID token when both carry an explicit account ID.
    let access = (tokens["access_token"] as? String).flatMap(payload)?["https://api.openai.com/auth"] as? [String: Any]
    let identity = (tokens["id_token"] as? String).flatMap(payload)?["https://api.openai.com/auth"] as? [String: Any]
    let accessID = access?["chatgpt_account_id"] as? String
    let identityID = identity?["chatgpt_account_id"] as? String
    let matchingIdentity = accessID == nil || identityID == nil || accessID == identityID
    for claims in [access, matchingIdentity ? identity : nil].compactMap({ $0 }) {
      if let end = date(claims["chatgpt_subscription_active_until"]) {
        return AISubscriptionDate(date: end, kind: .activeUntil, source: "Codex 本机登录信息")
      }
    }
    return nil
  }
  static func parseIndex(_ object: [String: Any]) -> AISubscriptionDate? {
    guard let active = object["current_account_id"] as? String, !active.isEmpty,
      let accounts = object["accounts"] as? [[String: Any]],
      let account = accounts.first(where: { $0["id"] as? String == active }),
      let end = date(account["subscription_active_until"]) else { return nil }
    return AISubscriptionDate(date: end, kind: .activeUntil, source: "Cockpit Tools 当前账号缓存")
  }
  /// Local-only account boundary for comparing quota snapshots. Never sent to a feed or model.
  static func accountFingerprint(home: URL) -> String? {
    guard let value = object(home.appendingPathComponent(".codex/auth.json")),
      let tokens = value["tokens"] as? [String: Any] else { return nil }
    for name in ["access_token", "id_token"] {
      if let token = tokens[name] as? String, let claims = payload(token)?["https://api.openai.com/auth"] as? [String: Any],
        let account = claims["chatgpt_account_id"] as? String, !account.isEmpty {
        return SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
      }
    }
    return nil
  }
  static func read(home: URL, codexHome: URL? = nil) -> AISubscriptionDate? {
    let authFile = (codexHome ?? home.appendingPathComponent(".codex")).appendingPathComponent("auth.json")
    if FileManager.default.fileExists(atPath: authFile.path) {
      // An existing login is authoritative. Do not substitute another Cockpit
      // account if this account has no end date or uses an API key.
      return object(authFile).flatMap(parseAuth)
    }
    let index = home.appendingPathComponent(".cockpit_tools/codex_accounts.json")
    return object(index, maxSize: 2_000_000).flatMap(parseIndex)
  }
}
