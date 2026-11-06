import AppKit
import Combine
import Foundation

struct CareOperation: Identifiable, Codable {
  let id: UUID
  let time: Date
  let title: String
  var detail: String
  var items: [CareMovedFile]
}
struct CareMovedFile: Identifiable, Codable {
  let original: String
  let trash: String
  let device: UInt64
  let inode: UInt64
  let bytes: UInt64
  var restored = false
  var id: String { trash }
}

@MainActor final class CareStore: ObservableObject {
  static let shared = CareStore()
  @Published private(set) var scan = CareScan()
  @Published private(set) var scanning = false
  @Published private(set) var processing = false
  @Published var selection = Set<String>()
  @Published var protected: Set<String>
  @Published private(set) var operations: [CareOperation] = []
  @Published private(set) var message = "选择需要整理的内容"
  @Published private(set) var messageTime: Date?
  @Published private(set) var messagePage: CarePage = .clean
  @Published private(set) var currentAI = false
  @Published var filter = "全部"
  @Published var search = ""
  @Published private(set) var projectRoots: [URL]
  private var cancellation: CareCancellation?
  private var generation = UUID()
  private let defaults: UserDefaults
  private let historyURL: URL
  private let home: URL
  private let io = DispatchQueue(label: "studio.lele.Chengguan.care.persistence", qos: .utility)
  var selectedFiles: [CareFile] { scan.files.filter { selection.contains($0.id) } }
  var selectedBytes: UInt64 { selectedFiles.reduce(0) { $0 + $1.bytes } }
  var totalBytes: UInt64 { scan.files.reduce(0) { $0 + $1.bytes } }
  var feed: [AIQuickMessage] {
    guard let time = messageTime else { return [] }
    return [AIQuickMessage(id: "care-latest", time: time, title: message, detail: "", symbol: processing || scanning ? "arrow.triangle.2.circlepath" : "checkmark.circle", priority: processing || scanning ? 1 : 0, carePage: messagePage)]
  }
  var visibleFiles: [CareFile] {
    scan.files.filter { (filter == "全部" || $0.kind.rawValue == filter) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
  }
  init(defaults: UserDefaults = .standard, directory: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.defaults = defaults
    self.home = home
    protected = Set(defaults.stringArray(forKey: "care.protected") ?? [])
    projectRoots = (defaults.stringArray(forKey: "care.projectRoots") ?? []).map { URL(fileURLWithPath: $0) }
    let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chengguan")
    historyURL = base.appendingPathComponent("care-history.json")
    if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([CareOperation].self, from: data) { operations = saved }
  }
  func announce(_ value: String, page: CarePage? = nil) { message = value; messageTime = Date(); if let page { messagePage = page } }
  func toggle(_ file: CareFile) {
    guard !processing, !file.partial, !isProtected(file) else { return }
    if !selection.insert(file.id).inserted { selection.remove(file.id) }
  }
  func isProtected(_ file: CareFile) -> Bool {
    protected.contains { file.path == $0 || CareScanner.inside(file.url, URL(fileURLWithPath: $0)) || CareScanner.inside(URL(fileURLWithPath: $0), file.url) }
  }
  func reviewReason(_ file: CareFile) -> String? {
    let running = NSWorkspace.shared.runningApplications
    return CareSafety.reason(file, home: home, protected: protected,
      runningIDs: Set(running.compactMap(\.bundleIdentifier)), selfPath: Bundle.main.bundlePath,
      runningPaths: Set(running.compactMap { $0.bundleURL?.path }))
  }
  func protect(_ file: CareFile) { protected.insert(file.path); selection.remove(file.id); defaults.set(Array(protected).sorted(), forKey: "care.protected") }
  func unprotect(_ path: String) { protected.remove(path); defaults.set(Array(protected).sorted(), forKey: "care.protected") }
  func addProjectRoot() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
    panel.message = "只扫描你选择的项目目录"
    guard panel.runModal() == .OK else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser
    projectRoots = Array(Set(projectRoots + panel.urls.filter { CareScanner.inside($0, home) && !CareScanner.hasSymlink($0) })).sorted { $0.path < $1.path }
    defaults.set(projectRoots.map(\.path), forKey: "care.projectRoots")
  }
  func removeRoot(_ root: URL) { projectRoots.removeAll { $0 == root }; defaults.set(projectRoots.map(\.path), forKey: "care.projectRoots") }
  func start(ai: Bool) {
    guard !processing else { return }
    cancellation?.cancel()
    let token = CareCancellation(), id = UUID(), roots = projectRoots, protected = protected, home = home
    cancellation = token; generation = id; scanning = true; currentAI = ai; selection = []; scan = CareScan(); filter = "全部"; search = ""
    announce(ai ? "正在检查 AI 缓存与旧会话…" : "正在扫描可整理内容…", page: ai ? .ai : .clean)
    Task {
      let result = await Task.detached(priority: .utility) {
        CareScanner.scan(home: home, aiOnly: ai, projectRoots: roots, protected: protected, token: token)
      }.value
      guard generation == id else { return }
      scan = result; scanning = false
      announce("发现 \(result.files.count) 项 · \(Format.bytes(totalBytes))" + (result.partial ? " · 部分扫描未完成" : "") + (result.skipped > 0 ? " · \(result.skipped) 项受保护或无法读取" : ""))
    }
  }
  func cancel() { cancellation?.cancel(); announce("正在停止扫描…") }
  func trash(_ input: [CareFile], title: String = "整理") {
    guard !processing else { return }
    let files = CareSafety.nonOverlapping(input)
    guard !files.isEmpty else { return }
    processing = true; announce("正在移到废纸篓…", page: .history)
    let protected = protected, running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    let own = Bundle.main.bundlePath, home = home
    Task {
      let result = await Task.detached(priority: .utility) { () -> (CareOperation, Set<String>) in
        var moved: [CareMovedFile] = [], errors: [String] = [], completed = Set<String>()
        for file in files {
          let activeApps = NSWorkspace.shared.runningApplications
          let currentlyRunning = Set(activeApps.compactMap(\.bundleIdentifier)).union(running)
          let activePaths = Set(activeApps.compactMap { $0.bundleURL?.path }).union(runningPaths)
          if let reason = CareSafety.reason(file, home: home, protected: protected, runningIDs: currentlyRunning, selfPath: own, runningPaths: activePaths) {
            errors.append(file.name + "：" + reason); continue
          }
          guard let rechecked = CareScanner.measure(file.url, kind: file.kind, owner: file.owner, seconds: 8),
            !rechecked.partial, rechecked.bytes == file.bytes, rechecked.newestModification == file.newestModification else {
            errors.append(file.name + "：内容已变化或无法完整复查，请重新扫描"); continue
          }
          var trashURL: NSURL?
          do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: &trashURL)
            guard let trash = trashURL as URL?, let id = CareScanner.fingerprint(trash) else { errors.append(file.name + "：已移走，恢复位置未报告，请在废纸篓查看"); completed.insert(file.id); continue }
            moved.append(CareMovedFile(original: file.path, trash: trash.path, device: id.0, inode: id.1, bytes: file.bytes))
            completed.insert(file.id)
          } catch { errors.append(file.name + "：" + error.localizedDescription) }
        }
        let detail = "已移走 \(completed.count) 项 · \(Format.bytes(moved.reduce(0) { $0 + $1.bytes }))" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
        return (CareOperation(id: UUID(), time: Date(), title: title, detail: detail, items: moved), completed)
      }.value
      operations.insert(result.0, at: 0); operations = Array(operations.prefix(100)); persist()
      scan.files.removeAll { result.1.contains($0.id) }; selection.subtract(result.1)
      processing = false; announce(result.0.detail.components(separatedBy: "\n").first ?? result.0.detail)
    }
  }
  func restore(operationID: UUID) {
    guard !processing, let index = operations.firstIndex(where: { $0.id == operationID }) else { return }
    let items = operations[index].items.filter { !$0.restored }
    guard !items.isEmpty else { return }
    processing = true; announce("正在恢复…", page: .history)
    Task {
      let result = await Task.detached(priority: .utility) { () -> (Set<String>, [String]) in
        var restored = Set<String>(), errors: [String] = []
        for file in items {
          let source = URL(fileURLWithPath: file.trash), target = URL(fileURLWithPath: file.original)
          // Trash location is returned by macOS, not invented from a filename. Validate its identity.
          guard source.pathComponents.contains(".Trash") || source.pathComponents.contains(".Trashes"),
            let identity = CareScanner.fingerprint(source), identity.0 == file.device, identity.1 == file.inode,
            !CareScanner.hasSymlink(source), !CareScanner.hasSymlink(target.deletingLastPathComponent()),
            !FileManager.default.fileExists(atPath: target.path) else { errors.append(target.lastPathComponent + "：原位置已占用或文件已变化"); continue }
          do { try FileManager.default.moveItem(at: source, to: target); restored.insert(file.id) }
          catch { errors.append(target.lastPathComponent + "：" + error.localizedDescription) }
        }
        return (restored, errors)
      }.value
      if let i = operations.firstIndex(where: { $0.id == operationID }) {
        for j in operations[i].items.indices where result.0.contains(operations[i].items[j].id) { operations[i].items[j].restored = true }
        operations[i].detail += "\n已恢复 \(result.0.count) 项" + (result.1.isEmpty ? "" : "\n" + result.1.joined(separator: "\n"))
      }
      persist(); processing = false; announce("已恢复 \(result.0.count) 项" + (result.1.isEmpty ? "" : " · 部分项目需在废纸篓查看"))
    }
  }
  func record(_ title: String, detail: String) {
    operations.insert(CareOperation(id: UUID(), time: Date(), title: title, detail: detail, items: []), at: 0)
    operations = Array(operations.prefix(100)); persist(); announce(title + " · " + detail.components(separatedBy: "\n")[0], page: .history)
  }
  private func persist() {
    let records = operations, url = historyURL
    io.async {
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records); try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      } catch { DispatchQueue.main.async { self.announce("记录保存失败：" + error.localizedDescription) } }
    }
  }
  func flush() async { await withCheckedContinuation { continuation in io.async { continuation.resume() } } }
}

