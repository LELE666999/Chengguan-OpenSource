import SwiftUI

func nasBytes(_ value: Double?) -> String { value.map { Format.memory($0) } ?? "—" }
func nasRate(_ value: Double?) -> String { value.map { Format.networkRate($0) } ?? "—" }

struct NASSummaryCard: View {
  @ObservedObject private var nas = NASMonitor.shared
  var compact = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: compact ? 5 : 7) {
        HStack(spacing: 6) {
          Image(systemName: "server.rack").foregroundStyle(Theme.accent)
          Text("NAS").fontWeight(.semibold)
          Spacer(minLength: 3)
          Circle().fill(nas.current ? Color.green : Color.secondary).frame(width: 5, height: 5)
          Text(nas.status).font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: compact ? 11 : 12))
        if let s = nas.snapshot {
          ValueText(text: s.free.map { nasBytes($0) } ?? Format.percent(s.cpu), size: compact ? 25 : 25)
          HStack(spacing: 6) {
            Text(s.free == nil ? "CPU" : "可用")
            Spacer(minLength: 0)
            Text("CPU \(Format.percent(s.cpu))").lineLimit(1)
          }.font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
          Text(nas.state == .connecting ? "连接中…" : "连接 NAS").font(Theme.number(compact ? 20 : 23))
          Text("家里的设备，一起看").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if !compact { HistoryGraph(values: nas.cpuHistory, color: Theme.accent, ceiling: 100).frame(height: 18) }
      }.frame(maxWidth: .infinity, minHeight: compact ? 71 : 95, alignment: .leading)
        .opacity(nas.snapshot != nil && !nas.current ? 0.6 : 1)
        .padding(compact ? 10 : 14)
        .background(compact ? Theme.menuCard : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 15 : 18))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 15 : 18))
    }.buttonStyle(CareRowStyle()).help("查看 NAS 状态")
  }
}

struct NASWorkspace: View {
  @ObservedObject private var nas = NASMonitor.shared
  @ObservedObject private var legacy = LegacyNASMonitor.shared
  @AppStorage("nas.selectedDevice") private var selectedDevice = "主 NAS"
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          SettingsGlassSegments(selection: $selectedDevice, options: ["主 NAS", "DH2100+"])
          Spacer()
        }
        if selectedDevice == "DH2100+" {
          LegacyNASPanel()
        } else {
        HStack(spacing: 12) {
          Image(systemName: "server.rack").font(.system(size: 27)).foregroundStyle(Theme.accent)
          VStack(alignment: .leading, spacing: 5) {
            Text("家里的 NAS").font(.system(size: 23, weight: .semibold))
            Text(nas.snapshot.map { [$0.model, $0.firmware.isEmpty ? "" : "UGOS \($0.firmware)"].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "连接家里的绿联 NAS")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
          NASStatusBadge()
          Spacer()
          if nas.configuration.isConfigured {
            Button { nas.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(nas.busy)
            Button { nas.openConsole() } label: { Label("打开绿联", systemImage: "arrow.up.right") }
          }
          Button { nas.showConnection = true } label: { Label(nas.configuration.isConfigured ? "连接设置" : "连接 NAS", systemImage: "slider.horizontal.3") }
        }.buttonStyle(AIControlButtonStyle())
        NASContent()
        }
      }.padding(24).frame(maxWidth: 1440).frame(maxWidth: .infinity)
    }.sheet(isPresented: $nas.showConnection) { NASConnectionSheet() }
      .sheet(isPresented: $legacy.showConnection) { LegacyNASConnectionSheet() }
      .onAppear { nas.start(); legacy.start() }
  }
}

private struct NASStatusBadge: View {
  @ObservedObject private var nas = NASMonitor.shared
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(nas.current ? Color.green : nas.state == .offline ? .orange : .secondary).frame(width: 6, height: 6)
      Text(nas.status)
    }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 6)
      .background(.quaternary.opacity(0.5), in: Capsule())
  }
}

struct NASMenuPage: View {
  @ObservedObject private var nas = NASMonitor.shared
  @AppStorage("nas.selectedDevice") private var selectedDevice = "主 NAS"
  let open: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingsGlassSegments(selection: $selectedDevice, options: ["主 NAS", "DH2100+"], compact: true)
      if selectedDevice == "DH2100+" {
        LegacyNASPanel(compact: true, open: open)
      } else {
      HStack { Text(nas.snapshot?.name ?? "家里的 NAS").font(.system(size: 15, weight: .semibold)); Spacer(); NASStatusBadge() }
      NASContent(compact: true)
      Button(action: open) { Label(nas.configuration.isConfigured ? "打开 NAS 详情" : "连接 NAS", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
        .buttonStyle(AIControlButtonStyle())
      }
    }.padding(6)
  }
}

