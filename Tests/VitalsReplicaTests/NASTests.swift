import Foundation
import Security
import XCTest
@testable import VitalsReplica

final class NASTests: XCTestCase {
  func testHardwareArtworkIsPackagedAndDecodable() {
    for name in ["nas-pool", "nas-hdd", "nas-ssd", "nas-nvme"] {
      let image = VisualResources.image(name)
      XCTAssertTrue(image.isValid, name)
      XCTAssertGreaterThan(image.size.width, 0, name)
      XCTAssertGreaterThan(image.size.height, 0, name)
    }
  }
  private func value(_ object: Any) throws -> NASValue {
    try JSONDecoder().decode(NASValue.self, from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
  }
  func testEndpointValidationProtectsCredentials() throws {
    for s in ["http://192.168.1.9:9999", "https://nas.example.com:9443", "http://home.local:9999/"] {
      XCTAssertNotNil(try NASConfiguration.baseURL(s))
    }
    for s in ["http://public.example.com", "http://192.168.1.9@evil.com:9999", "https://user:password@nas.local", "https://nas.local?token=abc", "https://nas.local/a", "file:///tmp/nas", "https://nas.local#x"] {
      XCTAssertThrowsError(try NASConfiguration.baseURL(s), s)
    }
  }
  func testFirmwareNumericStringsUnitsAndMissingData() throws {
    let values = try [
      "monitor": value(["cpu_usage_rate": 0.8, "ram_usage_rate": "51.2", "upload_speed": ["value": 3.8, "unit": "MB/s"]]),
      "thermal": value(["cpu_temperature": "67", "fan_list": [["speed": 1200]]]),
      "pools": value(["result": [["name": "pool1", "total": "1000", "used": 1000, "free": 0,
        "volumes": [["filesystem": "btrfs", "total": "1000", "used": 700]]]]]),
      "disks": value(["result": [["label": "HDD 1", "status": 973, "size": 9000]]])
    ]
    let s = NASSnapshot.parse(values, unavailable: ["任务管理器"])
    XCTAssertEqual(s.cpu, 0.8) // A sub-1 percent reading must stay sub-1.
    XCTAssertEqual(s.memory, 51.2); XCTAssertEqual(s.upload, 3_800_000)
    XCTAssertNil(s.download); XCTAssertNil(s.memoryTotal)
    XCTAssertEqual(s.temperature, 67); XCTAssertEqual(s.fans.first?.rpm, 1200)
    XCTAssertEqual(s.free, 300); XCTAssertEqual(s.pools.first?.filesystem, "btrfs")
    XCTAssertEqual(s.disks.first?.status, "状态码 973")
    XCTAssertNil(s.disks.first?.temperature)
    XCTAssertEqual(s.unavailable, ["任务管理器"])
  }
  func testTaskManagerTakesPriorityWithoutInventingMissingPools() throws {
    let s = NASSnapshot.parse(try ["stat": value([
      "overview": ["cpu": [["used_percent": "6.5", "temp": 72]], "mem": [["used_percent": 55]], "cpu_fan": [["speed": 1560]]],
      "mem": ["structure": ["total": 8_000_000_000, "used": 4_400_000_000]]]),
      "monitor": value(["cpu_usage_rate": 20]), "net": value(["series": [["send_rate": 512, "recv_rate": 1024]]])])
    XCTAssertEqual(s.cpu, 6.5); XCTAssertEqual(s.memoryTotal, 8_000_000_000)
    XCTAssertEqual(s.temperature, 72); XCTAssertEqual(s.download, 1024)
    XCTAssertEqual(s.fans.first?.name, "CPU 风扇")
    XCTAssertNil(s.total); XCTAssertNil(s.free)
  }
  func testInvalidValuesNeverBecomeHealthyZeroReadings() throws {
    let s = NASSnapshot.parse(try ["monitor": value(["cpu_usage_rate": 250, "ram_usage_rate": -1, "upload_speed": ["value": 3, "unit": "mystery"]]),
      "thermal": value(["cpu_temperature": 900])])
    XCTAssertNil(s.cpu); XCTAssertNil(s.memory); XCTAssertNil(s.temperature); XCTAssertNil(s.upload)
    XCTAssertTrue(s.suggestions.isEmpty)
  }
  func testPartialPoolCapacityNeverReportedAsWholeNASFreeSpace() throws {
    let s = NASSnapshot.parse(try ["pools": value(["result": [["total": 100, "used": 100,
      "volumes": [["total": 100, "used": 50]]], ["name": "Unavailable"]]])])
    XCTAssertNil(s.total); XCTAssertNil(s.free)
    XCTAssertEqual(s.pools.first?.free, 50)
  }
  func testExpiredHTTP200EnvelopeRequiresReauthentication() throws {
    XCTAssertThrowsError(try NASClient.unwrap(value(["code": 1024, "msg": "secret-token"]))) { error in
      guard case NASError.expired = error else { return XCTFail("Expected expired session") }
      XCTAssertFalse(error.localizedDescription.contains("secret-token"))
    }
    XCTAssertThrowsError(try NASClient.unwrap(value(["code": 403, "msg": "private-owner"]))) { error in
      XCTAssertFalse(error.localizedDescription.contains("private-owner"))
    }
  }
  func testRSAEncryptionIsDecryptableAndRejectsMalformedKeys() throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
    let encrypted = try NASRSA.encrypt("synthetic-password", header: der.base64EncodedString())
    let plaintext = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(base64Encoded: encrypted)! as CFData, nil)) as Data
    XCTAssertEqual(String(data: plaintext, encoding: .utf8), "synthetic-password")
    // Actual UGOS 1.19 wire format: base64(PEM(SPKI)), with an RSA PEM label.
    func tlv(_ tag: UInt8, _ body: Data) -> Data {
      let length = body.count
      let prefix: [UInt8] = length < 128 ? [tag, UInt8(length)] : [tag, 0x82, UInt8(length >> 8), UInt8(length & 255)]
      return Data(prefix) + body
    }
    let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
    let spki = tlv(0x30, algorithm + tlv(0x03, Data([0]) + der))
    let pem = "-----BEGIN RSA PUBLIC KEY-----\n" + spki.base64EncodedString() + "\n-----END RSA PUBLIC KEY-----\n"
    XCTAssertEqual(try NASRSA.keyData(spki.base64EncodedString()), der)
    XCTAssertEqual(try NASRSA.keyData(pem), der)
    let wrapped = Data(pem.utf8).base64EncodedString()
    XCTAssertEqual(try NASRSA.keyData(wrapped), der)
    let wrappedCipher = try NASRSA.encrypt("wrapped-format-test", header: wrapped)
    let unwrapped = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(base64Encoded: wrappedCipher)! as CFData, nil)) as Data
    XCTAssertEqual(String(data: unwrapped, encoding: .utf8), "wrapped-format-test")
    XCTAssertThrowsError(try NASRSA.keyData("not-a-public-key"))
    XCTAssertThrowsError(try NASRSA.keyData(Data([0x30, 0x84, 0xff]).base64EncodedString()))
  }
  func testRecommendationsHaveNumericEvidence() throws {
    let s = NASSnapshot.parse(try ["monitor": value(["cpu_usage_rate": 95, "ram_usage_rate": 94]),
      "pools": value(["result": [["name": "Pool", "total": 1000, "used": 1000,
        "volumes": [["total": 1000, "used": 950]]]]])])
    XCTAssertEqual(s.suggestions.count, 3)
    XCTAssertTrue(s.suggestions.contains { $0.contains("缓存") })
  }
  func testFullyAllocatedPoolIsNotAFullFilesystem() throws {
    let s = NASSnapshot.parse(try ["pools": value(["result": [["total": 1000, "used": 1000, "free": 0, "level": "basic",
      "volumes": [["name": "volume1", "total": 950, "used": 5, "available": 930, "filesystem": "ext4"]]]]])])
    let pool = try XCTUnwrap(s.pools.first)
    XCTAssertEqual(s.total, 950); XCTAssertEqual(s.free, 930)
    XCTAssertEqual(pool.used, 5); XCTAssertEqual(pool.poolCapacity, 1000); XCTAssertEqual(pool.unallocated, 0)
    XCTAssertEqual(pool.level, "Basic"); XCTAssertEqual(pool.name, "存储池 1")
    XCTAssertEqual(pool.fraction!, 5.0 / 950, accuracy: 0.00001)
    XCTAssertTrue(s.suggestions.isEmpty)
  }
  func testVolumeAccountingRejectsMissingAndImpossibleValues() throws {
    let s = NASSnapshot.parse(try ["pools": value(["result": [
      ["total": 1000, "used": 1000, "free": 0],
      ["volumes": [["total": 100, "used": 101, "available": 200]]],
      ["volumes": [["total": 100, "used": 50, "available": 40], ["total": 100]]],
      ["volumes": [["total": 100, "used": 100, "available": 0]]]
    ]])])
    XCTAssertNil(s.pools[0].used); XCTAssertNil(s.pools[0].free)
    XCTAssertNil(s.pools[1].used); XCTAssertNil(s.pools[1].free)
    XCTAssertNil(s.pools[2].used); XCTAssertNil(s.pools[2].free)
    XCTAssertEqual(s.pools[3].free, 0)
    XCTAssertEqual(s.suggestions.count, 1)
    XCTAssertNil(s.free)
  }
  func testFanMotionPausesForUnknownOfflineOrReducedMotion() {
    XCTAssertEqual(NASFanMotion.turnsPerSecond(rpm: 1300, live: true, reduced: false), 1300.0 / 1100)
    for value: Double? in [nil, 0, -1, .infinity, .nan] {
      XCTAssertEqual(NASFanMotion.turnsPerSecond(rpm: value, live: true, reduced: false), 0)
    }
    XCTAssertEqual(NASFanMotion.turnsPerSecond(rpm: 1300, live: false, reduced: false), 0)
    XCTAssertEqual(NASFanMotion.turnsPerSecond(rpm: 1300, live: true, reduced: true), 0)
    XCTAssertEqual(NASFanMotion.turnsPerSecond(rpm: 10000, live: true, reduced: false), 2.2)
  }
  func testAuthenticatedPollingUsesReadEndpointsAndSurvivesPartialFirmwareSupport() async throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    let key = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
    let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data
    let lock = NSLock()
    var requests: [String: Int] = [:]
    NASStubProtocol.handler = { request in
      let path = request.url!.path
      lock.lock(); requests[path, default: 0] += 1; lock.unlock()
      if path.hasSuffix("/verify/check") { return (200, ["x-rsa-token": der.base64EncodedString()], ["code": 200, "data": [:]]) }
      if path.hasSuffix("/verify/login") { return (200, [:], ["code": 200, "data": ["token": "synthetic-token", "auth_type": "header"]]) }
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "UG-Agent"), "PC/WEB")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ugreen-Token"), "synthetic-token")
      XCTAssertTrue(NASClient.endpoints.contains { URLComponents(string: $0.1)?.path == path })
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value, "synthetic-token")
      if path.hasSuffix("/taskmgr/stat/get_all") {
        return (200, [:], ["code": 200, "data": ["overview": ["cpu": [["used_percent": 7, "temp": 71]], "mem": [["used_percent": 51]]]]])
      }
      return (404, [:], [:])
    }
    let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [NASStubProtocol.self]
    let client = NASClient(config: NASConfiguration(endpoint: "http://nas.local:9999", username: "synthetic-user"), sessionConfiguration: session)
    try await client.login(password: "synthetic-password")
    let reading = try await client.snapshot()
    XCTAssertEqual(reading.cpu, 7); XCTAssertEqual(reading.temperature, 71)
    XCTAssertFalse(reading.unavailable.isEmpty); XCTAssertNil(reading.free)
    _ = try await client.snapshot()
    XCTAssertEqual(requests["/ugreen/v1/sysinfo/machine/common"], 1)
    XCTAssertEqual(requests["/ugreen/v1/storage/pool/list"], 2)
    XCTAssertEqual(requests["/ugreen/v2/storage/disk/list"], 2)
  }
  func testExpiredParallelEndpointsCauseOnlyOneRelogin() async throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    let key = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
    let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data
    let lock = NSLock()
    var logins = 0
    NASStubProtocol.handler = { request in
      let path = request.url!.path
      if path.hasSuffix("/verify/check") { return (200, ["x-rsa-token": der.base64EncodedString()], ["code": 200, "data": [:]]) }
      if path.hasSuffix("/verify/login") {
        lock.lock(); logins += 1; let current = logins; lock.unlock()
        return (200, [:], ["code": 200, "data": ["token": "synthetic-\(current)"]])
      }
      let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
      if token == "synthetic-1" { return (200, [:], ["code": 1024]) }
      return (200, [:], ["code": 200, "data": [:]])
    }
    let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [NASStubProtocol.self]
    let client = NASClient(config: NASConfiguration(endpoint: "http://nas.local:9999", username: "test"), sessionConfiguration: session)
    try await client.login(password: "synthetic")
    _ = try await client.snapshot()
    XCTAssertEqual(logins, 2)
  }
  func testTwoStepHandshakeKeepsTrustAnExplicitChoice() async throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    let key = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
    let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
    let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data
    NASStubProtocol.handler = { request in
      let path = request.url!.path
      if path.hasSuffix("/verify/check") { return (200, ["x-rsa-token": der.base64EncodedString()], ["code": 200, "data": [:]]) }
      if path.hasSuffix("/verify/code/login") {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
          stream.open(); defer { stream.close() }; var all = Data(), buffer = [UInt8](repeating: 0, count: 1024)
          while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; all.append(contentsOf: buffer.prefix(count)) }
          data = all
        }
        let body = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
        XCTAssertEqual(body["trust"] as? Bool, false)
        XCTAssertEqual(body["token_id"] as? String, "synthetic-challenge")
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "UG-Client-Id"))
        return (200, [:], ["code": 200, "data": ["token": "synthetic-token"]])
      }
      return (200, [:], ["code": 200, "data": ["enable_otp": true, "token_id": "synthetic-challenge"]])
    }
    let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [NASStubProtocol.self]
    let client = NASClient(config: NASConfiguration(endpoint: "http://nas.local:9999", username: "test"), sessionConfiguration: session)
    do { try await client.login(password: "synthetic"); XCTFail("Must require OTP") }
    catch NASError.otp { }
    try await client.login(password: "synthetic", otp: "123456")
  }
  func testLegacyReadingsUseDeviceStatusAndPreserveUnavailableValues() throws {
    let basic = try value(["cpu": ["cpu_temp": 45], "memory": ["mem_total": 2000, "mem_used_size": 500, "mem_used": 25], "fan": ["fan_speed": 60]])
    let cpu = try value(["cpu": ["cpu_used": 12]])
    let network = try value(["network": ["download_speed": 1200, "upload_speed": 800]])
    let disks = try value(["harddisk": [["disk_place": 1, "disk_temp": 37]]])
    let r = LegacyNASReadings.parse(basic: basic, cpu: cpu, network: network, disks: disks)
    XCTAssertEqual(r.cpu, 12); XCTAssertEqual(r.temperature, 45); XCTAssertEqual(r.memory, 25)
    XCTAssertEqual(r.memoryUsed, 500); XCTAssertEqual(r.download, 1200); XCTAssertEqual(r.upload, 800)
    XCTAssertEqual(r.fanPercent, 60); XCTAssertEqual(r.disks.first?.temperature, 37)
    let temps = try value(["harddisk": [["interface": "ata1", "disk_temp": 37], ["interface": "ata2", "disk_temp": 40]]])
    let inventory = try value(["disks": [["interface": "ata2", "model": "Drive B", "size": 4000], ["interface": "ata1", "model": "Drive A", "size": 2000]]])
    let combined = LegacyNASReadings.parse(basic: .null, cpu: .null, network: .null, disks: temps, inventory: inventory)
    XCTAssertEqual(combined.disks.first?.name, "硬盘 2"); XCTAssertEqual(combined.disks.first?.size, 4000)
    XCTAssertEqual(combined.disks.first?.temperature, 40); XCTAssertEqual(combined.disks.last?.temperature, 37)
    XCTAssertEqual(combined.disks.last?.model, "Drive A")
    let missing = LegacyNASReadings.parse(basic: .null, cpu: .null, network: .null, disks: .null)
    XCTAssertFalse(missing.hasMetrics); XCTAssertNil(missing.cpu); XCTAssertNil(missing.fanPercent)
    let invalid = LegacyNASReadings.parse(basic: try value(["fan": ["fan_speed": 120]]), cpu: try value(["cpu": ["cpu_used": -1]]), network: .null, disks: .null)
    XCTAssertNil(invalid.fanPercent); XCTAssertNil(invalid.cpu)
  }
  func testLegacyLoginAndStorageStayOnTheirOwnEndpoint() async throws {
    NASStubProtocol.handler = { request in
      XCTAssertEqual(request.url?.host, "old-nas.local")
      switch request.url?.path {
      case "/v1/user/offline/login":
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
          stream.open(); defer { stream.close() }; var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
          while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
          data = result
        }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as! [String: Any]
        XCTAssertEqual(body["offline_username"] as? String, "example")
        XCTAssertEqual(body["offline_password"] as? String, "477831ec950d1ffa47797f5857f34a93")
        XCTAssertEqual(body["loginmethod"] as? Int, 7)
        return (200, [:], ["code": 200, "data": ["api_token": "legacy-token"]])
      case "/v2/storage/list":
        XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Token"), "legacy-token")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "legacy-token")
        return (200, [:], ["code": 200, "data": ["storages": [
          ["label": "空间 1", "size": 1000, "used": 300], ["size": 500, "used": 600]
        ]]])
      default: return (404, [:], [:])
      }
    }
    let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [NASStubProtocol.self]
    let client = LegacyNASClient(config: NASConfiguration(endpoint: "http://old-nas.local:9999", username: "example"), sessionConfiguration: session)
    try await client.login("synthetic-password")
    let pools = try await client.storage()
    XCTAssertEqual(pools.count, 1); XCTAssertEqual(pools[0].total, 1000); XCTAssertEqual(pools[0].used, 300)
  }
}

private final class NASStubProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, [String: String], Any))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, headers, object) = try Self.handler!(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
