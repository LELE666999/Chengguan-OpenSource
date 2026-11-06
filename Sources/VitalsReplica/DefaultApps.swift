import AppKit
import Combine
import UniformTypeIdentifiers

enum DefaultOpenTarget: Hashable, Sendable {
  case scheme(String), contentType(String)
  var name: String { switch self { case .scheme(let value): value.uppercased(); case .contentType(let value): UTType(value)?.preferredFilenameExtension.map { "." + $0 } ?? value } }
}

struct DefaultOpenItem: Identifiable, Equatable, Sendable {
  let id: String, title: String, detail: String, symbol: String, category: String
  let targets: [DefaultOpenTarget]
  var custom = false
  static let builtIn: [Self] = [
    .init(id: "browser", title: "浏览器", detail: "HTTP · HTTPS · 网页", symbol: "globe", category: "常用", targets: [.scheme("http"), .scheme("https"), .contentType(UTType.html.identifier)]),
    .init(id: "email", title: "邮件", detail: "邮件链接", symbol: "envelope", category: "常用", targets: [.scheme("mailto")]),
    .init(id: "calendar", title: "日历", detail: "订阅链接", symbol: "calendar", category: "常用", targets: [.scheme("webcal")]),
  ] + [
    ("txt", "纯文本", "doc.text", "文档"), ("md", "Markdown", "text.document", "文档"),
    ("pdf", "PDF", "doc.richtext", "文档"), ("rtf", "富文本", "doc.text", "文档"),
    ("docx", "Word", "doc.text", "文档"), ("xlsx", "Excel", "tablecells", "文档"),
    ("pptx", "PowerPoint", "rectangle.on.rectangle", "文档"), ("csv", "CSV", "tablecells", "文档"),
    ("json", "JSON", "curlybraces", "代码"), ("yaml", "YAML", "curlybraces", "代码"),
    ("py", "Python", "chevron.left.forwardslash.chevron.right", "代码"), ("html", "HTML", "chevron.left.forwardslash.chevron.right", "代码"),
    ("jpg", "JPEG", "photo", "媒体"), ("png", "PNG", "photo", "媒体"),
    ("heic", "HEIC", "photo", "媒体"), ("svg", "SVG", "photo", "媒体"),
    ("mp4", "MP4", "film", "媒体"), ("mov", "QuickTime", "film", "媒体"),
    ("mp3", "MP3", "music.note", "媒体"), ("wav", "WAV", "waveform", "媒体"),
    ("zip", "ZIP", "archivebox", "压缩包"), ("7z", "7-Zip", "archivebox", "压缩包"),
  ].compactMap { ext, title, symbol, category in
    guard let type = UTType(filenameExtension: ext) else { return nil }
    return Self(id: "ext:" + ext, title: title, detail: "." + ext, symbol: symbol, category: category, targets: [.contentType(type.identifier)])
  }
}

struct DefaultApplication: Identifiable, Equatable {
  let url: URL, name: String, bundleID: String?
  var id: String { url.standardizedFileURL.path }
  init(url: URL) {
    self.url = url.standardizedFileURL
    let bundle = Bundle(url: url)
    name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
    bundleID = bundle?.bundleIdentifier
  }
}

enum DefaultAppsRules {
  static func normalizedExtension(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let ext = value.hasPrefix(".") ? String(value.dropFirst()) : value
    guard !ext.isEmpty, ext.count <= 32, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
          ext.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
    return ext
  }
  static func sameApplication(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
  }
  static func uniqueApplications(_ urls: [URL]) -> [DefaultApplication] {
    // Launch Services can return an updater's old app copies. Keep its preferred copy first.
    var seen = Set<String>()
    return urls.compactMap { url in
      let app = DefaultApplication(url: url)
      guard seen.insert(app.bundleID ?? app.id).inserted else { return nil }
      return app
    }
  }
}

protocol DefaultAppsSystem: Sendable {
  func current(_ target: DefaultOpenTarget) -> URL?
  func candidates(_ target: DefaultOpenTarget) -> [URL]
  func set(_ application: URL, for target: DefaultOpenTarget) async throws
}

struct MacDefaultAppsSystem: DefaultAppsSystem {
  func current(_ target: DefaultOpenTarget) -> URL? {
    switch target {
    case .scheme(let value): return URL(string: value + ":").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    case .contentType(let value): return UTType(value).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }
  }
  func candidates(_ target: DefaultOpenTarget) -> [URL] {
    switch target {
    case .scheme(let value): return URL(string: value + ":").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
    case .contentType(let value): return UTType(value).map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
    }
  }
  func set(_ application: URL, for target: DefaultOpenTarget) async throws {
    // Official AppKit API: protected defaults use Apple's own asynchronous consent dialog.
    switch target {
    case .scheme(let value): try await NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: value)
    case .contentType(let value):
      guard let type = UTType(value) else { throw CocoaError(.fileReadUnknown) }
      try await NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type)
    }
  }
}

struct DefaultOpenStatus: Equatable {
  var applications: [URL?]
  var application: DefaultApplication? { applications.first.flatMap { $0 }.map(DefaultApplication.init) }
  var mixed: Bool {
    guard let first = applications.first ?? nil else { return applications.contains { $0 != nil } }
    return applications.contains { !DefaultAppsRules.sameApplication(first, $0) }
  }
}

