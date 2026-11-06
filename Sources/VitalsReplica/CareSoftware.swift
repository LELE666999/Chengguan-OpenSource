import AppKit
import Combine
import CoreServices
import Foundation

struct CareApp: Identifiable, Sendable {
  let path: String
  let bundleID: String
  let name: String
  let version: String
  let feed: URL?
  let appStore: Bool
  let installed: Date?
  let protected: Bool
  var indexedBytes: UInt64? = nil
  var lastUsed: Date? = nil
  var id: String { path }
  var source: String { appStore ? "App Store" : feed == nil ? "独立安装" : "Sparkle" }
}
struct CareStartup: Identifiable, Sendable {
  let path: String
  let label: String
  let user: Bool
  var id: String { path }
}
struct CareAppUpdate: Equatable {
  let text: String
  var url: URL?
}

enum CareSoftwareScanner {
  static func apps(roots: [URL]) -> [CareApp] {
    var found: [CareApp] = []
    for root in roots {
      guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .addedToDirectoryDateKey], options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in iterator {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .addedToDirectoryDateKey])
        if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
        if url.pathComponents.count - root.pathComponents.count > 3 { iterator.skipDescendants(); continue }
        guard url.pathExtension == "app" else { continue }
        iterator.skipDescendants()
        guard let info = Bundle(url: url)?.infoDictionary else { continue }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)).flatMap { validFeed($0) ? $0 : nil }
        let metadata = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
        let size = metadata.flatMap { MDItemCopyAttribute($0, kMDItemFSSize) as? NSNumber }?.uint64Value
        let used = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        found.append(CareApp(path: url.path, bundleID: id, name: name,
          version: info["CFBundleShortVersionString"] as? String ?? "—", feed: feed,
          appStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
          installed: values?.addedToDirectoryDate,
          protected: id.isEmpty || id.hasPrefix("com.apple.") || id == "studio.lele.Chengguan" || url.path.contains("Input Methods"), indexedBytes: size, lastUsed: used))
      }
    }
    return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  static func validFeed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
      !host.isEmpty, host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return false }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 && (parts[0] == 127 || parts[0] == 10 || parts[0] == 0 || parts[0] == 169 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))) { return false }
    return !host.contains(":")
  }
  static func associated(_ app: CareApp, apps: [CareApp], home: URL, token: CareCancellation = CareCancellation(), deadline: Date = .distantFuture) -> [CareFile] {
    guard app.bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{2,200}$", options: .regularExpression) != nil,
      apps.filter({ $0.bundleID == app.bundleID }).count == 1 else { return [] }
    var paths: [(String, CareFile.Kind)] = [
      ("Library/Caches/" + app.bundleID, .cache),
      ("Library/Preferences/" + app.bundleID + ".plist", .data),
      ("Library/Saved Application State/" + app.bundleID + ".savedState", .data),
      ("Library/Application Support/" + app.bundleID, .data)
    ]
    if !app.name.contains("/"), app.name.count > 2, apps.filter({ $0.name == app.name }).count == 1 { paths.append(("Library/Application Support/" + app.name, .data)) }
    return paths.compactMap { path, kind in
      guard !token.cancelled, Date() < deadline, FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) else { return nil }
      return CareScanner.measure(home.appendingPathComponent(path), kind: kind, owner: app.bundleID,
        note: kind == .cache ? "可重新生成" : "包含个人设置或数据 · 默认保留", seconds: min(4, deadline.timeIntervalSinceNow), token: token)
    }
  }
  static func startup(home: URL) -> [CareStartup] {
    [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")].flatMap { root in
      let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
      return urls.filter { $0.pathExtension == "plist" && !CareScanner.hasSymlink($0) }.map { url in
        // Label only; never display ProgramArguments/environment, which can contain secrets.
        let plist = (try? Data(contentsOf: url)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        return CareStartup(path: url.path, label: plist?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent, user: root.path.hasPrefix(home.path + "/"))
      }
    }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }
}

