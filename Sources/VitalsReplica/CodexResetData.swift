import CryptoKit
import Foundation

struct CodexResetEvent: Codable, Identifiable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case scheduled, completed, bankedScheduled, banked, watch, observed }
  let id: String
  let kind: Kind
  let time: Date
  let scheduled: Date?
  let expires: Date?
  let text: String
  let source: URL
  var fingerprint: String { id + ":" + kind.rawValue + ":" + String(scheduled?.timeIntervalSince1970 ?? 0) }
  var title: String {
    switch kind {
    case .scheduled: "已公布重置预告"
    case .completed: "公开重置已确认"
    case .bankedScheduled: "重置卡即将发放"
    case .banked: "重置卡发放公告"
    case .watch: "有新的公开信号"
    case .observed: "社区观察到额度恢复"
    }
  }
  var explanation: String {
    switch kind {
    case .scheduled: "时间以原帖为准，到点仍需确认是否完成。"
    case .completed: "Tibo 公告已完成；你的账号以实际额度为准。"
    case .bankedScheduled: "公开发放预告，尚不代表当前账号已收到。"
    case .banked: "请在 Codex 用量页核对是否到账；不会自动使用。"
    case .watch: "尚未确认重置，不推算到账时间。"
    case .observed: "来自社区观察，尚无可核验的完成公告。"
    }
  }
  func active(at now: Date) -> Bool {
    time <= now.addingTimeInterval(300) && now.timeIntervalSince(time) < 30 * 86400 && (expires.map { $0 > now } ?? true)
  }
}

struct CodexResetSnapshot: Codable, Sendable {
  let generatedAt: Date
  let events: [CodexResetEvent]
  func fresh(at now: Date) -> Bool { generatedAt <= now.addingTimeInterval(300) && now.timeIntervalSince(generatedAt) < 3600 }
  func visible(at now: Date) -> [CodexResetEvent] {
    events.filter { $0.active(at: now) }.sorted {
      let a = [.scheduled, .bankedScheduled, .watch].contains($0.kind), b = [.scheduled, .bankedScheduled, .watch].contains($1.kind)
      return a == b ? $0.time > $1.time : a
    }
  }
}

/// Independently implemented against the source's public v1 OpenAPI schema.
/// Never treat community observations, forecasts, or elapsed deadlines as account receipts.
enum CodexResetParser {
  static let attribution = URL(string: "https://codex-resets.com")!
  static func source(_ object: [String: Any]) -> URL? {
    guard let raw = object["url"] as? String, let url = URL(string: raw), url.scheme == "https",
      url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
      ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? ""),
      url.path.range(of: "^/thsottiaux/status/[0-9]+$", options: .regularExpression) != nil else { return nil }
    if object["type"] as? String == "x_post", object["author"] as? String != "thsottiaux" { return nil }
    return url
  }
  static func event(_ object: [String: Any], scheduled: Bool = false) -> CodexResetEvent? {
    guard let id = object["id"] as? String, !id.isEmpty, id.count <= 100,
      let type = object["reset_type"] as? String, ["regular", "banked"].contains(type),
      let time = UsageLogParser.date(object["announced_at"] as? String),
      let text = object["text"] as? String, !text.isEmpty, text.utf8.count < 16_000,
      let origin = object["source"] as? [String: Any], let url = source(origin),
      ["x_post", "observed"].contains(origin["type"] as? String ?? "") else { return nil }
    // A source marked "observed" cannot support a confirmed announcement, or a reset-card grant.
    let observed = origin["type"] as? String == "observed"
    if observed && (scheduled || type == "banked") { return nil }
    if !observed && id != url.lastPathComponent { return nil }
    return CodexResetEvent(id: id, kind: observed ? .observed : type == "banked" ? (scheduled ? .bankedScheduled : .banked) : scheduled ? .scheduled : .completed,
      time: time, scheduled: UsageLogParser.date(object["scheduled_for"] as? String), expires: nil,
      text: String(text.prefix(2000)), source: url)
  }
  static func parse(status: Data, history: Data? = nil) throws -> CodexResetSnapshot {
    guard let root = try JSONSerialization.jsonObject(with: status) as? [String: Any],
      let data = root["data"] as? [String: Any], let meta = root["meta"] as? [String: Any], meta["api_version"] as? String == "v1",
      let generated = UsageLogParser.date(meta["generated_at"] as? String),
      data.keys.contains("latest_reset"), data.keys.contains("scheduled_reset"), data.keys.contains("active_watch") else {
      throw AIAnalysisError.message("公告源格式已变化。")
    }
    var events: [CodexResetEvent] = []
    if let latest = data["latest_reset"] as? [String: Any], let value = event(latest) { events.append(value) }
    if let next = data["scheduled_reset"] as? [String: Any], next["status"] as? String == "scheduled", let value = event(next, scheduled: true) { events.append(value) }
    if let watch = data["active_watch"] as? [String: Any],
      let time = UsageLogParser.date(watch["observed_at"] as? String), let expires = UsageLogParser.date(watch["expires_at"] as? String),
      let text = watch["text"] as? String, !text.isEmpty, text.utf8.count < 16000,
      let origin = watch["source"] as? [String: Any], origin["type"] as? String == "x_post", let url = source(origin) {
      events.append(.init(id: url.lastPathComponent, kind: .watch, time: time, scheduled: nil, expires: expires, text: String(text.prefix(2000)), source: url))
    }
    if let history, let object = try? JSONSerialization.jsonObject(with: history) as? [String: Any],
      let meta = object["meta"] as? [String: Any], meta["api_version"] as? String == "v1",
      let generated = UsageLogParser.date(meta["generated_at"] as? String), abs(generated.timeIntervalSince(rootDate(root))) < 3600,
      let rows = object["data"] as? [[String: Any]] {
      for row in rows.prefix(30) {
        if let value = event(row), !events.contains(where: { $0.id == value.id }) { events.append(value) }
      }
    }
    return .init(generatedAt: generated, events: Array(events.prefix(30)))
  }
  private static func rootDate(_ root: [String: Any]) -> Date {
    UsageLogParser.date((root["meta"] as? [String: Any])?["generated_at"] as? String) ?? .distantPast
  }
}

struct CodexQuotaBaseline {
  var account: String
  var provider: ProviderUsage
  static func recovery(previous: Self?, current: Self, now: Date) -> String? {
    guard let previous, !current.account.isEmpty, previous.account == current.account,
      let oldTime = previous.provider.updated, let time = current.provider.updated,
      time > oldTime, now.timeIntervalSince(time) < 180, time.timeIntervalSince(oldTime) < 300 else { return nil }
    for limit in current.provider.limits {
      guard let old = previous.provider.limits.first(where: { $0.name == limit.name }) else { continue }
      for window in limit.windows {
        guard let prior = old.windows.first(where: { $0.minutes == window.minutes && $0.label == window.label }),
          let reset = prior.resets, reset > time, window.resets == reset,
          prior.used - window.used >= 15 else { continue }
        return String(format: "本机剩余额度从 %.1f%% 升至 %.1f%%；恢复原因待确认。", 100 - prior.used, 100 - window.used)
      }
    }
    return nil
  }
}
