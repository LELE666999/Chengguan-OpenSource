import Foundation
import XCTest
@testable import VitalsReplica

final class AIAnalysisTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_600_000)
  private let reportText = """
  {"status":"attention","summary":"内存压力升高，建议继续观察。","findings":[{"priority":"medium","title":"内存压力","evidence":"当前 memory_pressure 为 warning","explanation":"结合交换量判断。","suggestion":"先减少暂时不用的窗口。","target":"memory"}],"limitations":["只有短时间样本"],"next_checks":["观察内存压力是否回落"]}
  """
  private func fixture() -> MonitorSnapshot {
    var s = MonitorSnapshot()
    s.time = now; s.cpu = 32; s.totalMemory = 48 * 1024 * 1024 * 1024
    s.appMemory = 20 * 1024 * 1024 * 1024; s.swap = 1024 * 1024 * 1024; s.pressureLevel = 2
    s.coreUsage = [20, 30, 40, 50]
    s.volumes = [VolumeSample(path: "/Users/private-owner/Secret", name: "SecretVolume", total: 1000, free: 100, removable: false)]
    s.error = "private log with private credential"
    s.localNetwork.addresses = [LocalIPv4Address(interface: "en0", address: "192.168.33.42")]
    let process = ProcessSample(pid: 654321, ppid: 1, uid: 501, start: 42, name: "SecretProcess",
      path: "/Users/private-owner/Secret.app/run", cpu: 230, memory: 1024, measured: true)
    s.groups = [AppGroup(id: "secret.bundle.id", name: "SecretApp", bundlePath: "/Users/private-owner/Secret.app", processes: [process])]
    return s
  }
  private func sample(names: Bool = false) throws -> AIPreparedSample {
    let s = fixture()
    var old = s.point; old.time = now.addingTimeInterval(-120); old.cpu = 10
    return try AIPreparedSample.prepare(snapshot: s, history: [old, s.point], minutes: 15,
      includeAppNames: names, paused: false, now: now)
  }
  private func envelope(_ content: String, finish: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]],
      "usage": ["prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150]])
  }
  func testDefaultPayloadExcludesNamesPathsAddressesPIDsAndLogs() throws {
    let sample = try sample()
    for privateValue in ["SecretApp", "SecretProcess", "/Users/", "private-owner", "SecretVolume", "secret.bundle.id", "192.168.33.42", "654321", "private credential"] {
      XCTAssertFalse(sample.json.contains(privateValue), "Leaked field: \(privateValue)")
    }
    XCTAssertEqual(sample.appLabels["App1"], "SecretApp")
    XCTAssertTrue(sample.json.contains("App1"))
    let request = try AIAnalysisClient.request(config: AIConfiguration(), key: "synthetic-test-only", sample: sample)
    XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("SecretApp"))
  }
  func testOptInAddsOnlyAppDisplayName() throws {
    let sample = try sample(names: true)
    XCTAssertTrue(sample.json.contains("SecretApp"))
    XCTAssertFalse(sample.json.contains("secret.bundle.id"))
    XCTAssertFalse(sample.json.contains("/Users/"))
  }
  func testSystemProcessAggregateIsExplicitWithoutLeakingAppIdentity() throws {
    var s = fixture()
    s.groups = [AppGroup(id: "system.macos", name: "macOS", bundlePath: nil, processes: s.groups[0].processes)]
    let prepared = try AIPreparedSample.prepare(snapshot: s, history: [s.point], minutes: 5,
      includeAppNames: false, paused: false, now: now)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any])
    let apps = try XCTUnwrap(root["top_apps_current_sample_only"] as? [[String: Any]])
    XCTAssertEqual(apps[0]["group_kind"] as? String, "system_aggregate")
    XCTAssertFalse(prepared.json.contains("system.macos"))
    XCTAssertEqual(prepared.appLabels["App1"], "macOS")
  }
  func testUnitsPartialMeasurementAndMissingMetricsRemainExplicit() throws {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try sample().json.utf8)) as? [String: Any])
    let current = try XCTUnwrap(root["current"] as? [String: Any])
    XCTAssertTrue(current["gpu_percent"] is NSNull)
    XCTAssertTrue(current["temperature_c"] is NSNull)
    XCTAssertTrue(current["power_connected"] is NSNull)
    XCTAssertEqual(current["memory_pressure"] as? String, "warning")
    XCTAssertEqual(current["memory_total_bytes"] as? UInt64, fixture().totalMemory)
    let apps = try XCTUnwrap(root["top_apps_current_sample_only"] as? [[String: Any]])
    XCTAssertEqual(apps.count, 1)
    XCTAssertEqual(apps[0]["cpu_single_core_percent"] as? Double, 230)
  }
  func testWindowReportsGapsRatherThanFillingThem() throws {
    let data = try sample()
    XCTAssertEqual(data.sampleCount, 2)
    XCTAssertEqual(data.observedSeconds, 120)
    let root = try JSONSerialization.jsonObject(with: Data(data.json.utf8)) as! [String: Any]
    let window = root["observed_window"] as! [String: Any]
    XCTAssertEqual(window["maximum_sample_gap_seconds"] as? Double, 120)
    XCTAssertEqual((window["cpu_percent"] as? [String: Any])?["mean"] as? Double, 21)
    XCTAssertEqual((window["gpu_percent"] as? [String: Any])?["sample_count"] as? Int, 0)
  }
  func testPausedStaleAndUninitializedSamplesAreRejected() throws {
    XCTAssertThrowsError(try AIPreparedSample.prepare(snapshot: fixture(), history: [], minutes: 15, includeAppNames: false, paused: true, now: now))
    XCTAssertThrowsError(try AIPreparedSample.prepare(snapshot: fixture(), history: [], minutes: 15, includeAppNames: false, paused: false, now: now.addingTimeInterval(31)))
    XCTAssertThrowsError(try AIPreparedSample.prepare(snapshot: MonitorSnapshot(), history: [], minutes: 15, includeAppNames: false, paused: false, now: now))
  }
  func testNonFiniteValuesBecomeNullAndOutOfWindowSamplesAreExcluded() throws {
    var s = fixture(); s.gpu = .nan; s.temperature = .infinity
    var old = s.point; old.time = now.addingTimeInterval(-301)
    let value = try AIPreparedSample.prepare(snapshot: s, history: [old, s.point], minutes: 5, includeAppNames: false, paused: false, now: now)
    XCTAssertEqual(value.sampleCount, 1)
    let root = try JSONSerialization.jsonObject(with: Data(value.json.utf8)) as! [String: Any]
    XCTAssertTrue((root["current"] as! [String: Any])["gpu_percent"] is NSNull)
  }
  func testEndpointNormalizationAndCredentialIsolation() throws {
    XCTAssertEqual(try AIEndpoint.completion(" HTTPS://API.XIAOMIMIMO.COM:443/v1/chat/completions/ ").absoluteString,
                   "https://api.xiaomimimo.com/v1/chat/completions")
    let a = AIConfiguration(), same = AIConfiguration(provider: .mimo, endpoint: "https://api.xiaomimimo.com:443/v1/", model: "other")
    XCTAssertEqual(try AIKeychain.account(a), try AIKeychain.account(same))
    let other = AIConfiguration(provider: .mimo, endpoint: "https://token-plan-cn.xiaomimimo.com/v1", model: a.model)
    XCTAssertNotEqual(try AIKeychain.account(a), try AIKeychain.account(other))
    XCTAssertTrue(AIEndpoint.isTokenPlan(other.endpoint))
    XCTAssertFalse(AIEndpoint.isTokenPlan("https://token-plan-cn.xiaomimimo.com.attacker.example/v1"))
  }
  func testInvalidEndpointsAndHeaderInjectionAreRejected() throws {
    for value in ["http://example.com", "file:///tmp/a", "https://user:password@example.com", "https://example.com/?key=secret", "https://example.com/#x", ""] {
      XCTAssertThrowsError(try AIEndpoint.base(value))
    }
    XCTAssertThrowsError(try AIAnalysisClient.request(config: AIConfiguration(), key: "test\nHeader: injected", sample: nil))
  }
  func testKeychainRoundTripReplacementAndRemovalUseIsolatedTestAccount() throws {
    let config = AIConfiguration(provider: .compatible,
      endpoint: "https://\(UUID().uuidString.lowercased()).invalid/v1", model: "test-only")
    defer { try? AIKeychain.remove(config) }
    XCTAssertFalse(AIKeychain.contains(config))
    try AIKeychain.save("synthetic-test-value-1", config: config)
    XCTAssertTrue(AIKeychain.contains(config))
    XCTAssertEqual(try AIKeychain.read(config), "synthetic-test-value-1")
    try AIKeychain.save("synthetic-test-value-2", config: config)
    XCTAssertEqual(try AIKeychain.read(config), "synthetic-test-value-2")
    try AIKeychain.remove(config)
    XCTAssertFalse(AIKeychain.contains(config))
    XCTAssertThrowsError(try AIKeychain.read(config))
  }
  @MainActor func testBackgroundKeychainReadUsesOnlyIsolatedSyntheticAccount() async throws {
    let config = AIConfiguration(provider: .compatible,
      endpoint: "https://\(UUID().uuidString.lowercased()).invalid/v1", model: "test-only")
    defer { try? AIKeychain.remove(config) }
    try await AIKeychain.saveAsync("synthetic-async-value", config: config)
    let exists = await AIKeychain.containsAsync(config)
    XCTAssertTrue(exists)
    let value = try await AIKeychain.readAsync(config, allowsInteraction: false)
    XCTAssertEqual(value, "synthetic-async-value")
    try await AIKeychain.removeAsync(config)
    let removed = await AIKeychain.containsAsync(config)
    XCTAssertFalse(removed)
  }
  func testProviderSpecificAuthenticationAndTokenCaps() throws {
    let mimo = try AIAnalysisClient.request(config: AIConfiguration(), key: "synthetic-key", sample: sample())
    XCTAssertEqual(mimo.value(forHTTPHeaderField: "api-key"), "synthetic-key")
    XCTAssertNil(mimo.value(forHTTPHeaderField: "Authorization"))
    let mb = try JSONSerialization.jsonObject(with: mimo.httpBody!) as! [String: Any]
    XCTAssertEqual(mb["max_completion_tokens"] as? Int, 3072)
    XCTAssertEqual((mb["thinking"] as? [String: String])?["type"], "disabled")
    XCTAssertFalse(String(decoding: mimo.httpBody!, as: UTF8.self).contains("synthetic-key"))
    let config = AIConfiguration(provider: .deepseek, endpoint: AIProvider.deepseek.endpoint, model: "deepseek-flash")
    let deep = try AIAnalysisClient.request(config: config, key: "synthetic-key", sample: nil)
    XCTAssertEqual(deep.url?.absoluteString, "https://api.deepseek.com/chat/completions")
    XCTAssertEqual(deep.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    let db = try JSONSerialization.jsonObject(with: deep.httpBody!) as! [String: Any]
    XCTAssertEqual(db["max_tokens"] as? Int, 32)
    XCTAssertNil(db["response_format"])
    XCTAssertFalse(String(decoding: deep.httpBody!, as: UTF8.self).contains("monitoring_data"))
  }
  func testCustomProviderOmitsVendorOnlyParameters() throws {
    let config = AIConfiguration(provider: .compatible, endpoint: "https://example.com/v1", model: "custom-model")
    let request = try AIAnalysisClient.request(config: config, key: "synthetic", sample: sample())
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    XCTAssertNil(body["thinking"])
    XCTAssertNotNil(body["response_format"])
    XCTAssertEqual(body["max_tokens"] as? Int, 3072)
  }
  func testReportSchemaAndTruncationAreValidated() throws {
    let report = try AIReport.parse(reportText)
    XCTAssertEqual(report.findings.first?.target.tab, .memory)
    XCTAssertEqual(try AIReport.parse("```json\n\(reportText)\n```"), report)
    XCTAssertThrowsError(try AIReport.parse("{\"summary\":\"Incomplete\"}"))
    XCTAssertThrowsError(try AIReport.parse(reportText.replacingOccurrences(of: "\"medium\"", with: "\"execute_shell\"")))
    XCTAssertThrowsError(try AIReport.parse(reportText.replacingOccurrences(of: "\"attention\"", with: "\"unknown\"")))
    XCTAssertThrowsError(try AIAnalysisClient.decode(envelope(reportText, finish: "length")))
    XCTAssertThrowsError(try AIAnalysisClient.decode(envelope("", finish: "content_filter")))
    let completion = try AIAnalysisClient.decode(envelope(reportText))
    XCTAssertEqual(completion.usage?.totalTokens, 150)
  }
  func testHistoryBoundedRoundTripAndPrivatePermissions() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = AIHistoryFile(url: folder.appendingPathComponent("ai.json"))
    XCTAssertEqual(try file.load().count, 0)
    let report = try AIReport.parse(reportText)
    let records = (0..<25).map { _ in AIAnalysisRecord(id: UUID(), createdAt: now, sampledAt: now, mode: .overview,
      provider: "Mock", model: "test", requestedMinutes: 15, sampleCount: 2, observedSeconds: 120,
      appLabels: ["App1": "LocalApp"], report: report, usage: nil, duration: 1) }
    try file.save(records)
    let loaded = try file.load()
    XCTAssertEqual(loaded.count, 20)
    XCTAssertEqual(loaded.first?.report, report)
    XCTAssertFalse(loaded.first!.markdown.contains("App1：LocalApp"))
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try file.save([])
    XCTAssertTrue(try file.load().isEmpty)
  }
  func testMockedHTTPCompletionAndNoRetryOnQuotaError() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIStubProtocol.self]
    let client = AIAnalysisClient(configuration: config)
    AIStubProtocol.set(status: 200, data: try envelope(reportText))
    let reply = try await client.complete(config: AIConfiguration(), key: "synthetic-only", sample: sample())
    XCTAssertEqual(try AIReport.parse(reply.content).status, .attention)
    XCTAssertEqual(AIStubProtocol.count, 1)
    AIStubProtocol.set(status: 429, data: Data("do not display arbitrary server text".utf8))
    do {
      _ = try await client.complete(config: AIConfiguration(), key: "synthetic-only", sample: sample())
      XCTFail("Expected quota error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("额度"))
      XCTAssertFalse(error.localizedDescription.contains("arbitrary"))
    }
    XCTAssertEqual(AIStubProtocol.count, 1)
  }
  func testHTTPResponseLimitAndCancellation() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIStubProtocol.self]
    let client = AIAnalysisClient(configuration: config)
    AIStubProtocol.set(status: 200, data: Data(repeating: 65, count: 262_145))
    do {
      _ = try await client.complete(config: AIConfiguration(), key: "synthetic-only", sample: nil)
      XCTFail("Expected response size error")
    } catch { XCTAssertTrue(error.localizedDescription.contains("过大")) }
    AIStubProtocol.set(status: 200, data: try envelope("OK"), delay: 2)
    let task = Task { try await client.complete(config: AIConfiguration(), key: "synthetic-only", sample: nil) }
    try await Task.sleep(nanoseconds: 30_000_000)
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
  func testProviderEndpointsAndModelRequestsDoNotRequireManualModel() throws {
    for provider in AIProvider.allCases where provider != .compatible {
      let config = AIConfiguration(provider: provider, endpoint: provider.endpoint, model: "")
      let request = try AIAnalysisClient.modelsRequest(config: config, key: "synthetic-key")
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertNil(request.httpBody)
      XCTAssertEqual(request.url?.path, (try AIEndpoint.base(provider.endpoint)).path + "/models")
      XCTAssertEqual(AIProvider.matching(provider.endpoint + "/"), provider)
      if provider == .mimo { XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-key") }
      else { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key") }
    }
    let accounts = try AIProvider.allCases.map {
      try AIKeychain.account(AIConfiguration(provider: $0, endpoint: "https://same.invalid/v1", model: ""))
    }
    XCTAssertEqual(Set(accounts).count, AIProvider.allCases.count)
    XCTAssertEqual(try AIEndpoint.models(AIConfiguration(provider: .siliconflow, endpoint: AIProvider.siliconflow.endpoint, model: "")).query, "sub_type=chat")
    XCTAssertNil(AIProvider.matching("https://api.deepseek.com.attacker.example"))
    XCTAssertThrowsError(try AIAnalysisClient.modelsRequest(config: AIConfiguration(), key: "key\nInjected: value"))
  }
  func testModelCatalogFiltersNonTextModelsDeduplicatesAndPrefersRecommended() throws {
    let data = try JSONSerialization.data(withJSONObject: ["data": [
      ["id": "mimo-v2.6-pro"], ["id": "mimo-v2.6-flash"], ["id": "mimo-v2.6-flash"],
      ["id": "mimo-v2.5-tts"], ["id": "image-model", "output_modalities": ["image"]],
      ["id": "embed-model", "sub_type": "embedding"], ["id": "qwen-vl", "output_modalities": ["text"]],
      ["id": "response-only", "supported_endpoints": ["responses"]], ["id": "bad\nname"],
      ["id": "a/new-chat-model"], ["id": ""]
    ]])
    XCTAssertEqual(try AIAnalysisClient.decodeModels(data, provider: .mimo),
      ["mimo-v2.6-flash", "mimo-v2.6-pro", "a/new-chat-model", "qwen-vl"])
  }
  func testInvalidEmptyAndOversizedCatalogsAreRejected() throws {
    for data in [Data("not-json".utf8), Data("{\"models\":[]}".utf8), Data("{\"data\":[]}".utf8),
      try JSONSerialization.data(withJSONObject: ["data": Array(repeating: ["id": "model"], count: 5001)])] {
      XCTAssertThrowsError(try AIAnalysisClient.decodeModels(data, provider: .compatible))
    }
  }
  func testModelFetchAndOnlyUnsupportedOfficialRoutesFallBackToPresets() async throws {
    let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [AIStubProtocol.self]
    let client = AIAnalysisClient(configuration: setup)
    AIStubProtocol.set(status: 200, data: Data("{\"data\":[{\"id\":\"account-chat-model\"}]}".utf8))
    let actual = try await client.models(config: AIConfiguration(), key: "synthetic")
    XCTAssertTrue(actual.remote); XCTAssertEqual(actual.models, ["account-chat-model"])
    for status in [404, 405, 501] {
      AIStubProtocol.set(status: status, data: Data())
      let fallback = try await client.models(config: AIConfiguration(), key: "synthetic")
      XCTAssertFalse(fallback.remote); XCTAssertNotNil(fallback.note)
      XCTAssertEqual(fallback.models, AIProvider.mimo.models)
    }
    for status in [401, 403, 429, 500] {
      AIStubProtocol.set(status: status, data: Data("do not expose backend body".utf8))
      do { _ = try await client.models(config: AIConfiguration(), key: "synthetic"); XCTFail("Must report failure") }
      catch { XCTAssertFalse(error.localizedDescription.contains("backend body")) }
      XCTAssertEqual(AIStubProtocol.count, 1)
    }
    AIStubProtocol.set(status: 404, data: Data())
    let custom = AIConfiguration(provider: .mimo, endpoint: "https://custom.invalid/v1", model: "")
    do { _ = try await client.models(config: custom, key: "synthetic"); XCTFail("No custom route fallback") }
    catch { XCTAssertTrue(error.localizedDescription.contains("找不到")) }
  }
  @MainActor func testProviderSwitchCancelsCatalogAndLateResultsCannotReplaceNewProvider() async throws {
    let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [AIStubProtocol.self]
    let catalog = AIModelCatalog(client: AIAnalysisClient(configuration: setup), usageRecorder: { _, _ in })
    AIStubProtocol.set(status: 200, data: Data("{\"data\":[{\"id\":\"old-model\"}]}".utf8), delay: 0.2)
    catalog.refresh(AIConfiguration(), key: "synthetic-old")
    try await Task.sleep(for: .milliseconds(25))
    let next = AIConfiguration(provider: .deepseek, endpoint: AIProvider.deepseek.endpoint, model: "")
    catalog.reset(next)
    AIStubProtocol.set(status: 200, data: Data("{\"data\":[{\"id\":\"new-model\"}]}".utf8))
    catalog.refresh(next, key: "synthetic-new")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(catalog.models, ["new-model"]); XCTAssertTrue(catalog.remote); XCTAssertNil(catalog.error)
    AIStubProtocol.set(status: 200, data: Data(), delay: 0.2)
    catalog.refresh(next, key: "synthetic-new", debounce: true)
    catalog.reset(AIConfiguration())
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(AIStubProtocol.count, 0)
    XCTAssertEqual(catalog.models, AIProvider.mimo.models); XCTAssertFalse(catalog.loading)
  }
  func testReasoningOnlyProvidersAreNotSentUnsupportedDisableFlag() throws {
    for provider in [AIProvider.zhipu, .minimax] {
      let config = AIConfiguration(provider: provider, endpoint: provider.endpoint, model: provider.models.first!)
      let request = try AIAnalysisClient.request(config: config, key: "synthetic", sample: sample())
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      XCTAssertNil(body["thinking"])
      XCTAssertEqual(body["max_tokens"] as? Int, 8192)
      if provider == .minimax { XCTAssertNil(body["response_format"]); XCTAssertEqual(body["reasoning_effort"] as? String, "low") }
    }
    let config = AIConfiguration(provider: .qwen, endpoint: AIProvider.qwen.endpoint, model: "qwen3.8-flash")
    let request = try AIAnalysisClient.request(config: config, key: "synthetic", sample: sample())
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    XCTAssertEqual(body["enable_thinking"] as? Bool, false)
    XCTAssertNil(body["thinking"])
  }
  func testReasoningTextIsNotDisplayedOrSavedAsReport() throws {
    let reply = try AIAnalysisClient.decode(envelope("<think>private internal reasoning</think>\n" + reportText))
    XCTAssertEqual(reply.content, reportText)
    XCTAssertEqual(try AIReport.parse(reply.content).status, .attention)
    XCTAssertThrowsError(try AIAnalysisClient.decode(envelope("<think>incomplete")))
    XCTAssertThrowsError(try AIAnalysisClient.decode(envelope("<think>only reasoning</think>")))
  }
  @MainActor func testConnectionVerifiesInferenceBeforeShowingFetchedModels() async throws {
    let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [AIStubProtocol.self]
    var recorded: [(AITokenUsage?, Bool)] = []
    let catalog = AIModelCatalog(client: AIAnalysisClient(configuration: setup), usageRecorder: { recorded.append(($0, $1)) })
    AIStubProtocol.set(status: 200, data: Data("{\"data\":[{\"id\":\"actual-model\"}]}".utf8),
      postStatus: 200, postData: try envelope("OK"))
    catalog.refresh(AIConfiguration(), key: "synthetic", test: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(catalog.connected); XCTAssertTrue(catalog.remote)
    XCTAssertEqual(catalog.models, ["actual-model"]); XCTAssertEqual(AIStubProtocol.count, 2)
    XCTAssertEqual(recorded.count, 1); XCTAssertTrue(recorded[0].1); XCTAssertEqual(recorded[0].0?.totalTokens, 150)
    AIStubProtocol.set(status: 200, data: Data("{\"data\":[{\"id\":\"actual-model\"}]}".utf8), postStatus: 403)
    catalog.reset(AIConfiguration()); catalog.refresh(AIConfiguration(), key: "synthetic", test: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(catalog.connected); XCTAssertNotNil(catalog.error)
    XCTAssertFalse(catalog.remote); XCTAssertEqual(AIStubProtocol.count, 2)
    XCTAssertEqual(recorded.count, 2); XCTAssertFalse(recorded[1].1); XCTAssertNil(recorded[1].0)
  }
  @MainActor func testUnsupportedCatalogStillRequiresSuccessfulConnectionForPresets() async throws {
    let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [AIStubProtocol.self]
    let catalog = AIModelCatalog(client: AIAnalysisClient(configuration: setup), usageRecorder: { _, _ in })
    AIStubProtocol.set(status: 404, data: Data(), postStatus: 200, postData: try envelope("OK"))
    catalog.refresh(AIConfiguration(), key: "synthetic", test: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(catalog.connected); XCTAssertFalse(catalog.remote); XCTAssertNotNil(catalog.note)
    XCTAssertEqual(AIStubProtocol.count, 2)
    AIStubProtocol.set(status: 404, data: Data(), postStatus: 401)
    catalog.reset(AIConfiguration()); catalog.refresh(AIConfiguration(), key: "synthetic", test: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(catalog.connected); XCTAssertNotNil(catalog.error)
  }
  func testConciseSummaryKeepsHistoryFreshnessAndFixedActionDestinations() throws {
    let text = String(repeating: "准确指标", count: 30) + "\n后续"
    let report = AIReport(status: .attention, summary: text, findings: [], limitations: [], nextChecks: [])
    let item = AIAnalysisRecord(id: UUID(), createdAt: now, sampledAt: now, mode: .overview,
      provider: "Mock", model: "model", requestedMinutes: 15, sampleCount: 2, observedSeconds: 120,
      appLabels: [:], report: report, usage: nil, duration: 1)
    XCTAssertEqual(item.conciseSummary.count, 75)
    XCTAssertFalse(item.conciseSummary.contains("\n"))
    XCTAssertTrue(item.isRecent(at: now.addingTimeInterval(10)))
    XCTAssertFalse(item.isRecent(at: now.addingTimeInterval(901)))
    XCTAssertFalse(item.isRecent(at: now.addingTimeInterval(-1)))
    XCTAssertNil(AIReport.Target.memory.settingsURL)
    XCTAssertEqual(AIReport.Target.battery.settingsURL?.scheme, "x-apple.systempreferences")
    XCTAssertEqual(AIReport.Target.network.settingsURL?.absoluteString, "x-apple.systempreferences:com.apple.Network-Settings.extension")
  }
  func testRedirectIsRefused() {
    let delegate = AINoRedirectDelegate()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://example.com")!
    let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example"])!
    delegate.urlSession(session, task: session.dataTask(with: url), willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://other.example")!)) { request in XCTAssertNil(request) }
    XCTAssertTrue(AIAnalysisClient.httpError(302).localizedDescription.contains("重定向"))
  }
}

private final class AIStubProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var status = 200
  private static var payload = Data()
  private static var delay = 0.0
  private static var requests = 0
  private static var postStatus: Int?
  private static var postPayload = Data()
  static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
  static func set(status: Int, data: Data, delay: Double = 0, postStatus: Int? = nil, postData: Data = Data()) {
    lock.lock(); defer { lock.unlock() }
    self.status = status; payload = data; self.delay = delay; requests = 0
    self.postStatus = postStatus; self.postPayload = postData
  }
  private var work: DispatchWorkItem?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests += 1
    let post = request.httpMethod == "POST" && Self.postStatus != nil
    let status = post ? Self.postStatus! : Self.status, data = post ? Self.postPayload : Self.payload, delay = Self.delay
    Self.lock.unlock()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    self.work = work
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
  }
  override func stopLoading() { work?.cancel() }
}
