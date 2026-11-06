import AppKit
import DiskArbitration

enum StorageEjectResult: Equatable, Sendable {
  case ejected
  case unavailable
  case failed(String)
}

enum StorageEjector {
  /// Uses the OS's normal safe eject, without force-unmount or process termination.
  static func eject(_ volume: ExternalVolume) async -> StorageEjectResult {
    await Task.detached(priority: .userInitiated) {
      guard ExternalStorageReader.readMounted(volume) != nil else { return .unavailable }
      do {
        try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path, isDirectory: true))
        return .ejected
      } catch {
        return .failed(error.localizedDescription)
      }
    }.value
  }
}
