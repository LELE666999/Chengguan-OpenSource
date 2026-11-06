import Foundation
import Darwin

struct StorageSpeedTarget: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let directory: String
  let format: String
  let transport: String
  let external: ExternalVolume?
  init(volume: ExternalVolume) {
    id = volume.id; name = volume.name; directory = volume.path
    format = volume.formatDescription; transport = volume.transport; external = volume
  }
  /// The user's temporary directory is on the writable Data volume, not the sealed system volume.
  static let internalDisk = local(directory: NSTemporaryDirectory())
  static func local(directory: String) -> Self {
    let info = try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey])
    return Self(id: "internal-" + (info?.volumeUUIDString ?? "local"), name: "内置存储", directory: directory,
      format: info?.volumeLocalizedFormatDescription ?? "本地文件系统", transport: "内置", external: nil)
  }
  private init(id: String, name: String, directory: String, format: String, transport: String, external: ExternalVolume?) {
    self.id = id; self.name = name; self.directory = directory; self.format = format; self.transport = transport; self.external = external
  }
}

enum StorageSpeedSize: Int, CaseIterable, Identifiable {
  case quick = 256, standard = 1024, extended = 2048
  var id: Int { rawValue }
  var bytes: Int { rawValue * 1_048_576 }
  var title: String { self == .quick ? "256 MiB" : self == .standard ? "1 GiB" : "2 GiB" }
}
enum StorageSpeedPhase: String, Codable, Sendable {
  case preparing, writing, syncing, reading, complete
  var title: String {
    switch self {
    case .preparing: "准备中"
    case .writing: "正在写入"
    case .syncing: "正在同步写入"
    case .reading: "正在读取并校验"
    case .complete: "测试完成"
    }
  }
}
struct StorageSpeedProgress: Sendable {
  let sequence: Int
  let phase: StorageSpeedPhase
  let fraction: Double
  let megabytesPerSecond: Double
  let samples: [Double]
  var completedWrite: StorageSpeedReading? = nil
}
struct StorageSpeedReading: Codable, Equatable, Sendable {
  let bytes: Int
  let seconds: Double
  let samples: [Double]
  var average: Double { seconds > 0 ? Double(bytes) / seconds / 1_000_000 : 0 }
  // Samples are time windows, never the fastest individual system call.
  var peak: Double { max(average, samples.max() ?? 0) }
}
struct StorageSpeedResult: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let targetID: String
  let name: String
  let date: Date
  let format: String
  let transport: String
  let write: StorageSpeedReading
  let read: StorageSpeedReading
  let fullSync: Bool
  var valid: Bool {
    func validReading(_ value: StorageSpeedReading) -> Bool {
      value.bytes > 0 && value.bytes <= StorageSpeedSize.extended.bytes && value.seconds.isFinite && value.seconds > 0
        && value.samples.count <= 1024 && value.samples.allSatisfy { $0.isFinite && $0 >= 0 }
    }
    return !targetID.isEmpty && targetID.count <= 512 && name.count <= 512 && date.timeIntervalSince1970.isFinite
      && validReading(write) && validReading(read) && write.bytes == read.bytes
  }
  var shortTest: Bool { min(write.seconds, read.seconds) < 2 }
  var text: String {
    "\(name) · \(format) · \(transport)\n" +
    "顺序写入 \(Self.rate(write.average)) MB/s · 采样峰值 \(Self.rate(write.peak)) MB/s\n" +
    "顺序读取 \(Self.rate(read.average)) MB/s · 采样峰值 \(Self.rate(read.peak)) MB/s\n" +
    "数据量 \(Format.bytes(UInt64(write.bytes))) · F_NOCACHE · 读回校验通过 · \(fullSync ? "F_FULLFSYNC" : "fsync")\n" +
    "实测为整个存储连接的表现，不代表线缆独立速度或硬件最高持续速度。"
  }
  static func rate(_ value: Double) -> String { String(format: "%.1f", value) }
}
enum StorageSpeedError: LocalizedError, Equatable {
  case message(String)
  var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Finite sequential I/O, on a private file only. No raw devices, shell, caches purge or privilege escalation.
enum StorageSpeedEngine {
  struct Configuration: Sendable {
    var bytes = StorageSpeedSize.standard.bytes
    var blockBytes = 4 * 1_048_576
    var reserveBytes: UInt64 = 512 * 1_048_576
    var timeout: TimeInterval = 180
  }
  static func validate(bytes: Int, free: UInt64, reserve: UInt64, readOnly: Bool) throws {
    guard !readOnly else { throw StorageSpeedError.message("此存储为只读，无法执行写入测试。") }
    guard bytes > 0, bytes <= StorageSpeedSize.extended.bytes else { throw StorageSpeedError.message("测试数据量无效。") }
    guard free >= reserve, free - reserve >= UInt64(bytes) else {
      throw StorageSpeedError.message("可用空间不足；测试文件之外还需保留至少 512 MiB。")
    }
  }
  static func run(target: StorageSpeedTarget, configuration c: Configuration = .init(),
                  progress: @Sendable (StorageSpeedProgress) -> Void = { _ in }) throws -> StorageSpeedResult {
    try Task.checkCancellation()
    if let external = target.external {
      guard let live = ExternalStorageReader.readMounted(external) else { throw StorageSpeedError.message("存储已移除或连接已变化。") }
      guard live.readOnly != true else { throw StorageSpeedError.message("此存储为只读，无法执行写入测试。") }
    }
    guard c.blockBytes > 0, c.blockBytes <= 16 * 1_048_576, c.timeout > 0 else {
      throw StorageSpeedError.message("测试参数无效。")
    }
    var before = statfs()
    guard statfs(target.directory, &before) == 0 else { throw failure("无法访问存储") }
    let root = Darwin.open(target.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw failure("无法访问存储") }
    defer { Darwin.close(root) }
    var fs = statfs()
    guard fstatfs(root, &fs) == 0, fs.f_fsid.val == before.f_fsid.val else {
      throw StorageSpeedError.message("连接已变化，请重新选择存储。")
    }
    guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw StorageSpeedError.message("仅支持本机挂载的存储。") }
    if let external = target.external {
      let source = withUnsafePointer(to: &fs.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
      guard source == "/dev/" + external.bsdName else { throw StorageSpeedError.message("连接已变化，请重新选择存储。") }
    }
    let available = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_bsize))
    guard !available.overflow else { throw StorageSpeedError.message("无法确认可用空间。") }
    try validate(bytes: c.bytes, free: available.partialValue, reserve: c.reserveBytes, readOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0)
    let fileName = ".chengguan-speed-" + UUID().uuidString + ".tmp"
    let fd = openat(root, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw failure("无法创建测速临时文件") }
    defer { Darwin.close(fd) }
    // Unlink *before* writing: the open descriptor owns the file; closing, cancellation and process exit reclaim it.
    // All file operations stay anchored to descriptors, even if /Volumes/name is reused by a different device.
    guard unlinkat(root, fileName, 0) == 0 else {
      let error = failure("此文件系统无法安全清理测速文件")
      _ = unlinkat(root, fileName, 0)
      throw error
    }
    guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw failure("此存储不支持绕过系统文件缓存，未开始测速") }
    let block = min(c.blockBytes, c.bytes)
    let source = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16384)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16384)
    defer { source.deallocate(); buffer.deallocate() }
    arc4random_buf(source, block)
    let started = ProcessInfo.processInfo.systemUptime
    var sequence = 0
    var completedWrite: StorageSpeedReading?
    func check() throws {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - started < c.timeout else { throw StorageSpeedError.message("测试已超时，请检查设备连接后重试。") }
    }
    func emit(_ phase: StorageSpeedPhase, _ fraction: Double, _ rate: Double = 0, _ samples: [Double] = []) {
      sequence += 1; progress(.init(sequence: sequence, phase: phase, fraction: fraction, megabytesPerSecond: rate, samples: samples, completedWrite: completedWrite))
    }
    emit(.writing, 0)
    var meter = Meter(start: ProcessInfo.processInfo.systemUptime)
    var offset = 0
    while offset < c.bytes {
      try check()
      let count = min(block, c.bytes - offset)
      var done = 0
      while done < count {
        try check()
        let n = Darwin.write(fd, source.advanced(by: done), count - done)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw failure("写入失败") }
        done += n
      }
      offset += count
      if meter.record(bytes: offset, at: ProcessInfo.processInfo.systemUptime) {
        emit(.writing, Double(offset) / Double(c.bytes) * 0.5, meter.samples.last ?? 0, meter.samples)
      }
    }
    try check(); emit(.syncing, 0.5, 0, meter.samples)
    let fullSync = fcntl(fd, F_FULLFSYNC) == 0
    if !fullSync { guard fsync(fd) == 0 else { throw failure("写入同步失败") } }
    // The average includes the final flush. Hardware caches may remain when only fsync is supported.
    let writeResult = meter.finish(bytes: c.bytes, at: ProcessInfo.processInfo.systemUptime)
    completedWrite = writeResult
    try check()
    guard lseek(fd, 0, SEEK_SET) == 0 else { throw failure("无法读取测试文件") }
    emit(.reading, 0.5)
    meter = Meter(start: ProcessInfo.processInfo.systemUptime); offset = 0
    while offset < c.bytes {
      try check()
      let count = min(block, c.bytes - offset)
      var done = 0
      while done < count {
        try check()
        let n = Darwin.read(fd, buffer.advanced(by: done), count - done)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw failure("读取失败或测试文件不完整") }
        done += n
      }
      guard memcmp(source, buffer, count) == 0 else { throw StorageSpeedError.message("读回校验未通过；请检查存储与连接。") }
      offset += count
      if meter.record(bytes: offset, at: ProcessInfo.processInfo.systemUptime) {
        emit(.reading, 0.5 + Double(offset) / Double(c.bytes) * 0.5, meter.samples.last ?? 0, meter.samples)
      }
    }
    try check()
    let readResult = meter.finish(bytes: c.bytes, at: ProcessInfo.processInfo.systemUptime)
    emit(.complete, 1)
    return StorageSpeedResult(id: UUID(), targetID: target.id, name: target.name, date: Date(), format: target.format,
      transport: target.transport, write: writeResult, read: readResult, fullSync: fullSync)
  }
  struct Meter {
    let start: Double
    private var lastTime: Double
    private var lastBytes = 0
    private(set) var samples: [Double] = []
    init(start: Double) { self.start = start; lastTime = start }
    mutating func record(bytes: Int, at now: Double) -> Bool {
      guard now - lastTime >= 0.25, bytes >= lastBytes else { return false }
      samples.append(Double(bytes - lastBytes) / (now - lastTime) / 1_000_000)
      lastBytes = bytes; lastTime = now; return true
    }
    mutating func finish(bytes: Int, at now: Double) -> StorageSpeedReading {
      let seconds = max(now - start, 0.000001)
      if bytes > lastBytes && now - lastTime >= 0.1 {
        samples.append(Double(bytes - lastBytes) / (now - lastTime) / 1_000_000)
      }
      if samples.isEmpty { samples = [Double(bytes) / seconds / 1_000_000] }
      return .init(bytes: bytes, seconds: seconds, samples: samples)
    }
  }
  private static func failure(_ prefix: String) -> StorageSpeedError {
    .message(prefix + "：" + String(cString: strerror(errno)))
  }
}
