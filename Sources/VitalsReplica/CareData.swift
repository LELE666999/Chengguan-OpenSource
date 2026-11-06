import Foundation
import Darwin

enum CarePage: String, CaseIterable, Identifiable {
  case clean = "清理", ai = "AI 数据", software = "软件", space = "空间", maintain = "维护", history = "记录"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .clean: "sparkles.rectangle.stack"
    case .ai: "sparkles"
    case .software: "square.stack.3d.up"
    case .space: "square.grid.3x3.square"
    case .maintain: "wrench.and.screwdriver"
    case .history: "clock.arrow.circlepath"
    }
  }
}

struct CareFile: Identifiable, Codable, Equatable {
  enum Kind: String, Codable { case cache = "缓存", log = "日志", developer = "构建", installer = "安装包", session = "旧会话", application = "应用", data = "个人数据", file = "文件" }
  let path: String
  let kind: Kind
  let bytes: UInt64
  let partial: Bool
  let device: UInt64
  let inode: UInt64
  var owner: String? = nil
  var note = ""
  var newestModification: Date? = nil
  var id: String { path }
  var url: URL { URL(fileURLWithPath: path) }
  var name: String { url.lastPathComponent }
  var sizeText: String { (partial ? "≥ " : "") + Format.bytes(bytes) }
}

final class CareCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  func cancel() { lock.lock(); stopped = true; lock.unlock() }
  var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

struct CareScan: Sendable {
  var files: [CareFile] = []
  var skipped = 0
  var partial = false
  var completedAt: Date?
}

