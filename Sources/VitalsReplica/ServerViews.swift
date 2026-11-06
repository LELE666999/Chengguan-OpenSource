import AppKit
import SwiftUI

func serverBytes(_ value: Double?) -> String { value.map { Format.memory($0) } ?? "—" }

struct ServerSummaryCard: View {
  @ObservedObject private var server = ServerMonitor.shared
  var compact = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 5) {
          Label("服务器", systemImage: "cloud").foregroundStyle(Theme.accent).fontWeight(.semibold)
          Spacer(minLength: 0)
          Text(server.stateLabel).font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 11))
        Text(server.snapshot?.transferRemaining.map { serverBytes($0) } ?? "连接搬瓦工").font(Theme.number(22)).lineLimit(1).minimumScaleFactor(0.8)
        Text(server.snapshot == nil ? server.profile?.name ?? "云端设备" : "本月剩余流量").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        if !compact { Color.clear.frame(height: 18) }
      }.frame(maxWidth: .infinity, minHeight: compact ? 71 : 95, alignment: .leading).padding(compact ? 10 : 14)
        .background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 15 : 18))
    }.buttonStyle(CareRowStyle()).help("查看搬瓦工服务器")
  }
}

struct ServerConnectionView: View {
  @ObservedObject private var server = ServerMonitor.shared
  @Environment(\.dismiss) private var dismiss
  @State private var name = "搬瓦工"
  @State private var veid = ""
  @State private var host = ""
  @State private var key = ""
  @State private var busy = false
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack { Text("连接服务器").font(.system(size: 23, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.buttonStyle(AIControlButtonStyle()).disabled(busy) }
      VStack(alignment: .leading, spacing: 14) {
        field("名称") { TextField("搬瓦工", text: $name) }
        field("VEID") { TextField("KiwiVM 中的 VPS ID", text: $veid) }
        field("公网地址") { TextField("可选", text: $host) }
        field("API Key") { SecureField("已保存则留空", text: $key) }
      }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
      HStack(alignment: .top) {
        Text("KiwiVM → Extras → API 获取 Key，仅保存在本机钥匙串。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Spacer()
        if let p = profile.panelURL { Link("打开 KiwiVM ↗", destination: p).font(.system(size: 11)) }
      }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if server.profile != nil {
          Button("移除连接") {
            busy = true; error = nil
            task = Task { do { try await server.disconnect(); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
          }.buttonStyle(AIControlButtonStyle()).foregroundStyle(.red).disabled(busy)
        }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(busy ? "正在连接…" : "保存并测试") {
          busy = true; error = nil
          task = Task {
            do { try await server.connect(profile, key: key); key = ""; dismiss() }
            catch { if !Task.isCancelled { self.error = (error as? ServerError)?.localizedDescription ?? ServerError.transport.localizedDescription } }
            busy = false
          }
        }.buttonStyle(AIControlButtonStyle(prominent: true)).disabled(busy || !profile.valid)
      }
    }.padding(26).frame(width: 490).interactiveDismissDisabled(busy)
      .onAppear { if let p = server.profile { name = p.name; veid = p.veid; host = p.host } }
      .onDisappear { task?.cancel(); key = "" }
  }
  private var profile: ServerProfile { .init(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "搬瓦工" : name, veid: veid.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines)) }
  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 12)).foregroundStyle(.secondary); content().textFieldStyle(.roundedBorder).font(.system(size: 13)) }
  }
}
