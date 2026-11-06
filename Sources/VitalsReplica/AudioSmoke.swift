import AVFoundation
import CoreAudio
import Foundation

/// Opt-in command-line diagnostics. The signal stays in memory; no audio is saved.
enum AudioSmoke {
  static func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
  static func tone() {
    let engine = AVAudioEngine()
    let format = engine.outputNode.inputFormat(forBus: 0)
    var phase = 0.0
    let source = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(list)
      for frame in 0..<Int(frames) {
        let sample = Float(sin(phase) * 0.0001)
        phase += 2 * .pi * 997 / format.sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi }
        for buffer in buffers {
          guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
          for channel in 0..<Int(buffer.mNumberChannels) { data[frame * Int(buffer.mNumberChannels) + channel] = sample }
        }
      }
      return noErr
    }
    engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
    do {
      try engine.start()
      let parent = getppid(), deadline = Date().addingTimeInterval(600)
      while Date() < deadline && getppid() == parent { wait(0.5) }
      engine.stop()
    } catch { fputs("Tone start failed: \(error)\n", stderr) }
  }
  static func run(reportURL: URL) {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--audio-tone"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    var output: [String: Any] = ["passed": false, "signal_amplitude": 0.0001, "audio_saved": false]
    do {
      try child.run()
      defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
      let audio = Peripherals()
      let deadline = Date().addingTimeInterval(12)
      repeat { wait(0.25); audio.refreshAudio() } while !audio.clients.contains(where: { $0.pid == child.processIdentifier && $0.playing }) && Date() < deadline
      let objects = audio.clients.filter { $0.pid == child.processIdentifier }.map(\.id)
      let originalOutput = audio.output, originalInput = audio.input
      let originalOutputVolume = audio.outputVolume, originalInputVolume = audio.inputVolume
      let route = try ProcessAudioGain(objects: objects, output: originalOutput, volume: 25)
      defer { route.stop() }
      // Leave time for an OS permission prompt. Zero samples never count as success.
      let permissionDeadline = Date().addingTimeInterval(90)
      repeat { wait(0.25) } while (route.diagnostics["input_rms"] as? Float ?? 0) < 0.000001 && Date() < permissionDeadline
      let quarter = route.diagnostics
      route.setVolume(0); wait(0.3); let muted = route.diagnostics
      route.setVolume(100); wait(0.3); let restored = route.diagnostics
      route.stop(); wait(0.3); audio.refreshAudio()
      let input = quarter["input_rms"] as? Float ?? 0
      let quarterRatio = input > 0 ? (quarter["output_rms"] as? Float ?? 0) / input : 0
      let restoredInput = restored["input_rms"] as? Float ?? 0
      let restoredRatio = restoredInput > 0 ? (restored["output_rms"] as? Float ?? 0) / restoredInput : 0
      let unchanged = originalOutput == audio.output && originalInput == audio.input && abs(originalOutputVolume - audio.outputVolume) < 0.01 && abs(originalInputVolume - audio.inputVolume) < 0.01
      output["quarter"] = quarter; output["muted"] = muted; output["restored"] = restored
      output["quarter_ratio"] = quarterRatio; output["restored_ratio"] = restoredRatio
      output["system_devices_and_volumes_unchanged"] = unchanged
      output["passed"] = input > 0.000001 && abs(quarterRatio - 0.25) < 0.01 && abs(restoredRatio - 1) < 0.01 && (muted["output_rms"] as? Float ?? 1) < 0.00000001 && unchanged
    } catch { output["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: reportURL, options: .atomic) }
  }
}
