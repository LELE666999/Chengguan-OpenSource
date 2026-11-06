import XCTest
@testable import VitalsReplica

final class AISessionActivityTests: XCTestCase {
  private func event(_ type: String, _ turn: String, at second: Int) -> Data {
    Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-29T04:00:\(String(format: "%02d", second))Z\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}".utf8)
  }
  func testActiveTurnStaysWorkingUntilItActuallyCompletes() {
    var state = CodexSessionActivity()
    XCTAssertEqual(state.phase, .unknown)
    state.consume(event("task_started", "a", at: 0))
    XCTAssertEqual(state.phase, .working)
    state.consume(event("token_count", "a", at: 1))
    XCTAssertEqual(state.phase, .working)
    state.consume(event("task_complete", "a", at: 2))
    XCTAssertEqual(state.phase, .idle)
    // A delayed older start must not revive a completed turn.
    state.consume(event("task_started", "a", at: 0))
    XCTAssertEqual(state.phase, .idle)
    XCTAssertEqual(AIRuntimePhase.process(cpu: 0), .unknown)
    XCTAssertEqual(AIRuntimePhase.process(cpu: 2), .activeProcess)
  }
  func testCompletingOneOverlappingTurnDoesNotEndTheOther() {
    var state = CodexSessionActivity()
    state.consume(event("task_started", "a", at: 0))
    state.consume(event("task_started", "b", at: 1))
    state.consume(event("task_complete", "a", at: 2))
    XCTAssertEqual(state.phase, .working)
    XCTAssertEqual(state.activeTurns, ["b"])
    state.consume(event("turn_aborted", "b", at: 3))
    XCTAssertEqual(state.phase, .idle)
    state.consume(event("task_started", "c", at: 4))
    XCTAssertEqual(state.phase, .working)
  }
  func testOnlyMetadataAndLifecycleEventsAreUsed() {
    var state = CodexSessionActivity()
    state.consume(Data("{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/sample/project\"}}".utf8))
    XCTAssertEqual(state.directory, "/sample/project")
    state.consume(Data("{\"type\":\"response_item\",\"timestamp\":\"2026-10-29T04:00:00Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"fake\"}}".utf8))
    state.consume(Data("invalid task_started".utf8))
    XCTAssertEqual(state.phase, .unknown)
    XCTAssertNil(state.lastEvent)
  }
  func testOpenFileInventoryAcceptsOnlyScopedRolloutsAndDeduplicatesHandles() {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/activity-tests/"
    let path = root + "2026/rollout-example.jsonl"
    let output = "p123\nn\(path)\nn\(path)\nn\(root)login.jsonl\nn/other/rollout-example.jsonl\np456\nn\(root)rollout-second.jsonl\n"
    let result = AISessionActivityStore.openRollouts(output, root: root)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[path], 123)
    XCTAssertEqual(result[root + "rollout-second.jsonl"], 456)
  }
}
