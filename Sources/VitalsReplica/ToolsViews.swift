import AppKit
import Combine
import CoreAudio
import SwiftUI

struct ProjectsView: View {
  @ObservedObject var model: MonitorModel
  @State private var expandedProjects = Set<String>()
  private var color: Color { MonitorTab.projects.color }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 9) {
        MetricIcon(symbol: "folder.fill", color: color)
        Text("项目").font(.system(size: 14, weight: .semibold))
      }
      ValueText(text: "\(model.snapshot.projects.count) 个项目正在运行", size: 49)
      if !DeveloperContext.labels(model.snapshot).isEmpty {
        Text(DeveloperContext.labels(model.snapshot).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        summary(
          "memorychip.fill", "内存",
          Format.memory(model.snapshot.projects.reduce(UInt64(0)) { $0 + $1.memory }), "")
        summary(
          "cpu.fill", "CPU",
          String(format: "%.1f%%", model.snapshot.projects.reduce(0) { $0 + $1.cpu }), "所有项目合计")
        summary(
          "square.stack.3d.up.fill", "进程",
          String(model.snapshot.projects.reduce(0) { $0 + $1.processes.count }), "服务器、监视程序、编辑器")
        summary(
          "point.3.connected.trianglepath.dotted", "开放的端口",
          String(Set(model.snapshot.projects.flatMap(\.ports)).count),
          model.snapshot.projects.flatMap(\.ports).isEmpty ? "没有在监听的端口" : "本机监听端口")
      }
      if model.snapshot.projects.isEmpty {
        EmptyState(
          symbol: "folder", title: "没有正在运行的项目",
          detail: "当开发服务器、测试运行器或编辑器在项目文件夹中工作时，它会连同内存、CPU和开放的端口一起显示在这里。")
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(model.snapshot.projects) { p in
              Panel {
                VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                  MetricIcon(symbol: "folder.fill", color: color)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.system(size: 15, weight: .semibold))
                    Text(p.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(
                      .enabled)
                    HStack {
                      ForEach(p.ports, id: \.self) { port in
                        Text(":\(String(port))").font(.system(size: 11, design: .monospaced))
                          .padding(.horizontal, 7).padding(.vertical, 3).background(
                            color.opacity(0.08), in: Capsule())
                      }
                    }
                  }
                  Spacer()
                  VStack(alignment: .trailing, spacing: 4) {
                    Text(Format.memory(p.memory)).font(Theme.number(17))
                    Text("CPU \(Format.appCPU(p.cpu)) · \(p.processes.count)个进程").font(
                      .system(size: 11)
                    ).foregroundStyle(.secondary)
                  }
                  Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p.path))
                  } label: {
                    Image(systemName: "folder")
                  }.help("在访达中显示")
                  Button("停止…", role: .destructive) { model.stopProject(p) }
                }
                ForEach(DeveloperContext.serviceNotes(model.snapshot).filter { $0.projectID == p.path }) { note in
                  Label(note.title + " · " + note.detail, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("进程与端口", isExpanded: Binding(get: { expandedProjects.contains(p.id) }, set: { if $0 { expandedProjects.insert(p.id) } else { expandedProjects.remove(p.id) } })) {
                  ForEach(p.processes) { process in
                    HStack {
                      Text(process.name); Text("PID \(process.pid)").foregroundStyle(.secondary)
                      Spacer(); Text("CPU \(Format.appCPU(process.cpu)) · \(Format.memory(process.memory))")
                    }.font(.system(size: 11)).padding(.vertical, 4)
                  }
                }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
                }

              }
            }
          }
        }
      }
    }.buttonStyle(AIControlButtonStyle()).padding(20)
  }
  private func summary(_ icon: String, _ title: String, _ value: String, _ subtitle: String)
    -> some View
  {
    Panel(padding: 14) {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 7) {
          MetricIcon(symbol: icon, color: color)
          Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Text(value).font(Theme.number(27, .bold))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 85, alignment: .top)
    }
  }
}
struct AgentsView: View {
  @ObservedObject var model: MonitorModel
  var body: some View {
    ScrollView {
      AIUsagePanel(model: model)
        .frame(maxWidth: 1100).frame(maxWidth: .infinity).padding(20)
    }
  }
}
struct AudioAppRow: Identifiable {
  let id: String, name: String, path: String?
  var playing: Bool, recording: Bool
  var objects: [AudioObjectID]
  static func collect(_ clients: [AudioClient], snapshot: MonitorSnapshot) -> [AudioAppRow] {
    var apps: [String: AudioAppRow] = [:]
    for client in clients where client.pid != ProcessInfo.processInfo.processIdentifier {
      let group = snapshot.groups.first { $0.processes.contains { $0.pid == client.pid } }
      let id = group?.id ?? "audio.\(client.pid)"
      let name =
        group?.name ?? snapshot.processes.first { $0.pid == client.pid }?.name ?? "音频进程"
      if var row = apps[id] {
        row.playing = row.playing || client.playing
        row.recording = row.recording || client.recording
        row.objects.append(client.id)
        apps[id] = row
      } else {
        apps[id] = AudioAppRow(
          id: id, name: name, path: group?.bundlePath, playing: client.playing,
          recording: client.recording, objects: [client.id])
      }
    }
    return apps.values.sorted {
      $0.playing != $1.playing ? $0.playing : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

}
struct SoundView: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var audio = Peripherals.shared
  @ObservedObject private var mixer = AppAudioMixer.shared
  @State private var out = 0.0
  @State private var mic = 0.0
  @State private var editingVolume = false
  @State private var selection: String?
  private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
  private var rows: [AudioAppRow] {
    AudioAppRow.collect(audio.clients, snapshot: model.snapshot).filter {
      model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 14) {
        devicePanel(input: false)
        devicePanel(input: true)
      }.padding(.horizontal, 20).padding(.top, 20)
      Text("\(rows.count)个App正在使用音频 · \(rows.filter(\.playing).count)个正在播放").font(.system(size: 12))
        .foregroundStyle(.secondary).padding(.horizontal, 24)
      GeometryReader { geometry in
      Table(rows, selection: $selection) {
        TableColumn("App") { row in
          HStack(spacing: 9) {
            AppIcon(path: row.path, size: 18)
            Text(row.name)
          }.foregroundStyle(row.playing ? .primary : .secondary)
        }.width(geometry.size.width * 0.33)
        TableColumn("正在播放") { row in
          HStack {
            if row.playing || row.recording {
              Image(systemName: row.recording ? "mic.fill" : "waveform")
            }
            Text(row.recording ? "正在录音" : row.playing ? "正在播放" : "无声")
          }.foregroundStyle(row.playing || row.recording ? MonitorTab.sound.color : .secondary)
        }.width(geometry.size.width * 0.18)
        TableColumn("音量") { row in
          AppVolumeControl(row: row, output: audio.output)
        }
      }.tableStyle(.inset(alternatesRowBackgrounds: true))
      }.padding(.top, 10)
      if mixer.volumes.values.contains(where: { $0 < 100 }) {
        HStack { Spacer(); Button("全部恢复为100%") { mixer.reset() }.buttonStyle(.plain) }.font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 6)
      }
      if let error = audio.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
    }.alert("App 混音", isPresented: Binding(get: { mixer.error != nil }, set: { if !$0 { mixer.error = nil } })) {
      Button("好") { mixer.error = nil }
    } message: { Text(mixer.error ?? "") }
    .onAppear {
      audio.refreshAudio()
      out = audio.outputVolume
      mic = audio.inputVolume
    }.onReceive(refresh) { _ in
      audio.refreshAudio()
      mixer.reconcile(AudioAppRow.collect(audio.clients, snapshot: model.snapshot), output: audio.output)
    }.onChange(of: audio.outputVolume) { _, v in
      if !editingVolume { out = v }
    }.onChange(of: audio.inputVolume) { _, v in if !editingVolume { mic = v } }
  }
  private func devicePanel(input: Bool) -> some View {
    Panel(padding: 14) {
      HStack(spacing: 12) {
        MetricIcon(
          symbol: input ? "mic.fill" : "speaker.wave.2.fill", color: MonitorTab.sound.color)
        VStack(alignment: .leading, spacing: 2) {
          Text(input ? "输入" : "输出").font(.system(size: 13, weight: .semibold))
          Picker(
            input ? "输入设备" : "输出设备",
            selection: Binding(
              get: { input ? audio.input : audio.output },
              set: { audio.selectDevice($0, input: input) })
          ) {
            ForEach(audio.devices.filter { input ? $0.input : $0.output }) { d in
              Text(d.name).tag(d.id)
            }
          }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 210, alignment: .leading)
        }
        Spacer(minLength: 5)
        Image(systemName: input ? "mic.fill" : "speaker.wave.2.fill").font(.system(size: 12))
          .foregroundStyle(.secondary)
        Slider(
          value: input ? $mic : $out, in: 0...100,
          onEditingChanged: { editing in
            editingVolume = editing
            if !editing { audio.setVolume(input ? mic : out, input: input) }
          }
        ).tint(MonitorTab.sound.color).disabled(
          input ? !audio.inputWritable : !audio.outputWritable)
        Text(Format.percent(input ? audio.inputVolume : audio.outputVolume)).font(Theme.number(13))
          .frame(width: 40, alignment: .trailing)
      }.frame(height: 28)
    }
  }
}
struct BluetoothView: View {
  @ObservedObject var model: MonitorModel
  @StateObject private var data = Peripherals()
  @State private var selection: String?
  private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
  private var connected: [BluetoothInfo] {
    data.bluetooth.filter {
      $0.connected
        && (model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search))
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Panel(padding: 14) {
        HStack(spacing: 12) {
          MetricIcon(symbol: "dot.radiowaves.left.and.right", color: .blue)
          VStack(alignment: .leading, spacing: 3) {
            Text(data.bluetoothLoading && data.bluetooth.isEmpty ? "正在读取设备…" : "已连接\(connected.count)个").font(.system(size: 13, weight: .semibold))
            Text("\(connected.filter { !$0.batteries.isEmpty }.count)个已报告电量 · \(data.bluetooth.filter { !$0.connected }.count)个未连接").font(
              .system(size: 11)
            ).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
          } label: {
            Label("蓝牙设置…", systemImage: "arrow.up.right")
          }
        }.frame(height: 28)
      }.padding(.horizontal, 20).padding(.top, 20)
      Table(connected, selection: $selection) {
        TableColumn("设备") { device in
          HStack(spacing: 10) {
            Image(systemName: device.symbol).foregroundStyle(Theme.accent)
            Text(device.name)
          }
        }.width(min: 250, ideal: 550, max: 900)
        TableColumn("种类") { device in Text(device.kind).foregroundStyle(.secondary) }.width(
          min: 150, ideal: 330, max: 500)
        TableColumn("电池") { device in BluetoothBatteryLabel(batteries: device.batteries).frame(maxWidth: .infinity, alignment: .trailing) }.width(min: 160, ideal: 260, max: 400)
      }.tableStyle(.inset(alternatesRowBackgrounds: true))
      if let error = data.bluetoothError { Text(error).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 20) }
    }.onAppear { data.refreshBluetooth() }.onReceive(refresh) { _ in data.refreshBluetooth() }
  }
}
