import Foundation
import DiskArbitration

struct StorageDiskSignal: Sendable {
  enum Kind: Sendable { case mounted, removed, appeared }
  let kind: Kind
  let bsdName: String
  let path: String?
  var whole = false
}

/// Disk Arbitration runs in common modes so an open menu or confirmation cannot defer removal.
@MainActor final class StorageDiskEvents {
  private var session: DASession?
  var onEvent: ((StorageDiskSignal) -> Void)?
  func start() {
    guard session == nil, let session = DASessionCreate(nil) else { return }
    self.session = session
    let context = Unmanaged.passUnretained(self).toOpaque()
    DARegisterDiskAppearedCallback(session, nil, storageDiskAppeared, context)
    DARegisterDiskDisappearedCallback(session, nil, storageDiskDisappeared, context)
    DARegisterDiskDescriptionChangedCallback(session, nil,
      [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray, storageDiskChanged, context)
    DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
  }
  func stop() {
    guard let session else { return }
    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    let context = Unmanaged.passUnretained(self).toOpaque()
    DAUnregisterCallback(session, unsafeBitCast(storageDiskAppeared, to: UnsafeMutableRawPointer.self), context)
    DAUnregisterCallback(session, unsafeBitCast(storageDiskDisappeared, to: UnsafeMutableRawPointer.self), context)
    DAUnregisterCallback(session, unsafeBitCast(storageDiskChanged, to: UnsafeMutableRawPointer.self), context)
    self.session = nil
  }
  fileprivate func receive(_ signal: StorageDiskSignal) { if session != nil { onEvent?(signal) } }
}

private func storageSignal(_ disk: DADisk, _ kind: StorageDiskSignal.Kind) -> StorageDiskSignal {
  let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
  let path = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
  return StorageDiskSignal(kind: kind, bsdName: DADiskGetBSDName(disk).map { String(cString: $0) } ?? "",
    path: path, whole: description[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false)
}
private func deliverStorageSignal(_ signal: StorageDiskSignal, _ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  // The registered callbacks and their teardown all run on the main run loop.
  MainActor.assumeIsolated { Unmanaged<StorageDiskEvents>.fromOpaque(context).takeUnretainedValue().receive(signal) }
}
private let storageDiskAppeared: DADiskAppearedCallback = { disk, context in
  let signal = storageSignal(disk, .appeared)
  deliverStorageSignal(signal, context)
}
private let storageDiskDisappeared: DADiskDisappearedCallback = { disk, context in
  deliverStorageSignal(storageSignal(disk, .removed), context)
}
private let storageDiskChanged: DADiskDescriptionChangedCallback = { disk, keys, context in
  let signal = storageSignal(disk, .mounted)
  let pathChanged = (keys as NSArray).contains(kDADiskDescriptionVolumePathKey)
  deliverStorageSignal(StorageDiskSignal(kind: pathChanged && signal.path == nil ? .removed : .mounted,
    bsdName: signal.bsdName, path: signal.path, whole: signal.whole), context)
}