struct DefaultAppsChangeResult {
  let failures: [String], mismatches: [String]
  var verified: Bool { failures.isEmpty && mismatches.isEmpty }
}

enum DefaultAppsChange {
  @MainActor static func apply(_ application: URL, to item: DefaultOpenItem, system: any DefaultAppsSystem) async -> DefaultAppsChangeResult {
    var failures: [String] = []
    for target in item.targets {
      if DefaultAppsRules.sameApplication(system.current(target), application) { continue }
      do { try await system.set(application, for: target) }
      catch {
        // Read back even after an error: the OS may have applied the association.
        if DefaultAppsRules.sameApplication(system.current(target), application) { continue }
        let detail = error as NSError
        NSLog("Default application update failed: %@", String(reflecting: detail))
        let unconfirmed = detail.domain == NSCocoaErrorDomain && [NSFileReadUnknownError, NSUserCancelledError].contains(detail.code)
        failures.append(target.name + "：" + (unconfirmed ? "系统未确认，已保留原默认应用" : error.localizedDescription + "（\(detail.code)）"))
        break // Respect a declined system panel; do not ask again for the next scheme.
      }
    }
    let mismatches = item.targets.filter { !DefaultAppsRules.sameApplication(system.current($0), application) }.map(\.name)
    return .init(failures: failures, mismatches: mismatches)
  }
}

@MainActor final class DefaultAppsStore: ObservableObject {
  static let shared = DefaultAppsStore()
  @Published private(set) var customItems: [DefaultOpenItem] = []
  @Published private(set) var statuses: [String: DefaultOpenStatus] = [:]
  @Published private(set) var changing: String?
  @Published private(set) var refreshing = false
  @Published var error: String?
  @Published var message: String?
  private let system: any DefaultAppsSystem
  private let queue = DispatchQueue(label: "studio.lele.Chengguan.defaultApps", qos: .utility)
  private var revision = 0
  var items: [DefaultOpenItem] { DefaultOpenItem.builtIn + customItems }
  init(system: any DefaultAppsSystem = MacDefaultAppsSystem()) {
    self.system = system
    customItems = (UserDefaults.standard.stringArray(forKey: "defaultOpenExtensions") ?? []).compactMap { Self.item(for: $0) }
      .filter { candidate in !DefaultOpenItem.builtIn.contains { $0.id == candidate.id } }
  }
  nonisolated static func item(for text: String) -> DefaultOpenItem? {
    guard let ext = DefaultAppsRules.normalizedExtension(text), let type = UTType(filenameExtension: ext) else { return nil }
    return .init(id: "ext:" + ext, title: "." + ext, detail: type.localizedDescription ?? type.identifier, symbol: "doc", category: "自定", targets: [.contentType(type.identifier)], custom: true)
  }
  func add(_ text: String) -> String? {
    guard let item = Self.item(for: text) else { error = "请输入扩展名，例如 md、psd 或 epub。"; return nil }
    if let existing = items.first(where: { $0.id == item.id || $0.targets == item.targets }) {
      message = "已显示 " + existing.title; return existing.id
    }
    customItems.append(item); save(); refresh(force: true); return item.id
  }
  func remove(_ item: DefaultOpenItem) { customItems.removeAll { $0.id == item.id }; save() }
  private func save() { UserDefaults.standard.set(customItems.map { String($0.id.dropFirst(4)) }, forKey: "defaultOpenExtensions") }
  func refresh(force: Bool = false) {
    guard changing == nil, !refreshing || force else { return }
    revision += 1; let expected = revision, items = items, system = system
    refreshing = true
    queue.async {
      let next = Dictionary(uniqueKeysWithValues: items.map { ($0.id, DefaultOpenStatus(applications: $0.targets.map { system.current($0) })) })
      Task { @MainActor in
        guard self.revision == expected else { return }
        self.statuses = next; self.refreshing = false
      }
    }
  }
  func applications(for item: DefaultOpenItem) -> [DefaultApplication] {
    let eligibleTargets = item.id == "browser" ? Array(item.targets.prefix(2)) : item.targets
    let candidates = eligibleTargets.map { system.candidates($0) }
    let urls = candidates.flatMap { $0 }
    let current = statuses[item.id]?.applications.compactMap { $0 } ?? []
    return DefaultAppsRules.uniqueApplications(current + urls).filter { app in
      item.id != "browser" || candidates.allSatisfy { values in values.contains { Bundle(url: $0)?.bundleIdentifier == app.bundleID && app.bundleID != nil } }
    }.sorted {
      let selected = statuses[item.id]?.application?.url
      let lhs = DefaultAppsRules.sameApplication(selected, $0.url), rhs = DefaultAppsRules.sameApplication(selected, $1.url)
      return lhs != rhs ? lhs : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  func apply(_ application: DefaultApplication, to item: DefaultOpenItem) {
    guard changing == nil else { return }
    changing = item.id; error = nil; message = nil
    revision += 1; refreshing = false // Invalidate snapshots started before this write.
    Task {
      let result = await DefaultAppsChange.apply(application.url, to: item, system: system)
      changing = nil
      if result.verified { message = item.title + "已改为 " + application.name }
      else if !result.failures.isEmpty { error = "未完全更新：" + result.failures.joined(separator: "；") }
      else { error = "系统尚未确认 " + result.mismatches.joined(separator: "、") + " 的更改，请重试。" }
      refresh(force: true)
    }
  }
}
