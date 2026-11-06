import AppKit
import Foundation
import IOKit
import IOKit.ps
import MonitorBridge

enum SystemValue {
  static func string(_ key: String) -> String? {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
  }
  static func int(_ key: String) -> Int? {
    var n: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(key, &n, &size, nil, 0) == 0 ? Int(n) : nil
  }
  static let chip = string("machdep.cpu.brand_string") ?? "Mac"
  static let clusters: [(String, Int)] = (0..<5).compactMap { i in
    guard let name = string("hw.perflevel\(i).name"),
      let count = int("hw.perflevel\(i).physicalcpu"), count > 0
    else { return nil }
    return (name, count)
  }.reversed()
  static var coreLabels: [String] {
    clusters.flatMap { (name, n) in
      Array(
        repeating: name.hasPrefix("Super") ? "S" : (name.hasPrefix("Efficiency") ? "E" : "P"),
        count: n)
    }
  }
  static var clusterDescription: String {
    clusters.map { "\($0.1)个\($0.0 == "Super" ? "超级":($0.0 == "Efficiency" ? "能效":"性能"))内核" }
      .joined(separator: "  ·  ")
  }
  static func properties(_ className: String) -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var values: [[String: Any]] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      var data: Unmanaged<CFMutableDictionary>?
      if IORegistryEntryCreateCFProperties(service, &data, kCFAllocatorDefault, 0) == KERN_SUCCESS,
        let d = data?.takeRetainedValue() as? [String: Any]
      {
        values.append(d)
      }
    }
    return values
  }
}

enum Command {
  struct Output {
    var text: String
    var status: Int32
  }
  static func run(_ path: String, _ arguments: [String], timeout: Double = 4, includeError: Bool = false) -> Output {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardOutput = pipe
    p.standardError = includeError ? pipe : FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return Output(text: "", status: -1) }
    let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    deadline.cancel()
    return Output(text: String(data: data, encoding: .utf8) ?? "", status: p.terminationStatus)
  }
}

struct CollectionPolicy: Equatable {
  var visible = true
  var battery = false
  var incident = false
  var networkInterval: Double { incident ? 5 : visible ? (battery ? 10 : 5) : 20 }
  var hardwareInterval: Double { incident ? 2 : visible ? (battery ? 5 : 2) : 10 }
  var projectInterval: Double { incident ? 10 : visible ? 20 : 60 }
  var volumeInterval: Double { incident ? 10 : visible ? 15 : 60 }
  var batteryInterval: Double { visible ? 5 : 15 }
  var title: String { incident ? "异常观察" : !visible ? "后台节能" : battery ? "电池节能" : "标准" }
}

final class SystemCollector {
  var policy = CollectionPolicy()
  private var cachedHardware = MonitorSnapshot()
  private var cachedBattery = BatterySample()
  private var cachedVolumes: [VolumeSample] = []
  private var cachedAgents: [String: String] = [:]
  private var moduleDates: [String: Double] = [:]
  private var projectScanTime: Date?

  private var lastSystem: VRSystem?
  private var lastTime: Double?
  private var previous: [String: (cpu: UInt64, read: UInt64, write: UInt64, wake: UInt64)] = [:]
  private var previousEnergy: [String: UInt64] = [:]
  private var networkPrevious: [String: (UInt64, UInt64)] = [:]
  private var networkRates: [String: (Double, Double)] = [:]
  private var lastNetworkTime: Double?
  private var lastDisk: (UInt64, UInt64)?
  private var totals = (received: 0.0, sent: 0.0, written: 0.0)
  private var names: [String: String] = [:]
  private var systemBundles: Set<String> = []
  private var previousDiscovery: Double = 0
  private var projectPaths: [String: String] = [:]
  private var processPorts: [Int32: [Int]] = [:]
  private var sensorKeys: [(String, String)] = []
  private var sensorsDiscovered = false
  private let smc = SMC()
  private lazy var energyReader = ChipEnergyReader()
  private var cachedPower = PowerSample()

