import Combine
import Foundation
import SQLite3

/// Only lifecycle metadata is decoded. Prompts, tool arguments and responses are not retained.
struct CodexSessionActivity {
  var directory: String?
  var activeTurns = Set<String>()
  var ended = false
  var lastEvent: Date?
  private var transitions: [String: Date] = [:]
  private struct Envelope: Decodable {
    var type: String
    var timestamp: String?
    var payload: Payload
    struct Payload: Decodable {
      var type: String?
      var cwd: String?
      var turn_id: String?
    }
  }
  mutating func consume(_ line: Data) {
    guard ["session_meta", "task_started", "task_complete", "turn_aborted"].contains(where: { line.range(of: Data($0.utf8)) != nil }),
      let event = try? JSONDecoder().decode(Envelope.self, from: line) else { return }
    if event.type == "session_meta" { directory = event.payload.cwd; return }
    guard event.type == "event_msg", let type = event.payload.type,
      ["task_started", "task_complete", "turn_aborted"].contains(type),
      let time = UsageLogParser.date(event.timestamp) else { return }
    let turn = event.payload.turn_id ?? "legacy-turn"
    guard time >= (transitions[turn] ?? .distantPast) else { return }
    transitions[turn] = time
    if type == "task_started" { activeTurns.insert(turn) }
    else { activeTurns.remove(turn); ended = true }
    lastEvent = max(lastEvent ?? .distantPast, time)
  }
  var phase: AIRuntimePhase { !activeTurns.isEmpty ? .working : ended ? .idle : .unknown }
}

enum AIRuntimePhase: String {
  case working, idle, activeProcess, unknown
  static func process(cpu: Double) -> Self { cpu > 1 ? .activeProcess : .unknown }
  var title: String {
    switch self {
    case .working: "工作中"
    case .idle: "已结束"
    case .activeProcess: "进程活跃"
    case .unknown: "状态待确认"
    }
  }
  var explanation: String {
    switch self {
    case .working: "已记录任务开始，尚未收到完成或中断事件；包括模型回复与工具执行期间。"
    case .idle: "最近任务已完成或中断，会话仍由客户端打开。"
    case .activeProcess: "检测到 CPU 活动，暂未获得会话生命周期。"
    case .unknown: "尚未取得可核验的会话状态；低 CPU 占用不代表空闲。"
    }
  }
}

struct AIRuntimeSession: Identifiable {
  var id: String
  var provider: String
  var title: String
  var directory: String?
  var process: ProcessSample
  var phase: AIRuntimePhase
  var sharedResources = false
}

/// Open rollout files identify live client sessions; app-server processes are not conversations.
final class AISessionActivityStore: ObservableObject {
  static let shared = AISessionActivityStore()
  @Published private(set) var codexSessions: [AIRuntimeSession] = []
  private let queue = DispatchQueue(label: "studio.lele.chengguan.session-activity", qos: .utility)
  private var reading = false
  private var last = Date.distantPast
  private var files: [String: FileState] = [:]
  private struct FileState {
    var inode: UInt64 = 0
    var offset: UInt64 = 0
    var activity = CodexSessionActivity()
  }
  func refresh(agents: [AgentSample]) {
    guard !reading, Date().timeIntervalSince(last) >= 2.5 else { return }
    last = Date(); reading = true
    let processes = agents.filter { $0.name == "Codex" }.map(\.process)
    queue.async { [weak self] in
      guard let self else { return }
      let home = FileManager.default.homeDirectoryForCurrentUser
      let root = home.appendingPathComponent(".codex/sessions").resolvingSymlinksInPath().path + "/"
      let processByPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
      let openFiles: [String: Int32]
      if processes.isEmpty { openFiles = [:] }
      else {
        let output = Command.run("/usr/sbin/lsof", ["-a", "-p", processes.map { String($0.pid) }.joined(separator: ","), "-Fpn"], timeout: 2)
        openFiles = Self.openRollouts(output.text, root: root)
      }
      var result: [AIRuntimeSession] = []
      let perProcess = Dictionary(grouping: openFiles.values, by: { $0 }).mapValues(\.count)
      for (path, pid) in openFiles {
        guard let process = processByPID[pid] else { continue }
        var state = self.files[path] ?? FileState()
        self.scan(URL(fileURLWithPath: path), state: &state)
        self.files[path] = state
        let directory = state.activity.directory
        let project = directory.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0 == "/" || $0.isEmpty ? nil : $0 }
        let title = Self.title(for: path, home: home) ?? project ?? "Codex"
        result.append(AIRuntimeSession(id: path, provider: "Codex", title: title, directory: directory,
          process: process, phase: state.activity.phase, sharedResources: (perProcess[pid] ?? 0) > 1))
      }
      self.files = self.files.filter { openFiles[$0.key] != nil }
      result.sort {
        if ($0.phase == .working) != ($1.phase == .working) { return $0.phase == .working }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
      DispatchQueue.main.async { self.codexSessions = result; self.reading = false }
    }
  }
  static func openRollouts(_ output: String, root: String) -> [String: Int32] {
    var current: Int32?
    var result: [String: Int32] = [:]
    for line in output.split(separator: "\n") {
      if line.first == "p" { current = Int32(line.dropFirst()) }
      else if line.first == "n", let pid = current {
        let path = String(line.dropFirst())
        guard path.hasPrefix(root), path.hasSuffix(".jsonl"), URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") else { continue }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root) else { continue }
        result[resolved] = pid
      }
    }
    return result
  }
  private func scan(_ url: URL, state: inout FileState) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let file = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? file.close() }
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    if inode != state.inode || size < state.offset { state = FileState(inode: inode) }
    try? file.seek(toOffset: state.offset)
    var line = Data(), skipped = false, position = state.offset
    while let chunk = try? file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        if !skipped {
          line.append(chunk[start..<newline])
          if line.count < 4 * 1024 * 1024 { state.activity.consume(line) }
        }
        line.removeAll(keepingCapacity: true); skipped = false
        state.offset = position + UInt64(newline - chunk.startIndex + 1)
        start = newline + 1
      }
      if !skipped {
        line.append(chunk[start...])
        if line.count > 4 * 1024 * 1024 { line.removeAll(keepingCapacity: true); skipped = true }
      }
      position += UInt64(chunk.count)
    }
  }
  private static func title(for rollout: String, home: URL) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(home.appendingPathComponent(".codex/state_5.sqlite").path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if let db { sqlite3_close(db) }; return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 50)
    var query: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COALESCE(NULLIF(name, ''), title) FROM threads WHERE rollout_path = ? LIMIT 1", -1, &query, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(query) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(query, 1, rollout, -1, transient)
    guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_text(query, 0) else { return nil }
    let value = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : String(value.prefix(100))
  }
}
