import XCTest
import MonitorBridge
@testable import VitalsReplica

final class AdvisorTests: XCTestCase {
  private let now = Date().addingTimeInterval(-4000)
  private func process(pid: Int32 = 42424, start: UInt64 = 999, uid: UInt32 = getuid(), path: String = "/Applications/Test.app/Contents/MacOS/Test", cpu: Double = 250) -> ProcessSample {
    ProcessSample(pid: pid, ppid: 1, uid: uid, start: start, name: "Test", path: path, cpu: cpu, memory: 1_000_000, measured: true)
  }
  private func snapshot(time: Date? = nil, cpu: Double = 90) -> MonitorSnapshot {
    var s = MonitorSnapshot(); s.time = time ?? now; s.cpu = cpu; s.totalMemory = 16_000_000_000; s.appMemory = 8_000_000_000
    s.pressureLevel = 1; let p = process(); s.processes = [p]
    s.groups = [AppGroup(id: "/Applications/Test.app", name: "Test", bundlePath: "/Applications/Test.app", processes: [p])]
    return s
  }
  func testActionRejectsPIDReuseOwnershipStalenessRecoveryAndCompositionChanges() throws {
    let s = snapshot(), action = AdvisorAction.quit(s.groups[0], snapshot: s, evidence: "test")
    XCTAssertNil(action.invalidReason(snapshot: s, now: now, uid: getuid(), selfPID: getpid()))
    var changed = s; changed.processes = [process(start: 1000)]
    XCTAssertNotNil(action.invalidReason(snapshot: changed, now: now, uid: getuid(), selfPID: getpid()))
    XCTAssertNotNil(action.invalidReason(snapshot: s, now: now, uid: getuid() + 1, selfPID: getpid()))
    XCTAssertNotNil(action.invalidReason(snapshot: s, now: now.addingTimeInterval(91), uid: getuid(), selfPID: getpid()))
    XCTAssertNotNil(action.invalidReason(snapshot: snapshot(cpu: 20), now: now, uid: getuid(), selfPID: getpid()))
    changed = s; changed.groups[0].processes.append(process(pid: 42425))
    XCTAssertNotNil(action.invalidReason(snapshot: changed, now: now, uid: getuid(), selfPID: getpid()))
    let selfGroup = AppGroup(id: "self", name: "self", bundlePath: "/Applications/Self.app", processes: [process(pid: getpid())])
    XCTAssertNotNil(AdvisorAction.quit(selfGroup, snapshot: s, evidence: "self").invalidReason(snapshot: s, now: now, uid: getuid(), selfPID: getpid()))
  }
  func testStopProjectValidatesPortsAndIdentityAndOnlySignalsTestOwnedChild() throws {
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    let p = process(pid: child.processIdentifier, start: vr_process_start(child.processIdentifier), path: "/bin/sleep")
    var s = snapshot(); s.processes = [p]
    let project = ProjectSample(path: "/tmp/test-owned", name: "Test", processes: [p], ports: [45454]); s.projects = [project]
    let action = AdvisorAction.stop(project, snapshot: s)
    XCTAssertNil(action.invalidReason(snapshot: s, now: now, uid: getuid(), selfPID: getpid()))
    s.projects = [ProjectSample(path: project.path, name: project.name, processes: [p], ports: [45455])]
    XCTAssertNotNil(action.invalidReason(snapshot: s, now: now, uid: getuid(), selfPID: getpid()))
    XCTAssertEqual(vr_process_signal(p.pid, p.start, SIGTERM), 0)
    child.waitUntilExit(); XCTAssertFalse(child.isRunning)
  }
  func testReplacedTargetIsNotMistakenForCompletedQuitOrStop() {
    var s = snapshot()
    let quit = AdvisorAction.quit(s.groups[0], snapshot: s, evidence: "test")
    let project = ProjectSample(path: "/tmp/test-owned", name: "Test", processes: s.processes, ports: [45454])
    let stop = AdvisorAction.stop(project, snapshot: s)
    s.processes = [process(pid: 42425, start: 1000)]
    s.groups[0].processes = s.processes
    s.projects = [ProjectSample(path: project.path, name: project.name, processes: s.processes, ports: project.ports)]
    s.projectScanTime = now.addingTimeInterval(60)
    XCTAssertEqual(quit.targetEnded(snapshot: s, after: now), false)
    XCTAssertEqual(stop.targetEnded(snapshot: s, after: now), false)
    s.projects = []; s.groups = []
    XCTAssertEqual(quit.targetEnded(snapshot: s, after: now), true)
    XCTAssertEqual(stop.targetEnded(snapshot: s, after: now), true)
    s.projectScanTime = now
    XCTAssertNil(stop.targetEnded(snapshot: s, after: now))
  }
  func testOutcomeRequiresCoverageAndDoesNotClaimCausality() {
    let before = ResourceWindow(cpu: 90, memory: 8e9, pressure: 2, seconds: 40, samples: 21)
    var after = ResourceWindow(cpu: 20, memory: 7e9, pressure: 1, seconds: 35, samples: 18)
    XCTAssertEqual(ActionOutcome.assess(before: before, after: after, targetExited: false, workloadChanged: false).0, .unchanged)
    XCTAssertEqual(ActionOutcome.assess(before: before, after: after, targetExited: true, workloadChanged: true).0, .inconclusive)
    let improved = ActionOutcome.assess(before: before, after: after, targetExited: true, workloadChanged: false)
    XCTAssertEqual(improved.0, .improved); XCTAssertTrue(improved.1.contains("不能单独证明因果"))
    after.seconds = 5
    XCTAssertEqual(ActionOutcome.assess(before: before, after: after, targetExited: true, workloadChanged: false).0, .inconclusive)
  }
  func testCoverageAndChartsLeaveGapsAndPauseBlank() {
    var coverage = ObservationCoverage()
    for seconds in [0.0, 2, 4, 120, 122] { coverage.record(now.addingTimeInterval(seconds)) }
    XCTAssertEqual(coverage.seconds(from: now, to: now.addingTimeInterval(200)), 6)
    coverage.record(now.addingTimeInterval(124), newSpan: true)
    XCTAssertEqual(coverage.seconds(from: now, to: now.addingTimeInterval(200)), 6)
    let points = [0.0, 30, 300, 330].map { AppHistoryPoint(time: now.addingTimeInterval($0), cpu: 1, memory: 2) }
    XCTAssertEqual(SegmentedAppPoint.make(points).map(\.segment), [0, 0, 1, 1])
  }
  func testBaselineSeparatesContextExcludesRecentAndPressure() {
    var b = PersonalBaseline()
    for i in 0..<40 { b.observe(snapshot(time: now.addingTimeInterval(Double(i) * 60), cpu: 20)) }
    let future = now.addingTimeInterval(3000)
    XCTAssertTrue(b.value(appID: "/Applications/Test.app", context: "unknown:general", now: future)?.ready == true)
    XCTAssertNil(b.value(appID: "/Applications/Test.app", context: "power:general", now: future))
    XCTAssertEqual(b.value(appID: "/Applications/Test.app", context: "unknown:general", now: now)?.count, nil)
    let count = b.readings.count
    var pressure = snapshot(time: future, cpu: 95); pressure.pressureLevel = 4; b.observe(pressure)
    XCTAssertEqual(b.readings.count, count)
  }
  func testAdaptiveHeartbeatReturnsToShortIntervalOnPressure() {
    var policy = AdaptiveAnalysisPolicy()
    for second in stride(from: 0, through: 602, by: 2) { policy.observe(snapshot(time: now.addingTimeInterval(Double(second)), cpu: 20), hasIncident: false) }
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(602), enabled: true), 15)
    for second in stride(from: 604, through: 1802, by: 2) { policy.observe(snapshot(time: now.addingTimeInterval(Double(second)), cpu: 20), hasIncident: false) }
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(1802), enabled: true), 30)
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(1802), enabled: false), 5)
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(3000), enabled: true), 5)
    policy.observe(snapshot(time: now.addingTimeInterval(3000), cpu: 20), hasIncident: false)
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(3000), enabled: true), 5)
    policy.observe(snapshot(time: now.addingTimeInterval(3002), cpu: 90), hasIncident: true)
    XCTAssertEqual(policy.minutes(base: 5, now: now.addingTimeInterval(3003), enabled: true), 5)
  }
  func testUsageLedgerCountsUnknownUsageWithoutInventingTokens() throws {
    var ledger = AIUsageLedger()
    ledger.record(at: now, usage: AITokenUsage(promptTokens: 100, completionTokens: 20, totalTokens: nil), success: true)
    ledger.record(at: now, usage: nil, success: false)
    ledger.record(at: now, usage: AITokenUsage(promptTokens: nil, completionTokens: nil, totalTokens: -20), success: true)
    let restored = try JSONDecoder().decode(AIUsageLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored.days[0].requests, 3); XCTAssertEqual(restored.days[0].tokens, 120)
    XCTAssertEqual(restored.days[0].missingUsage, 2); XCTAssertEqual(restored.days[0].failed, 1)
  }
  func testAppHistoryRoundTripAndInjectionSafeID() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = HistoryStore(url: dir.appendingPathComponent("test.sqlite"))
    let start = Date().addingTimeInterval(-400)
    for seconds in [0.0, 30, 300] { db.record(snapshot(time: start.addingTimeInterval(seconds)), force: true) }
    let points = db.appPoints(id: "/Applications/Test.app", since: start.addingTimeInterval(-1))
    XCTAssertEqual(points.count, 3); XCTAssertEqual(points[0].cpu, 250)
    XCTAssertTrue(db.appPoints(id: "' OR 1=1 --", since: start).isEmpty)
    XCTAssertEqual(SegmentedAppPoint.make(points).last?.segment, 1)
  }
  func testAdvisorPayloadExcludesActionTargetsTokensPathsAndNames() throws {
    let s = snapshot(time: Date())
    let sample = try AIPreparedSample.prepare(snapshot: s, history: [s.point], minutes: 5, includeAppNames: false, paused: false)
    let action = AdvisorAction.quit(s.groups[0], snapshot: s, evidence: "PRIVATE secret path 192.168.1.22")
    let result = try sample.addingAdvisor(snapshot: s, baseline: PersonalBaseline(), actions: [action])
    XCTAssertFalse(result.json.contains("/Applications")); XCTAssertFalse(result.json.contains("PRIVATE")); XCTAssertFalse(result.json.contains("192.168")); XCTAssertFalse(result.json.contains("42424"))
    XCTAssertTrue(result.json.contains("baseline_ready")); XCTAssertTrue(result.json.contains("quitApp"))
  }
  @MainActor func testTimelineRecoveryGapAndRestartDoNotInventResults() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("advisor.json")
    let store = AdvisorStore(file: file)
    let event = AIMonitorEvent(id: UUID(), time: now, kind: .cpu, title: "Test", detail: "high", target: .cpu, duration: 12, urgent: true)
    store.observe(snapshot(), events: [event], network: AINetworkState())
    store.observe(snapshot(time: now.addingTimeInterval(2)), events: [], network: AINetworkState())
    XCTAssertTrue(store.episodes[0].active)
    store.observe(snapshot(time: now.addingTimeInterval(100), cpu: 10), events: [], network: AINetworkState())
    XCTAssertEqual(store.episodes[0].ending, "采样中断")
    XCTAssertEqual(store.coverage.seconds(from: now, to: now.addingTimeInterval(200)), 2)
    let second = AIMonitorEvent(id: UUID(), time: now.addingTimeInterval(102), kind: .cpu, title: "Test", detail: "high", target: .cpu, urgent: true)
    store.observe(snapshot(time: second.time), events: [second], network: AINetworkState())
    store.observe(snapshot(time: now.addingTimeInterval(104), cpu: 20), events: [], network: AINetworkState())
    XCTAssertEqual(store.episodes[0].ending, "已恢复")
    XCTAssertTrue(store.dailyText(on: now).contains("已观察"))
  }
  func testCollectionPolicyKeepsAnomalySamplingFast() {
    let quiet = CollectionPolicy(visible: false, battery: true, incident: false)
    let incident = CollectionPolicy(visible: false, battery: true, incident: true)
    XCTAssertGreaterThan(quiet.projectInterval, incident.projectInterval)
    XCTAssertGreaterThan(quiet.hardwareInterval, incident.hardwareInterval)
    XCTAssertEqual(incident.networkInterval, 5)
  }
  func testDiskScanDoesNotFollowSymlinkOrDeleteFiles() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inner = root.appendingPathComponent("folder"), external = root.appendingPathComponent("outside")
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try? Data(repeating: 1, count: 1_000_000).write(to: external)
    try? FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("link"), withDestinationURL: external)
    XCTAssertEqual(DiskUsageStore.scan(inner).bytes, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
  }
  @MainActor func testArchiveRoundTripEndsUnobservedIncidentsAndRuns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("advisor.json"), store = AdvisorStore(file: file)
    let event = AIMonitorEvent(id: UUID(), time: now, kind: .cpu, title: "CPU", detail: "high", target: .cpu, urgent: true)
    store.observe(snapshot(), events: [event], network: AINetworkState())
    let action = AdvisorAction.quit(snapshot().groups[0], snapshot: snapshot(), evidence: "test")
    let id = store.begin(action); store.transition(id, .observing, "test")
    store.recordUsage(usage: nil, success: false)
    await store.flush()
    let restored = AdvisorStore(file: file)
    XCTAssertEqual(restored.episodes[0].ending, "监测中断")
    XCTAssertEqual(restored.runs[0].state, .inconclusive)
    XCTAssertEqual(restored.todayUsage.requests, 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }
  func testPersonalBaselineRequiresPersistentPressureAndDoesNotLabelNormalCompile() {
    var baseline = PersonalBaseline()
    for i in 0..<40 {
      var s = snapshot(time: now.addingTimeInterval(Double(i) * 60), cpu: 20)
      var p = process(cpu: 20); p.cpu = 20; s.groups[0].processes = [p]
      s.groups.append(AppGroup(id: "other.app", name: "Other", bundlePath: "/Applications/Other.app", processes: [process(pid: 42425, cpu: 20)]))
      baseline.observe(s)
    }
    var engine = AIMonitorEngine()
    let start = now.addingTimeInterval(4000)
    var events: [AIMonitorEvent] = []
    for seconds in stride(from: 0, through: 40, by: 2) {
      events += engine.observe(snapshot(time: start.addingTimeInterval(Double(seconds)), cpu: 70), network: AINetworkState(), baseline: baseline)
    }
    XCTAssertEqual(events.filter { $0.title == "CPU 高于同场景常态" }.count, 1)
    var normal = AIMonitorEngine()
    XCTAssertTrue(normal.observe(snapshot(time: start, cpu: 20), network: AINetworkState(), baseline: baseline).isEmpty)
    XCTAssertTrue(normal.observe(snapshot(time: start.addingTimeInterval(40), cpu: 20), network: AINetworkState(), baseline: baseline).isEmpty)
    var swapping = AIMonitorEngine(), switchedEvents: [AIMonitorEvent] = []
    for seconds in stride(from: 0, through: 40, by: 2) {
      var s = snapshot(time: start.addingTimeInterval(Double(seconds)), cpu: 70)
      if seconds >= 20 { s.groups = [AppGroup(id: "other.app", name: "Other", bundlePath: "/Applications/Other.app", processes: [process(pid: 42425)])] }
      switchedEvents += swapping.observe(s, network: AINetworkState(), baseline: baseline)
    }
    XCTAssertFalse(switchedEvents.contains { $0.title == "CPU 高于同场景常态" }, "Different Apps must not share a continuous personal CPU window")
  }
  func testInitialOfflineIsVisibleAndAddressActionsExpireOnChange() {
    var engine = AIMonitorEngine(), network = AINetworkState(); network.connected = false
    XCTAssertTrue(engine.observe(snapshot(), network: network).contains { $0.kind == .network && $0.urgent })
    var s = snapshot(); s.localNetwork = LocalNetworkSnapshot(addresses: [LocalIPv4Address(interface: "en0", address: "192.0.2.1")])
    let action = AdvisorAction.simple(.copyAddress, "Copy", snapshot: s)
    s.localNetwork = LocalNetworkSnapshot(addresses: [LocalIPv4Address(interface: "en0", address: "192.0.2.2")])
    XCTAssertNotNil(action.invalidReason(snapshot: s, now: now, uid: getuid(), selfPID: getpid()))
  }
  func testServiceHintsDoNotInventPortConflicts() {
    var s = snapshot()
    s.projects = [ProjectSample(path: "/tmp/a", name: "A", processes: [], ports: [3000]), ProjectSample(path: "/tmp/b", name: "B", processes: [], ports: [3000])]
    let notes = DeveloperContext.serviceNotes(s)
    XCTAssertEqual(notes.count, 2); XCTAssertTrue(notes.allSatisfy { $0.detail.contains("尚不能确认冲突") })
  }
  func testWarmupDoesNotCreateFakeZeroHistory() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    var s = snapshot(time: Date()); s.isWarmup = true; db.record(s, force: true)
    XCTAssertTrue(db.appPoints(id: s.groups[0].id, since: s.time.addingTimeInterval(-10)).isEmpty)
  }

}
