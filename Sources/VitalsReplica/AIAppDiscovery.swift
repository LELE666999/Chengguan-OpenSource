import AppKit
import Foundation
import CoreFoundation

enum UsageNumeric {
  static func value(_ object: Any?) -> Double? {
    guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
    return number.doubleValue
  }
}

struct InstalledAIApp {
  let name: String
  let path: String
  var running = false
}

/// Discovery reads app metadata and explicitly named numeric caches. Authenticated
/// quota requests are isolated in provider-specific clients.
enum AIAppDiscovery {
  static let catalog: [(String, [String])] = [
    ("Grok Bot", ["Grok Bot"]), ("Codex", ["Codex"]), ("ChatGPT", ["ChatGPT", "ChatGPT Classic"]),
    ("Claude", ["Claude", "Claude Code"]), ("Cursor", ["Cursor"]), ("Antigravity", ["Antigravity"]),
    ("Windsurf", ["Windsurf"]), ("Kiro", ["Kiro"]), ("Kimi", ["Kimi"]), ("MiniMax", ["MiniMax"]),
    ("CodeBuddy", ["CodeBuddy", "CodeBuddy CN"]), ("WorkBuddy", ["WorkBuddy", "WorkBuddy AI"]),
    ("Trae", ["Trae", "Trae CN", "TRAE SOLO", "TRAE SOLO CN"]),
    ("Qoder", ["Qoder", "Qoder CN", "Qoder IDE", "QoderWork"]), ("QClaw", ["QClaw"]),
    ("豆包", ["豆包", "Doubao"]), ("腾讯元宝", ["腾讯元宝"]), ("AutoGLM", ["AutoGLM"]),
    ("DeepSeek", ["DeepSeek", "DeepSeek Harness"]), ("Grok", ["Grok"]),
    ("Gemini", ["Gemini"]), ("Cherry Studio", ["Cherry Studio"]), ("Chatbox", ["Chatbox"]),
    ("Ollama", ["Ollama"]), ("LM Studio", ["LM Studio"]), ("Jan", ["Jan"]),
    ("Today", ["Today"]), ("Midjourney", ["Midjourney"]), ("Perplexity", ["Perplexity"]),
    ("Poe", ["Poe"]), ("Manus", ["Manus"]), ("CherryIN", ["CherryIN"]),
    ("Typeless", ["Typeless"]), ("闪电说", ["闪电说"]), ("Handy", ["Handy"]),
    ("扣子", ["扣子", "Coze"]), ("ima", ["ima", "ima.copilot"]), ("NotebookLM", ["NotebookLM"]),
  ]

  static func identify(_ fileName: String) -> String? {
    let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
    return catalog.first { $0.1.contains { $0.lowercased() == stem } }?.0
  }

  static func installed(roots: [URL]? = nil) -> [InstalledAIApp] {
    let fm = FileManager.default
    let roots = roots ?? [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    var found: [String: InstalledAIApp] = [:]
    for root in roots {
      for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] where url.pathExtension == "app" {
        guard let name = identify(url.lastPathComponent) else { continue }
        let app = InstalledAIApp(name: name, path: url.path, running: running.contains(url.standardizedFileURL.path))
        if found[name] == nil || app.running { found[name] = app }
      }
    }
    return found.values.sorted { $0.name < $1.name }
  }

  static func merge(usage: [ProviderUsage], installed: [InstalledAIApp], home: URL, now: Date = Date()) -> [ProviderUsage] {
    var result = Dictionary(uniqueKeysWithValues: usage.map { ($0.id, $0) })
    for app in installed {
      var entry = result[app.name] ?? ProviderUsage(id: app.name, tokenCountsAvailable: false,
        source: "已发现 App", unavailable: "暂未提供可读取的额度")
      entry.appPath = app.path; entry.running = app.running
      if app.name == "Grok Bot" {
        let folder = home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        if var quota = GrokBotUsageCache.read(folder: folder, now: now) {
          quota.appPath = app.path; quota.running = app.running; entry = quota
        } else { entry.unavailable = "打开 Grok Bot 更新额度" }
      } else if ["Ollama", "LM Studio", "Jan"].contains(app.name), entry.limits.isEmpty {
        entry.unavailable = "本地模型无统一套餐额度"
      }
      result[app.name] = entry
    }
    return result.values.sorted {
      let left = !$0.limits.isEmpty, right = !$1.limits.isEmpty
      if left != right { return left }
      if $0.running != $1.running { return $0.running }
      return $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }
}

enum GrokBotUsageCache {
  private static func object(_ url: URL) -> [String: Any]? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000,
      let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json
  }
  static func decodeFileName(_ name: String) -> String? {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var bits: UInt32 = 0, count = 0, bytes: [UInt8] = []
    for character in name.lowercased() {
      guard let value = alphabet.firstIndex(of: character) else { return nil }
      bits = ((bits << 5) | UInt32(value)) & 0xffff; count += 5
      if count >= 8 { count -= 8; bytes.append(UInt8((bits >> count) & 255)) }
    }
    return String(bytes: bytes, encoding: .utf8)
  }
  static func read(folder: URL, now: Date = Date()) -> ProviderUsage? {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    var named: [String: URL] = [:]
    for file in files where file.pathExtension == "blob" {
      guard let key = decodeFileName(file.deletingPathExtension().lastPathComponent),
        key == "sand.client.slice.client-meta.account-slot" || key.hasSuffix(".weekly-usage.cache") else { continue }
      named[key] = file
    }
    guard let slotFile = named["sand.client.slice.client-meta.account-slot"],
      let slot = object(slotFile)?["value"] as? String, !slot.isEmpty,
      let encoded = slot.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))),
      let file = named["sand.client.slice.account.\(encoded).weekly-usage.cache"],
      let json = object(file) else { return nil }
    return parse(json, now: now)
  }
  static func parse(_ json: [String: Any], now: Date = Date()) -> ProviderUsage? {
    guard let value = json["value"] as? [String: Any], value["kind"] as? String == "present",
      let reading = value["reading"] as? [String: Any], let usage = reading["usage"] as? [String: Any],
      let percent = UsageNumeric.value(usage["percentUsed"]), percent >= 0,
      let readMS = UsageNumeric.value(reading["readAtMs"]), readMS > 0 else { return nil }
    let time = Date(timeIntervalSince1970: readMS / 1000)
    guard time <= now.addingTimeInterval(60) else { return nil }
    let trial = usage["isSandTrial"] as? Bool == true
    let reset = UsageNumeric.value(usage["nextResetMs"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
    let expiry = UsageNumeric.value(value["expiresAtMs"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
    let window = UsageWindow(used: min(100, percent), minutes: trial ? 0 : 10080, resets: reset, label: trial ? "试用额度" : "每周额度")
    return ProviderUsage(id: "Grok Bot", limits: [UsageLimit(provider: "Grok Bot", name: "Grok Bot", time: time, windows: [window])],
      updated: time, tokenCountsAvailable: false, source: "Grok Bot 本机额度", expires: min(expiry ?? time.addingTimeInterval(86400), time.addingTimeInterval(86400)))
  }
}
