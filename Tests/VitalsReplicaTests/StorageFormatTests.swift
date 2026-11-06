import XCTest
import SwiftUI
@testable import VitalsReplica

final class StorageFormatTests: XCTestCase {
  private func proof(partition changes: [String: Any] = [:], device parentChanges: [String: Any] = [:], registryID: UInt64 = 123) -> StorageEraseProof {
    let volume = ExternalVolume(id: "disk8s1:volume-uuid", name: "相机卡", path: "/Volumes/相机卡", bsdName: "disk8s1",
      device: "SD Card", transport: "USB", format: .exfat, formatDescription: "exFAT", total: 16_000_000_000,
      free: 8_000_000_000, readOnly: false, isCard: true, cameraFolder: nil, contentChecked: true)
    var p: [String: Any] = ["DeviceIdentifier": "disk8s1", "DeviceNode": "/dev/disk8s1", "ParentWholeDisk": "disk8",
      "MountPoint": volume.path, "VolumeName": volume.name, "VolumeUUID": "volume-uuid", "DiskUUID": "partition-uuid",
      "FilesystemType": "exfat", "TotalSize": 16_000_000_000, "WholeDisk": false, "Internal": false,
      "WritableMedia": true, "PartitionMapPartition": true]
    var d: [String: Any] = ["DeviceIdentifier": "disk8", "DeviceNode": "/dev/disk8", "WholeDisk": true,
      "VirtualOrPhysical": "Physical", "DeviceTreePath": "IODeviceTree:/external/usb@1", "Internal": false,
      "WritableMedia": true, "RemovableMedia": true, "BusProtocol": "USB", "Content": "GUID_partition_scheme"]
    changes.forEach { p[$0] = $1 }; parentChanges.forEach { d[$0] = $1 }
    return StorageEraseProof(volume: volume, partition: .init(p), device: .init(d), registryID: registryID)
  }
  func testOnlyExplicitPhysicalExternalPartitionsAreAccepted() throws {
    try StorageErasePolicy.validate(proof())
    try StorageErasePolicy.validate(proof(partition: ["Bootable": true]))
    let sd = proof(partition: ["Internal": true], device: ["Internal": true, "BusProtocol": "Secure Digital"])
    try StorageErasePolicy.validate(sd)
    XCTAssertThrowsError(try StorageErasePolicy.validate(proof(partition: ["Internal": true], device: ["Internal": true])))
    XCTAssertThrowsError(try StorageErasePolicy.validate(proof(partition: ["Internal": NSNull()], device: ["Internal": NSNull()])))
    XCTAssertThrowsError(try StorageErasePolicy.validate(proof(device: ["VirtualOrPhysical": "Virtual"])))
    XCTAssertThrowsError(try StorageErasePolicy.validate(proof(device: ["VirtualOrPhysical": NSNull()])))
  }
  func testIdentityAndPermissionInformationMustBePresentAndConsistent() {
    for change: [String: Any] in [["WholeDisk": true], ["WholeDisk": NSNull()], ["PartitionMapPartition": false],
      ["DeviceNode": "/dev/disk0s1"], ["MountPoint": "/"], ["VolumeName": "Other"], ["ParentWholeDisk": "disk0"],
      ["VolumeUUID": ""], ["DiskUUID": ""], ["WritableMedia": false], ["WritableMedia": NSNull()], ["Locked": true], ["TotalSize": 0]] {
      XCTAssertThrowsError(try StorageErasePolicy.validate(proof(partition: change)), "Must reject \(change)")
    }
    for change: [String: Any] in [["WholeDisk": false], ["WritableMedia": false], ["DeviceTreePath": ""], ["DeviceIdentifier": "disk0"]] {
      XCTAssertThrowsError(try StorageErasePolicy.validate(proof(device: change)))
    }
    XCTAssertThrowsError(try StorageErasePolicy.validate(proof(registryID: 0)))
  }
  func testAPFSSharedContainersSystemAndRaidUseDiskUtilityInstead() {
    for change: [String: Any] in [["FilesystemType": "apfs"], ["APFSContainerReference": "disk9"], ["APFSPhysicalStores": []],
      ["RAIDSlice": true], ["RAIDMaster": true], ["OSInternalMedia": true], ["SystemImage": true], ["FilesystemType": "unknown"]] {
      XCTAssertThrowsError(try StorageErasePolicy.validate(proof(partition: change)))
    }
  }
  func testReusedBSDNamesAndReconnectedMediaDoNotMatchConfirmedIdentity() {
    let original = proof()
    XCTAssertFalse(original.matches(proof(partition: ["VolumeUUID": "replacement"])))
    XCTAssertFalse(original.matches(proof(partition: ["DiskUUID": "replacement"])))
    XCTAssertFalse(original.matches(proof(device: ["DeviceTreePath": "IODeviceTree:/other"])))
    XCTAssertFalse(original.matches(proof(registryID: 456)))
    var changedCapacity = original.volume; changedCapacity.free = 1_000_000
    XCTAssertTrue(original.matches(.init(volume: changedCapacity, partition: original.partition, device: original.device, registryID: original.registryID)))
  }
  func testAllowedFormatsHaveFixedArgumentsAndNeverEraseTheWholeDevice() throws {
    for format in StorageEraseFormat.allCases {
      let request = StorageEraseRequest(proof: proof(), format: format, name: "NewDisk")
      try StorageErasePolicy.validate(request)
      XCTAssertEqual(request.arguments, ["eraseVolume", format.diskutilName, "NewDisk", "/dev/disk8s1"])
      XCTAssertFalse(request.arguments.contains("eraseDisk")); XCTAssertFalse(request.arguments.contains("force"))
    }
    try StorageEraseFormat.exfat.validate(name: "相机素材")
    // Argument arrays, never a shell: these remain a single inert volume-label argument.
    let quoted = StorageEraseRequest(proof: proof(), format: .apfs, name: "$(echo x)")
    try StorageErasePolicy.validate(quoted); XCTAssertEqual(quoted.arguments[2], "$(echo x)")
  }
  func testVolumeLabelRulesRejectOptionsPathsControlsAndIncompatibleFATNames() {
    for bad in ["", " ", " leading", "trailing ", "a/b", "a:b", "-force", "a\nb", "a\0b"] {
      XCTAssertThrowsError(try StorageEraseFormat.exfat.validate(name: bad))
    }
    XCTAssertThrowsError(try StorageEraseFormat.exfat.validate(name: String(repeating: "a", count: 16)))
    XCTAssertThrowsError(try StorageEraseFormat.exfat.validate(name: String(repeating: "😀", count: 8)))
    for bad in ["相机卡", "abcdefghijkl", "a.b", "a*b"] { XCTAssertThrowsError(try StorageEraseFormat.fat32.validate(name: bad)) }
  }
  func testLargeMediaCannotSilentlySelectFAT32() {
    let request = StorageEraseRequest(proof: proof(partition: ["TotalSize": 128_000_000_000]), format: .fat32, name: "CARD")
    XCTAssertThrowsError(try StorageErasePolicy.validate(request))
    let mbr = StorageEraseRequest(proof: proof(device: ["Content": "FDisk_partition_scheme"]), format: .apfs, name: "Mac")
    XCTAssertThrowsError(try StorageErasePolicy.validate(mbr))
  }
  func testRealInspectorRejectsMissingDeviceAndStartupDiskWithoutRunningFormatter() {
    XCTAssertThrowsError(try StorageEraseEngine.inspect(proof().volume))
    var system = proof().volume; system = ExternalVolume(id: system.id, name: "Macintosh HD", path: "/", bsdName: "disk0s1",
      device: "APPLE SSD", transport: "Apple Fabric", format: .apfs, formatDescription: "APFS", total: nil, free: nil,
      readOnly: false, isCard: false, cameraFolder: nil, contentChecked: false)
    XCTAssertThrowsError(try StorageEraseEngine.inspect(system))
    XCTAssertThrowsError(try StorageEraseEngine.info("disk8;echo unsafe"))
  }
  @MainActor func testRejectedInspectionCannotProduceAConfirmationOrExecute() async {
    let store = StorageFormatStore(inspector: { _ in throw StorageEraseError.message("Disconnected") }, eraser: { _ in XCTFail("Must not run") })
    await store.prepare(proof().volume)
    XCTAssertEqual(store.phase, .blocked); XCTAssertNil(store.proof)
    XCTAssertThrowsError(try store.request(format: .exfat, name: "Disk"))
    await store.erase(.init(proof: proof(), format: .exfat, name: "Disk"))
    XCTAssertEqual(store.phase, .blocked)
  }
  @MainActor func testRemovalImmediatelyRevokesPreparedConfirmation() async throws {
    let value = proof()
    let store = StorageFormatStore(inspector: { _ in value }, eraser: { _ in XCTFail("Removed target cannot run") })
    await store.prepare(value.volume); XCTAssertEqual(store.phase, .ready)
    store.checkConnection([])
    XCTAssertEqual(store.phase, .blocked); XCTAssertNil(store.proof)
    XCTAssertThrowsError(try store.request(format: .exfat, name: "Disk"))
  }
  @MainActor func testFormattingHasSingleExecutionAndCannotSwitchTargetsOrPrepareNewConfirmation() async throws {
    let value = proof(), started = expectation(description: "Formatting started"), gate = DispatchSemaphore(value: 0)
    let counter = FormatExecutionCounter()
    let store = StorageFormatStore(inspector: { _ in value }, eraser: { _ in counter.increment(); started.fulfill(); gate.wait() })
    await store.prepare(value.volume)
    let request = try store.request(format: .exfat, name: "Disk")
    XCTAssertEqual(counter.count, 0, "Preparing confirmation must not start the formatter")
    let task = Task { await store.erase(request) }
    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(store.running)
    await store.prepare(value.volume); XCTAssertTrue(store.running)
    XCTAssertThrowsError(try store.request(format: .apfs, name: "Other"))
    await store.erase(request); XCTAssertEqual(counter.count, 1)
    gate.signal(); await task.value
    XCTAssertEqual(store.phase, .complete); XCTAssertFalse(store.running)
  }
  @MainActor func testConfirmationForAReplacedDeviceCannotExecute() async {
    let value = proof(), replaced = proof(registryID: 456)
    let store = StorageFormatStore(inspector: { _ in value }, eraser: { _ in XCTFail("Stale confirmation cannot execute") })
    await store.prepare(value.volume)
    await store.erase(.init(proof: replaced, format: .exfat, name: "Disk"))
    XCTAssertEqual(store.phase, .ready)
  }
  @MainActor func testExecutionFailureDoesNotPublishSuccessOrAutomaticallyRetry() async throws {
    let value = proof(), counter = FormatExecutionCounter()
    let store = StorageFormatStore(inspector: { _ in value }, eraser: { _ in counter.increment(); throw StorageEraseError.message("Device busy") })
    await store.prepare(value.volume)
    let request = try store.request(format: .exfat, name: "Disk")
    await store.erase(request); XCTAssertEqual(store.phase, .failed); XCTAssertTrue(store.message.contains("Device busy"))
    await store.erase(request); XCTAssertEqual(counter.count, 1)
  }
  @MainActor func testRenderFormatWindowWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["CHENGGUAN_STORAGE_RENDER_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let value = proof(), store = StorageFormatStore(inspector: { _ in value }, eraser: { _ in XCTFail("Rendering cannot format") })
    await store.prepare(value.volume)
    for (name, scheme) in [("format-light", ColorScheme.light), ("format-dark", ColorScheme.dark)] {
      // AppKit-backed text fields cannot be rendered by ImageRenderer; capture a hosted view instead.
      let host = NSHostingView(rootView: StorageFormatView(volume: value.volume, store: store).content.frame(width: 520, height: 600).environment(\.colorScheme, scheme))
      host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
  }
  func testInspectConnectedVolumeWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["CHENGGUAN_FORMAT_INSPECT_PATH"] else { return }
    let volume = try XCTUnwrap(ExternalStorageReader.read().volumes.first { $0.path == path })
    // Inspection only: no request or formatter is created for a connected user device.
    let value = try StorageEraseEngine.inspect(volume)
    XCTAssertEqual(value.volume.id, volume.id); XCTAssertEqual(value.partition.node, "/dev/" + volume.bsdName)
    XCTAssertNotEqual(value.registryID, 0)
  }
}

private final class FormatExecutionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return value }
  func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