  func sample() -> MonitorSnapshot {
    let started = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.01, started - (lastTime ?? started))
    var s = MonitorSnapshot()
    s.isWarmup = lastSystem == nil
    s.collectionMode = policy.title
    s.networkSampleInterval = policy.networkInterval
    func measure(_ name: String, _ work: () -> Void) {
      let begin = ProcessInfo.processInfo.systemUptime
      work(); s.moduleDurations[name] = ProcessInfo.processInfo.systemUptime - begin
    }
    func due(_ name: String, _ interval: Double) -> Bool {
      guard started - (moduleDates[name] ?? -.infinity) >= interval else { return false }
      moduleDates[name] = started; return true
    }
    var raw = VRSystem()
    if !vr_read_system(&raw) { s.error = "暂时无法读取系统指标" }
    let ticks = withUnsafeBytes(of: raw.cores) { Array($0.bindMemory(to: VRTicks.self)) }
    let oldTicks = lastSystem.map { system in
      withUnsafeBytes(of: system.cores) { Array($0.bindMemory(to: VRTicks.self)) }
    }
    var user = 0.0
    var system = 0.0
    var total = 0.0
    for i in 0..<min(Int(raw.core_count), ticks.count) {
      let now = ticks[i]
      let old = oldTicks?[i]
      let u = Double(now.user &- (old?.user ?? now.user))
      let sy = Double(now.system &- (old?.system ?? now.system))
      let idle = Double(now.idle &- (old?.idle ?? now.idle))
      let nice = Double(now.nice &- (old?.nice ?? now.nice))
      let t = u + sy + idle + nice
      user += u + nice
      system += sy
      total += t
      s.coreUsage.append(t > 0 ? min(100, (u + sy + nice) / t * 100) : 0)
    }
    s.user = total > 0 ? user / total * 100 : 0
    s.system = total > 0 ? system / total * 100 : 0
    s.cpu = s.user + s.system
    s.coreLabels = SystemValue.coreLabels
    s.clusterDescription = SystemValue.clusterDescription
    s.load = raw.load.0
    s.totalMemory = raw.memory_total
    s.localNetwork = LocalNetworkSnapshot.read()
    s.appMemory = raw.memory_app
    s.wired = raw.memory_wired
    s.compressed = raw.memory_compressed
    s.cached = raw.memory_cached
    s.swap = raw.swap_used
    s.pressureLevel = Int(raw.pressure_level)
    if let old = lastSystem {
      s.download = CounterMath.rate(
        current: raw.network_in, previous: old.network_in, elapsed: elapsed)
      s.upload = CounterMath.rate(
        current: raw.network_out, previous: old.network_out, elapsed: elapsed)
    }
    var buffer = [VRProcess](repeating: VRProcess(), count: Int(max(256, vr_process_capacity())))
    let count = Int(vr_read_processes(&buffer, Int32(buffer.count)))
    var next: [String: (UInt64, UInt64, UInt64, UInt64)] = [:]
    var nextEnergy: [String: UInt64] = [:]
    for p in buffer.prefix(count) {
      let name = withUnsafePointer(to: p.name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
      }
      let path = withUnsafePointer(to: p.path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
      }
      var item = ProcessSample(
        pid: p.pid, ppid: p.ppid, uid: p.uid, start: p.start_sec, name: name, path: path,
        memory: p.memory, measured: p.measured, measurementError: p.read_error)
      let prev = previous[item.identity]
      item.cpu =
        CounterMath.rate(current: p.cpu_ns, previous: prev?.cpu, elapsed: elapsed) / 1e9 * 100
      item.readRate = CounterMath.rate(
        current: p.read_bytes, previous: prev?.read, elapsed: elapsed)
      item.writeRate = CounterMath.rate(
        current: p.write_bytes, previous: prev?.write, elapsed: elapsed)
      item.wakeups = CounterMath.rate(current: p.wakeups, previous: prev?.wake, elapsed: elapsed)
      if p.energy_measured {
        if let old = previousEnergy[item.identity], p.energy_nj >= old {
          item.powerWatts = PowerMeasurement.watts(energy: Double(p.energy_nj - old), unit: "nJ", seconds: elapsed)
        }
        nextEnergy[item.identity] = p.energy_nj
      }
      next[item.identity] = (p.cpu_ns, p.read_bytes, p.write_bytes, p.wakeups)
      s.processes.append(item)
    }
    previous = next
    previousEnergy = nextEnergy
    if due("network", policy.networkInterval) { measure("App 网络") { readProcessNetwork(s.processes, now: started) } }
    for i in s.processes.indices {
      if let n = networkRates[s.processes[i].identity] {
        s.processes[i].networkIn = n.0
        s.processes[i].networkOut = n.1
      }
    }
    for p in s.processes {
      if let root = AppGrouping.bundleRoot(p.path), names[root] == nil {
        let bundle = Bundle(path: root)
        names[root] = URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
        if root != "/System/Library/CoreServices/Finder.app",
          root.hasPrefix("/System/Library/") || root.hasPrefix("/Library/Apple/")
            || ((bundle?.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
              && ((bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true
                || (bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) == true))
        {
          systemBundles.insert(root)
        }
      }
    }
    s.groups = AppGrouping.groups(s.processes, names: names, systemBundles: systemBundles)
    s.unmeasured = s.processes.filter { !$0.measured }.count
    if due("hardware", policy.hardwareInterval) { measure("传感器") { cachedHardware = MonitorSnapshot(); readHardware(&cachedHardware) } }
    s.gpu = cachedHardware.gpu; s.gpuMemory = cachedHardware.gpuMemory
    s.sensors = cachedHardware.sensors; s.temperature = cachedHardware.temperature; s.fan = cachedHardware.fan
    let disk = readDiskCounters()
    s.read = CounterMath.rate(current: disk.0, previous: lastDisk?.0, elapsed: elapsed)
    s.write = CounterMath.rate(current: disk.1, previous: lastDisk?.1, elapsed: elapsed)
    lastDisk = disk
    totals.received += s.download * elapsed
    totals.sent += s.upload * elapsed
    totals.written += s.write * elapsed
    s.received = totals.received
    s.sent = totals.sent
    s.written = totals.written
    if due("battery", policy.batteryInterval) { measure("电池") { cachedBattery = readBattery() } }
    if due("volumes", policy.volumeInterval) { measure("磁盘容量") { cachedVolumes = readVolumes() } }
    s.battery = cachedBattery; s.volumes = cachedVolumes
    if due("power", policy.visible ? 5 : 20) {
      measure("功率") {
        let properties = SystemValue.properties("AppleSmartBattery").first ?? [:]
        cachedPower = PowerSample(system: PowerMeasurement.valid(smc.getValue("PSTR")),
          adapter: PowerMeasurement.valid(smc.getValue("PDTR")),
          battery: PowerMeasurement.batteryWatts(voltage: (properties["Voltage"] as? NSNumber)?.doubleValue, current: properties["Amperage"] as? NSNumber),
          display: PowerMeasurement.valid(smc.getValue("PDBR")), components: energyReader.read())
        if !cachedPower.components.contains(where: { $0.id == "CPU" }),
          let cpu = ["PPMC", "PCPT", "PCPC", "PC0C"].compactMap({ PowerMeasurement.valid(smc.getValue($0)) }).first, cpu > 0 {
          cachedPower.components.insert(PowerComponent(id: "CPU", watts: cpu), at: 0)
        }
      }
    }
    s.power = cachedPower
    if due("projects", policy.projectInterval) {
      measure("项目端口") { discoverProjects(s.processes) }
      projectScanTime = Date()
      cachedAgents = [:]
    }
    s.projectScanTime = projectScanTime
    s.listeningPorts = Array(Set(processPorts.values.flatMap { $0 })).sorted()
    s.projects = makeProjects(s.processes)
    s.agents = s.processes.compactMap { p in
      let cmd = URL(fileURLWithPath: p.path).lastPathComponent.lowercased()
      let name: String?
      if ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"].contains(cmd) {
        name = "Codex"
      } else if cmd == "claude" {
        name = "Claude Code"
      } else if cmd == "opencode" {
        name = "OpenCode"
      } else if cmd == "aider" {
        name = "Aider"
      } else {
        name = nil
      }
      guard let name else { return nil }
      if cachedAgents[p.identity] == nil { cachedAgents[p.identity] = cwd(p.pid) }
      return AgentSample(process: p, name: name, directory: cachedAgents[p.identity])
    }
    lastSystem = raw
    lastTime = started
    s.time = Date()
    s.samplingDuration = ProcessInfo.processInfo.systemUptime - started
    return s
  }

