import AppKit
import Combine
import Foundation
import SwiftUI

struct UsageWindow: Codable, Equatable {
  var used: Double
  var minutes: Int
  var resets: Date?
  var label: String?
}
struct UsageEntry: Codable {
  var key: String, provider: String
  var time: Date
  var input: Int64, output: Int64, cached: Int64
  var model: String? = nil
  var cacheWrite: Int64? = nil
  var reasoning: Int64? = nil
  var total: Int64 { input + output }
}
struct UsageLimit: Codable {
  var provider: String, name: String
  var time: Date
  var windows: [UsageWindow]
}
struct UsageFile: Codable {
  var offset: UInt64 = 0, inode: UInt64 = 0
  var previous: Int64 = 0, previousInput: Int64 = 0, previousOutput: Int64 = 0, previousCached: Int64 = 0
  var entries: [UsageEntry] = []
  var limits: [String: UsageLimit] = [:]
  var model: String? = nil
  var stepIdentity: String? = nil
}
struct UsageDay: Equatable, Identifiable {
  var date: Date
  var tokens: Int64
  var id: Date { date }
}
struct ProviderUsage: Identifiable {
  var id: String
  var today: Int64 = 0, week: Int64 = 0, cached: Int64 = 0
  var last7Days: Int64 = 0
  var daily: [UsageDay] = []
  var limits: [UsageLimit] = []
  var updated: Date?
  var appPath: String?
  var running = false
  var tokenCountsAvailable = true
  var source = "本机用量记录"
  var unavailable: String?
  var expires: Date?
  var subscription: AISubscriptionDate?
  var month: Int64 = 0
  var monthlyDaily: [UsageDay] = []
  var models: [UsageModelTotal] = []
  func stale(at now: Date = Date()) -> Bool {
    if let expires, now >= expires { return true }
    return limits.contains { $0.windows.contains { ($0.resets ?? .distantFuture) <= now } }
  }
}

