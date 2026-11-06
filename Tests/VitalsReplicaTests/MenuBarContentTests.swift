import XCTest
@testable import VitalsReplica

final class MenuBarContentTests: XCTestCase {
  func testSelectionRoundTripsAndRemovesAllCopies() {
    let id = "Codex · 每周"
    let selected = MenuBarSelection.toggle(id, in: "[]")
    XCTAssertEqual(MenuBarSelection.parse(selected), [id])
    XCTAssertEqual(MenuBarSelection.parse(MenuBarSelection.toggle(id, in: selected)), [])
    XCTAssertEqual(MenuBarSelection.parse("invalid"), [])
  }

  @MainActor func testLiveValuesAndUnavailableSources() {
    let suite = "MenuBarContentTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "aiUsageEnabled")
    defaults.set(MenuBarSelection.encode(["gpu", "nasCPU"]), forKey: "menuExtraMetrics")
    var snapshot = MonitorSnapshot()
    snapshot.cpu = 24; snapshot.totalMemory = 8 * 1_073_741_824
    snapshot.appMemory = 2 * 1_073_741_824; snapshot.gpu = 36
    let window = UsageWindow(used: 30, minutes: 300, resets: Date().addingTimeInterval(300), label: nil)
    let limit = UsageLimit(provider: "Codex", name: "Codex", time: Date(), windows: [window])
    let provider = ProviderUsage(id: "Codex", limits: [limit])
    let id = MenuBarSelection.quotaID(provider: provider, limit: limit, window: window, index: 0)
    defaults.set(MenuBarSelection.encode([id]), forKey: "menuQuotaSelection")
    var nas = NASSnapshot(); nas.cpu = 42
    let live = MenuBarPresentation.make(snapshot: snapshot, providers: [provider], nas: nas, nasCurrent: true, activities: [], defaults: defaults)
    XCTAssertEqual(live.parts, ["24%", "2.00 GB", "GPU 36%", "NAS CPU 42%", "Codex 5小时 70%"])
    let offline = MenuBarPresentation.make(snapshot: snapshot, providers: [], nas: nas, nasCurrent: false, activities: [], defaults: defaults)
    XCTAssertEqual(offline.parts.suffix(2), ["NAS CPU —", "AI —"])
  }
}
