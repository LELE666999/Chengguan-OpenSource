import Darwin
import Foundation

/// Read-only collector benchmark. It never loads AI configuration or credentials.
enum CollectorBenchmark {
  static func run(_ collector: SystemCollector) {
    func cpuTime() -> Double {
      var r = rusage(); getrusage(RUSAGE_SELF, &r)
      return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    _ = collector.sample()
    let begin = ProcessInfo.processInfo.systemUptime, cpuBefore = cpuTime()
    var samples: [MonitorSnapshot] = []
    for _ in 0..<12 { Thread.sleep(forTimeInterval: 2); samples.append(collector.sample()) }
    let elapsed = ProcessInfo.processInfo.systemUptime - begin
    let durations = samples.map { $0.samplingDuration * 1000 }.sorted()
    let own = samples.compactMap { $0.processes.first { $0.pid == getpid() } }
    let output: [String: Any] = ["samples": samples.count, "wall_seconds": elapsed,
      "collector_process_cpu_percent_one_core": (cpuTime() - cpuBefore) / elapsed * 100,
      "mean_sample_ms": durations.reduce(0, +) / Double(durations.count), "max_sample_ms": durations.max() ?? 0,
      "mean_footprint_bytes": own.map { Double($0.memory) }.reduce(0, +) / Double(max(1, own.count)),
      "mean_wakeups_per_second": own.map(\.wakeups).reduce(0, +) / Double(max(1, own.count))]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
  }
}
