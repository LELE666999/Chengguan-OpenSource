import Foundation

/// A bounded, in-memory diagnostic window. No process paths or credentials are retained.
struct OverviewAppReading: Identifiable, Sendable {
  let id: String, name: String
  let bundlePath: String?
  var cpu: Double, memory: Double
}
struct OverviewFrame: Identifiable, Sendable {
  let point: HistoryPoint
  let user: Double, system: Double
  let cores: [Double]
  let apps: [OverviewAppReading]
  var id: Date { point.time }
  init(_ snapshot: MonitorSnapshot) {
    point = snapshot.point; user = snapshot.user; system = snapshot.system
    cores = snapshot.coreUsage
    apps = snapshot.groups.filter { $0.measuredCount > 0 }.map {
      OverviewAppReading(id: $0.id, name: $0.name, bundlePath: $0.bundlePath,
                         cpu: $0.cpu, memory: Double($0.memory))
    }
  }
}
enum OverviewTimeline {
  /// Do not draw an invented continuous curve through sleep or a paused sampler.
  static func segments(_ frames: [OverviewFrame]) -> [[OverviewFrame]] {
    var result: [[OverviewFrame]] = []
    for frame in frames {
      if let previous = result.last?.last, frame.id.timeIntervalSince(previous.id) <= 10 {
        result[result.count - 1].append(frame)
      } else { result.append([frame]) }
    }
    return result
  }
  static func frames(_ frames: [OverviewFrame], in range: ClosedRange<Date>?) -> [OverviewFrame] {
    guard let range else { return frames }
    if range.upperBound.timeIntervalSince(range.lowerBound) < 1 {
      // A point selection cannot silently jump across a sleep or sampling gap.
      guard let nearest = frames.min(by: { abs($0.id.timeIntervalSince(range.lowerBound)) < abs($1.id.timeIntervalSince(range.lowerBound)) }),
            abs(nearest.id.timeIntervalSince(range.lowerBound)) <= 10 else { return [] }
      return [nearest]
    }
    return frames.filter { range.contains($0.id) }
  }
  static func ranking(_ frames: [OverviewFrame], memory: Bool) -> [OverviewAppReading] {
    guard !frames.isEmpty else { return [] }
    var apps: [String: OverviewAppReading] = [:]
    for frame in frames {
      for reading in frame.apps {
        if var app = apps[reading.id] {
          app.cpu += reading.cpu; app.memory += reading.memory; apps[reading.id] = app
        } else { apps[reading.id] = reading }
      }
    }
    return apps.values.map {
      var app = $0
      app.cpu /= Double(frames.count); app.memory /= Double(frames.count)
      return app
    }.sorted {
      let lhs = memory ? $0.memory : $0.cpu, rhs = memory ? $1.memory : $1.cpu
      return lhs == rhs ? $0.id < $1.id : lhs > rhs
    }
  }
}

struct SensorExtremum: Sendable {
  var minimum: Double, maximum: Double
}
struct SensorExtremaTracker {
  private(set) var values: [String: SensorExtremum] = [:]
  mutating func observe(_ sensors: [SensorSample]) {
    for sensor in sensors where sensor.value.isFinite {
      let old = values[sensor.key]
      values[sensor.key] = SensorExtremum(minimum: min(old?.minimum ?? sensor.value, sensor.value),
                                         maximum: max(old?.maximum ?? sensor.value, sensor.value))
    }
  }
}