/// Original native implementation. Only explicit candidates are eligible for review.
/// No shell interpolation, symlink traversal, cloud materialization, or silent permanent removal.
enum CareScanner {
  static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    .isUbiquitousItemKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]

  static func fingerprint(_ url: URL) -> (UInt64, UInt64)? {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { return nil }
    return (UInt64(st.st_dev), UInt64(st.st_ino))
  }
  static func inside(_ child: URL, _ parent: URL) -> Bool {
    let c = child.standardizedFileURL.path, p = parent.standardizedFileURL.path
    return c != p && c.hasPrefix(p == "/" ? "/" : p + "/")
  }
  static func hasSymlink(_ url: URL) -> Bool {
    var current = url.standardizedFileURL
    while current.path != "/" {
      var st = stat()
      if lstat(current.path, &st) != 0 { return true }
      if st.st_mode & S_IFMT == S_IFLNK {
        // macOS preserves /var and /tmp in URL canonicalization. Only accept the
        // immutable system aliases to their exact /private counterpart.
        let expected = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
        guard let target = expected[current.path], let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path),
          actual == target || actual == "/" + target else { return true }
      }
      current.deleteLastPathComponent()
    }
    return false
  }
  static func measure(_ url: URL, kind: CareFile.Kind, owner: String? = nil, note: String = "",
                      seconds: Double = 2, token: CareCancellation = CareCancellation()) -> CareFile? {
    guard !hasSymlink(url), let identity = fingerprint(url), let values = try? url.resourceValues(forKeys: keys),
      values.isUbiquitousItem != true else { return nil }
    var bytes: UInt64 = 0, partial = false, count = 0
    var newest = values.contentModificationDate
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    func size(_ v: URLResourceValues) -> UInt64 { UInt64(max(0, v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)) }
    if values.isDirectory == true {
      guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
        options: [], errorHandler: { _, _ in partial = true; return true }) else { return nil }
      var seen = Set<String>()
      for case let file as URL in iterator {
        count += 1
        if token.cancelled || count > 80_000 || ProcessInfo.processInfo.systemUptime > deadline { partial = true; break }
        guard let v = try? file.resourceValues(forKeys: keys) else { partial = true; continue }
        if let date = v.contentModificationDate { newest = max(newest ?? date, date) }
        if v.isSymbolicLink == true { iterator.skipDescendants(); continue }
        if v.isUbiquitousItem == true { iterator.skipDescendants(); partial = true; continue }
        if v.isRegularFile == true, let id = fingerprint(file), seen.insert("\(id.0):\(id.1)").inserted { bytes += size(v) }
      }
    } else if values.isRegularFile == true { bytes = size(values) }
    else { return nil }
    return CareFile(path: url.standardizedFileURL.path, kind: kind, bytes: bytes, partial: partial,
      device: identity.0, inode: identity.1, owner: owner, note: note, newestModification: newest)
  }

  static func scan(home: URL, aiOnly: Bool, projectRoots: [URL], protected: Set<String>,
                   now: Date = Date(), token: CareCancellation) -> CareScan {
    var output = CareScan()
    let fm = FileManager.default, deadline = ProcessInfo.processInfo.systemUptime + 45
    func children(_ path: String) -> [URL] {
      let url = home.appendingPathComponent(path)
      guard !hasSymlink(url) else { return [] }
      do { return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) }
      catch { if fm.fileExists(atPath: url.path) { output.skipped += 1 }; return [] }
    }
    func add(_ url: URL, _ kind: CareFile.Kind, owner: String? = nil, age: Double = 0, note: String = "") {
      guard !token.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { output.partial = true; return }
      guard !protected.contains(where: { url.path == $0 || inside(url, URL(fileURLWithPath: $0)) }) else { output.skipped += 1; return }
      if age > 0 {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
          now.timeIntervalSince(modified) >= age else { return }
      }
      if let file = measure(url, kind: kind, owner: owner, note: note, token: token), file.bytes > 0 {
        if age > 0, let newest = file.newestModification, now.timeIntervalSince(newest) < age { return }
        output.files.append(file); output.partial = output.partial || file.partial
      } else { output.skipped += 1 }
    }
    let aiNames = ["codex", "claude", "cursor", "chatgpt", "openai", "anthropic", "grok", "codebuddy", "windsurf", "kiro", "trae", "qoder", "gemini", "ollama", "lmstudio"]
    // Cache containers only. App Support, browser profiles, Keychain and model weights are excluded.
    for file in children("Library/Caches") {
      let name = file.lastPathComponent
      if name.hasPrefix("studio.lele.Chengguan") { continue }
      if aiOnly && !aiNames.contains(where: { name.lowercased().contains($0) }) { continue }
      let bundleLike = name.range(of: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+){2,}$", options: .regularExpression) != nil
      add(file, .cache, owner: bundleLike ? name : nil, age: bundleLike ? 0 : 7 * 86400, note: "退出相关 App 后可重新生成")
    }
    if aiOnly {
      for path in [".codex/sessions", ".claude/projects"] {
        let root = home.appendingPathComponent(path)
        guard !hasSymlink(root), let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsPackageDescendants]) else { continue }
        var count = 0
        for case let url as URL in iterator {
          count += 1
          if count > 30_000 || token.cancelled || ProcessInfo.processInfo.systemUptime > deadline { output.partial = true; break }
          if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
          if url.pathExtension == "jsonl" { add(url, .session, age: 90 * 86400, note: "90 天前的会话 · 移走后对应历史和用量统计会减少") }
        }
      }
    } else {
      let logs = home.appendingPathComponent("Library/Logs")
      if !hasSymlink(logs), let iterator = fm.enumerator(at: logs, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants]) {
        var count = 0
        for case let file as URL in iterator {
          count += 1
          if token.cancelled || count > 20_000 || ProcessInfo.processInfo.systemUptime > deadline { output.partial = true; break }
          let v = try? file.resourceValues(forKeys: keys)
          if v?.isSymbolicLink == true { iterator.skipDescendants(); continue }
          if v?.isRegularFile == true { add(file, .log, age: 30 * 86400, note: "30 天前的日志") }
        }
      }
      for file in children("Downloads") where ["dmg", "pkg", "mpkg", "iso"].contains(file.pathExtension.lowercased()) {
        add(file, .installer, age: 7 * 86400, note: "保留已安装 App · 移走安装文件")
      }
      for path in ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives"] {
        for file in children(path) { add(file, .developer, age: 30 * 86400, note: path.hasSuffix("Archives") ? "归档含发布与符号文件 · 请确认已有备份" : "30 天未更新 · 下次构建重新生成") }
      }
      for root in projectRoots where inside(root, home) && !hasSymlink(root) {
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
        // Read .build/.next explicitly at each project because the enumerator skips hidden entries.
        func buildCandidates(_ dir: URL) {
          let manifests = ["Package.swift", "package.json", "Cargo.toml", "build.gradle", "pom.xml"]
          guard manifests.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) else { return }
          for name in ["node_modules", ".next", ".build", "target", "build", "dist"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { add(url, .developer, age: 14 * 86400, note: "构建或依赖目录 · 需要重新构建 / 安装依赖") }
          }
        }
        buildCandidates(root)
        for case let dir as URL in iterator {
          if token.cancelled || ProcessInfo.processInfo.systemUptime > deadline { output.partial = true; break }
          let depth = dir.pathComponents.count - root.pathComponents.count
          let v = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
          if v?.isSymbolicLink == true || depth > 4 || ["node_modules", "target", "build", "dist"].contains(dir.lastPathComponent) { iterator.skipDescendants(); continue }
          if v?.isDirectory == true { buildCandidates(dir) }
        }
      }
    }
    var seen = Set<String>()
    output.files = output.files.filter { seen.insert($0.path).inserted }.sorted { $0.bytes > $1.bytes }
    output.partial = output.partial || token.cancelled
    output.completedAt = now
    return output
  }
}

