import AppKit
import Combine

@MainActor final class StorageSpeedStore: ObservableObject {
  static let shared = StorageSpeedStore(historyURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Chengguan/storage-speed.json"))
  @Published private(set) var active: StorageSpeedTarget?
  @Published private(set) var progress: StorageSpeedProgress?
  @Published private(set) var history: [StorageSpeedResult] = []
  @Published private(set) var status: String?
  @Published private(set) var cancelling = false
  @Published private(set) var historyIssue: String?
  private var worker: Task<StorageSpeedResult, Error>?
  private var observer: AnyCancellable?
  private var generation: UUID?
  private let historyURL: URL?
  var running: Bool { active != nil }
  init(historyURL: URL? = nil) {
    self.historyURL = historyURL
    if let historyURL, FileManager.default.fileExists(atPath: historyURL.path) {
      do {
        let size = try historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 2_000_000 else { throw StorageSpeedError.message("测速历史文件过大。") }
        let decoded = try JSONDecoder().decode([StorageSpeedResult].self, from: Data(contentsOf: historyURL))
        history = Array(decoded.filter(\.valid).prefix(10))
        if decoded.contains(where: { !$0.valid }) { historyIssue = "已忽略无效的历史记录。" }
      } catch { historyIssue = "历史暂不可用；仍可开始新测试。" }
    }
  }
  func result(for id: String) -> StorageSpeedResult? { history.first { $0.targetID == id } }
  func start(_ target: StorageSpeedTarget, size: StorageSpeedSize) {
    guard !running else { return }
    guard !StorageFormatStore.shared.running else { status = "请等待格式化完成后再测速。"; return }
    if let v = target.external, ExternalStorageMonitor.shared.busy.contains(v.id) { status = "存储正在操作中，请稍后再试。"; return }
    let token = UUID(); generation = token
    active = target; progress = .init(sequence: 0, phase: .preparing, fraction: 0, megabytesPerSecond: 0, samples: [])
    cancelling = false; status = nil
    if let v = target.external {
      observer = ExternalStorageMonitor.shared.$volumes.sink { [weak self] volumes in
        guard !volumes.contains(where: { $0.id == v.id && $0.path == v.path }) else { return }
        self?.cancel(reason: "设备已移除，测速已停止。")
      }
    }
    ExternalStorageMonitor.shared.speedMessage(target, title: target.name + " 开始测速", detail: "正在使用临时文件测试读写")
    let task = Task.detached(priority: .utility) { [weak self] in
      try StorageSpeedEngine.run(target: target, configuration: .init(bytes: size.bytes)) { [weak self] update in
        Task { @MainActor [weak self] in
          guard let self, generation == token, active != nil, update.sequence > (progress?.sequence ?? -1) else { return }
          progress = update
        }
      }
    }
    worker = task
    // An initial publisher event may already have discovered disconnection.
    if cancelling { task.cancel() }
    Task { [weak self] in
      do {
        let result = try await task.value
        guard let self, generation == token else { return }
        if !cancelling {
          history.insert(result, at: 0); history = Array(history.prefix(10)); save()
          status = nil
          ExternalStorageMonitor.shared.speedMessage(target, title: target.name + " 测速完成",
            detail: "读 \(StorageSpeedResult.rate(result.read.average)) · 写 \(StorageSpeedResult.rate(result.write.average)) MB/s")
        }
      } catch {
        guard let self, generation == token else { return }
        if !cancelling { status = error is CancellationError ? "已停止测试。" : error.localizedDescription }
        ExternalStorageMonitor.shared.speedMessage(target, title: target.name + " 测速已停止", detail: status ?? "测试已停止")
      }
      guard let self, generation == token else { return }
      active = nil; worker = nil; observer = nil; cancelling = false; generation = nil
    }
  }
  func cancel(reason: String = "已取消测试，临时文件会在关闭后释放。") {
    guard running else { return }
    cancelling = true; status = reason; worker?.cancel()
  }
  private func save() {
    guard let historyURL else { return }
    do {
      try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
      historyIssue = nil
    } catch { historyIssue = "结果已生成，但未能保存历史。" }
  }
}
