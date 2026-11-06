import CoreServices
import Foundation

/// FSEvents is a hint, not a source of truth: a bounded periodic scan repairs dropped events.
/// All methods run on the usage queue, so a change arriving during a scan stays pending.
final class UsageFileEvents {
  private var stream: FSEventStreamRef?
  private var roots: [String] = []
  private var aliases: [(physical: String, logical: String)] = []
  private var changed = Set<String>()
  private var lastDiscovery = Date.distantPast
  private var needsDiscovery = true
  var onChange: (() -> Void)?
  func start(roots: [URL], queue: DispatchQueue) {
    guard stream == nil else { return }
    aliases = roots.map { ($0.resolvingSymlinksInPath().path, $0.standardizedFileURL.path) }
    self.roots = aliases.map(\.physical)
    var ancestors = Set<String>()
    for root in roots {
      var ancestor = root
      while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
      if ancestor.hasDirectoryPath == false, (try? ancestor.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { ancestor.deleteLastPathComponent() }
      ancestors.insert(ancestor.resolvingSymlinksInPath().path)
    }
    let paths = ancestors.filter { a in !ancestors.contains { b in a != b && a.hasPrefix(b + "/") } }
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
      guard let info else { return }
      let owner = Unmanaged<UsageFileEvents>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
      var relevant = false
      for i in 0..<min(count, paths.count) {
        let path = URL(fileURLWithPath: paths[i]).resolvingSymlinksInPath().path
        let lost = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
        if lost { owner.needsDiscovery = true; relevant = true }
        guard owner.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
        for alias in owner.aliases {
          if path == alias.physical || path.hasPrefix(alias.physical + "/") {
            owner.changed.insert(alias.logical + path.dropFirst(alias.physical.count))
          } else if alias.physical.hasPrefix(path + "/") { owner.needsDiscovery = true }
        }
        relevant = true
        if flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { owner.needsDiscovery = true }
      }
      if relevant { owner.onChange?() }
    }, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    if let stream { FSEventStreamSetDispatchQueue(stream, queue); if !FSEventStreamStart(stream) { stop() } }
  }
  func take(now: Date, force: Bool) -> (discover: Bool, paths: Set<String>) {
    let discover = force || needsDiscovery || now.timeIntervalSince(lastDiscovery) >= 600
    if discover { lastDiscovery = now; needsDiscovery = false }
    let paths = changed; changed.removeAll()
    return (discover, paths)
  }
  func stop() {
    if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    stream = nil
  }
  deinit { stop() }
}
