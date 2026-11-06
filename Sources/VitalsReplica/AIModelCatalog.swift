import Foundation

struct AIModelList {
  let models: [String]
  let remote: Bool
  let note: String?
}

extension AIAnalysisClient {
  static func modelsRequest(config: AIConfiguration, key: String) throws -> URLRequest {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= 4096,
      !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw AIAnalysisError.message("请填入有效的 API Key。")
    }
    var request = URLRequest(url: try AIEndpoint.models(config))
    request.httpMethod = "GET"
    request.timeoutInterval = 25
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if config.provider == .mimo { request.setValue(key, forHTTPHeaderField: "api-key") }
    else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    return request
  }

  static func decodeModels(_ data: Data, provider: AIProvider) throws -> [String] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let entries = root["data"] as? [[String: Any]], entries.count <= 5000 else {
      throw AIAnalysisError.message("模型列表格式不兼容，可在高级中指定模型。")
    }
    var seen = Set<String>()
    let excluded = ["embedding", "rerank", "-tts", "-asr", "whisper", "flux", "stable-diffusion",
                    "image-generation", "video-generation", "speech", "-audio", "bge-", "cosyvoice", "sensevoice", "funasr"]
    var names = entries.compactMap { entry -> String? in
      guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 150,
        id == id.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        !excluded.contains(where: { id.lowercased().contains($0) }) else { return nil }
      if let outputs = entry["output_modalities"] as? [String], !outputs.contains("text") { return nil }
      if let type = entry["sub_type"] as? String, !["chat", "text-generation"].contains(type) { return nil }
      if let endpoints = entry["supported_endpoints"] as? [String],
        !endpoints.contains(where: { $0.contains("chat/completions") || $0 == "chat" }) { return nil }
      return seen.insert(id).inserted ? id : nil
    }
    let order = provider.models
    names.sort { a, b in
      let ai = order.firstIndex(of: a) ?? Int.max, bi = order.firstIndex(of: b) ?? Int.max
      return ai == bi ? a.localizedStandardCompare(b) == .orderedAscending : ai < bi
    }
    guard !names.isEmpty else { throw AIAnalysisError.message("此接口未返回可用于分析的对话模型。") }
    return names
  }

  func models(config: AIConfiguration, key: String) async throws -> AIModelList {
    do {
      let request = try Self.modelsRequest(config: config, key: key)
      let response = try await data(for: request, maximumBytes: 1_048_576)
      return AIModelList(models: try Self.decodeModels(response, provider: config.provider), remote: true, note: nil)
    } catch AIAnalysisError.http(let status) where [404, 405, 501].contains(status) {
      // Never turn auth/network errors or an arbitrary custom route into apparent success.
      guard !config.provider.models.isEmpty,
        try AIEndpoint.base(config.endpoint) == AIEndpoint.base(config.provider.endpoint) else {
        throw AIAnalysisError.http(status)
      }
      return AIModelList(models: config.provider.models, remote: false, note: "接口未提供模型查询，已显示预设。")
    }
  }
}

@MainActor final class AIModelCatalog: ObservableObject {
  @Published private(set) var models: [String] = []
  @Published private(set) var remote = false
  @Published private(set) var revision = 0
  @Published private(set) var loading = false
  @Published private(set) var connected = false
  @Published private(set) var error: String?
  @Published private(set) var note: String?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private let client: AIAnalysisClient
  private let usageRecorder: @MainActor (AITokenUsage?, Bool) -> Void

  init(client: AIAnalysisClient = AIAnalysisClient(), usageRecorder: (@MainActor (AITokenUsage?, Bool) -> Void)? = nil) {
    self.client = client
    self.usageRecorder = usageRecorder ?? { AdvisorStore.shared.recordUsage(usage: $0, success: $1) }
  }
  func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
  func reset(_ config: AIConfiguration) {
    cancel(); remote = false; connected = false; models = config.provider.models; error = nil; note = nil
  }
  func refresh(_ config: AIConfiguration, key: String, debounce: Bool = false, test: Bool = false) {
    cancel()
    let token = generation
    error = nil; note = nil; connected = false; loading = true
    task = Task { [weak self] in
      guard let self else { return }
      var inferenceSent = false
      var inferenceUsage: AITokenUsage?
      var inferenceSucceeded = false
      defer { if inferenceSent { self.usageRecorder(inferenceUsage, inferenceSucceeded) } }
      do {
        if debounce { try await Task.sleep(for: .milliseconds(1000)) }
        try Task.checkCancellation()
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? try await AIKeychain.readAsync(config, allowsInteraction: true) : key
        let result = try await self.client.models(config: config, key: credential)
        if test {
          var checked = config
          if result.remote && !result.models.contains(checked.model), let first = result.models.first { checked.model = first }
          inferenceSent = true
          let completion = try await self.client.complete(config: checked, key: credential, sample: nil)
          inferenceUsage = completion.usage; inferenceSucceeded = true
        }
        try Task.checkCancellation()
        guard self.generation == token else { return }
        self.remote = result.remote; self.models = result.models; self.note = result.note
        self.connected = result.remote || test
        self.revision += 1
      } catch is CancellationError { }
      catch { if self.generation == token { self.error = error.localizedDescription } }
      if self.generation == token { self.loading = false; self.task = nil }
    }
  }
}
