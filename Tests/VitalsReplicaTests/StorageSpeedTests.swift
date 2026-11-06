import XCTest
import SwiftUI
@testable import VitalsReplica

final class StorageSpeedTests: XCTestCase {
  private func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("Chengguan-speed-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }
  func testRealUncachedReadWriteVerifiesDataAndLeavesExistingFilesUntouched() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("important-footage.dat")
    let content = Data("user data must remain unchanged".utf8); try content.write(to: existing)
    let target = StorageSpeedTarget.local(directory: root.path)
    let result = try await Task.detached {
      try StorageSpeedEngine.run(target: target, configuration: .init(bytes: 17 * 1_048_576 + 128))
    }.value
    XCTAssertEqual(result.write.bytes, 17 * 1_048_576 + 128)
    XCTAssertEqual(result.read.bytes, result.write.bytes)
    XCTAssertGreaterThan(result.read.average, 0); XCTAssertGreaterThan(result.write.average, 0)
    XCTAssertGreaterThanOrEqual(result.write.peak, result.write.average)
    XCTAssertEqual(try Data(contentsOf: existing), content)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["important-footage.dat"])
    XCTAssertTrue(result.text.contains("F_NOCACHE")); XCTAssertTrue(result.text.contains("不代表线缆独立速度"))
    let restored = try JSONDecoder().decode(StorageSpeedResult.self, from: JSONEncoder().encode(result))
    XCTAssertEqual(restored, result)
  }
  func testCancellationReclaimsFileAndNeverReturnsCompletedResult() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let target = StorageSpeedTarget.local(directory: root.path)
    let started = expectation(description: "private file opened")
    let release = DispatchSemaphore(value: 0)
    let task = Task.detached {
      try StorageSpeedEngine.run(target: target, configuration: .init(bytes: 16 * 1_048_576)) { value in
        if value.phase == .writing && value.fraction == 0 {
          started.fulfill(); release.wait()
        }
      }
    }
    await fulfillment(of: [started], timeout: 4)
    // The directory is already empty while the test descriptor is open.
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    task.cancel(); release.signal()
    do { _ = try await task.value; XCTFail("A cancelled test must not become a result") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
  func testTimeoutCleansUpInsteadOfPublishingPartialSpeedAsSuccess() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let target = StorageSpeedTarget.local(directory: root.path)
    do {
      _ = try await Task.detached { try StorageSpeedEngine.run(target: target, configuration: .init(bytes: 1_048_576, timeout: 0.00000001)) }.value
      XCTFail("Timed out test should fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
  func testSymlinkTargetDirectoryIsRejectedWithoutWriting() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("linked")
    let real = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let target = StorageSpeedTarget.local(directory: link.path)
    do {
      _ = try await Task.detached { try StorageSpeedEngine.run(target: target, configuration: .init(bytes: 1_048_576)) }.value
      XCTFail("Do not follow target directory symlinks")
    } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
  }
  func testRemovedExternalIdentityFailsBeforeAnyWrite() async throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let volume = ExternalVolume(id: "missing", name: "Removed", path: root.path, bsdName: "disk99999s1",
      device: "Card", transport: "USB", format: .exfat, formatDescription: "exFAT", total: nil, free: nil,
      readOnly: false, isCard: true, cameraFolder: nil, contentChecked: true)
    do {
      _ = try await Task.detached { try StorageSpeedEngine.run(target: StorageSpeedTarget(volume: volume)) }.value
      XCTFail("A stale volume must not fall back to writing on the system disk")
    } catch { XCTAssertTrue(error.localizedDescription.contains("移除")) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
  func testReadOnlyAndCapacityReserveRejectUnsafeWorkloads() {
    XCTAssertThrowsError(try StorageSpeedEngine.validate(bytes: 1024, free: 1_000_000, reserve: 512, readOnly: true))
    XCTAssertThrowsError(try StorageSpeedEngine.validate(bytes: 1024, free: 1024, reserve: 512, readOnly: false))
    XCTAssertThrowsError(try StorageSpeedEngine.validate(bytes: -1, free: UInt64.max, reserve: 512, readOnly: false))
    XCTAssertThrowsError(try StorageSpeedEngine.validate(bytes: Int.max, free: UInt64.max, reserve: 512, readOnly: false))
    XCTAssertNoThrow(try StorageSpeedEngine.validate(bytes: 1024, free: 1536, reserve: 512, readOnly: false))
  }
  func testSpeedUsesElapsedWindowsAndIncludesFlushTimeInAverage() {
    var meter = StorageSpeedEngine.Meter(start: 10)
    XCTAssertFalse(meter.record(bytes: 4_000_000, at: 10.001))
    XCTAssertTrue(meter.record(bytes: 16_000_000, at: 10.5))
    XCTAssertTrue(meter.record(bytes: 32_000_000, at: 11))
    let value = meter.finish(bytes: 32_000_000, at: 12) // One second spent flushing.
    XCTAssertEqual(value.average, 16, accuracy: 0.001)
    XCTAssertEqual(value.peak, 32, accuracy: 0.001)
    XCTAssertEqual(value.samples.count, 2)
  }
  @MainActor func testCorruptOrOversizedHistoryDoesNotBreakNewTests() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    try Data("invalid".utf8).write(to: file)
    let corrupt = StorageSpeedStore(historyURL: file)
    XCTAssertTrue(corrupt.history.isEmpty); XCTAssertNotNil(corrupt.historyIssue); XCTAssertFalse(corrupt.running)
    try Data(count: 2_000_001).write(to: file)
    XCTAssertNotNil(StorageSpeedStore(historyURL: file).historyIssue)
  }
  @MainActor func testDecodedButInvalidHistoryCannotReachByteFormattingOrSpeedUI() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("history.json")
    let bad = StorageSpeedReading(bytes: -1024, seconds: 0, samples: [2])
    let result = StorageSpeedResult(id: UUID(), targetID: "test", name: "Invalid", date: Date(), format: "APFS", transport: "内置",
      write: bad, read: bad, fullSync: true)
    try JSONEncoder().encode([result]).write(to: file)
    let store = StorageSpeedStore(historyURL: file)
    XCTAssertTrue(store.history.isEmpty); XCTAssertNotNil(store.historyIssue)
  }
  @MainActor func testRenderSpeedViewWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["CHENGGUAN_SPEED_RENDER_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    func render<V: View>(_ view: V, name: String, scheme: ColorScheme) throws {
      let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)); renderer.scale = 2
      let image = try XCTUnwrap(renderer.nsImage)
      let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    func reading(_ seconds: Double) -> StorageSpeedReading {
      StorageSpeedReading(bytes: 1_000_000_000, seconds: seconds, samples: [])
    }
    for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
      for width in [790, 850] {
        try render(StorageSpeedView().content.frame(width: CGFloat(width), height: 680), name: "speed-\(name)-\(width)", scheme: scheme)
      }
      // Match the 204 pt card in the reported screenshot, including units and slow media.
      for (sample, write, read) in [("seconds", 1.22, 1.12), ("milliseconds", 0.58, 0.14), ("slow", 20_000.0, 666.7)] {
        try render(StorageTransferEstimate(write: reading(write), read: reading(read)).frame(width: 204),
          name: "estimate-\(name)-\(sample)", scheme: scheme)
      }
      try render(StorageTransferEstimate(write: nil, read: nil).frame(width: 204), name: "estimate-\(name)-empty", scheme: scheme)
    }
  }
}
