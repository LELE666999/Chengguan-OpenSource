import Foundation
import DiskArbitration
import IOKit

/// Per mounted volume: APFS volumes can share a container, so capacities are never summed.
struct ExternalVolume: Identifiable, Equatable, Codable, Sendable {
  let id: String
  var name: String
  let path: String
  let bsdName: String
  var device: String
  var transport: String
  var format: StorageFormat
  var formatDescription: String
  var total: UInt64?
  var free: UInt64?
  var readOnly: Bool?
  var isCard: Bool
  var cameraFolder: String?
  var contentChecked: Bool
  var used: UInt64? {
    guard let total, let free, total > 0, free <= total else { return nil }
    return total - free
  }
  var fraction: Double? {
    guard let used, let total, total > 0 else { return nil }
    return Double(used) / Double(total)
  }
  var lowSpace: Bool { fraction.map { $0 >= 0.9 } ?? false }
  var symbol: String { isCard ? "sdcard.fill" : "externaldrive.fill" }
  var capacityText: String {
    guard let free else { return "容量暂不可用" }
    return Format.bytes(free) + " 可用"
  }
  var subtitle: String {
    [formatDescription, transport, readOnly == true ? "只读" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

enum StorageFormat: String, Codable, Sendable {
  case exfat, fat32, fat, apfs, hfs, ntfs, other
  static func identify(kind: String, description: String) -> Self {
    let text = (kind + " " + description).lowercased()
    if text.contains("exfat") { return .exfat }
    if text.contains("fat32") || text.contains("fat 32") { return .fat32 }
    if text.contains("apfs") { return .apfs }
    if text.contains("ntfs") { return .ntfs }
    if text.contains("hfs") || text.contains("mac os extended") || text.contains("mac os 扩展") { return .hfs }
    if text.contains("msdos") || text.contains("ms-dos") || text.contains("fat") { return .fat }
    return .other
  }
  var title: String {
    switch self {
    case .exfat: "exFAT"
    case .fat32: "FAT32"
    case .fat: "MS-DOS (FAT)"
    case .apfs: "APFS"
    case .hfs: "Mac OS 扩展"
    case .ntfs: "NTFS"
    case .other: "未知格式"
    }
  }
  var suitability: String {
    switch self {
    case .exfat: "适合 Mac 与 Windows 交换文件，也适合大文件。相机等设备须确认支持 exFAT。"
    case .fat32: "适合兼容 FAT32 的设备。单个文件须小于 4 GiB，大视频可考虑 exFAT。"
    case .fat: "适合支持 FAT 的设备；具体 FAT 版本未确认，文件大小限制以实际格式为准。"
    case .apfs: "适合 Mac 专用存储和 SSD。Windows 原生不能直接读取；容器内多个卷共享可用空间。"
    case .hfs: "适合旧版 Mac 与兼容设备。跨 Mac、Windows 交换文件可考虑 exFAT。"
    case .ntfs: "常用于 Windows。此 Mac 能否写入以当前只读状态和已安装驱动为准。"
    case .other: "格式未识别。请在磁盘工具中查看，不据此推断兼容设备。"
    }
  }
}

/// Physical evidence is separate from the removable bit: external SSDs often set it to false.
struct StorageDeviceEvidence: Sendable {
  var isInternal: Bool?
  var removable = false
  var ejectable = false
  var local = true
  var transport = ""
  var model = ""
  var location = ""
  var diskImage = false
  var isCard: Bool {
    let s = (transport + " " + model).lowercased()
    return s.contains("secure digital") || s.contains("sd card") || s.contains("sdxc") || s.contains("sdhc") || model.range(of: "(^|[ _-])SD($|[ _-])", options: [.regularExpression, .caseInsensitive]) != nil
  }
  var isExternalStorage: Bool {
    let p = transport.lowercased(), m = model.lowercased()
    guard local, !diskImage, !p.contains("virtual"), !m.contains("disk image") else { return false }
    // A built-in SD reader is internal, but its removable card belongs in this section.
    if isInternal == true { return (removable || ejectable) && isCard }
    if isInternal == false || location.lowercased() == "external" { return true }
    return ["usb", "thunderbolt", "firewire", "secure digital"].contains { p.contains($0) }
  }
}

struct StorageReadResult: Codable, Sendable {
  var volumes: [ExternalVolume] = []
  var readable = true
  var unavailablePaths: [String] = []
}

enum ExternalStorageReader {
  static func mountedPaths() -> Set<String>? {
    FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])
      .map { Set($0.map(\.path)) }
  }
  static func readMounted(_ expected: ExternalVolume) -> ExternalVolume? {
    guard let session = DASessionCreate(nil), let live = try? readVolume(URL(fileURLWithPath: expected.path), session: session),
      live.id == expected.id, live.path == expected.path, live.bsdName == expected.bsdName else { return nil }
    return live
  }
  static let keys: Set<URLResourceKey> = [
    .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey,
    .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
    .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey,
  ]
  static func read() -> StorageReadResult {
    guard let session = DASessionCreate(nil),
      let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
    else { return StorageReadResult(readable: false) }
    var seen = Set<String>()
    var volumes: [ExternalVolume] = [], unavailable: [String] = []
    for url in urls {
      do {
        if let volume = try readVolume(url, session: session), seen.insert(volume.id).inserted { volumes.append(volume) }
      } catch { unavailable.append(url.path) }
    }
    return StorageReadResult(volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, unavailablePaths: unavailable)
  }
  static func readVolume(_ url: URL, session: DASession) throws -> ExternalVolume? {
    let values = try url.resourceValues(forKeys: keys)
    guard let isLocal = values.volumeIsLocal else { throw CocoaError(.fileReadUnknown) }
    guard isLocal else { return nil }
    guard let disk = DADiskCreateFromVolumePath(nil, session, url as CFURL),
      let desc = DADiskCopyDescription(disk) as? [String: Any],
      let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { throw CocoaError(.fileReadUnknown) }
    let whole = DADiskCopyWholeDisk(disk).flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
    func property(_ key: CFString) -> Any? { desc[key as String] ?? whole[key as String] }
    func string(_ key: CFString) -> String { (property(key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let media = DADiskCopyIOMedia(disk)
    defer { if media != 0 { IOObjectRelease(media) } }
    func parentProperty(_ key: String) -> Any? {
      guard media != 0 else { return nil }
      return IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, nil,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
    let model = string(kDADiskDescriptionDeviceModelKey)
    let daProtocol = string(kDADiskDescriptionDeviceProtocolKey)
    let characteristics = parentProperty("Protocol Characteristics") as? [String: Any] ?? [:]
    let physicalProtocol = characteristics["Physical Interconnect"] as? String ?? parentProperty("Physical Interconnect") as? String ?? ""
    let transport = [physicalProtocol, daProtocol].first { !$0.isEmpty && !$0.lowercased().contains("virtual") } ?? daProtocol
    let evidence = StorageDeviceEvidence(
      isInternal: property(kDADiskDescriptionDeviceInternalKey) as? Bool ?? values.volumeIsInternal,
      removable: property(kDADiskDescriptionMediaRemovableKey) as? Bool ?? values.volumeIsRemovable ?? false,
      ejectable: property(kDADiskDescriptionMediaEjectableKey) as? Bool ?? values.volumeIsEjectable ?? false,
      local: values.volumeIsLocal == true, transport: transport, model: model,
      location: characteristics["Physical Interconnect Location"] as? String ?? parentProperty("Physical Interconnect Location") as? String ?? "",
      diskImage: model == "Disk Image" || (daProtocol.lowercased().contains("virtual") && physicalProtocol.isEmpty))
    guard evidence.isExternalStorage else { return nil }
    let rawFormat = values.volumeLocalizedFormatDescription ?? string(kDADiskDescriptionVolumeTypeKey)
    let format = StorageFormat.identify(kind: string(kDADiskDescriptionVolumeKindKey), description: rawFormat)
    let capacity = validCapacity(total: values.volumeTotalCapacity.map(Int64.init), free: values.volumeAvailableCapacity.map(Int64.init))
    return ExternalVolume(id: bsd + ":" + (values.volumeUUIDString ?? url.path),
      name: values.volumeName ?? url.lastPathComponent, path: url.path, bsdName: bsd,
      device: model, transport: transport.isEmpty ? "连接方式未知" : transport,
      format: format, formatDescription: rawFormat.isEmpty ? format.title : rawFormat,
      total: capacity.0, free: capacity.1, readOnly: values.volumeIsReadOnly,
      isCard: evidence.isCard, cameraFolder: nil, contentChecked: false)
  }
  static func validCapacity(total: Int64?, free: Int64?) -> (UInt64?, UInt64?) {
    let total = total.flatMap { $0 > 0 ? UInt64($0) : nil }
    let free = free.flatMap { $0 >= 0 ? UInt64($0) : nil }
    guard let total else { return (nil, nil) }
    return (total, free.flatMap { $0 <= total ? $0 : nil })
  }
  /// Only checks a known directory, never lists files, follows links, or reads media contents.
  static func cameraFolder(at root: URL) -> String? {
    for name in ["DCIM", "dcim"] {
      let child = root.appendingPathComponent(name, isDirectory: true)
      if let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        v.isDirectory == true, v.isSymbolicLink != true { return name }
    }
    return nil
  }
  static func withContentHints(_ result: StorageReadResult) -> StorageReadResult {
    var result = result
    for i in result.volumes.indices {
      result.volumes[i].cameraFolder = cameraFolder(at: URL(fileURLWithPath: result.volumes[i].path))
      result.volumes[i].contentChecked = true
    }
    return result
  }
}
