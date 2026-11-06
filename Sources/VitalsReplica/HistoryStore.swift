import Foundation
import SQLite3

struct HistoryTotals: Sendable {
  var cpu = 0.0, downloaded = 0.0, uploaded = 0.0, written = 0.0
}
struct AppHistorySummary: Identifiable, Sendable {
  let id: String, name: String
  let cpuSeconds: Double, memory: Double
}

struct AppHistoryPoint: Identifiable, Sendable {
  let time: Date
  let cpu: Double
  let memory: Double
  var id: Date { time }
}

final class HistoryStore {
  private var db: OpaquePointer?
  private var lastWrite: Date = .distantPast
  private var lastCleanup: Date = .distantPast
  let url: URL
  init(url: URL? = nil) {
    self.url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("VitalsReplica/history.sqlite")
    try? FileManager.default.createDirectory(
      at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if sqlite3_open_v2(
      self.url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
      == SQLITE_OK
    {
      sqlite3_busy_timeout(db, 2000)
      execute(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS samples(time REAL PRIMARY KEY,cpu REAL,memory REAL,gpu REAL,download REAL,upload REAL,disk_read REAL,disk_write REAL,temperature REAL,battery REAL); CREATE TABLE IF NOT EXISTS apps(time REAL,id TEXT,name TEXT,cpu REAL,memory REAL,PRIMARY KEY(time,id)); CREATE INDEX IF NOT EXISTS apps_time ON apps(time);"
      )
    }
  }
  deinit { sqlite3_close(db) }
  private func execute(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
  func record(_ snapshot: MonitorSnapshot, force: Bool = false) {
    guard !snapshot.isWarmup else { return }
    guard force || snapshot.time.timeIntervalSince(lastWrite) >= 30 else { return }
    let p = snapshot.point
    var stmt: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "INSERT OR REPLACE INTO samples VALUES(?,?,?,?,?,?,?,?,?,?)", -1, &stmt, nil)
        == SQLITE_OK
    else { return }
    let vals: [Double?] = [
      p.time.timeIntervalSince1970, p.cpu, p.memory, p.gpu, p.download, p.upload, p.read, p.write,
      p.temperature, p.battery,
    ]
    for (i, v) in vals.enumerated() {
      if let v {
        sqlite3_bind_double(stmt, Int32(i + 1), v)
      } else {
        sqlite3_bind_null(stmt, Int32(i + 1))
      }
    }
    let success = sqlite3_step(stmt) == SQLITE_DONE
    sqlite3_finalize(stmt)
    guard success else { return }
    lastWrite = snapshot.time
    execute("BEGIN TRANSACTION")
    if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO apps VALUES(?,?,?,?,?)", -1, &stmt, nil)
      == SQLITE_OK
    {
      for g in snapshot.groups {
        sqlite3_bind_double(stmt, 1, p.time.timeIntervalSince1970)
        _ = g.id.withCString {
          sqlite3_bind_text(stmt, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        _ = g.name.withCString {
          sqlite3_bind_text(stmt, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_double(stmt, 4, g.cpu)
        sqlite3_bind_double(stmt, 5, Double(g.memory))
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
      }
      sqlite3_finalize(stmt)
    }
    execute("COMMIT")
    if snapshot.time.timeIntervalSince(lastCleanup) > 3600 {
      let days = UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 30
      let cutoff = snapshot.time.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
      execute("DELETE FROM samples WHERE time<\(cutoff); DELETE FROM apps WHERE time<\(cutoff);")
      lastCleanup = snapshot.time
    }
  }
  func points(since: Date, buckets: Int = 240) -> [HistoryPoint] {
    let width = max(30, Date().timeIntervalSince(since) / Double(max(1, buckets)))
    let sql =
      "SELECT MIN(time),AVG(cpu),AVG(memory),AVG(gpu),AVG(download),AVG(upload),AVG(disk_read),AVG(disk_write),AVG(temperature),AVG(battery) FROM samples WHERE time>=? GROUP BY CAST(time / ? AS INTEGER) ORDER BY MIN(time)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
    sqlite3_bind_double(stmt, 2, width)
    var values: [HistoryPoint] = []
    func n(_ i: Int32) -> Double? {
      sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
    }
    while sqlite3_step(stmt) == SQLITE_ROW {
      values.append(
        HistoryPoint(
          time: Date(timeIntervalSince1970: n(0) ?? 0), cpu: n(1) ?? 0, memory: n(2) ?? 0,
          gpu: n(3), download: n(4) ?? 0, upload: n(5) ?? 0, read: n(6) ?? 0, write: n(7) ?? 0,
          temperature: n(8), battery: n(9)))
    }
    return values
  }
  func totals(since: Date) -> HistoryTotals {
    let sql =
      "WITH intervals AS (SELECT *,LEAD(time) OVER(ORDER BY time)-time AS dt FROM samples WHERE time>=?) SELECT AVG(cpu),SUM(download*CASE WHEN dt BETWEEN 0 AND 90 THEN dt ELSE 0 END),SUM(upload*CASE WHEN dt BETWEEN 0 AND 90 THEN dt ELSE 0 END),SUM(disk_write*CASE WHEN dt BETWEEN 0 AND 90 THEN dt ELSE 0 END) FROM intervals"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return HistoryTotals() }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return HistoryTotals() }
    return HistoryTotals(
      cpu: sqlite3_column_double(stmt, 0), downloaded: sqlite3_column_double(stmt, 1),
      uploaded: sqlite3_column_double(stmt, 2), written: sqlite3_column_double(stmt, 3))
  }
  func appSummary(since: Date) -> [AppHistorySummary] {
    let sql =
      "WITH intervals AS (SELECT *,LEAD(time) OVER(PARTITION BY id ORDER BY time)-time AS dt FROM apps WHERE time>=?) SELECT id,name,SUM(cpu/100*CASE WHEN dt BETWEEN 0 AND 90 THEN dt ELSE 0 END),AVG(memory) FROM intervals GROUP BY id ORDER BY 3 DESC LIMIT 12"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
    var result: [AppHistorySummary] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let id = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) else {
        continue
      }
      result.append(
        AppHistorySummary(
          id: String(cString: id), name: String(cString: name),
          cpuSeconds: sqlite3_column_double(stmt, 2), memory: sqlite3_column_double(stmt, 3)))
    }
    return result
  }
  func appPoints(id: String, since: Date) -> [AppHistoryPoint] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT time,cpu,memory FROM apps WHERE id=? AND time>=? ORDER BY time LIMIT 4000", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    _ = id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
    var result: [AppHistoryPoint] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      result.append(AppHistoryPoint(time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)), cpu: sqlite3_column_double(stmt, 1), memory: sqlite3_column_double(stmt, 2)))
    }
    return result
  }
  func exportFiles(since: Date) -> [(String, String)] {
    let hourly = points(since: since, buckets: max(1, Int(Date().timeIntervalSince(since) / 3600)))
    let fiveMinutes = points(
      since: since, buckets: max(1, Int(Date().timeIntervalSince(since) / 300)))
    var apps = "day,app,cpu_seconds,memory_average_bytes,memory_peak_bytes\n"
    let sql =
      "WITH intervals AS (SELECT *,LEAD(time) OVER(PARTITION BY id ORDER BY time)-time AS dt FROM apps WHERE time>=?) SELECT strftime('%Y-%m-%d',time,'unixepoch','localtime'),name,SUM(cpu/100*CASE WHEN dt BETWEEN 0 AND 90 THEN dt ELSE 0 END),AVG(memory),MAX(memory) FROM intervals GROUP BY 1,id ORDER BY 1,2"
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
      sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
      while sqlite3_step(stmt) == SQLITE_ROW {
        let day = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        apps +=
          "\(day),\(Self.csvField(name)),\(sqlite3_column_double(stmt,2)),\(sqlite3_column_double(stmt,3)),\(sqlite3_column_double(stmt,4))\n"
      }
    }
    sqlite3_finalize(stmt)
    return [
      ("Apps-daily.csv", apps), ("Mac-hourly.csv", Self.csv(hourly)),
      ("Readings-5min.csv", Self.csv(fiveMinutes)),
    ]
  }
  static func csv(_ points: [HistoryPoint]) -> String {
    let iso = ISO8601DateFormatter()
    return
      "time,cpu_percent,memory_bytes,gpu_percent,download_bytes_s,upload_bytes_s,disk_read_bytes_s,disk_write_bytes_s,temperature_c,battery_percent\n"
      + points.map { p in
        [
          iso.string(from: p.time), String(p.cpu), String(p.memory),
          p.gpu.map(String.init(describing:)) ?? "", String(p.download), String(p.upload),
          String(p.read), String(p.write), p.temperature.map(String.init(describing:)) ?? "",
          p.battery.map(String.init(describing:)) ?? "",
        ].joined(separator: ",")
      }.joined(separator: "\n") + "\n"
  }
  static func csvField(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
