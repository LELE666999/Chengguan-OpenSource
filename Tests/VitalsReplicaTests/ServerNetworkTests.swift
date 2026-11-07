import Darwin
import XCTest
@testable import VitalsReplica

final class ServerNetworkTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func raw(_ rows: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["error": 0, "data": rows])
  }
  private func row(_ time: Double, _ incoming: Any, _ outgoing: Any) -> [String: Any] {
    ["timestamp": time, "network_in_bytes": incoming, "network_out_bytes": outgoing]
  }
  func testKiwiIntervalBytesAreNotDifferencedLikeCounters() throws {
    let stats = try ServerNetworkStats.parse(raw([row(1_799_999_400, 30000, 60000), row(1_799_999_700, 15000, 9000)]), now: now)
    XCTAssertEqual(stats.interval, 300)
    XCTAssertEqual(stats.download, 50)
    XCTAssertEqual(stats.upload, 30)
    XCTAssertEqual(stats.dayIncoming, 45000)
    XCTAssertEqual(stats.dayOutgoing, 69000)
  }
  func testSortingDuplicatesMalformedFutureAndStaleSamples() throws {
    let stats = try ServerNetworkStats.parse(raw([row(1_799_999_700, 300, 600), row(1_799_999_400, 10, 20),
      row(1_799_999_700, "600", "1200"), row(1_800_001_000, 1, 2), row(1_799_999_900, true, 2), row(1_799_999_800, -1, 2)]), now: now)
    XCTAssertEqual(stats.samples.count, 2)
    XCTAssertEqual(stats.download, 2); XCTAssertEqual(stats.upload, 4)
    let stale = try ServerNetworkStats.parse(raw([row(1_799_995_000, 300, 600), row(1_799_995_300, 300, 600)]), now: now)
    XCTAssertNil(stale.download); XCTAssertNil(stale.upload)
    let gap = try ServerNetworkStats.parse(raw([row(1_799_995_300, 300, 600), row(1_799_999_700, 300, 600)]), now: now)
    XCTAssertNil(gap.upload)
    let one = try ServerNetworkStats.parse(raw([row(1_799_999_700, 1, 2)]), now: now)
    XCTAssertNil(one.upload)
    XCTAssertThrowsError(try ServerNetworkStats.parse(Data(#"{"error":1,"data":[]}"#.utf8)))
  }
  func testReadOnlyRawStatisticsRequestCannotChooseArbitraryAction() throws {
    let request = try KiwiClient.request(profile: .init(name: "Test", veid: "123", host: ""), key: "test&secret", reading: .network)
    XCTAssertEqual(request.url?.absoluteString, "https://api.64clouds.com/v1/getRawUsageStats")
    XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.url?.query)
    XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("test%26secret"))
  }
  func testProxyRatesUseBothCountersAndDiscardResetOrLongGap() throws {
    let old = MacProxySnapshot(time: now, uploadTotal: 100, downloadTotal: 1000, connections: 2, memory: nil)
    var new = MacProxySnapshot(time: now.addingTimeInterval(2), uploadTotal: 300, downloadTotal: 1800, connections: 3, memory: nil)
    XCTAssertEqual(new.rates(since: old).upload, 100); XCTAssertEqual(new.rates(since: old).download, 400)
    new.uploadTotal = 1
    XCTAssertNil(new.rates(since: old).upload); XCTAssertNil(new.rates(since: old).download)
    new.uploadTotal = 300; new.time = now.addingTimeInterval(60)
    XCTAssertNil(new.rates(since: old).download)
    XCTAssertNil(new.rates(since: nil).download)
    let parsed = try MacProxySnapshot.parse(Data(#"{"uploadTotal":100,"downloadTotal":200,"memory":1234,"connections":[{"metadata":{"host":"private.invalid"},"chains":["private"]}]}"#.utf8), now: now)
    XCTAssertEqual(parsed.connections, 1); XCTAssertEqual(parsed.memory, 1234)
    XCTAssertFalse(String(describing: parsed).contains("private"))
    XCTAssertThrowsError(try MacProxySnapshot.parse(Data(#"{"uploadTotal":true,"downloadTotal":2,"connections":[]}"#.utf8)))
  }
  func testConfigOnlyAllowsLocalControllerAndHandlesQuotedSecrets() {
    let yaml = "secret: 'fake#with''quote' # comment\nexternal-controller-unix: '/tmp/test.sock'\nexternal-controller: 127.0.0.1:9090\n"
    let configs = MihomoConfiguration.parse(yaml, source: "Test")
    XCTAssertEqual(configs.count, 2); XCTAssertEqual(configs.first?.secret, "fake#with'quote")
    for address in ["0.0.0.0:9090", "192.168.1.1:9090", "example.com:9090", "user:pass@127.0.0.1:9090", "127.0.0.1:9090/other"] {
      XCTAssertTrue(MihomoConfiguration.parse("external-controller: \(address)", source: "Test").isEmpty)
    }
    XCTAssertEqual(MihomoConfiguration.parse("external-controller: '[::1]:9090'", source: "Test").count, 1)
    XCTAssertTrue(MihomoConfiguration.parse("secret: \"bad\\r\\nheader\"\nexternal-controller: 127.0.0.1:9090", source: "Test").isEmpty)
  }
  func testHTTPFramingChunkedPartialStatusAndSizeLimits() throws {
    let partial = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}".utf8)
    XCTAssertNil(try LocalProxyHTTP.body(partial))
    var full = partial; full.append(Data("\r\n0\r\n\r\n".utf8))
    XCTAssertEqual(try LocalProxyHTTP.body(full), Data(#"{"a":1}"#.utf8))
    XCTAssertThrowsError(try LocalProxyHTTP.body(partial, eof: true))
    XCTAssertThrowsError(try LocalProxyHTTP.body(Data("HTTP/1.1 302 Found\r\nLocation: https://example.invalid\r\n\r\n".utf8)))
    XCTAssertThrowsError(try LocalProxyHTTP.body(Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".utf8)))
    XCTAssertThrowsError(try LocalProxyHTTP.body(Data("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n".utf8)))
  }
  func testPublicIPValidationAndFixedLookupDestination() throws {
    for invalid in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.1.1", "100.64.1.1", "203.0.113.1", "198.51.100.1", "192.0.2.1", "0.0.0.0", "255.255.255.255", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "2001:db8::1", "https://8.8.8.8/", "8.8.8.8?token=x", "example.com"] {
      XCTAssertNil(PublicIPAddress.canonical(invalid), invalid)
      XCTAssertThrowsError(try ServerIPInfo.request(invalid))
    }
    XCTAssertEqual(PublicIPAddress.canonical("2606:4700:4700::1111"), "2606:4700:4700::1111")
    let request = try ServerIPInfo.request("8.8.8.8")
    XCTAssertEqual(request.url?.host, "ipwho.is"); XCTAssertEqual(request.url?.scheme, "https"); XCTAssertEqual(request.url?.path, "/8.8.8.8")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let data = Data(#"{"success":true,"ip":"8.8.8.8","country":"United States","region":"California","city":"Mountain View","connection":{"asn":15169,"org":"Google LLC","isp":"Google LLC"},"timezone":{"id":"America/Los_Angeles"}}"#.utf8)
    let info = try ServerIPInfo.parse(data, expected: "8.8.8.8")
    XCTAssertEqual(info.asn, "AS15169"); XCTAssertEqual(info.timezone, "America/Los_Angeles")
    XCTAssertThrowsError(try ServerIPInfo.parse(data, expected: "1.1.1.1"))
  }
  func testTransportRejectsRemoteControllerAndNonReadOnlyPathBeforeConnecting() async {
    for pair in [("/connections", LocalProxyEndpoint.tcp("8.8.8.8", 9090)), ("/restart", .tcp("127.0.0.1", 9090))] {
      do { _ = try await LocalProxyHTTP.get(pair.0, configuration: .init(endpoint: pair.1, secret: "test", source: "Test")); XCTFail("Must reject") }
      catch { XCTAssertTrue(error is NetworkReadingError) }
    }
  }
}

@MainActor final class MacProxyMonitorTests: XCTestCase {
  func testLateReplyAfterStopCannotRestoreOldReadings() async throws {
    let configuration = MihomoConfiguration(endpoint: .unix("/tmp/test.sock"), secret: "test", source: "Test")
    var pending: CheckedContinuation<Data, Error>?
    let monitor = MacProxyMonitor(discover: { [configuration] }, get: { _, _ in
      try await withCheckedThrowingContinuation { pending = $0 }
    })
    monitor.refresh()
    for _ in 0..<100 { await Task.yield(); if pending != nil { break } }
    XCTAssertNotNil(pending)
    monitor.stop()
    pending?.resume(returning: Data(#"{"uploadTotal":1,"downloadTotal":2,"connections":[]}"#.utf8))
    for _ in 0..<30 { await Task.yield() }
    XCTAssertNil(monitor.snapshot); XCTAssertNil(monitor.upload); XCTAssertFalse(monitor.loading)
  }
  func testUnavailableProxyNeverClaimsZeroTraffic() async {
    let monitor = MacProxyMonitor(discover: { [] }, get: { _, _ in XCTFail("No request"); throw NetworkReadingError.unavailable })
    monitor.refresh()
    for _ in 0..<100 { await Task.yield(); if !monitor.loading { break } }
    XCTAssertNotNil(monitor.error); XCTAssertNil(monitor.snapshot); XCTAssertNil(monitor.upload); XCTAssertNil(monitor.download)
    monitor.stop()
  }
}
