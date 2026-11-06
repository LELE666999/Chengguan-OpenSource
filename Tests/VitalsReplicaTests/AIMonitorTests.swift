import Foundation
import XCTest
@testable import VitalsReplica

final class AIMonitorTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_792_600_000)
  private let online = AINetworkState(connected: true, transport: "Wi-Fi")
  private func sample(_ seconds: Double = 0, cpu: Double = 15, memory: UInt64 = 1_073_741_824) -> MonitorSnapshot {
    var s = MonitorSnapshot()
    s.time = start.addingTimeInterval(seconds); s.cpu = cpu; s.totalMemory = 16_106_127_360
    s.coreUsage = Array(repeating: cpu, count: 8); s.pressureLevel = 1
    s.localNetwork.addresses = [LocalIPv4Address(interface: "en0", address: "192.168.51.9")]
    let p = ProcessSample(pid: 987654, ppid: 1, uid: 501, start: 10, name: "PrivateProc",
      path: "/Users/private-name/PrivateEditor.app/run", cpu: cpu * 6, memory: memory, measured: true)
    s.groups = [AppGroup(id: "private.bundle.id", name: "PrivateEditor", bundlePath: "/Users/private-name/PrivateEditor.app", processes: [p])]
    return s
  }
  func testCPURequiresContinuousEvidenceAndDoesNotRepeatUntilRecovery() {
    var engine = AIMonitorEngine()
    XCTAssertTrue(engine.observe(sample(0, cpu: 90), network: online).isEmpty)
    for second in stride(from: 2.0, through: 10, by: 2) {
      XCTAssertTrue(engine.observe(sample(second, cpu: 90), network: online).isEmpty)
    }
    let events = engine.observe(sample(12, cpu: 90), network: online)
    XCTAssertEqual(events.map(\.kind), [.cpu])
    XCTAssertEqual(events.first?.appID, "private.bundle.id")
    XCTAssertTrue(events.first?.detail.contains("PrivateEditor") == true)
    XCTAssertEqual(events.first?.duration, 12)
    XCTAssertTrue(engine.observe(sample(14, cpu: 90), network: online).isEmpty)
    XCTAssertTrue(engine.observe(sample(16, cpu: 50), network: online).contains { $0.resolved && $0.target == .cpu })
    // An immediate relapse is suppressed for two minutes, but it is not forgotten forever.
    for second in stride(from: 18.0, through: 118, by: 2) { _ = engine.observe(sample(second, cpu: 90), network: online) }
    XCTAssertTrue(engine.observe(sample(132, cpu: 90), network: online).contains { $0.kind == .cpu })
  }
  func testSamplingGapDoesNotLookLikeSustainedLoadOrMemoryGrowth() {
    var engine = AIMonitorEngine()
    _ = engine.observe(sample(0, cpu: 90), network: online)
    _ = engine.observe(sample(10, cpu: 90), network: online)
    XCTAssertTrue(engine.observe(sample(200, cpu: 90, memory: 9_000_000_000), network: online).isEmpty)
    XCTAssertEqual(engine.trends(now: start.addingTimeInterval(200)).first?.seconds, 0)
  }
  func testCriticalCPUThresholdHasItsOwnContinuousDuration() {
    var engine = AIMonitorEngine()
    _ = engine.observe(sample(0, cpu: 86), network: online)
    _ = engine.observe(sample(2, cpu: 86), network: online)
    XCTAssertTrue(engine.observe(sample(4, cpu: 99), network: online).isEmpty)
    XCTAssertTrue(engine.observe(sample(6, cpu: 99), network: online).isEmpty)
    let critical = engine.observe(sample(8, cpu: 99), network: online).first { $0.kind == .cpu }
    XCTAssertEqual(critical?.duration, 4)
    XCTAssertTrue(engine.observe(sample(12, cpu: 99), network: online).isEmpty)
  }
  func testCriticalMemoryIsImmediateButHighUsageAloneIsNotAnIncident() {
    var engine = AIMonitorEngine()
    XCTAssertTrue(engine.observe(sample(0, memory: 12_000_000_000), network: online).isEmpty)
    var critical = sample(2, memory: 12_000_000_000); critical.pressureLevel = 4
    XCTAssertTrue(engine.observe(critical, network: online).contains { $0.kind == .memory && $0.urgent })
    XCTAssertTrue(engine.observe(sample(4), network: online).contains { $0.resolved && $0.target == .memory })
  }
  func testWarningEscalatesToCriticalWithoutWaitingForRecovery() {
    var engine = AIMonitorEngine()
    for second in stride(from: 0.0, through: 6, by: 2) {
      var s = sample(second); s.pressureLevel = 2; _ = engine.observe(s, network: online)
    }
    var warning = sample(8); warning.pressureLevel = 2
    XCTAssertTrue(engine.observe(warning, network: online).contains { $0.title == "内存压力升高" })
    var critical = sample(10); critical.pressureLevel = 4
    XCTAssertTrue(engine.observe(critical, network: online).contains { $0.title == "内存压力严重" })
  }
  func testAddressRouteAndInterfaceChangesAreLocalEvents() {
    var engine = AIMonitorEngine()
    XCTAssertTrue(engine.observe(sample(), network: online).isEmpty)
    var moved = sample(2)
    moved.localNetwork.addresses = [LocalIPv4Address(interface: "en0", address: "192.168.51.20")]
    let changes = engine.observe(moved, network: AINetworkState(connected: false, transport: "unknown"))
    XCTAssertTrue(changes.contains { $0.kind == .address && $0.detail.contains("192.168.51.20") })
    XCTAssertTrue(changes.contains { $0.kind == .network && $0.urgent })
    moved.time = start.addingTimeInterval(4)
    XCTAssertTrue(engine.observe(moved, network: online).contains { $0.kind == .network && $0.resolved })
    moved.time = start.addingTimeInterval(6)
    XCTAssertTrue(engine.observe(moved, network: AINetworkState(connected: true, transport: "以太网")).contains { $0.title.contains("切换") })
  }
  func testEndpointAvailabilityDoesNotClaimAllInternetIsBroken() {
    var engine = AIMonitorEngine()
    _ = engine.observe(sample(), network: online)
    var failed = online; failed.endpointReachable = false
    let issue = engine.observe(sample(2), network: failed).first { $0.kind == .endpoint }
    XCTAssertTrue(issue?.detail.contains("不代表所有网站") == true)
    var recovered = online; recovered.endpointReachable = true; recovered.endpointLatencyMS = 45
    XCTAssertTrue(engine.observe(sample(4), network: recovered).contains { $0.kind == .recovery && $0.target == .network })
  }
  func testMemoryGrowthIsCorrelatedWithActualPressureAndNamedLocally() {
    var engine = AIMonitorEngine()
    for second in stride(from: 0.0, through: 60, by: 2) {
      _ = engine.observe(sample(second, memory: UInt64(1_000_000_000 + second * 25_000_000)), network: online)
    }
    var s = sample(62, memory: 3_000_000_000); s.pressureLevel = 2
    let changes = engine.observe(s, network: online)
    XCTAssertTrue(changes.contains { $0.kind == .memory && $0.title.contains("PrivateEditor") && $0.detail.contains("尚不能确认") })
  }
  func testAutomaticContextDoesNotLeakNamesIdentifiersOrAddresses() throws {
    let s = sample()
    let prepared = try AIPreparedSample.prepare(snapshot: s, history: [s.point], minutes: 5, includeAppNames: false, paused: false, now: start)
    let event = AIMonitorEvent(id: UUID(), time: start, kind: .address, title: "PrivateEditor 变化",
      detail: "192.168.51.20 /Users/private-name secret", target: .network, appID: "private.bundle.id")
    let trend = AIAppTrend(id: "private.bundle.id", name: "PrivateEditor", seconds: 90, meanCPU: 80, peakCPU: 200, memoryGrowth: 100_000_000)
    let result = try prepared.addingMonitoring(events: [event], trends: [trend], network: online)
    for value in ["PrivateEditor", "192.168.", "/Users/", "private.bundle.id", "987654", "secret"] {
      XCTAssertFalse(result.json.contains(value), "Leaked: \(value)")
    }
    XCTAssertTrue(result.json.contains("App1"))
    XCTAssertTrue(result.json.contains("mean_single_core_cpu_percent"))
    XCTAssertTrue(result.json.contains("causation_limit"))
  }
  func testAutomaticBudgetCapsRateBacksOffAndBlocksCredentialFailures() {
    var budget = AIAutomaticBudget()
    XCTAssertTrue(budget.mayRun(now: start, intervalMinutes: 5, event: false))
    budget.started(now: start)
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(59), intervalMinutes: 5, event: true))
    XCTAssertTrue(budget.mayRun(now: start.addingTimeInterval(60), intervalMinutes: 5, event: true))
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(60), intervalMinutes: 5, event: false))
    budget.finished(now: start, error: AIAnalysisError.http(429))
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(119), intervalMinutes: 5, event: true))
    XCTAssertTrue(budget.mayRun(now: start.addingTimeInterval(120), intervalMinutes: 5, event: true))
    budget.finished(now: start, error: AIAnalysisError.http(401))
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(2000), intervalMinutes: 5, event: true))
    budget.resume()
    budget.finished(now: start, error: AIAnalysisError.keychain)
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(2000), intervalMinutes: 5, event: true))
    budget.resume()
    for second in stride(from: 60.0, through: 660, by: 60) { budget.started(now: start.addingTimeInterval(second)) }
    XCTAssertFalse(budget.mayRun(now: start.addingTimeInterval(1000), intervalMinutes: 5, event: true))
    XCTAssertTrue(budget.mayRun(now: start.addingTimeInterval(3601), intervalMinutes: 5, event: true))
  }
  func testAnonymizedLabelsAreResolvedLocallyWithoutPartialReplacement() throws {
    let report = AIReport(status: .attention, summary: "App1 与 App10，App100 未知", findings: [], limitations: [], nextChecks: [])
    let item = AIAnalysisRecord(id: UUID(), createdAt: start, sampledAt: start, mode: .overview, provider: "MiMo", model: "synthetic",
      requestedMinutes: 5, sampleCount: 1, observedSeconds: 0, appLabels: ["App1": "编辑器", "App10": "浏览器"], report: report, usage: nil, duration: 1)
    XCTAssertEqual(item.conciseSummary, "编辑器 与 浏览器，App100 未知")
    XCTAssertEqual(item.displayText("App1占用较高；建议观察App10的任务。"), "编辑器占用较高；建议观察浏览器的任务。")
    XCTAssertEqual(item.displayText("APP1、app 10；MyApp1、App10Helper"), "编辑器、浏览器；MyApp1、App10Helper")
    XCTAssertFalse(item.markdown.contains("App1 与 App10"))
    // Existing 0.4.x histories have no trigger field and must still load.
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
    json.removeValue(forKey: "trigger")
    XCTAssertNil(try JSONDecoder().decode(AIAnalysisRecord.self, from: JSONSerialization.data(withJSONObject: json)).trigger)
  }
}