final class CareAppcast: NSObject, XMLParserDelegate {
  struct Release { let version: String; let url: URL?; var minimumOS = ""; var architectures = ""; var channel = ""; var delta = false }
  var releases: [Release] = []
  private var version = ""
  private var shortVersion = ""
  private var minimumOS = ""
  private var architectures = ""
  private var channel = ""
  private var delta = false
  private var url: URL?
  private var element = ""
  private var text = ""
  private var deltaDepth = 0
  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
    element = elementName; text = ""
    if elementName == "sparkle:deltas" { deltaDepth += 1 }
    if deltaDepth > 0 { return }
    if elementName == "item" { version = ""; shortVersion = ""; minimumOS = ""; architectures = ""; channel = ""; delta = false; url = nil }
    if elementName == "enclosure" {
      version = attributes["sparkle:version"] ?? version
      shortVersion = attributes["sparkle:shortVersionString"] ?? shortVersion
      architectures = attributes["sparkle:cpuArchitecture"] ?? architectures
      delta = delta || attributes["sparkle:deltaFrom"] != nil || attributes["sparkle:installationType"] == "delta"
      url = attributes["url"].flatMap(URL.init(string:)).flatMap { CareSoftwareScanner.validFeed($0) ? $0 : nil }
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    if elementName == "sparkle:deltas" { deltaDepth = max(0, deltaDepth - 1); text = ""; return }
    if deltaDepth > 0 { text = ""; return }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementName == "sparkle:shortVersionString" { shortVersion = value }
    if elementName == "sparkle:version" { version = value }
    if elementName == "sparkle:minimumSystemVersion" { minimumOS = value }
    if elementName == "sparkle:channel" { channel = value }
    if elementName == "item", !version.isEmpty || !shortVersion.isEmpty {
      releases.append(Release(version: shortVersion.isEmpty ? version : shortVersion, url: url, minimumOS: minimumOS, architectures: architectures, channel: channel, delta: delta))
    }
    text = ""
  }
  static func parse(_ data: Data) -> [Release] {
    guard data.count <= 2_000_000 else { return [] }
    let delegate = CareAppcast(), parser = XMLParser(data: data); parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    return parser.parse() ? delegate.releases : []
  }
  static func compatible(_ releases: [Release], os: String, architecture: String) -> [Release] {
    releases.filter {
      !$0.delta && ($0.channel.isEmpty || $0.channel == "stable")
        && ($0.minimumOS.isEmpty || $0.minimumOS.compare(os, options: .numeric) != .orderedDescending)
        && ($0.architectures.isEmpty || $0.architectures.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(architecture))
    }
  }
}

private final class CareUpdateRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.map(CareSoftwareScanner.validFeed) == true ? request : nil)
  }
}

@MainActor final class CareSoftwareStore: ObservableObject {
  static let shared = CareSoftwareStore()
  @Published private(set) var apps: [CareApp] = []
  @Published private(set) var startup: [CareStartup] = []
  @Published private(set) var loading = false
  @Published private(set) var reviewing = false
  @Published private(set) var files: [CareFile] = []
  @Published var selected = Set<String>()
  @Published var appSelection = Set<String>()
  @Published var reviewOpen = false
  @Published private(set) var reviewApps: [CareApp] = []
  private var reviewGeneration = UUID()
  private var reviewToken: CareCancellation?
  init(apps: [CareApp] = []) { self.apps = apps }
  var selectedApps: [CareApp] { apps.filter { appSelection.contains($0.id) } }
  var reviewSelection: [CareFile] { files.filter { selected.contains($0.id) } }
  func toggleApp(_ app: CareApp) {
    guard !app.protected else { return }
    if !appSelection.insert(app.id).inserted { appSelection.remove(app.id) }
  }
  func selectVisible() { appSelection.formUnion(visibleApps.filter { !$0.protected }.map(\.id)) }

