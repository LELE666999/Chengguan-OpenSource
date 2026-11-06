import Foundation
import SQLite3

struct UsageModelTotal: Identifiable, Equatable {
  var id: String
  var input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0
  var total: Int64 { input + output }
  static func aggregate(_ entries: [UsageEntry]) -> [Self] {
    var rows: [String: Self] = [:]
    for entry in entries where entry.total > 0 {
      let model = entry.model.flatMap { $0.isEmpty ? nil : $0 } ?? "未记录模型"
      var row = rows[model] ?? Self(id: model)
      row.input += entry.input; row.output += entry.output; row.cached += entry.cached
      rows[model] = row
    }
    return rows.values.sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }
  }
}

struct UsageSource {
  var root: URL
  var provider: String
  static func local(home: URL) -> [Self] {
    var sources = [Self(root: home.appendingPathComponent(".codex/sessions"), provider: "Codex"),
      Self(root: home.appendingPathComponent(".codex/archived_sessions"), provider: "Codex")]
    sources += ClaudeUsageSources.roots(home: home).map { Self(root: $0, provider: "Claude") }
    for (path, provider) in [(".gemini/tmp", "Gemini CLI"), (".qwen/projects", "Qwen Code"),
      (".qwen/tmp", "Qwen Code"), (".kimi/sessions", "Kimi Code"), (".kimi-code/sessions", "Kimi Code"),
      (".local/share/opencode/storage/message", "OpenCode"), (".local/share/kilo/storage/message", "Kilo Code")] {
      sources.append(Self(root: home.appendingPathComponent(path), provider: provider))
    }
    return sources
  }
  func accepts(_ url: URL) -> Bool {
    if ["Codex", "Claude"].contains(provider) { return url.pathExtension == "jsonl" }
    if provider == "Kimi Code" { return url.lastPathComponent == "wire.jsonl" }
    if provider == "OpenCode" || provider == "Kilo Code" { return url.pathExtension == "json" }
    return url.pathComponents.contains("chats") && ["json", "jsonl"].contains(url.pathExtension)
  }
}

/// Decode only documented usage metadata; no message content is retained.
enum AdditionalUsageParser {
  static func count(_ object: [String: Any], _ key: String) -> Int64 {
    guard let n = UsageNumeric.value(object[key]), n >= 0, n < 1e15 else { return 0 }
    return Int64(n)
  }
  static func timestamp(_ value: Any?) -> Date? {
    if let text = value as? String { return UsageLogParser.date(text) }
    guard let n = UsageNumeric.value(value), n > 0 else { return nil }
    return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
  }
  static func consume(_ data: Data, provider: String, state: inout UsageFile) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let messages = root["messages"] as? [[String: Any]] {
      for message in messages { consume(message, provider: provider, state: &state) }
    } else { consume(root, provider: provider, state: &state) }
  }
  private static func consume(_ root: [String: Any], provider: String, state: inout UsageFile) {
    if provider == "Kimi Code", let message = root["message"] as? [String: Any], message["type"] as? String == "StepBegin",
      let time = timestamp(root["timestamp"]) {
      state.stepIdentity = "step:" + String(time.timeIntervalSince1970); return
    }
    var time = timestamp(root["timestamp"]), model = root["model"] as? String
    var input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0
    var creation: Int64 = 0, reasoning: Int64 = 0
    var identifier = root["id"] as? String
    switch provider {
    case "Gemini CLI":
      guard root["type"] as? String == "gemini", let u = root["tokens"] as? [String: Any] else { return }
      input = count(u, "input"); output = count(u, "output"); cached = count(u, "cached")
      // Gemini reports thoughts outside candidatesTokenCount. Total can also include tool prompts.
      reasoning = count(u, "thoughts")
      output += reasoning
      input = max(input, count(u, "total") - output)
    case "Qwen Code":
      guard root["type"] as? String == "assistant", let u = root["usageMetadata"] as? [String: Any] else { return }
      input = count(u, "promptTokenCount"); cached = count(u, "cachedContentTokenCount")
      reasoning = count(u, "thoughtsTokenCount")
      output = count(u, "candidatesTokenCount") + reasoning
      input = max(input, count(u, "totalTokenCount") - output)
    case "Kimi Code":
      guard let message = root["message"] as? [String: Any], message["type"] as? String == "StatusUpdate",
        let payload = message["payload"] as? [String: Any], let u = payload["token_usage"] as? [String: Any] else { return }
      cached = count(u, "input_cache_read"); creation = count(u, "input_cache_creation")
      input = count(u, "input_other") + cached + creation; output = count(u, "output")
      // Status updates can repeat a step's totals. Replace by stable message ID when supplied.
      identifier = payload["message_id"] as? String ?? state.stepIdentity
    case "OpenCode", "Kilo Code":
      guard (root["role"] as? String ?? root["type"] as? String) == "assistant",
        let u = root["tokens"] as? [String: Any] else { return }
      let cache = u["cache"] as? [String: Any] ?? [:]
      cached = count(cache, "read"); creation = count(cache, "write")
      input = count(u, "input") + cached + creation; output = count(u, "output")
      // OpenCode's TokenUsage.total explicitly adds reasoning to output (unlike Codex).
      reasoning = count(u, "reasoning"); output += reasoning
      let modelRef = root["model"] as? [String: Any]
      model = root["modelID"] as? String ?? modelRef?["modelID"] as? String ?? modelRef?["id"] as? String
      time = timestamp((root["time"] as? [String: Any])?["created"]) ?? time
    default: return
    }
    guard let time, input + output > 0 else { return }
    let key = provider + ":" + (identifier ?? String(time.timeIntervalSince1970))
    let entry = UsageEntry(key: key, provider: provider, time: time, input: input, output: output,
      cached: cached, model: model, cacheWrite: creation, reasoning: reasoning)
    if let index = state.entries.firstIndex(where: { $0.key == key }) { state.entries[index] = entry }
    else { state.entries.append(entry) }
  }
}

enum UsageDatabaseReader {
  /// SQLite's read-only connection includes committed WAL records. No credentials or content columns are selected.
  static func read(_ url: URL, provider: String, since: Date) -> UsageFile? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }; return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 250)
    var state = UsageFile()
    // OpenCode's original and v2 schemas both store numeric assistant metadata in data.
    for table in ["message", "session_message"] {
      var statement: OpaquePointer?
      let sql = """
      SELECT id, time_created, json_extract(data,'$.tokens'), json_extract(data,'$.modelID'),
        COALESCE(json_extract(data,'$.model.modelID'),json_extract(data,'$.model.id')), json_extract(data,'$.role'), json_extract(data,'$.type')
      FROM \(table) WHERE time_created >= ? AND json_valid(data) AND json_type(data,'$.tokens')='object'
      """
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
      func string(_ col: Int32) -> String? { sqlite3_column_text(statement, col).map { String(cString: $0) } }
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = string(0), let tokens = string(2), tokens.utf8.count < 16_384,
          let u = try? JSONSerialization.jsonObject(with: Data(tokens.utf8)) else { continue }
        let root: [String: Any] = ["id": id, "role": string(5) ?? "assistant", "type": string(6) ?? "assistant",
          "time": ["created": sqlite3_column_int64(statement, 1)], "tokens": u, "modelID": string(3) ?? string(4) ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: root) { AdditionalUsageParser.consume(data, provider: provider, state: &state) }
      }
    }
    return state
  }
}
