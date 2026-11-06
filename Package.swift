// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "VitalsReplica",
  platforms: [.macOS("15.0")],
  products: [.executable(name: "Chengguan", targets: ["VitalsReplica"])],
  targets: [
    .target(name: "DisplayBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]),
    .target(
      name: "MonitorBridge", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("proc")]),
    .executableTarget(
      name: "VitalsReplica", dependencies: ["MonitorBridge", "DisplayBridge"],
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("CoreWLAN"),
        .linkedFramework("IOBluetooth"), .linkedFramework("ServiceManagement"), .linkedFramework("Security"), .linkedFramework("AVFoundation"), .linkedFramework("SceneKit"), .linkedFramework("DiskArbitration"),
        .linkedLibrary("sqlite3"),
      ]),
    .testTarget(name: "VitalsReplicaTests", dependencies: ["VitalsReplica", "MonitorBridge", "DisplayBridge"]),
  ]
)