  @Published var search = ""
  @Published var mode = "应用"
  @Published var sort = "名称"
  @Published private(set) var message = ""
  @Published private(set) var updates: [String: CareAppUpdate] = [:]
  @Published private(set) var checking = Set<String>()
  var visibleApps: [CareApp] {
    apps.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (mode != "更新" || $0.feed != nil || $0.appStore) }
      .sorted {
        switch sort {
        case "安装时间": return ($0.installed ?? .distantPast) > ($1.installed ?? .distantPast)
        case "最近使用": return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
        case "占用空间": return ($0.indexedBytes ?? 0) > ($1.indexedBytes ?? 0)
        default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
      }
  }
  func refresh() {
    guard !loading else { return }; loading = true
    Task {
      let result = await Task.detached(priority: .utility) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (CareSoftwareScanner.apps(roots: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]), CareSoftwareScanner.startup(home: home))
      }.value
      apps = result.0; startup = result.1; appSelection.formIntersection(Set(apps.map(\.id))); loading = false
    }
  }
  func review(_ selection: [CareApp]) {
    cancelReview()
    let targets = selection.filter { !$0.protected }
    guard !targets.isEmpty else { return }
    let token = CareCancellation(), generation = UUID(), inventory = apps
    reviewToken = token; reviewGeneration = generation; reviewApps = targets
    reviewOpen = true; reviewing = true; files = []; selected = []; message = "正在核对 \(targets.count) 个 App…"
    Task {
      let result = await Task.detached(priority: .utility) { () -> ([CareFile], Int) in
        let home = FileManager.default.homeDirectoryForCurrentUser, deadline = Date().addingTimeInterval(45)
        var result: [CareFile] = [], checked = 0
        for app in targets {
          guard !token.cancelled, Date() < deadline else { break }
          if let main = CareScanner.measure(URL(fileURLWithPath: app.path), kind: .application, owner: app.bundleID, seconds: min(6, deadline.timeIntervalSinceNow), token: token) {
            result.append(main)
          }
          checked += 1
          let current = checked
          await MainActor.run {
            guard self.reviewGeneration == generation, self.reviewOpen else { return }
            self.message = "正在核对 \(current)/\(targets.count) · " + app.name
          }
        }
        // App bundles take priority. Personal data is always opt-in.
        for app in targets {
          guard !token.cancelled, Date() < deadline else { break }
          result += CareSoftwareScanner.associated(app, apps: inventory, home: home, token: token, deadline: deadline)
        }
        return (CareSafety.nonOverlapping(result), checked)
      }.value
      guard reviewGeneration == generation, reviewOpen else { return }
      files = result.0; reviewing = false
      selected = Set(files.filter { $0.kind == .application && !$0.partial && CareStore.shared.reviewReason($0) == nil }.map(\.id))
      message = result.1 < targets.count ? "已核对 \(result.1)/\(targets.count) 个 App · 其余可分批审阅" : "个人数据默认保留 · 运行中的 App 请先退出"
    }
  }
  func cancelReview() { reviewToken?.cancel(); reviewGeneration = UUID(); reviewing = false }
  func toggle(_ file: CareFile) {
    guard !reviewing, CareStore.shared.reviewReason(file) == nil else { return }
    if !selected.insert(file.id).inserted { selected.remove(file.id) }
  }
  func check(_ app: CareApp) {
    guard let feed = app.feed, !checking.contains(app.id) else { return }
    checking.insert(app.id)
    Task {
      defer { checking.remove(app.id) }
      do {
        var request = URLRequest(url: feed); request.timeoutInterval = 12; request.setValue("Chengguan/0.7", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: CareUpdateRedirectGuard(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let finalURL = http.url, CareSoftwareScanner.validFeed(finalURL) else { updates[app.id] = CareAppUpdate(text: "更新源暂不可读"); return }
        guard response.expectedContentLength <= 2_000_000 else { updates[app.id] = CareAppUpdate(text: "更新目录过大，请在 App 内检查"); return }
        var data = Data()
        for try await byte in stream {
          guard data.count < 2_000_000 else { updates[app.id] = CareAppUpdate(text: "更新目录过大，请在 App 内检查"); return }
          data.append(byte)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let releases = CareAppcast.compatible(CareAppcast.parse(data), os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture)
        guard let latest = releases.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) else { updates[app.id] = CareAppUpdate(text: "请在 App 内检查兼容更新"); return }
        let newer = latest.version.compare(app.version, options: .numeric) == .orderedDescending
        updates[app.id] = CareAppUpdate(text: newer ? "可用版本 " + latest.version : "未发现更高版本", url: newer ? latest.url : nil)
      } catch { updates[app.id] = CareAppUpdate(text: "检查失败，请稍后重试") }
    }
  }
}

struct MaintenanceTask: Identifiable {
  let id: String
  let title: String
  let detail: String
  let command: String?
  let arguments: [String]
  static let all = [
    Self(id: "quicklook", title: "快速预览", detail: "重建缩略图缓存", command: "/usr/bin/qlmanage", arguments: ["-r", "cache"]),
    Self(id: "plugins", title: "预览插件", detail: "重新加载 Quick Look 生成器", command: "/usr/bin/qlmanage", arguments: ["-r"]),
    Self(id: "dns", title: "本地 DNS", detail: "刷新目录服务缓存", command: "/usr/bin/dscacheutil", arguments: ["-flushcache"]),
    Self(id: "spotlight", title: "Spotlight", detail: "检查索引状态", command: "/usr/bin/mdutil", arguments: ["-s", "/"]),
    Self(id: "volume", title: "磁盘验证", detail: "只读检查启动卷 · 可能需要数分钟", command: "/usr/sbin/diskutil", arguments: ["verifyVolume", "/"])
  ]
}
@MainActor final class MaintenanceStore: ObservableObject {
  static let shared = MaintenanceStore()
  @Published var selection: Set<String> = ["quicklook", "plugins", "dns", "spotlight"]
  @Published private(set) var results: [String: String] = [:]
  @Published private(set) var running = false
  func run() {
    guard !running, !selection.isEmpty else { return }
    running = true; results = [:]
    let tasks = MaintenanceTask.all.filter { selection.contains($0.id) }
    Task {
      for task in tasks {
        results[task.id] = "执行中…"
        let result = await Task.detached(priority: .utility) {
          guard let path = task.command, FileManager.default.isExecutableFile(atPath: path) else { return "已跳过 · 此系统不可用" }
          let output = Command.run(path, task.arguments, timeout: task.id == "volume" ? 180 : 12, includeError: true)
          return output.status == 0 ? "已完成\n" + String(output.text.prefix(1200)) : "未完成（\(output.status)）\n" + String(output.text.prefix(500))
        }.value
        results[task.id] = result
      }
      running = false
      let completed = results.values.filter { $0.hasPrefix("已完成") }.count
      CareStore.shared.record("系统维护", detail: "\(completed) 项完成 · \(tasks.count - completed) 项未完成\n" + tasks.map { $0.title + "：" + (results[$0.id] ?? "未执行") }.joined(separator: "\n"))
    }
  }
}
