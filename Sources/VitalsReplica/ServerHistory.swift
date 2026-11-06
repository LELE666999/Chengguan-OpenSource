import Foundation

struct ServerResourceSample: Codable, Equatable, Identifiable, Sendable {
  var time: Date
  var memory: Double?
  var load: Double?
  var id: Date { time }
}

struct ServerTrafficDay: Codable, Equatable, Identifiable, Sendable {
  var date: Date
  var bytes: Double
  var intervals: Int
  var id: Date { date }
}

/// Numeric history only. Monthly counters are never presented as historical daily totals.
struct ServerHistory: Codable, Equatable, Sendable {
  struct Baseline: Codable, Equatable, Sendable {
    var time: Date
    var counter: Double
    var reset: Date?
  }
  var samples: [ServerResourceSample] = []
  var days: [ServerTrafficDay] = []
  var baseline: Baseline?
  var latest: Date?

  static func key(_ veid: String) -> String { "kiwiServerHistory." + veid }
  static func load(veid: String, defaults: UserDefaults, now: Date = .now, calendar: Calendar = .current) -> Self {
    guard let data = defaults.data(forKey: key(veid)), data.count < 2_000_000,
          var value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
    value.prune(now: now, calendar: calendar)
    return value
  }
  func save(veid: String, defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(veid)) }
  }
  mutating func record(_ snapshot: ServerSnapshot, calendar: Calendar = .current) {
    let now = snapshot.time
    guard now.timeIntervalSince1970.isFinite, latest.map({ now > $0 }) ?? true else { return }
    prune(now: now, calendar: calendar)
    latest = now
    let memory = Self.valid(snapshot.memoryUsed), load = Self.valid(snapshot.load.first)
    if memory != nil || load != nil { samples.append(.init(time: now, memory: memory, load: load)) }
    if let counter = Self.valid(snapshot.transferUsed) {
      if let previous = baseline, now > previous.time, previous.reset == snapshot.reset,
         counter >= previous.counter, calendar.isDate(previous.time, inSameDayAs: now) {
        // A delta crossing midnight cannot be assigned accurately to either day.
        // A changed reset date or falling counter is a new billing baseline.
        let day = calendar.startOfDay(for: now), delta = counter - previous.counter
        if let index = days.firstIndex(where: { $0.date == day }) {
          days[index].bytes += delta; days[index].intervals += 1
        } else { days.append(.init(date: day, bytes: delta, intervals: 1)) }
      }
      baseline = .init(time: now, counter: counter, reset: snapshot.reset)
    }
    samples = Array(samples.suffix(1440))
  }
  mutating func prune(now: Date, calendar: Calendar = .current) {
    let cutoff = now.addingTimeInterval(-86400)
    samples = Array(samples.filter {
      $0.time >= cutoff && $0.time <= now && ($0.memory == nil || Self.valid($0.memory) != nil) && ($0.load == nil || Self.valid($0.load) != nil)
    }.sorted { $0.time < $1.time }.suffix(1440))
    let dayCutoff = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? cutoff
    days = Array(days.filter { $0.date >= dayCutoff && $0.date <= now && Self.valid($0.bytes) != nil && $0.intervals > 0 }
      .sorted { $0.date < $1.date }.suffix(31))
    if let baseline, baseline.time > now || Self.valid(baseline.counter) == nil { self.baseline = nil }
    if let latest, latest > now { self.latest = nil }
  }
  func week(ending now: Date, calendar: Calendar = .current) -> [(date: Date, bytes: Double?)] {
    let today = calendar.startOfDay(for: now)
    return (-6...0).compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
      return (day, days.first { calendar.isDate($0.date, inSameDayAs: day) }?.bytes)
    }
  }
  private static func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
}
