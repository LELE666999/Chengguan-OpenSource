import XCTest
@testable import VitalsReplica

final class ServerParsingTests: XCTestCase {
  func testLiveServiceUnitsAndTrafficAccounting() throws {
    let s = try ServerSnapshot.parse(Data(#"{"error":0,"ve_status":"Running","plan_ram":1073741824,"mem_available_kb":"524288","plan_disk":21474836480,"ve_used_disk_space_b":3221225472,"plan_monthly_data":1073741824000,"data_counter":107374182400,"monthly_data_multiplier":3,"data_next_reset":1800000000,"load_average":"0.10 0.20 0.30","swap_total_kb":1024,"swap_available_kb":512,"is_cpu_throttled":"0","is_disk_throttled":1,"ssh_port":"22","ip_addresses":["203.0.113.9"]}"#.utf8))
    XCTAssertEqual(s.memoryUsed, 536870912)
    XCTAssertEqual(s.swapUsed, 524288)
    XCTAssertEqual(s.mappedDiskUsed, 3221225472)
    XCTAssertEqual(s.load, [0.1, 0.2, 0.3])
    // Counter and quota have the same accounting basis; do not apply a multiplier twice.
    XCTAssertEqual(s.transferRemaining, 966367641600)
    XCTAssertEqual(s.reset, Date(timeIntervalSince1970: 1800000000))
    XCTAssertEqual(s.cpuThrottled, false); XCTAssertEqual(s.diskThrottled, true)
    XCTAssertEqual(s.sshPort, 22)
  }
  func testStoppedOrPartialServiceDoesNotInventLiveReadings() throws {
    let s = try ServerSnapshot.parse(Data(#"{"error":0,"ve_status":"Stopped","plan_ram":1024,"mem_available_kb":9,"plan_disk":100}"#.utf8))
    XCTAssertNil(s.memoryUsed); XCTAssertNil(s.transferRemaining); XCTAssertNil(s.mappedDiskUsed)
    XCTAssertNil(s.cpuThrottled); XCTAssertTrue(s.load.isEmpty)
  }
  func testInvalidFieldsAndEnvelopes() throws {
    XCTAssertThrowsError(try ServerSnapshot.parse(Data(#"{"error":5,"message":"private response"}"#.utf8))) { error in
      XCTAssertFalse(error.localizedDescription.contains("private response"))
    }
    for data in [#"{"error":0}"#, #"{"error":true,"ve_status":"Running"}"#, #"{"error":1e30}"#, #"{"ve_status":"Running"}"#, "<html>login</html>"] {
      XCTAssertThrowsError(try ServerSnapshot.parse(Data(data.utf8)))
    }
    let s = try ServerSnapshot.parse(Data(#"{"error":0,"ve_status":"Running","mem_available_kb":"NaN","plan_ram":-1,"ssh_port":70000,"data_next_reset":0,"data_counter":-1}"#.utf8))
    XCTAssertNil(s.memoryTotal); XCTAssertNil(s.memoryAvailable); XCTAssertNil(s.sshPort); XCTAssertNil(s.reset); XCTAssertNil(s.transferUsed)
    let invalidReset = try ServerSnapshot.parse(Data(#"{"error":0,"ve_status":"Running","data_next_reset":1e30}"#.utf8))
    XCTAssertNil(invalidReset.reset)
  }
  func testRequestOnlyTargetsReadOnlyEndpointAndKeepsSecretOutOfURL() throws {
    let p = ServerProfile(name: "Test", veid: "123456", host: "203.0.113.9")
    let r = try KiwiClient.request(profile: p, key: "fake&key=+?#")
    XCTAssertEqual(r.httpMethod, "POST")
    XCTAssertEqual(r.url?.absoluteString, "https://api.64clouds.com/v1/getLiveServiceInfo")
    XCTAssertEqual(String(decoding: r.httpBody!, as: UTF8.self), "veid=123456&api_key=fake%26key%3D%2B%3F%23")
    XCTAssertNil(r.url?.query)
    XCTAssertThrowsError(try KiwiClient.request(profile: .init(name: "Bad", veid: "1/stop", host: ""), key: "x"))
    XCTAssertThrowsError(try KiwiClient.request(profile: p, key: " \n"))
  }
  func testDisplayGateInvalidatesQueuedCommandsAcrossOffAndOn() {
    let gate = DisplayAccessGate(), ticket = gate.ticket()
    XCTAssertTrue(gate.permits(ticket))
    gate.setEnabled(false); XCTAssertFalse(gate.permits(ticket)); XCTAssertFalse(gate.permits(gate.ticket()))
    gate.setEnabled(true); XCTAssertFalse(gate.permits(ticket)); XCTAssertTrue(gate.permits(gate.ticket()))
  }
}

@MainActor final class ServerMonitorTests: XCTestCase {
  private func reading() throws -> ServerSnapshot { try ServerSnapshot.parse(Data(#"{"error":0,"ve_status":"Running","data_counter":123}"#.utf8)) }
  private func profile(_ defaults: UserDefaults) throws -> ServerProfile {
    let p = ServerProfile(name: "Test", veid: "123", host: "203.0.113.1")
    defaults.set(try JSONEncoder().encode(p), forKey: ServerProfile.storageKey); return p
  }
  func testMissingKeyDoesNotMakeNetworkRequest() async throws {
    let suite = "ServerTests." + UUID().uuidString, d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    _ = try profile(d); var requests = 0
    let store = ServerMonitor(defaults: d, fetch: { _, _ in requests += 1; return try self.reading() }, readKey: { _ in nil })
    store.refresh(); for _ in 0..<100 { await Task.yield(); if !store.loading { break } }
    XCTAssertTrue(store.needsKey); XCTAssertEqual(requests, 0); XCTAssertNil(store.snapshot); XCTAssertEqual(store.stateLabel, "待连接")
    store.stop()
  }
  func testFailureRetainsLastReadingButMarksStaleAndReusesKey() async throws {
    let suite = "ServerTests." + UUID().uuidString, d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    _ = try profile(d); var requests = 0, reads = 0
    let store = ServerMonitor(defaults: d, fetch: { _, _ in
      requests += 1; if requests > 1 { throw ServerError.http(503) }; return try self.reading()
    }, readKey: { _ in reads += 1; return "fake" })
    store.refresh(); for _ in 0..<100 { await Task.yield(); if !store.loading { break } }
    let first = try XCTUnwrap(store.snapshot); XCTAssertFalse(store.stale)
    store.refresh(); for _ in 0..<100 { await Task.yield(); if !store.loading { break } }
    XCTAssertEqual(store.snapshot, first); XCTAssertTrue(store.stale); XCTAssertEqual(store.stateLabel, "待更新"); XCTAssertEqual(reads, 1)
    store.stop()
  }
  func testDisconnectIgnoresUncooperativeLateResponseAndClearsProfile() async throws {
    let suite = "ServerTests." + UUID().uuidString, d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    _ = try profile(d)
    var pending: CheckedContinuation<ServerSnapshot, Error>?
    let store = ServerMonitor(defaults: d, fetch: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }, readKey: { _ in "fake" }, removeKey: { _ in })
    store.refresh(); for _ in 0..<100 { await Task.yield(); if pending != nil { break } }
    XCTAssertNotNil(pending)
    try await store.disconnect(); pending?.resume(returning: try reading())
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(store.profile); XCTAssertNil(store.snapshot); XCTAssertNil(ServerProfile.load(d)); XCTAssertFalse(store.loading)
    store.stop()
  }
}