enum CareSafety {
  static func reason(_ file: CareFile, home: URL, protected: Set<String>, runningIDs: Set<String>, selfPath: String, runningPaths: Set<String> = []) -> String? {
    guard !file.partial else { return "扫描未完成，重新扫描后再处理" }
    let url = file.url.standardizedFileURL
    guard !CareScanner.hasSymlink(url), let identity = CareScanner.fingerprint(url), identity.0 == file.device, identity.1 == file.inode else { return "路径已变化，请重新扫描" }
    if let previous = file.newestModification, let current = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      current > previous.addingTimeInterval(0.01) { return "内容已变化，请重新扫描" }
    if protected.contains(where: { url.path == $0 || CareScanner.inside(url, URL(fileURLWithPath: $0)) || CareScanner.inside(URL(fileURLWithPath: $0), url) }) { return "包含受保护的项目" }
    if url.path == selfPath || CareScanner.inside(URL(fileURLWithPath: selfPath), url) || url.lastPathComponent == "澄观.app" { return "当前 App 受保护" }
    if runningPaths.contains(where: { url.path == $0 || CareScanner.inside(URL(fileURLWithPath: $0), url) }) { return "请先退出相关 App" }
    if let owner = file.owner, runningIDs.contains(owner) { return "请先退出相关 App" }
    let allowed: Bool
    if file.kind == .application {
      allowed = (CareScanner.inside(url, URL(fileURLWithPath: "/Applications")) || CareScanner.inside(url, home.appendingPathComponent("Applications")))
        && url.pathExtension == "app" && !url.path.contains("/Contents/")
        && !(file.owner?.hasPrefix("com.apple.") ?? false)
    } else {
      allowed = CareScanner.inside(url, home) && !url.path.contains("/.Trash/")
        && ![home.path, home.appendingPathComponent("Library").path].contains(url.path)
    }
    guard allowed else { return "此位置仅供查看" }
    // These are never cleanup candidates, even if called with a crafted selection.
    let denied = ["Library/Keychains", "Library/Mail", "Library/Messages", ".ssh", ".aws", ".config", ".Trash"]
    if denied.contains(where: { url.path == home.appendingPathComponent($0).path || CareScanner.inside(url, home.appendingPathComponent($0)) }) { return "受保护的数据" }
    for root in [".codex", ".claude"] where url.path == home.appendingPathComponent(root).path { return "会话与设置请分别选择" }
    if ["auth.json", "credentials.json", "credentials", ".env", ".npmrc", ".netrc"].contains(url.lastPathComponent) { return "受保护的配置" }
    return nil
  }
  static func nonOverlapping(_ files: [CareFile]) -> [CareFile] {
    let paths = Set(files.map(\.path))
    return files.filter { file in
      var parent = file.url.deletingLastPathComponent()
      while parent.path != "/" { if paths.contains(parent.path) { return false }; parent.deleteLastPathComponent() }
      return true
    }
  }
}