struct SpaceEntry: Identifiable, Sendable {
  let file: CareFile
  let directory: Bool
  var id: String { file.id }
}

@MainActor final class SpaceExplorer: ObservableObject {
  static let shared = SpaceExplorer()
  @Published private(set) var path = FileManager.default.homeDirectoryForCurrentUser
  @Published private(set) var entries: [SpaceEntry] = []
  @Published private(set) var scanning = false
  @Published private(set) var partial = false
  @Published private(set) var message = ""
  @Published var selected: String?
  private var token = CareCancellation()
  private var generation = UUID()
  var total: UInt64 { entries.reduce(0) { $0 + $1.file.bytes } }
  func open(_ url: URL) {
    guard !CareScanner.hasSymlink(url) else { message = "符号链接仅供在访达中查看"; return }
    token.cancel(); token = CareCancellation()
    let token = token, id = UUID(); generation = id; scanning = true; entries = []; selected = nil; path = url; message = "正在计算已分配空间…"
    Task {
      let result = await Task.detached(priority: .utility) { () -> ([SpaceEntry], Bool, String?) in
        do {
          let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(CareScanner.keys), options: [])
          var entries: [SpaceEntry] = [], partial = false
          let deadline = ProcessInfo.processInfo.systemUptime + 30
          var lastProgress = ProcessInfo.processInfo.systemUptime
          for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if token.cancelled || ProcessInfo.processInfo.systemUptime > deadline { partial = true; break }
            let v = try? child.resourceValues(forKeys: CareScanner.keys)
            guard v?.isSymbolicLink != true, v?.isUbiquitousItem != true else { partial = true; continue }
            if let file = CareScanner.measure(child, kind: .file, seconds: 1, token: token) {
              entries.append(SpaceEntry(file: file, directory: v?.isDirectory == true)); partial = partial || file.partial
            } else { partial = true }
            if ProcessInfo.processInfo.systemUptime - lastProgress > 0.4 {
              lastProgress = ProcessInfo.processInfo.systemUptime
              let snapshot = entries.sorted { $0.file.bytes > $1.file.bytes }
              await MainActor.run {
                guard self.generation == id else { return }
                self.entries = snapshot
                self.message = "正在计算 · \(snapshot.count) 项"
              }
            }
          }
          return (entries.sorted { $0.file.bytes > $1.file.bytes }, partial, nil)
        } catch { return ([], true, error.localizedDescription) }
      }.value
      guard generation == id else { return }
      entries = result.0; partial = result.1; scanning = false
      message = result.2 ?? "\(entries.count) 项 · \(Format.bytes(total))" + (partial ? " · 部分未读取，可进入目录继续扫描" : " · 已分配空间")
    }
  }
  func cancel() { token.cancel() }
  func choose() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }
}