  func freshForAction() -> MonitorSnapshot {
    moduleDates["projects"] = nil; moduleDates["volumes"] = nil
    return sample()
  }

  private func readProcessNetwork(_ processes: [ProcessSample], now: Double) {
    let result = Command.run(
      "/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"])
    guard result.status == 0 else {
      networkRates = [:]
      return
    }
    let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.identity) })
    var counters: [String: (UInt64, UInt64)] = [:]
    var rates: [String: (Double, Double)] = [:]
    for line in result.text.split(separator: "\n") {
      let cols = line.split(separator: ",", omittingEmptySubsequences: false)
      guard cols.count >= 3, let pid = Int32(cols[0].split(separator: ".").last ?? ""),
        let key = byPID[pid], let rx = UInt64(cols[1]), let tx = UInt64(cols[2])
      else { continue }
      let old = networkPrevious[key]
      let dt = now - (lastNetworkTime ?? now)
      if old != nil {
        rates[key] = (
          CounterMath.rate(current: rx, previous: old?.0, elapsed: dt),
          CounterMath.rate(current: tx, previous: old?.1, elapsed: dt)
        )
      }
      counters[key] = (rx, tx)
    }
    networkPrevious = counters
    networkRates = rates
    lastNetworkTime = now
  }
  private func readHardware(_ s: inout MonitorSnapshot) {
    if let stats = SystemValue.properties("AGXAccelerator").first?["PerformanceStatistics"]
      as? [String: Any]
    {
      s.gpu = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
      s.gpuMemory = (stats["In use system memory"] as? NSNumber)?.uint64Value
    }
    if !sensorsDiscovered {
      let generation = SystemValue.chip
      let cpuKeys: [String]
      if generation.contains("M5") {
        cpuKeys = [
          "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a",
          "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
        ]
      } else if generation.contains("M3") {
        cpuKeys = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E"]
      } else {
        cpuKeys = [
          "TC0P", "TC0D", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
          "Tp0f", "Tp0j", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Te05", "Te0S", "Te09", "Te0H",
        ]
      }
      let gpuKeys = [
        "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g", "Tg05", "Tg0D", "Tg0L",
        "TG0P",
      ]
      for (prefix, keys) in [("CPU", cpuKeys), ("GPU", gpuKeys)] {
        for (i, key) in keys.enumerated() {
          if let t = smc.getValue(key), t > 0, t < 130 {
            sensorKeys.append((key, "\(prefix) \(i+1)"))
          }
        }
      }
      sensorsDiscovered = true
    }
    s.sensors = sensorKeys.compactMap { key, name in
      guard let t = smc.getValue(key), t > 0, t < 130 else { return nil }
      return SensorSample(key: key, name: name, value: t, unit: "°C")
    }
    let temperatures = s.sensors.filter { $0.name.hasPrefix("CPU") }.map(\.value)
    if !temperatures.isEmpty {
      s.temperature = temperatures.reduce(0, +) / Double(temperatures.count)
    }
    s.fan = smc.getValue("F0Ac")
    for i in 0..<4 {
      if let rpm = smc.getValue("F\(i)Ac") {
        s.sensors.append(SensorSample(key: "F\(i)Ac", name: "风扇 \(i+1)", value: rpm, unit: "rpm"))
      }
    }
  }
  private func readDiskCounters() -> (UInt64, UInt64) {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    for d in SystemValue.properties("IOBlockStorageDriver") {
      if let st = d["Statistics"] as? [String: Any] {
        rx += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        tx += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
      }
    }
    return (rx, tx)
  }
  private func readBattery() -> BatterySample {
    var b = BatterySample()
    if let d = SystemValue.properties("AppleSmartBattery").first {
      let nested = d["BatteryData"] as? [String: Any] ?? [:]
      func n(_ key: String) -> Double? { ((d[key] ?? nested[key]) as? NSNumber)?.doubleValue }
      if let current = n("CurrentCapacity"), let max = n("MaxCapacity"), max > 0 {
        b.percent = min(100, current / max * 100)
      }
      if let full = n("AppleRawMaxCapacity") ?? n("NominalChargeCapacity"),
        let design = n("DesignCapacity"), design > 0
      {
        b.health = min(100, full / design * 100)
      }
      b.cycles = (d["CycleCount"] as? NSNumber)?.intValue
      b.temperature =
        n("Temperature").map { $0 / 100 } ?? smc.getValue("TB0T") ?? smc.getValue("TB1T")
      b.charging = (d["IsCharging"] as? Bool) ?? false
      b.plugged = (d["ExternalConnected"] as? Bool) ?? false
      b.watts = PowerMeasurement.batteryWatts(voltage: n("Voltage"), current: d["Amperage"] as? NSNumber).map(abs)
      if let t = n("TimeRemaining"), t > 0, t < 65535 { b.minutes = Int(t) }
    }
    return b
  }
  private func readVolumes() -> [VolumeSample] {
    let keys: [URLResourceKey] = [
      .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey,
    ]
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { u in
      guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true,
        let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacity
      else { return nil }
      return VolumeSample(
        path: u.path, name: v.volumeName ?? u.lastPathComponent, total: UInt64(total),
        free: UInt64(max(Int64(free), v.volumeAvailableCapacityForImportantUsage ?? 0)),
        removable: v.volumeIsInternal != true)
    }.sorted { ($0.path == "/" ? 0 : 1) < ($1.path == "/" ? 0 : 1) }
  }
  private func cwd(_ pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: 4096)
    return vr_process_cwd(pid, &path, 4096) ? String(cString: path) : nil
  }
  private func root(_ directory: String) -> String? {
    guard directory.hasPrefix("/Users/") || directory.hasPrefix("/Volumes/") else { return nil }
    var u = URL(fileURLWithPath: directory)
    for _ in 0..<10 {
      if [
        ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift",
        "Gemfile",
      ].contains(where: {
        FileManager.default.fileExists(atPath: u.appendingPathComponent($0).path)
      }) {
        return u.path
      }
      if u.path == NSHomeDirectory() || u.path == "/Users" || u.path == "/" { return nil }
      u.deleteLastPathComponent()
    }
    return nil
  }
  private func discoverProjects(_ processes: [ProcessSample]) {
    projectPaths = [:]
    processPorts = [:]
    let output = Command.run(
      "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 3)
    var pid: Int32 = 0
    for line in output.text.split(separator: "\n") {
      if line.hasPrefix("p") {
        pid = Int32(line.dropFirst()) ?? 0
      } else if line.hasPrefix("n"), let port = Int(line.split(separator: ":").last ?? ""), port > 0
      {
        processPorts[pid, default: []].append(port)
      }
    }
    let commands: Set<String> = [
      "node", "bun", "deno", "python", "python3", "ruby", "php", "go", "java", "swift", "cargo",
      "vite", "next-server",
    ]
    for p in processes where commands.contains(p.name.lowercased()) || processPorts[p.pid] != nil {
      if let dir = cwd(p.pid), let r = root(dir) { projectPaths[p.identity] = r }
    }
  }
  private func makeProjects(_ processes: [ProcessSample]) -> [ProjectSample] {
    var groups: [String: ProjectSample] = [:]
    for p in processes {
      guard let path = projectPaths[p.identity] else { continue }
      if groups[path] == nil {
        groups[path] = ProjectSample(
          path: path, name: URL(fileURLWithPath: path).lastPathComponent, processes: [], ports: [])
      }
      groups[path]!.processes.append(p)
      groups[path]!.ports += processPorts[p.pid] ?? []
    }
    return groups.values.map {
      var v = $0
      v.ports = Array(Set(v.ports)).sorted()
      return v
    }.sorted { $0.memory > $1.memory }
  }
}
