import CoreAudio
import Foundation
import MonitorBridge
import XCTest
@testable import VitalsReplica

final class UsageAudioTests: XCTestCase {
  func testCodexRepeatedCountersAndForksAreNotDoubleCounted() throws {
    var state = UsageFile()
    func event(_ timestamp: String, _ input: Int, _ output: Int, _ used: Int) -> Data {
      Data("""
      {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":\(output),"cached_input_tokens":50}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(used),"window_minutes":300,"resets_at":1792670000}}}}
      """.utf8)
    }
    UsageLogParser.consume(event("2026-10-22T08:00:00Z", 100, 20, 10), provider: "Codex", state: &state)
    UsageLogParser.consume(event("2026-10-22T08:01:00Z", 200, 30, 11), provider: "Codex", state: &state)
    UsageLogParser.consume(event("2026-10-22T08:02:00Z", 200, 30, 12), provider: "Codex", state: &state)
    XCTAssertEqual(state.entries.count, 2)
    XCTAssertEqual(state.entries.reduce(0) { $0 + $1.total }, 230)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let summary = UsageLogParser.summarize([state, state], now: try XCTUnwrap(UsageLogParser.date("2026-10-22T10:00:00Z")), calendar: calendar)
    XCTAssertEqual(summary.first?.today, 230)
    XCTAssertEqual(summary.first?.limits.first?.windows.first?.used, 12)
    XCTAssertEqual(summary.first?.cached, 50)
  }
  func testClaudeStreamingUsageReplacesEarlierMessageAndDeduplicatesFork() throws {
    var state = UsageFile()
    func entry(_ output: Int) -> Data {
      Data("""
      {"type":"assistant","timestamp":"2026-10-22T08:00:00Z","requestId":"req-1","message":{"id":"message-1","usage":{"input_tokens":10,"output_tokens":\(output),"cache_creation_input_tokens":20,"cache_read_input_tokens":100}}}
      """.utf8)
    }
    UsageLogParser.consume(entry(1), provider: "Claude Code", state: &state)
    UsageLogParser.consume(entry(20), provider: "Claude Code", state: &state)
    XCTAssertEqual(state.entries.count, 1)
    XCTAssertEqual(state.entries.first?.total, 150)
    let summary = UsageLogParser.summarize([state, state], now: try XCTUnwrap(UsageLogParser.date("2026-10-22T10:00:00Z")))
    XCTAssertEqual(summary.first?.today, 150)
    XCTAssertTrue(summary.first?.limits.isEmpty == true)
  }
  func testHistogramKeepsEntireTimeWindowAndPeaks() {
    XCTAssertEqual(HistoryGraph.buckets([9, 1, 2, 3, 4, 8], count: 3), [9, 3, 8])
    XCTAssertEqual(HistoryGraph.buckets([1, 2], count: 5), [1, 2])
  }
  func testGainRoutesStereoToPlanarAndSkipsHardwareInput() throws {
    let gain = try XCTUnwrap(vr_gain_create(0.5, 48_000))
    defer { vr_gain_destroy(gain) }
    let input = AudioBufferList.allocate(maximumBuffers: 2)
    let output = AudioBufferList.allocate(maximumBuffers: 2)
    defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
    var hardware: [Float] = [1, 1, 1, 1]
    var stereo: [Float] = [0.4, -0.8, 0.6, 0.2]
    var left: [Float] = [9, 9, 9], right: [Float] = [9, 9, 9]
    hardware.withUnsafeMutableBytes { hw in stereo.withUnsafeMutableBytes { src in
      left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(hw.count), mData: hw.baseAddress)
        input[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress)
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
        output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
        vr_gain_render(gain, input.unsafeMutablePointer, output.unsafeMutablePointer, 1)
      } }
    } }
    XCTAssertEqual(left[0], 0.2, accuracy: 0.00001); XCTAssertEqual(left[1], 0.3, accuracy: 0.00001)
    XCTAssertEqual(right[0], -0.4, accuracy: 0.00001); XCTAssertEqual(right[1], 0.1, accuracy: 0.00001)
    XCTAssertEqual(left[2], 0); XCTAssertEqual(right[2], 0)
    XCTAssertEqual(vr_gain_callbacks(gain), 1)
  }
  func testGainRampsToSilenceWithoutClicksOrNonFiniteSamples() throws {
    let gain = try XCTUnwrap(vr_gain_create(1, 1000))
    defer { vr_gain_destroy(gain) }
    vr_gain_set(gain, 0)
    let input = AudioBufferList.allocate(maximumBuffers: 1), output = AudioBufferList.allocate(maximumBuffers: 1)
    defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
    var samples = [Float](repeating: 0.5, count: 100), rendered = [Float](repeating: 9, count: 100)
    samples[0] = .nan
    samples.withUnsafeMutableBytes { source in rendered.withUnsafeMutableBytes { destination in
      input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(source.count), mData: source.baseAddress)
      output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress)
      vr_gain_render(gain, input.unsafeMutablePointer, output.unsafeMutablePointer, 0)
    } }
    XCTAssertEqual(rendered[0], 0)
    XCTAssertEqual(rendered[1], 0.475, accuracy: 0.00001)
    XCTAssertTrue(rendered.allSatisfy(\.isFinite))
    XCTAssertTrue(rendered.suffix(40).allSatisfy { abs($0) < 0.00001 })
  }
}