private struct NASContent: View {
  @ObservedObject private var nas = NASMonitor.shared
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 12 : 16) {
      if let error = nas.error {
        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let s = nas.snapshot {
        if !nas.current {
          Label("上次数据 · \(s.time.formatted(date: .omitted, time: .standard))", systemImage: "clock")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if compact {
          VStack(spacing: 12) {
            HStack(spacing: 12) { cpuCard(s); memoryCard(s) }
            HStack(spacing: 12) { fanCard(s, cpu: true); fanCard(s, cpu: false) }
          }
          networkCard(s)
        } else {
          HStack(spacing: 12) {
            cpuCard(s)
            memoryCard(s)
            networkCard(s)
            fanCard(s, cpu: true)
            fanCard(s, cpu: false)
          }
        }
        if !s.pools.isEmpty {
          NASMatrix(items: s.pools, columns: compact ? 2 : min(3, s.pools.count)) { pool in
            NASPoolCard(pool: pool, compact: compact)
          }
        }
        if !s.disks.isEmpty {
          NASMatrix(items: s.disks, columns: compact ? 1 : min(3, s.disks.count), spacing: compact ? 8 : 12) { disk in
            NASDiskCard(disk: disk, compact: compact)
          }
        }
        if s.fans.count > 2 {
          NASMatrix(items: Array(s.fans.dropFirst(2)), columns: compact ? 2 : 3) { fan in
            NASFanCard(name: fan.name, rpm: fan.rpm, live: nas.current, compact: compact)
          }
        }
        if !compact {
          HStack(spacing: 12) {
            trend("CPU 使用率", values: nas.cpuHistory, value: s.cpu, color: NASPalette.cpu)
            trend("内存使用率", values: nas.memoryHistory, value: s.memory, color: NASPalette.memory)
          }
        }
        if !s.suggestions.isEmpty {
          Panel(padding: compact ? 12 : 16) {
            VStack(alignment: .leading, spacing: 10) {
              Label("值得关注", systemImage: "lightbulb").font(.system(size: 12, weight: .semibold))
              ForEach(s.suggestions, id: \.self) { Text($0).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
              Button { nas.openConsole() } label: { Label("前往绿联查看", systemImage: "arrow.up.right") }
                .buttonStyle(AIControlButtonStyle(compact: true))
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if !s.unavailable.isEmpty {
          Text("暂未读取：" + s.unavailable.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .top) {
          Text("\(s.time.formatted(date: .omitted, time: .standard)) 更新")
          Spacer(minLength: 8)
          if let uptime = s.uptime { Text("运行 " + Format.duration(uptime)) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      } else {
        VStack(spacing: 14) {
          Image(systemName: "server.rack").font(.system(size: compact ? 32 : 48, weight: .light)).foregroundStyle(.secondary)
          Text(nas.state == .connecting ? "正在连接 NAS…" : "连接后，在这里查看 NAS 状态")
            .font(.system(size: compact ? 12 : 16, weight: .medium))
          Text("容量 · CPU · 温度 · 硬盘").font(.system(size: 11)).foregroundStyle(.secondary)
          if !compact { Button("连接 NAS") { nas.showConnection = true }.buttonStyle(AIControlButtonStyle(prominent: true)) }
        }.frame(maxWidth: .infinity).padding(.vertical, compact ? 24 : 90)
      }
    }
  }
  private func cpuCard(_ s: NASSnapshot) -> some View {
    metric("CPU", value: Format.percent(s.cpu), note: s.temperature.map(Format.temperature) ?? "温度未提供",
      symbol: "cpu", color: NASPalette.cpu, values: nas.cpuHistory, ceiling: 100)
  }
  private func memoryCard(_ s: NASSnapshot) -> some View {
    metric("内存", value: Format.percent(s.memory), note: s.memoryTotal.map { "\(nasBytes(s.memoryUsed)) / \(nasBytes($0))" } ?? "占用率",
      symbol: "memorychip", color: NASPalette.memory, values: nas.memoryHistory, ceiling: 100)
  }
  private func networkCard(_ s: NASSnapshot) -> some View {
    Panel(padding: compact ? 12 : 16) {
      VStack(alignment: .leading, spacing: 10) {
        Label("网络", systemImage: "arrow.down.arrow.up").font(.system(size: 12, weight: .medium))
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Image(systemName: "arrow.down").font(.system(size: 13))
          ValueText(text: nasRate(s.download), size: compact ? 23 : 26)
        }.foregroundStyle(NASPalette.network)
        HStack(spacing: 5) { Image(systemName: "arrow.up"); Text(nasRate(s.upload)) }
          .font(.system(size: 12, weight: .medium)).foregroundStyle(NASPalette.network)
        Spacer(minLength: 0)
        HistoryGraph(values: nas.downloadHistory, secondary: nas.uploadHistory, color: NASPalette.network,
          secondaryColor: NASPalette.cpu).frame(height: compact ? 22 : 28)
      }.frame(maxWidth: .infinity, minHeight: compact ? 100 : 148, alignment: .topLeading)
    }
  }
  private func fanCard(_ s: NASSnapshot, cpu: Bool) -> some View {
    let fan = s.fans.first { cpu ? $0.id.hasPrefix("cpu_fan") || $0.name.contains("CPU") : $0.id.hasPrefix("device_fan") || $0.name.contains("机箱") }
    return NASFanCard(name: cpu ? "CPU 风扇" : "机箱风扇", rpm: fan?.rpm, live: nas.current, compact: compact)
  }
  private func metric(_ name: String, value: String, note: String, symbol: String, color: Color, values: [Double], ceiling: Double?) -> some View {
    Panel(padding: compact ? 12 : 16) {
      VStack(alignment: .leading, spacing: 10) {
        Label(name, systemImage: symbol).font(.system(size: 12, weight: .medium))
        ValueText(text: value, size: compact ? 27 : 32).foregroundStyle(color)
        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        HistoryGraph(values: values, color: color, ceiling: ceiling).frame(height: compact ? 22 : 28)
      }.frame(maxWidth: .infinity, minHeight: compact ? 102 : 148, alignment: .topLeading)
    }
  }
  private func trend(_ name: String, values: [Double], value: Double?, color: Color) -> some View {
    Panel(padding: 16) {
      VStack(spacing: 12) {
        HStack { Text(name).font(.system(size: 12, weight: .medium)); Spacer(); Text(Format.percent(value)).font(Theme.number(14)).foregroundStyle(color) }
        HistoryGraph(values: values, color: color, ceiling: 100, grid: true).frame(height: 66)
        HStack { Text("较早"); Spacer(); Text("最近采样") }.font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }
}

struct NASConnectionSheet: View {
  @ObservedObject private var nas = NASMonitor.shared
  @Environment(\.dismiss) private var dismiss
  @State private var config = NASMonitor.shared.configuration
  @State private var password = ""
  @State private var otp = ""
  @State private var failure: String?
  @State private var remember = UserDefaults.standard.object(forKey: "nas.remember") as? Bool ?? true
  @State private var trust = false
  @State private var forgetting = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("连接 NAS").font(.system(size: 21, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.disabled(nas.busy) }
      VStack(alignment: .leading, spacing: 15) {
        field("地址") { TextField("http://nas.local:9999", text: $config.endpoint) }
        field("账号") { TextField("UGOS 账号", text: $config.username) }
        field("密码") { SecureField(nas.configuration.isConfigured ? "留空使用已保存密码" : "NAS 登录密码", text: $password) }
        if nas.needsOTP {
          field("验证码") { TextField("两步验证码", text: $otp) }
          Toggle("信任这台 Mac", isOn: $trust).toggleStyle(.checkbox)
        }
        Toggle("保存到本机钥匙串", isOn: $remember).toggleStyle(.checkbox)
      }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
      Text("只读取监测数据；不读取文件内容。每 10 秒同步，断线后自动重试。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if nas.configuration.isConfigured {
          Button("移除连接", role: .destructive) { forgetting = true }.disabled(nas.busy)
        }
        Spacer()
        if nas.busy { ProgressView().controlSize(.small) }
        Button(nas.needsOTP ? "验证并连接" : "连接并测试") { connect() }
          .buttonStyle(AIControlButtonStyle(prominent: true))
          .disabled(nas.busy || config.endpoint.isEmpty || config.username.isEmpty)
      }
    }.padding(26).frame(width: 480).buttonStyle(AIControlButtonStyle())
      .interactiveDismissDisabled(nas.busy)
      .onSubmit { if !nas.busy, !config.endpoint.isEmpty, !config.username.isEmpty { connect() } }
      .confirmationDialog("移除 NAS 连接？", isPresented: $forgetting) {
        Button("移除连接", role: .destructive) {
          Task { do { try await nas.forget(); dismiss() } catch { failure = error.localizedDescription } }
        }
      } message: { Text("仅移除此 Mac 保存的连接和密码。") }
  }
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); content().textFieldStyle(.roundedBorder).controlSize(.large) }
  }
  private func connect() {
    failure = nil
    Task {
      do { try await nas.connect(config, password: password, remember: remember, otp: otp, trust: trust); password = ""; otp = ""; dismiss() }
      catch { failure = error.localizedDescription }
    }
  }
}
