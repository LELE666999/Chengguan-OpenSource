import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import VitalsReplica

final class DefaultAppsTests: XCTestCase {
  private let first = URL(fileURLWithPath: "/Applications/First.app")
  private let second = URL(fileURLWithPath: "/Applications/Second.app")
  private var browser: DefaultOpenItem { DefaultOpenItem.builtIn.first { $0.id == "browser" }! }

  func testExtensionInputCannotBecomeAPathOrURL() {
    XCTAssertEqual(DefaultAppsRules.normalizedExtension(" .PSD \n"), "psd")
    XCTAssertEqual(DefaultAppsRules.normalizedExtension("7z"), "7z")
    for value in ["", ".", "../txt", "https://example.com", "file.txt", "a/b", "a b", String(repeating: "a", count: 33)] {
      XCTAssertNil(DefaultAppsRules.normalizedExtension(value), value)
    }
    XCTAssertEqual(DefaultAppsStore.item(for: ".jpeg")?.targets, DefaultAppsStore.item(for: "jpg")?.targets)
  }
  func testBrowserRepresentsBothWebSchemesAndHTML() {
    XCTAssertEqual(browser.targets, [.scheme("http"), .scheme("https"), .contentType(UTType.html.identifier)])
    XCTAssertFalse(DefaultOpenStatus(applications: [first, first, first]).mixed)
    XCTAssertTrue(DefaultOpenStatus(applications: [first, second, first]).mixed)
    XCTAssertTrue(DefaultOpenStatus(applications: [nil, second]).mixed)
    XCTAssertTrue(DefaultOpenStatus(applications: [first, nil]).mixed)
    XCTAssertFalse(DefaultOpenStatus(applications: [nil, nil]).mixed)
  }
  @MainActor func testGroupChangeReadsBackEverySystemAssociation() async {
    let system = FakeDefaultAppsSystem(values: Dictionary(uniqueKeysWithValues: browser.targets.map { ($0, first) }))
    let result = await DefaultAppsChange.apply(second, to: browser, system: system)
    XCTAssertTrue(result.verified)
    XCTAssertEqual(system.writes.count, 3)
    XCTAssertTrue(browser.targets.allSatisfy { system.current($0) == second })
  }
  @MainActor func testConsentRejectionCannotReportSuccessForWholeBrowser() async {
    let system = FakeDefaultAppsSystem(values: Dictionary(uniqueKeysWithValues: browser.targets.map { ($0, first) }))
    system.reject(.scheme("https"))
    let result = await DefaultAppsChange.apply(second, to: browser, system: system)
    XCTAssertFalse(result.verified)
    XCTAssertEqual(result.failures.count, 1)
    XCTAssertEqual(result.mismatches, ["HTTPS", ".html"])
    XCTAssertEqual(system.writes, [.scheme("http"), .scheme("https")])
    XCTAssertEqual(system.current(.scheme("https")), first)
    XCTAssertEqual(system.current(.scheme("http")), second)
  }
  @MainActor func testSilentSystemRefusalIsDetectedAndExistingDefaultIsNotRewritten() async {
    let system = FakeDefaultAppsSystem(values: Dictionary(uniqueKeysWithValues: browser.targets.map { ($0, first) }))
    let unchanged = await DefaultAppsChange.apply(first, to: browser, system: system)
    XCTAssertTrue(unchanged.verified)
    XCTAssertTrue(system.writes.isEmpty)
    system.ignore(.scheme("http"))
    let result = await DefaultAppsChange.apply(second, to: browser, system: system)
    XCTAssertFalse(result.verified)
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertEqual(result.mismatches, ["HTTP"])
  }
  @MainActor func testAppliedStateWinsOverLateCompletionError() async {
    let system = FakeDefaultAppsSystem(values: Dictionary(uniqueKeysWithValues: browser.targets.map { ($0, first) }))
    system.failAfterWrite(.scheme("http"))
    let result = await DefaultAppsChange.apply(second, to: browser, system: system)
    XCTAssertTrue(result.verified)
    XCTAssertEqual(system.writes.count, 3)
  }
}

/// No Launch Services writes: exercises cancellations, partial success and readback.
private final class FakeDefaultAppsSystem: DefaultAppsSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DefaultOpenTarget: URL]
  private var rejected: Set<DefaultOpenTarget> = [], ignored: Set<DefaultOpenTarget> = [], lateErrors: Set<DefaultOpenTarget> = []
  private var recorded: [DefaultOpenTarget] = []
  init(values: [DefaultOpenTarget: URL]) { self.values = values }
  var writes: [DefaultOpenTarget] { lock.withLock { recorded } }
  func reject(_ target: DefaultOpenTarget) { lock.withLock { _ = rejected.insert(target) } }
  func ignore(_ target: DefaultOpenTarget) { lock.withLock { _ = ignored.insert(target) } }
  func failAfterWrite(_ target: DefaultOpenTarget) { lock.withLock { _ = lateErrors.insert(target) } }
  func current(_ target: DefaultOpenTarget) -> URL? { lock.withLock { values[target] } }
  func candidates(_ target: DefaultOpenTarget) -> [URL] { [] }
  func set(_ application: URL, for target: DefaultOpenTarget) async throws { try write(application, to: target) }
  private func write(_ application: URL, to target: DefaultOpenTarget) throws {
    try lock.withLock {
      recorded.append(target)
      if rejected.contains(target) { throw CocoaError(.userCancelled) }
      if !ignored.contains(target) { values[target] = application }
      if lateErrors.contains(target) { throw CocoaError(.fileReadUnknown) }
    }
  }
}
