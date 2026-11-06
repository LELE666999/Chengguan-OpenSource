import Foundation
import DiskArbitration
import IOKit

enum StorageEraseFormat: String, CaseIterable, Identifiable, Sendable {
  case exfat, apfs, hfs, fat32
  var id: String { rawValue }
  var title: String {
    switch self { case .exfat: "exFAT"; case .apfs: "APFS"; case .hfs: "Mac OS 扩展"; case .fat32: "FAT32" }
  }
  var detail: String {
    switch self {
    case .exfat: "Mac 与 Windows · 大文件"
    case .apfs: "Mac 专用 · 适合 SSD"
    case .hfs: "日志式 · 兼容旧版 Mac"
    case .fat32: "旧设备 · 单个文件小于 4 GiB"
    }
  }
  var diskutilName: String {
    switch self { case .exfat: "ExFAT"; case .apfs: "APFS"; case .hfs: "JHFS+"; case .fat32: "FAT32" }
  }
  func validate(name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.hasPrefix("-"), name == name.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.contains(where: { $0 == "/" || $0 == ":" || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
      throw StorageEraseError.message("名称不能为空，不能以短横线开头，或包含斜线、冒号、控制字符及首尾空格。")
    }
    // Conservative UI limits keep labels portable across Apple's formatters.
    if self == .fat32 {
      let forbidden = CharacterSet(charactersIn: "\"*+,.;<=>?[\\]|…")
      guard name.utf8.count <= 11, name.unicodeScalars.allSatisfy({ $0.isASCII && !forbidden.contains($0) }) else {
        throw StorageEraseError.message("FAT32 名称请使用最多 11 位英文字母、数字或空格。")
      }
    } else if name.utf16.count > (self == .exfat ? 15 : 63) {
      throw StorageEraseError.message(self == .exfat ? "exFAT 名称最多 15 个字符。" : "名称最多 63 个字符。")
    }
  }
}

enum StorageEraseError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Only the identity and flags used for destructive-operation validation are retained.
struct StorageEraseDiskInfo: Equatable, Sendable {
  let identifier: String, node: String, parent: String, mountPoint: String, name: String
  let volumeUUID: String, partitionUUID: String, treePath: String, filesystem: String, bus: String, physical: String, scheme: String
  let size: UInt64
  let whole: Bool?, internalDevice: Bool?, writableMedia: Bool?, partition: Bool?
  let removable: Bool, ejectable: Bool, locked: Bool, raid: Bool, system: Bool, apfs: Bool
  init(_ values: [String: Any]) {
    func string(_ key: String) -> String { values[key] as? String ?? "" }
    identifier = string("DeviceIdentifier"); node = string("DeviceNode"); parent = string("ParentWholeDisk")
    mountPoint = string("MountPoint"); name = string("VolumeName"); volumeUUID = string("VolumeUUID")
    partitionUUID = string("DiskUUID"); treePath = string("DeviceTreePath"); filesystem = string("FilesystemType")
    bus = string("BusProtocol"); physical = string("VirtualOrPhysical")
    scheme = string("Content")
    size = (values["TotalSize"] as? NSNumber)?.uint64Value ?? 0
    whole = values["WholeDisk"] as? Bool; internalDevice = values["Internal"] as? Bool
    writableMedia = values["WritableMedia"] as? Bool; partition = values["PartitionMapPartition"] as? Bool
    removable = values["RemovableMedia"] as? Bool == true || values["Removable"] as? Bool == true
    ejectable = values["Ejectable"] as? Bool == true; locked = values["Locked"] as? Bool == true
    raid = values["RAIDMaster"] as? Bool == true || values["RAIDSlice"] as? Bool == true
    // "Bootable" is also true for ordinary exFAT volumes; it does not identify the startup disk.
    system = values["OSInternalMedia"] as? Bool == true || values["SystemImage"] as? Bool == true
    apfs = values["APFSContainerReference"] != nil || values["APFSPhysicalStores"] != nil || string("FilesystemType").lowercased() == "apfs"
  }
}

struct StorageEraseProof: Equatable, Sendable {
  let volume: ExternalVolume
  let partition: StorageEraseDiskInfo
  let device: StorageEraseDiskInfo
  let registryID: UInt64
  func matches(_ other: Self) -> Bool {
    volume.id == other.volume.id && volume.path == other.volume.path && volume.bsdName == other.volume.bsdName
      && partition == other.partition && device == other.device && registryID == other.registryID
  }
}

struct StorageEraseRequest: Sendable {
  let proof: StorageEraseProof
  let format: StorageEraseFormat
  let name: String
  var arguments: [String] { ["eraseVolume", format.diskutilName, name, proof.partition.node] }
}

enum StorageErasePolicy {
  static func validate(_ proof: StorageEraseProof) throws {
    let v = proof.volume, p = proof.partition, d = proof.device
    func reject(_ text: String) throws { throw StorageEraseError.message(text) }
    guard !p.apfs, !d.apfs else {
      return try reject("APFS 使用共享容器。请在磁盘工具中更改格式，以免影响其他卷。")
    }
    guard v.path.hasPrefix("/Volumes/"), URL(fileURLWithPath: v.path).deletingLastPathComponent().path == "/Volumes",
      p.mountPoint == v.path, p.identifier == v.bsdName, p.name == v.name,
      p.identifier.range(of: "^disk[0-9]+s[0-9]+$", options: .regularExpression) != nil,
      p.node == "/dev/" + p.identifier, p.whole == false, p.partition == true,
      !p.volumeUUID.isEmpty, !p.partitionUUID.isEmpty, p.size > 0, proof.registryID != 0 else {
      return try reject("设备身份无法确认。请重新连接，或使用磁盘工具。")
    }
    guard d.identifier == p.parent, d.identifier.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
      d.node == "/dev/" + d.identifier, d.whole == true, d.physical.lowercased() == "physical",
      !d.treePath.isEmpty, !p.raid, !d.raid, !p.system, !d.system else {
      return try reject("此设备需要在磁盘工具中处理。")
    }
    let internalCard = v.isCard && (d.removable || d.ejectable) && d.bus.lowercased().contains("secure digital")
    guard (d.internalDevice == false && p.internalDevice == false) || internalCard else {
      return try reject("澄观仅允许格式化已确认的外接存储。")
    }
    guard p.writableMedia == true, d.writableMedia == true, !p.locked, !d.locked else {
      return try reject("介质受写保护或未解锁。请先在磁盘工具中检查。")
    }
    guard ["exfat", "msdos", "hfs", "ntfs", "ufsd_ntfs"].contains(p.filesystem.lowercased()) else {
      return try reject("当前分区格式需要在磁盘工具中处理。")
    }
  }
  static func validate(_ request: StorageEraseRequest) throws {
    try validate(request.proof); try request.format.validate(name: request.name)
    if request.format == .apfs && request.proof.device.scheme != "GUID_partition_scheme" {
      throw StorageEraseError.message("APFS 需要 GUID 分区表。请在磁盘工具中调整分区方案。")
    }
    if request.format == .fat32 && request.proof.partition.size > 32_000_000_000 {
      throw StorageEraseError.message("大于 32 GB 的存储请选 exFAT；特殊设备可在磁盘工具中处理。")
    }
  }
}

enum StorageEraseEngine {
  static func inspect(_ expected: ExternalVolume) throws -> StorageEraseProof {
    guard let live = ExternalStorageReader.readMounted(expected) else { throw StorageEraseError.message("存储已移除或连接已变化，请重新选择。") }
    let partition = try info(expected.bsdName)
    let parent = try info(partition.parent)
    guard let session = DASessionCreate(nil), let disk = DADiskCreateFromBSDName(nil, session, expected.bsdName) else {
      throw StorageEraseError.message("无法确认存储设备。")
    }
    let media = DADiskCopyIOMedia(disk); defer { if media != 0 { IOObjectRelease(media) } }
    var registryID: UInt64 = 0
    guard media != 0, IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS else {
      throw StorageEraseError.message("无法确认存储连接。")
    }
    let proof = StorageEraseProof(volume: live, partition: partition, device: parent, registryID: registryID)
    try StorageErasePolicy.validate(proof)
    return proof
  }
  static func info(_ identifier: String) throws -> StorageEraseDiskInfo {
    guard identifier.range(of: "^disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil else { throw StorageEraseError.message("无效的设备标识。") }
    let output = Command.run("/usr/sbin/diskutil", ["info", "-plist", identifier], timeout: 5)
    guard output.status == 0, let data = output.text.data(using: .utf8),
      let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], values["Error"] as? Bool != true else {
      throw StorageEraseError.message("未能读取磁盘信息，请重新连接后重试。")
    }
    return StorageEraseDiskInfo(values)
  }
  /// Revalidate immediately before execution. No shell, sudo, force, whole-disk erase or automatic retry.
  static func erase(_ request: StorageEraseRequest) throws {
    try StorageErasePolicy.validate(request)
    let current = try inspect(request.proof.volume)
    guard request.proof.matches(current) else { throw StorageEraseError.message("存储连接或身份已变化，未执行格式化。请重新打开窗口。") }
    let process = Process(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); process.arguments = request.arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
    try process.run()
    // A formatter is not killed on a UI timeout; interrupting it can leave an unusable file system.
    var tail = Data()
    while true {
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      tail.append(chunk); if tail.count > 16_384 { tail = tail.suffix(16_384) }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let reason = String(data: tail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw StorageEraseError.message("格式化未完成。请关闭正在使用磁盘的文件，或在磁盘工具中检查。\n" + String(reason.suffix(600)))
    }
  }
}