/// Only numeric usage events are decoded. Conversation text and login files are never cached.
enum UsageLogParser {
  static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    return fractional.date(from: text) ?? plain.date(from: text)
  }
  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
  }()
  private static let plain = ISO8601DateFormatter()
  private static func number(_ object: [String: Any], _ key: String) -> Int64 { max(0, (object[key] as? NSNumber)?.int64Value ?? 0) }
  static func consume(_ data: Data, provider: String, state: inout UsageFile) {
    if provider != "Codex" && provider != "Claude" && provider != "Claude Code" {
      AdditionalUsageParser.consume(data, provider: provider, state: &state); return
    }
    if provider == "Codex", data.range(of: Data("\"turn_context\"".utf8)) != nil,
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       root["type"] as? String == "turn_context", let payload = root["payload"] as? [String: Any] {
      state.model = payload["model"] as? String; return
    }
    let marker = provider == "Codex" ? Data("\"token_count\"".utf8) : Data("\"usage\"".utf8)
    guard data.range(of: marker) != nil,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let time = date(root["timestamp"] as? String) else { return }
    if provider == "Codex" {
      guard root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
        payload["type"] as? String == "token_count" else { return }
      if let rate = payload["rate_limits"] as? [String: Any] {
        let name = rate["limit_name"] as? String ?? rate["limit_id"] as? String ?? "Codex"
        let windows: [UsageWindow] = ["primary", "secondary"].compactMap { key in
          guard let w = rate[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
          return UsageWindow(used: min(100, max(0, used)), minutes: Int(number(w, "window_minutes")),
                             resets: (w["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        if !windows.isEmpty { state.limits[name] = UsageLimit(provider: provider, name: name, time: time, windows: windows) }
      }
      guard let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any] else { return }
      let input = number(usage, "input_tokens"), output = number(usage, "output_tokens"), cached = number(usage, "cached_input_tokens")
      let total = input + output
      // Rate-limit notifications repeat the preceding usage object. Count cumulative advances only.
      guard total != state.previous else { return }
      let reset = total < state.previous
      let entry = UsageEntry(key: "Codex:\(time.timeIntervalSince1970):\(input):\(output):\(cached)", provider: provider, time: time,
                             input: reset ? input : max(0, input - state.previousInput),
                             output: reset ? output : max(0, output - state.previousOutput),
                             cached: reset ? cached : max(0, cached - state.previousCached), model: state.model)
      state.previous = total; state.previousInput = input; state.previousOutput = output; state.previousCached = cached
      if entry.total > 0 { state.entries.append(entry) }
    } else {
      guard root["type"] as? String == "assistant", let message = root["message"] as? [String: Any],
        let usage = message["usage"] as? [String: Any], let id = message["id"] as? String else { return }
      let request = root["requestId"] as? String ?? root["request_id"] as? String ?? ""
      let session = root["sessionId"] as? String ?? root["session_id"] as? String ?? ""
      let cached = number(usage, "cache_read_input_tokens")
      let input = number(usage, "input_tokens") + number(usage, "cache_creation_input_tokens") + cached
      let output = number(usage, "output_tokens")
      let key = "Claude:\(session):\(request):\(id)"
      // Streaming updates share a message ID; the final usage replaces the earlier snapshot.
      if let i = state.entries.firstIndex(where: { $0.key == key }) { state.entries.remove(at: i) }
      state.entries.append(UsageEntry(key: key, provider: provider, time: time, input: input, output: output, cached: cached,
        model: message["model"] as? String, cacheWrite: number(usage, "cache_creation_input_tokens")))
    }
  }
  static func summarize(_ files: [UsageFile], now: Date = Date(), calendar: Calendar = .current) -> [ProviderUsage] {
    let today = calendar.startOfDay(for: now)
    let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86400)
    let firstDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
    let month = calendar.dateInterval(of: .month, for: now)?.start ?? firstDay
    var dedup: [String: UsageEntry] = [:]
    var limits: [String: UsageLimit] = [:]
    for file in files {
      for entry in file.entries where entry.time >= min(firstDay, week, month) && entry.time <= now {
        if let old = dedup[entry.key], old.total > entry.total { continue }
        dedup[entry.key] = entry
      }
      for limit in file.limits.values where limit.time >= week {
        let key = limit.provider + ":" + limit.name
        if limit.time >= (limits[key]?.time ?? .distantPast) { limits[key] = limit }
      }
    }
    let providers = Set(dedup.values.map(\.provider)).union(limits.values.map(\.provider))
    return providers.sorted().map { name in
      let entries = dedup.values.filter { $0.provider == name }
      let quotas = limits.values.filter { $0.provider == name }.sorted { $0.name < $1.name }
      let days = (0..<7).map { offset -> UsageDay in
        let date = calendar.date(byAdding: .day, value: offset, to: firstDay) ?? firstDay
        return UsageDay(date: date, tokens: entries.filter { calendar.isDate($0.time, inSameDayAs: date) }.reduce(0) { $0 + $1.total })
      }
      var result = ProviderUsage(id: name, today: entries.filter { $0.time >= today }.reduce(0) { $0 + $1.total },
                           week: entries.filter { $0.time >= week }.reduce(0) { $0 + $1.total },
                           cached: entries.filter { $0.time >= today }.reduce(0) { $0 + $1.cached },
                           last7Days: days.reduce(0) { $0 + $1.tokens }, daily: days,
                           limits: quotas, updated: (entries.map(\.time) + quotas.map(\.time)).max())
      let monthEntries = entries.filter { $0.time >= month }
      result.month = monthEntries.reduce(0) { $0 + $1.total }
      let dayCount = (calendar.dateComponents([.day], from: month, to: today).day ?? 0) + 1
      result.monthlyDaily = (0..<dayCount).map { offset in
        let date = calendar.date(byAdding: .day, value: offset, to: month) ?? month
        return UsageDay(date: date, tokens: monthEntries.filter { calendar.isDate($0.time, inSameDayAs: date) }.reduce(0) { $0 + $1.total })
      }
      result.models = UsageModelTotal.aggregate(monthEntries)
      return result
    }
  }
}

final class AIUsageStore: ObservableObject {
  static let shared = AIUsageStore()
  @Published private(set) var providers: [ProviderUsage] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private let queue = DispatchQueue(label: "studio.lele.chengguan.usage", qos: .utility)
  private var files: [String: UsageFile] = [:]
  private var last = Date.distantPast
  private var loaded = false
  private var cursorQuota: ProviderUsage?
  private let claudeQuota = ClaudeQuota()
  private var lastRemoteRefresh = Date.distantPast
  private let events = UsageFileEvents()
  private var eventRefresh: DispatchWorkItem?
  private var pendingLocalRefresh = false
  private var databaseModified: [String: Date] = [:]
  private let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    // Rebuild numeric metadata once to include the days before the current calendar week.
    .appendingPathComponent("Chengguan/usage-metadata-v3.json")
  func refresh(force: Bool = false, authorizeClaude: Bool = false, filesChanged: Bool = false, localOnly: Bool = false) {
    guard UserDefaults.standard.bool(forKey: "aiUsageEnabled") else { return }
    if loading { pendingLocalRefresh = pendingLocalRefresh || filesChanged; return }
    guard force || filesChanged || Date().timeIntervalSince(last) > 30 else { return }
    loading = true; last = Date()
    queue.async { [weak self] in
      guard let self else { return }
      if !self.loaded {
        self.loaded = true
        if let data = try? Data(contentsOf: self.cache), let saved = try? JSONDecoder().decode([String: UsageFile].self, from: data) { self.files = saved }
      }
      let fm = FileManager.default
      let home = fm.homeDirectoryForCurrentUser
      let now = Date()
      let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
      let retention = min(monthStart, Calendar.current.date(byAdding: .day, value: -7, to: now) ?? monthStart)
      let roots = UsageSource.local(home: home)
      let databaseSources = [(home.appendingPathComponent(".local/share/opencode/opencode.db"), "OpenCode"),
        (home.appendingPathComponent(".local/share/kilo/kilo.db"), "Kilo Code")]
      self.events.onChange = { [weak self] in
        guard let self else { return }
        self.eventRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.refresh(filesChanged: true) } }
        self.eventRefresh = item; self.queue.asyncAfter(deadline: .now() + 2, execute: item)
      }
      if !localOnly { self.events.start(roots: roots.map(\.root) + databaseSources.map { $0.0.deletingLastPathComponent() }, queue: self.queue) }
      let changes = self.events.take(now: now, force: force)
      var found = Set(self.files.keys)
      if changes.discover { found.removeAll() }
      for source in roots {
        let urls: [URL]
        if changes.discover {
          if source.root.pathExtension == "jsonl" { urls = [source.root] }
          else {
            let enumerator = fm.enumerator(at: source.root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
            urls = enumerator?.compactMap { $0 as? URL }.filter { source.accepts($0) } ?? []
          }
        } else {
          urls = changes.paths.filter { $0 == source.root.path || $0.hasPrefix(source.root.path + "/") }
            .map { URL(fileURLWithPath: $0) }.filter { source.accepts($0) }
        }
        for url in urls {
          guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, (values.contentModificationDate ?? .distantPast) >= retention else {
            found.remove(url.path); self.files.removeValue(forKey: url.path); continue
          }
          found.insert(url.path)
          var state = self.files[url.path] ?? UsageFile()
          if let attributes = try? fm.attributesOfItem(atPath: url.path) {
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if state.inode != inode || size < state.offset { state = UsageFile(inode: inode) }
          }
          if url.pathExtension == "json" {
            if let size = values.fileSize, size > 32 * 1024 * 1024 { continue }
            // Legacy Gemini and OpenCode rewrite JSON snapshots; replace instead of accumulating.
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
              state = UsageFile(); AdditionalUsageParser.consume(data, provider: source.provider, state: &state)
            }
          } else { self.scan(url, provider: source.provider, state: &state) }
          state.entries.removeAll { $0.time < retention }
          self.files[url.path] = state
        }
      }
      for (url, provider) in databaseSources where fm.fileExists(atPath: url.path) {
        found.insert(url.path)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let modified = [url, wal].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? now
        if force || self.databaseModified[url.path] != modified {
          if let state = UsageDatabaseReader.read(url, provider: provider, since: retention) {
            self.files[url.path] = state; self.databaseModified[url.path] = modified
          }
        }
      }
      self.files = self.files.filter { found.contains($0.key) }
      var summary = AIAppDiscovery.merge(usage: UsageLogParser.summarize(Array(self.files.values)),
        installed: AIAppDiscovery.installed(), home: home)
      if let index = summary.firstIndex(where: { $0.id == "Codex" }) {
        summary[index].subscription = CodexSubscription.read(home: home)
      }
      if !localOnly, let index = summary.firstIndex(where: { $0.id == "Cursor" }) {
        if force || Date().timeIntervalSince(self.lastRemoteRefresh) > 300 {
          self.lastRemoteRefresh = Date()
          self.cursorQuota = CursorQuota.fetch(home: home)
        }
        if var quota = self.cursorQuota {
          quota.appPath = summary[index].appPath; quota.running = summary[index].running; summary[index] = quota
        }
      }
      if !localOnly, let index = summary.firstIndex(where: { $0.id == "Claude" }) {
        var quota = self.claudeQuota.fetch(home: home, force: force, allowInteraction: authorizeClaude)
        let local = summary[index]
        quota.appPath = local.appPath; quota.running = local.running
        quota.today = local.today; quota.week = local.week; quota.cached = local.cached
        quota.last7Days = local.last7Days; quota.daily = local.daily
        quota.month = local.month; quota.monthlyDaily = local.monthlyDaily; quota.models = local.models
        quota.tokenCountsAvailable = local.tokenCountsAvailable
        quota.updated = [quota.updated, local.updated].compactMap { $0 }.max()
        summary[index] = quota
      }
      try? fm.createDirectory(at: self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
      if changes.discover || !changes.paths.isEmpty {
        if let data = try? JSONEncoder().encode(self.files) { try? data.write(to: self.cache, options: .atomic) }
      }
      let account = CodexSubscription.accountFingerprint(home: home)
      DispatchQueue.main.async {
        self.providers = summary; self.loading = false
        if self.pendingLocalRefresh { self.pendingLocalRefresh = false; self.refresh(filesChanged: true) }
        if !localOnly { CodexResetStore.shared.observe(summary.first { $0.id == "Codex" }, account: account) }
      }
    }
  }
  private func scan(_ url: URL, provider: String, state: inout UsageFile) {
    guard let file = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? file.close() }
    try? file.seek(toOffset: state.offset)
    var line = Data(), skipped = false, position = state.offset
    while let chunk = try? file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        if !skipped {
          line.append(chunk[start..<newline])
          if line.count < 4 * 1024 * 1024 { UsageLogParser.consume(line, provider: provider, state: &state) }
        }
        line.removeAll(keepingCapacity: true); skipped = false
        state.offset = position + UInt64(newline - chunk.startIndex + 1)
        start = newline + 1
      }
      if !skipped { line.append(chunk[start...]); if line.count > 4 * 1024 * 1024 { line.removeAll(keepingCapacity: true); skipped = true } }
      position += UInt64(chunk.count)
    }
  }
}