struct SpaceTile: Identifiable {
  let index: Int
  let rect: CGRect
  var id: Int { index }
  static func layout(_ weights: [Double], in rect: CGRect) -> [SpaceTile] {
    let positive = weights.enumerated().filter { $0.element > 0 && $0.element.isFinite }
    func split(_ items: [(offset: Int, element: Double)], _ area: CGRect) -> [SpaceTile] {
      guard let first = items.first, area.width > 0, area.height > 0 else { return [] }
      if items.count == 1 { return [SpaceTile(index: first.offset, rect: area)] }
      let total = items.reduce(0) { $0 + $1.element }
      var accumulated = 0.0, midpoint = 1
      for i in 0..<(items.count - 1) {
        accumulated += items[i].element; midpoint = i + 1
        if accumulated >= total / 2 { break }
      }
      let left = Array(items.prefix(midpoint)), right = Array(items.dropFirst(midpoint))
      let fraction = left.reduce(0) { $0 + $1.element } / total
      if area.width >= area.height {
        let w = area.width * fraction
        return split(left, CGRect(x: area.minX, y: area.minY, width: w, height: area.height)) + split(right, CGRect(x: area.minX + w, y: area.minY, width: area.width - w, height: area.height))
      }
      let h = area.height * fraction
      return split(left, CGRect(x: area.minX, y: area.minY, width: area.width, height: h)) + split(right, CGRect(x: area.minX, y: area.minY + h, width: area.width, height: area.height - h))
    }
    return split(positive, rect)
  }
}
