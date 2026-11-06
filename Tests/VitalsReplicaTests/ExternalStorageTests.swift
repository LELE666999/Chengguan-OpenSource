import XCTest
import SwiftUI
@testable import VitalsReplica

final class ExternalStorageTests: XCTestCase {
  private func volume(_ id: String = "card", free: UInt64? = 60, bsd: String = "disk8s1") -> ExternalVolume {
    ExternalVolume(id: id, name: "相机存储卡", path: "/Volumes/Camera-" + id, bsdName: bsd, device: "SD Card Reader",
      transport: "Secure Digital", format: .exfat, formatDescription: "exFAT", total: 100, free: free,
      readOnly: false, isCard: true, cameraFolder: "DCIM", contentChecked: true)
  }
  func testExternalSSDNotMarkedRemovableIsIncluded() {
    XCTAssertTrue(StorageDeviceEvidence(isInternal: false, transport: "USB", model: "Portable SSD").isExternalStorage)
    XCTAssertTrue(StorageDeviceEvidence(isInternal: false, transport: "PCI-Express", model: "Thunderbolt NVMe").isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: true, transport: "PCI-Express", model: "APPLE SSD").isExternalStorage)
  }
  func testInternalReaderRemovableSDCardIsIncluded() {
    XCTAssertTrue(StorageDeviceEvidence(model: "USB3.0 CRW   -SD").isCard)
    XCTAssertFalse(StorageDeviceEvidence(model: "Portable SSD").isCard)
    XCTAssertTrue(StorageDeviceEvidence(isInternal: true, removable: true, transport: "Secure Digital").isExternalStorage)
    XCTAssertTrue(StorageDeviceEvidence(isInternal: true, ejectable: true, transport: "Secure Digital").isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: true, transport: "Secure Digital").isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: true, removable: true, transport: "SATA").isExternalStorage)
  }
  func testNetworkAndImagesAreNeverPhysicalExternalStorage() {
    XCTAssertFalse(StorageDeviceEvidence(isInternal: false, local: false, transport: "USB").isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: false, transport: "Virtual Interface", model: "Disk Image").isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: false, transport: "USB", diskImage: true).isExternalStorage)
    XCTAssertFalse(StorageDeviceEvidence(isInternal: false, transport: "USB", model: "Disk Image").isExternalStorage)
  }
  func testMissingInternalFlagNeedsEvidence() {
    XCTAssertFalse(StorageDeviceEvidence().isExternalStorage)
    XCTAssertTrue(StorageDeviceEvidence(transport: "USB").isExternalStorage)
    XCTAssertTrue(StorageDeviceEvidence(location: "External").isExternalStorage)
  }
  func testFormatIdentificationPreservesUnknownFATVersion() {
    XCTAssertEqual(StorageFormat.identify(kind: "exfat", description: ""), .exfat)
    XCTAssertEqual(StorageFormat.identify(kind: "msdos", description: "MS-DOS (FAT32)"), .fat32)
    XCTAssertEqual(StorageFormat.identify(kind: "msdos", description: "MS-DOS (FAT)"), .fat)
    XCTAssertEqual(StorageFormat.identify(kind: "apfs", description: "APFS (Encrypted)"), .apfs)
    XCTAssertEqual(StorageFormat.identify(kind: "ufsd_NTFS", description: ""), .ntfs)
    XCTAssertEqual(StorageFormat.identify(kind: "hfs", description: ""), .hfs)
    XCTAssertEqual(StorageFormat.identify(kind: "futurefs", description: "FutureFS"), .other)
  }
  func testBadCapacityNeverUnderflowsOrReportsFull() {
    XCTAssertNil(ExternalStorageReader.validCapacity(total: -1, free: 5).0)
    XCTAssertNil(ExternalStorageReader.validCapacity(total: 100, free: -1).1)
    XCTAssertNil(ExternalStorageReader.validCapacity(total: 100, free: 101).1)
    XCTAssertNil(ExternalStorageReader.validCapacity(total: 0, free: 0).0)
    XCTAssertNil(volume(free: 101).used)
    XCTAssertNil(volume(free: nil).fraction)
    XCTAssertFalse(volume(free: nil).lowSpace)
    XCTAssertEqual(volume(free: 0).used, 100)
    XCTAssertEqual(volume(free: 0).fraction, 1)
    XCTAssertTrue(volume(free: 0).lowSpace)
  }
  func testCameraHintOnlyAcceptsRealRootDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(ExternalStorageReader.cameraFolder(at: root))
    let dcim = root.appendingPathComponent("DCIM")
    try Data().write(to: dcim)
    XCTAssertNil(ExternalStorageReader.cameraFolder(at: root))
    try FileManager.default.removeItem(at: dcim)
    try FileManager.default.createSymbolicLink(at: dcim, withDestinationURL: root)
    XCTAssertNil(ExternalStorageReader.cameraFolder(at: root))
    try FileManager.default.removeItem(at: dcim)
    try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: false)
    XCTAssertEqual(ExternalStorageReader.cameraFolder(at: root), "DCIM")
    try FileManager.default.removeItem(at: dcim)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("dcim"), withIntermediateDirectories: false)
    XCTAssertEqual(ExternalStorageReader.cameraFolder(at: root)?.lowercased(), "dcim")
  }
  @MainActor func testMountRemoveAndRenameEvents() {
    let v = volume(), now = Date()
    let mounted = ExternalStorageMonitor.diff([], [v], now: now)
    XCTAssertEqual(mounted.count, 1); XCTAssertTrue(mounted[0].title.contains(v.name))
    XCTAssertTrue(mounted[0].storage)
    XCTAssertEqual(ExternalStorageMonitor.diff([v], [v], now: now).count, 0)
    let removed = ExternalStorageMonitor.diff([v], [], now: now)
    XCTAssertEqual(removed.count, 1); XCTAssertTrue(removed[0].title.contains("已移除"))
    var renamed = v; renamed.name = "工作盘"
    XCTAssertTrue(ExternalStorageMonitor.diff([v], [renamed], now: now)[0].title.contains("已更名"))
  }
  @MainActor func testLowSpaceTransitionsDoNotSpamOnEveryRead() {
    let normal = volume(), low = volume(free: 8), now = Date()
    let events = ExternalStorageMonitor.diff([normal], [low], now: now)
    XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].priority, 1)
    XCTAssertTrue(ExternalStorageMonitor.diff([low], [volume(free: 7)], now: now).isEmpty)
    XCTAssertTrue(ExternalStorageMonitor.diff([low], [volume(free: nil)], now: now).isEmpty)
    XCTAssertTrue(ExternalStorageMonitor.diff([low], [normal], now: now)[0].title.contains("恢复"))
  }
  @MainActor func testReadOnlyTransitionsAndSeparateVolumes() {
    var ro = volume(); ro.readOnly = true
    XCTAssertTrue(ExternalStorageMonitor.diff([volume()], [ro], now: Date())[0].title.contains("只读"))
    var unknown = volume(); unknown.readOnly = nil
    XCTAssertTrue(ExternalStorageMonitor.diff([unknown], [ro], now: Date()).isEmpty)
    XCTAssertEqual(ExternalStorageMonitor.diff([], [volume("A"), volume("B")], now: Date()).count, 2)
  }
  @MainActor func testFailedEnumerationKeepsVisibleVolumesAndNoFalseRemoval() {
    let monitor = ExternalStorageMonitor()
    monitor.apply(StorageReadResult(volumes: [volume()]))
    let count = monitor.changes.count
    monitor.apply(StorageReadResult(readable: false))
    XCTAssertEqual(monitor.volumes.count, 1)
    XCTAssertEqual(monitor.changes.count, count)
    XCTAssertFalse(monitor.readable)
    monitor.stop()
  }
  @MainActor func testOneUnreadableVolumeDoesNotHideOthersOrInventUnplug() {
    let monitor = ExternalStorageMonitor(), a = volume("A"), b = volume("B")
    monitor.apply(StorageReadResult(volumes: [a, b]))
    let count = monitor.changes.count
    monitor.apply(StorageReadResult(volumes: [b], unavailablePaths: [a.path]))
    XCTAssertEqual(monitor.volumes.count, 2)
    XCTAssertEqual(monitor.changes.count, count)
    monitor.stop()
  }
  @MainActor func testRecentStorageMessagesParticipateInFeed() {
    let now = Date(), events = ExternalStorageMonitor.diff([], [volume()], now: now)
    XCTAssertEqual(AIMessageFeed.messages(events: [], runs: [], now: now, extra: events).count, 1)
    XCTAssertTrue(AIMessageFeed.messages(events: [], runs: [], now: now.addingTimeInterval(1801), extra: events).isEmpty)
  }
  @MainActor func testUnmountImmediatelyRemovesAndBlocksStaleOrFailedReads() {
    let monitor = ExternalStorageMonitor(), v = volume()
    monitor.apply(StorageReadResult(volumes: [v]))
    let revision = monitor.revision
    monitor.workspaceEvent(NSWorkspace.didUnmountNotification, path: v.path)
    XCTAssertTrue(monitor.volumes.isEmpty)
    XCTAssertTrue(monitor.notice?.title.contains("已移除") == true)
    monitor.apply(StorageReadResult(readable: false))
    monitor.apply(StorageReadResult(volumes: [v]), revision: revision)
    monitor.apply(StorageReadResult(volumes: [v], unavailablePaths: [v.path]))
    XCTAssertTrue(monitor.volumes.isEmpty, "A late snapshot cannot resurrect an explicitly removed device")
    monitor.stop()
  }
  @MainActor func testSameCardCanRemountAndOldReadCannotReplaceNewState() {
    let monitor = ExternalStorageMonitor(), v = volume()
    monitor.apply(StorageReadResult(volumes: [v]))
    let revision = monitor.revision
    monitor.workspaceEvent(NSWorkspace.didUnmountNotification, path: v.path)
    monitor.workspaceEvent(NSWorkspace.didMountNotification, path: v.path)
    monitor.apply(StorageReadResult(volumes: [v]), revision: revision)
    XCTAssertTrue(monitor.volumes.isEmpty)
    monitor.apply(StorageReadResult(volumes: [v]), revision: monitor.revision)
    XCTAssertEqual(monitor.volumes, [v])
    XCTAssertTrue(monitor.notice?.title.contains("已连接") == true)
    monitor.stop()
  }
  @MainActor func testNativeWholeDiskRemovalDoesNotRemoveSimilarOrUnrelatedDisks() {
    let monitor = ExternalStorageMonitor()
    let a = volume("a"), b = volume("b", bsd: "disk8s2"), c = volume("c", bsd: "disk80s1"), d = volume("d", bsd: "disk9s1")
    monitor.apply(StorageReadResult(volumes: [a, b, c, d]))
    monitor.diskEvent(StorageDiskSignal(kind: .removed, bsdName: "disk8", path: nil, whole: true))
    XCTAssertEqual(Set(monitor.volumes.map(\.id)), [c.id, d.id])
    monitor.diskEvent(StorageDiskSignal(kind: .removed, bsdName: "disk80s1", path: nil))
    XCTAssertEqual(monitor.volumes, [d])
    let count = monitor.changes.count
    monitor.workspaceEvent(NSWorkspace.didUnmountNotification, path: c.path)
    XCTAssertEqual(monitor.changes.count, count, "DA and Workspace notifications should not duplicate removal")
    monitor.stop()
  }
  @MainActor func testMountTableFallbackRemovesImmediatelyAndAllowsReinsert() {
    let monitor = ExternalStorageMonitor(), a = volume("a"), b = volume("b", bsd: "disk9s1")
    monitor.apply(StorageReadResult(volumes: [a, b]))
    monitor.reconcileMountedPaths([a.path, b.path])
    monitor.reconcileMountedPaths([b.path])
    XCTAssertEqual(monitor.volumes, [b])
    monitor.apply(StorageReadResult(volumes: [a, b]))
    XCTAssertEqual(monitor.volumes, [b])
    monitor.reconcileMountedPaths([a.path, b.path])
    monitor.apply(StorageReadResult(volumes: [a, b]))
    XCTAssertEqual(monitor.volumes.count, 2)
    monitor.stop()
  }
  @MainActor func testSafeEjectSuccessRemovesCardAndKeepsConfirmationMessage() async {
    let monitor = ExternalStorageMonitor(ejector: { _ in .ejected }), v = volume()
    monitor.apply(StorageReadResult(volumes: [v]))
    await monitor.eject(v)
    XCTAssertTrue(monitor.volumes.isEmpty)
    XCTAssertTrue(monitor.ejecting.isEmpty); XCTAssertTrue(monitor.busy.isEmpty)
    XCTAssertTrue(monitor.notice?.title.contains("已安全推出") == true)
    monitor.apply(StorageReadResult(volumes: [v]))
    XCTAssertTrue(monitor.volumes.isEmpty)
    XCTAssertTrue(monitor.notice?.title.contains("已安全推出") == true)
    monitor.stop()
  }
  @MainActor func testSafeEjectFailureKeepsCardAndReportsBusyReason() async {
    let monitor = ExternalStorageMonitor(ejector: { _ in .failed("Device busy") }), v = volume()
    monitor.apply(StorageReadResult(volumes: [v]))
    await monitor.eject(v)
    XCTAssertEqual(monitor.volumes, [v])
    XCTAssertTrue(monitor.error?.contains("Device busy") == true)
    XCTAssertTrue(monitor.notice?.title.contains("推出失败") == true)
    XCTAssertTrue(monitor.ejecting.isEmpty); XCTAssertTrue(monitor.busy.isEmpty)
    monitor.stop()
  }
  @MainActor func testRemovedOrReplacedTargetNeverInvokesEjector() async {
    let monitor = ExternalStorageMonitor(ejector: { _ in XCTFail("A stale target cannot be ejected"); return .ejected })
    monitor.apply(StorageReadResult(volumes: [volume("replacement")]))
    await monitor.eject(volume("old"))
    XCTAssertEqual(monitor.volumes.map(\.id), ["replacement"])
    monitor.stop()
    XCTAssertNil(ExternalStorageReader.readMounted(volume("missing")))
  }
  @MainActor func testInFlightEjectIsSingleAndRemovalDoesNotEraseSuccess() async {
    let started = expectation(description: "Eject started"), gate = StorageEjectGate()
    let monitor = ExternalStorageMonitor(ejector: { _ in started.fulfill(); return await gate.wait() }), v = volume()
    monitor.apply(StorageReadResult(volumes: [v]))
    let task = Task { await monitor.eject(v) }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(monitor.ejecting.contains(v.id)); XCTAssertTrue(monitor.busy.contains(v.id))
    await monitor.eject(v) // A second click is ignored while the first request is pending.
    monitor.workspaceEvent(NSWorkspace.didUnmountNotification, path: v.path)
    XCTAssertTrue(monitor.volumes.isEmpty)
    await gate.finish(.ejected); await task.value
    XCTAssertTrue(monitor.notice?.title.contains("已安全推出") == true)
    XCTAssertTrue(monitor.ejecting.isEmpty)
    monitor.stop()
  }
  @MainActor func testRenderStorageLayoutsWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["CHENGGUAN_STORAGE_RENDER_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    var v = volume(); v.total = 128_000_000_000; v.free = 81_400_000_000
    for (name, scheme, width, compact, expanded) in [
      ("storage-menu-light", ColorScheme.light, CGFloat(229), true, false),
      ("storage-menu-dark", ColorScheme.dark, CGFloat(229), true, false),
      ("storage-main-light", ColorScheme.light, CGFloat(434), false, false),
      ("storage-main-dark", ColorScheme.dark, CGFloat(434), false, false),
      ("storage-details-light", ColorScheme.light, CGFloat(390), true, true),
      ("storage-details-dark", ColorScheme.dark, CGFloat(390), true, true)] {
      let content = expanded
        ? AnyView(ExternalStorageRow(volume: v, compact: true, initiallyExpanded: true))
        : AnyView(ExternalStorageCard(volume: v, compact: compact))
      let view = content.padding(12).frame(width: width).background(scheme == .dark ? Color(white: 0.12) : Color.white)
        .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_CN"))
      let renderer = ImageRenderer(content: view); renderer.scale = 2
      let image = try XCTUnwrap(renderer.nsImage)
      if !expanded { XCTAssertEqual(image.size.height, compact ? 115 : 223) }
      let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
  }
}

private actor StorageEjectGate {
  private var continuation: CheckedContinuation<StorageEjectResult, Never>?
  private var result: StorageEjectResult?
  func wait() async -> StorageEjectResult {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish(_ result: StorageEjectResult) {
    self.result = result; continuation?.resume(returning: result); continuation = nil
  }
}
