import XCTest
@testable import VitalsReplica

final class CareTests: XCTestCase {
  private var home: URL!
  private let fm = FileManager.default
  override func setUpWithError() throws {
    home = fm.temporaryDirectory.appendingPathComponent("chengguan-care-tests-" + UUID().uuidString).resolvingSymlinksInPath()
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { if let home { try? fm.removeItem(at: home) } }
  private func file(_ path: String, days: Double = 0) throws -> URL {
    let url = home.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 71, count: 8192).write(to: url)
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
    return url
  }
  private func oldDirectory(_ url: URL, days: Double = 100) throws {
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
  }
  private func reason(_ value: CareFile, protected: Set<String> = [], running: Set<String> = []) -> String? {
    CareSafety.reason(value, home: home, protected: protected, runningIDs: running, selfPath: "/Applications/澄观.app")
  }
  func testAgeRulesExcludeRecentLogsAndSessionCredentials() throws {
    _ = try file("Library/Logs/old.log", days: 45)
    _ = try file("Library/Logs/new.log", days: 1)
    _ = try file("Downloads/old.dmg", days: 14)
    _ = try file("Downloads/personal.zip", days: 100)
    _ = try file(".codex/sessions/old.jsonl", days: 100)
    _ = try file(".codex/sessions/new.jsonl", days: 10)
    _ = try file(".codex/auth.json", days: 100)
    let clean = CareScanner.scan(home: home, aiOnly: false, projectRoots: [], protected: [], token: CareCancellation())
    XCTAssertEqual(Set(clean.files.map(\.name)), ["old.log", "old.dmg"])
    let ai = CareScanner.scan(home: home, aiOnly: true, projectRoots: [], protected: [], token: CareCancellation())
    XCTAssertEqual(ai.files.map(\.name), ["old.jsonl"])
    XCTAssertNotNil(ai.completedAt)
  }
  func testBatchAssociationsKeepSharedCopiesAndOtherAppsData() throws {
    func app(_ name: String, _ id: String) -> CareApp {
      CareApp(path: home.appendingPathComponent("Applications/" + name + ".app").path, bundleID: id, name: name, version: "1", feed: nil, appStore: false, installed: nil, protected: false)
    }
    let first = app("First", "com.example.First"), second = app("Second", "com.example.Second")
    _ = try file("Library/Preferences/com.example.First.plist")
    _ = try file("Library/Preferences/com.example.Second.plist")
    _ = try file("Library/Preferences/com.example.Other.plist")
    let inventory = [first, second]
    let one = CareSoftwareScanner.associated(first, apps: inventory, home: home)
    let two = CareSoftwareScanner.associated(second, apps: inventory, home: home)
    XCTAssertEqual(Set((one + two).map(\.name)), ["com.example.First.plist", "com.example.Second.plist"])
    XCTAssertTrue((one + two).allSatisfy { $0.kind == .data })
    let duplicate = app("First Copy", first.bundleID)
    XCTAssertTrue(CareSoftwareScanner.associated(first, apps: inventory + [duplicate], home: home).isEmpty)
    let cancelled = CareCancellation(); cancelled.cancel()
    XCTAssertTrue(CareSoftwareScanner.associated(second, apps: inventory, home: home, token: cancelled).isEmpty)
  }
  @MainActor func testBulkAppSelectionExcludesProtectedAndPreservesFilteredChoices() {
    func app(_ name: String, protected: Bool = false) -> CareApp {
      CareApp(path: "/Applications/" + name + ".app", bundleID: "com.example." + name, name: name, version: "1", feed: nil, appStore: false, installed: nil, protected: protected)
    }
    let a = app("Alpha"), b = app("Beta"), system = app("System", protected: true)
    let store = CareSoftwareStore(apps: [a, b, system])
    store.search = "Alpha"; store.selectVisible()
    store.search = "Beta"; store.selectVisible()
    store.search = ""; store.selectVisible(); store.toggleApp(system)
    XCTAssertEqual(Set(store.selectedApps.map(\.id)), [a.id, b.id])
    store.sort = "安装时间"; store.toggleApp(a)
    XCTAssertEqual(store.selectedApps.map(\.id), [b.id])
  }
  func testDirectoryAgeCannotHideRecentChildren() throws {
    let current = try file("Library/Caches/LegacyCache/active.bin")
    try oldDirectory(current.deletingLastPathComponent())
    let result = CareScanner.scan(home: home, aiOnly: false, projectRoots: [], protected: [], token: CareCancellation())
    XCTAssertTrue(result.files.isEmpty)
  }
  func testSymlinkIsNotTraversedOrEligible() throws {
    let data = try file("Documents/source.bin", days: 100)
    let cache = home.appendingPathComponent("Library/Caches/linked")
    try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: cache, withDestinationURL: data.deletingLastPathComponent())
    XCTAssertNil(CareScanner.measure(cache, kind: .cache))
    XCTAssertTrue(CareScanner.scan(home: home, aiOnly: false, projectRoots: [], protected: [], token: CareCancellation()).files.isEmpty)
  }
  func testMeasureDoesNotDoubleCountHardLinksAndPartialIsExplicit() throws {
    let original = try file("Documents/a")
    try fm.linkItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent("b"))
    let one = try XCTUnwrap(CareScanner.measure(original, kind: .file))
    let folder = try XCTUnwrap(CareScanner.measure(original.deletingLastPathComponent(), kind: .file))
    XCTAssertEqual(folder.bytes, one.bytes)
    XCTAssertFalse(folder.partial)
    let token = CareCancellation(); token.cancel()
    XCTAssertTrue(try XCTUnwrap(CareScanner.measure(original.deletingLastPathComponent(), kind: .file, token: token)).partial)
  }
  func testProtectionAndRunningAppsCannotBeBypassedBySelection() throws {
    let url = try file("Library/Caches/com.example.Test/cache")
    let item = try XCTUnwrap(CareScanner.measure(url.deletingLastPathComponent(), kind: .cache, owner: "com.example.Test"))
    XCTAssertNil(reason(item))
    XCTAssertNotNil(reason(item, protected: [item.path]))
    XCTAssertNotNil(reason(item, protected: [home.appendingPathComponent("Library/Caches").path]))
    XCTAssertNotNil(reason(item, running: ["com.example.Test"]))
  }
  func testChangedPathIdentityIsRejected() throws {
    let url = try file("Documents/test")
    let item = try XCTUnwrap(CareScanner.measure(url, kind: .file))
    try Data("replacement".utf8).write(to: url, options: .atomic)
    XCTAssertNotNil(reason(item))
  }
  func testPartialAndSensitiveAndSystemLocationsAreReadOnly() throws {
    let url = try file("Library/Keychains/test")
    let item = try XCTUnwrap(CareScanner.measure(url, kind: .file))
    XCTAssertNotNil(reason(item))
    let auth = try XCTUnwrap(CareScanner.measure(try file(".codex/auth.json"), kind: .file))
    XCTAssertNotNil(reason(auth))
    let other = try XCTUnwrap(CareScanner.measure(try file("Documents/ordinary"), kind: .file))
    var partial = other
    partial = CareFile(path: other.path, kind: .file, bytes: other.bytes, partial: true, device: other.device, inode: other.inode)
    XCTAssertNotNil(reason(partial))
    XCTAssertNotNil(CareSafety.reason(other, home: home.appendingPathComponent("different"), protected: [], runningIDs: [], selfPath: ""))
  }
  func testParentAndChildAreProcessedOnlyOnce() throws {
    let url = try file("Documents/group/item")
    let parent = try XCTUnwrap(CareScanner.measure(url.deletingLastPathComponent(), kind: .file))
    let child = try XCTUnwrap(CareScanner.measure(url, kind: .file))
    XCTAssertEqual(CareSafety.nonOverlapping([child, parent]).map(\.path), [parent.path])
    XCTAssertFalse(CareScanner.inside(URL(fileURLWithPath: home.path + "-other"), home))
  }
  func testProtectedChildAndRunningAppAlsoProtectTheirParent() throws {
    let url = try file("Documents/group/private/keep")
    let group = try XCTUnwrap(CareScanner.measure(home.appendingPathComponent("Documents/group"), kind: .file))
    XCTAssertNotNil(reason(group, protected: [url.path]))
    XCTAssertNotNil(CareSafety.reason(group, home: home, protected: [], runningIDs: [], selfPath: "/Applications/澄观.app", runningPaths: [url.deletingLastPathComponent().path]))
  }
  func testProjectBuildsRequireExplicitRootManifestAndAge() throws {
    _ = try file("Projects/demo/package.json", days: 30)
    let build = try file("Projects/demo/.next/output", days: 30)
    try oldDirectory(build.deletingLastPathComponent(), days: 30)
    _ = try file("Projects/unrelated/build/user-file", days: 30)
    let noRoot = CareScanner.scan(home: home, aiOnly: false, projectRoots: [], protected: [], token: CareCancellation())
    XCTAssertTrue(noRoot.files.isEmpty)
    let selected = CareScanner.scan(home: home, aiOnly: false, projectRoots: [home.appendingPathComponent("Projects")], protected: [], token: CareCancellation())
    XCTAssertEqual(selected.files.map(\.name), [".next"])
  }
  func testTreeMapCoversAreaWithoutOverlapAndHandlesZero() {
    let bounds = CGRect(x: 0, y: 0, width: 700, height: 400)
    let layout = SpaceTile.layout([40, 30, 20, 10, 0, .nan], in: bounds)
    XCTAssertEqual(layout.count, 4)
    XCTAssertEqual(layout.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height, accuracy: 0.001)
    for a in layout { for b in layout where a.id != b.id { XCTAssertTrue(a.rect.intersection(b.rect).isEmpty) } }
    XCTAssertTrue(SpaceTile.layout([0, -1, .infinity], in: bounds).isEmpty)
  }
  func testAppcastParsingAndSourceValidation() {
    let xml = """
    <rss xmlns:sparkle="https://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><enclosure url="https://example.com/App.zip" sparkle:shortVersionString="1.4" sparkle:version="104" /></item>
    <item><enclosure url="http://example.com/bad.zip" sparkle:shortVersionString="1.5" /></item>
    </channel></rss>
    """
    let result = CareAppcast.parse(Data(xml.utf8))
    XCTAssertEqual(result.first?.version, "1.4")
    XCTAssertNotNil(result.first?.url)
    XCTAssertNil(result.last?.url)
    for address in ["http://example.com/feed", "https://user:pass@example.com/feed", "https://127.0.0.1/feed", "https://192.168.1.1/feed", "https://test.local/feed"] { XCTAssertFalse(CareSoftwareScanner.validFeed(URL(string: address)!)) }
  }
  func testExtraMessagesUseRecencyAndNavigateToCare() {
    let now = Date()
    let fresh = AIQuickMessage(id: "care", time: now, title: "扫描完成", detail: "", carePage: .clean)
    let old = AIQuickMessage(id: "old", time: now.addingTimeInterval(-1801), title: "旧记录", detail: "")
    let messages = AIMessageFeed.messages(events: [], runs: [], now: now, extra: [old, fresh])
    XCTAssertEqual(messages.map(\.id), ["care"])
    XCTAssertEqual(messages.first?.carePage, .clean)
  }
  func testUpdateSuggestionsExcludeIncompatibleBetaAndDelta() {
    let releases = [
      CareAppcast.Release(version: "1.0", url: nil),
      CareAppcast.Release(version: "2.0", url: nil, minimumOS: "99.0"),
      CareAppcast.Release(version: "3.0", url: nil, architectures: "x86_64"),
      CareAppcast.Release(version: "4.0", url: nil, channel: "beta"),
      CareAppcast.Release(version: "5.0", url: nil, delta: true)
    ]
    XCTAssertEqual(CareAppcast.compatible(releases, os: "15.0", architecture: "arm64").map(\.version), ["1.0"])
  }
  func testDeltaEnclosuresCannotReplaceFullReleaseURL() throws {
    let xml = """
    <rss xmlns:sparkle="https://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>500</sparkle:version><sparkle:shortVersionString>5.0</sparkle:shortVersionString>
    <enclosure url="https://example.com/full.zip" />
    <sparkle:deltas><enclosure url="https://example.com/4-to-5.delta" sparkle:deltaFrom="400" /></sparkle:deltas>
    </item></channel></rss>
    """
    let release = try XCTUnwrap(CareAppcast.parse(Data(xml.utf8)).first)
    XCTAssertEqual(release.version, "5.0")
    XCTAssertEqual(release.url?.lastPathComponent, "full.zip")
    XCTAssertFalse(release.delta)
  }
  @MainActor func testGeneratedFixtureCanBeTrashedRestoredAndNeverOverwrite() async throws {
    let url = try file("Documents/generated-test-only.txt")
    let original = try Data(contentsOf: url)
    let item = try XCTUnwrap(CareScanner.measure(url, kind: .file))
    let defaults = UserDefaults(suiteName: "care-tests-" + UUID().uuidString)!
    let store = CareStore(defaults: defaults, directory: home.appendingPathComponent("records"), home: home)
    store.trash([item])
    for _ in 0..<500 { if !store.processing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(store.processing)
    XCTAssertFalse(fm.fileExists(atPath: url.path), store.message)
    let operation = try XCTUnwrap(store.operations.first)
    XCTAssertEqual(operation.items.count, 1, operation.detail)
    // An existing original location must survive an attempted restore.
    try Data("new data".utf8).write(to: url)
    store.restore(operationID: operation.id)
    for _ in 0..<500 { if !store.processing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(try String(contentsOf: url), "new data")
    try fm.removeItem(at: url) // only the generated fixture
    store.restore(operationID: operation.id)
    for _ in 0..<500 { if !store.processing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertTrue(try XCTUnwrap(store.operations.first?.items.first).restored)
    await store.flush()
  }
  func testNestedBundleLinksDoNotBlockUninstallOrCountTheirDestination() throws {
    let binary = try file("Applications/Sample.app/Contents/MacOS/Sample")
    let outside = try file("Documents/outside")
    try fm.createSymbolicLink(at: binary.deletingLastPathComponent().appendingPathComponent("alias"), withDestinationURL: outside)
    let measured = try XCTUnwrap(CareScanner.measure(home.appendingPathComponent("Applications/Sample.app"), kind: .application, owner: "com.example.Sample"))
    XCTAssertFalse(measured.partial)
    XCTAssertEqual(measured.bytes, CareScanner.measure(binary, kind: .file)?.bytes)
    XCTAssertNil(reason(measured))
  }
}
