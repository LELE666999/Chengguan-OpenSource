import SwiftUI

struct DeviceDetailsView: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var health = DeviceHealthStore.shared
  @ObservedObject private var network = NetworkDetailsStore.shared
  @Environment(\.dismiss) private var dismiss
  @State private var filter = ""
  @State private var allInterfaces = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Label("设备详情", systemImage: "macbook").font(.system(size: 18, weight: .semibold))
        Spacer()
        Picker("详情页面", selection: $model.deviceDetailsPage) {
          Text("健康").tag("健康"); Text("硬件").tag("硬件"); Text("网络").tag("网络")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
        Button("完成") { dismiss() }.buttonStyle(AIControlButtonStyle(compact: true))
      }.padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if model.deviceDetailsPage == "健康" { healthPage }
          else if model.deviceDetailsPage == "硬件" { hardwarePage }
          else { networkPage }
        }.padding(22)
      }.id(model.deviceDetailsPage)
    }.frame(width: 1000, height: 690)
      .task(id: model.deviceDetailsPage) {
        refresh()
        guard model.deviceDetailsPage == "网络" else { return }
        // A task survives two-second model updates; a recreated Timer publisher would starve.
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          network.refresh()
        }
      }
  }
  private func refresh() {
    if model.deviceDetailsPage == "健康" { health.refresh() }
    if model.deviceDetailsPage == "网络" { network.refresh() }
  }
  private var healthPage: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("系统与存储").font(.system(size: 24, weight: .semibold))
          Text(health.report.time.map { "检查于 " + $0.formatted(date: .omitted, time: .standard) } ?? "正在检查…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        if health.loading { ProgressView().controlSize(.small) }
        Button("重新检查") { health.refresh(force: true) }.buttonStyle(AIControlButtonStyle(compact: true)).disabled(health.loading)
      }
      HStack(spacing: 12) {
        statusTile("CPU", value: Format.percent(model.snapshot.cpu), detail: model.snapshot.cpu > 85 ? "负载较高" : "当前占用", color: model.snapshot.cpu > 85 ? .orange : .green)
        statusTile("内存压力", value: model.snapshot.pressureLevel < 2 ? "正常" : "升高", detail: "交换 " + Format.memory(model.snapshot.swap), color: model.snapshot.pressureLevel < 2 ? .green : .orange)
        statusTile("散热", value: model.snapshot.temperature.map(Format.temperature) ?? "—", detail: thermalState, color: ProcessInfo.processInfo.thermalState.rawValue >= 2 ? .orange : .green)
      }
      Panel {
        VStack(spacing: 0) {
          ForEach(health.report.checks) { check in
            HStack(spacing: 10) {
              Image(systemName: check.state == .good ? "checkmark.circle.fill" : check.state == .attention ? "exclamationmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(check.state == .good ? .green : check.state == .attention ? .orange : Color.secondary)
              Text(check.title).font(.system(size: 13))
              Spacer()
              Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.vertical, 10)
            if check.id != health.report.checks.last?.id { Divider().opacity(0.4) }
          }
        }
      }
      Text("硬盘健康").font(.system(size: 16, weight: .semibold))
      if health.report.disks.isEmpty {
        Text(health.loading ? "正在读取物理磁盘…" : "没有可读取的物理磁盘数据").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ForEach(health.report.disks) { disk in
        Panel {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Image(systemName: disk.internalDisk ? "internaldrive.fill" : "externaldrive.fill").foregroundStyle(MonitorTab.disk.color)
              VStack(alignment: .leading, spacing: 4) {
                Text(disk.name).font(.system(size: 14, weight: .semibold))
                Text("\(disk.id) · \(disk.transport)").font(.system(size: 11)).foregroundStyle(.secondary)
              }
              Spacer()
              Label(disk.statusText, systemImage: disk.state == .good ? "checkmark.circle.fill" : disk.state == .attention ? "exclamationmark.circle.fill" : "minus.circle")
                .font(.system(size: 12)).foregroundStyle(disk.state == .good ? .green : disk.state == .attention ? .orange : Color.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), alignment: .leading, spacing: 18) {
              SmallStat(title: "温度", value: disk.temperature.map(Format.temperature) ?? "—")
              SmallStat(title: "寿命已用 · 厂商估算", value: Format.percent(disk.wear))
              SmallStat(title: "累计读取", value: disk.readBytes.map(Format.bytes) ?? "—")
              SmallStat(title: "累计写入", value: disk.writtenBytes.map(Format.bytes) ?? "—")
              SmallStat(title: "备用空间", value: Format.percent(disk.spare))
              SmallStat(title: "通电时间", value: disk.powerHours.map { String(format: "%.0f 小时", $0) } ?? "—")
              SmallStat(title: "介质错误", value: disk.mediaErrors.map { String(format: "%.0f", $0) } ?? "—")
              SmallStat(title: "容量", value: disk.size.map(Format.bytes) ?? "—")
            }
            if disk.smart == nil { Text("部分 USB 转接器不传递 SMART 数据。").font(.system(size: 11)).foregroundStyle(.secondary) }
          }
        }
      }
    }
  }
  private var thermalState: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "正常"; case .fair: "温热"; case .serious: "温度较高"; case .critical: "温度过高"; @unknown default: "未知"
    }
  }
  private var hardwarePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text(SystemValue.chip).font(.system(size: 24, weight: .semibold)); Spacer(); Text(model.snapshot.clusterDescription).font(.system(size: 12)).foregroundStyle(.secondary) }
      Text("每核心趋势").font(.system(size: 16, weight: .semibold))
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
        ForEach(Array(model.snapshot.coreUsage.enumerated()), id: \.offset) { index, value in
          Panel(padding: 12) {
            VStack(spacing: 10) {
              HStack {
                Text("\(index < model.snapshot.coreLabels.count ? model.snapshot.coreLabels[index] : "CPU")\(index + 1)").font(.system(size: 12, weight: .medium))
                Spacer(); Text(Format.percent(value)).font(Theme.number(13))
              }
              HistoryGraph(values: model.overviewFrames.suffix(90).compactMap { index < $0.cores.count ? $0.cores[index] : nil }, color: MonitorTab.cpu.color, ceiling: 100).frame(height: 38)
            }
          }
        }
      }
      HStack { Text("传感器").font(.system(size: 16, weight: .semibold)); Spacer(); Text("最低 / 最高：本次运行").font(.system(size: 11)).foregroundStyle(.secondary) }
      Panel {
        VStack(spacing: 0) {
          HStack { Text("名称").frame(maxWidth: .infinity, alignment: .leading); Text("当前").frame(width: 110, alignment: .trailing); Text("最低").frame(width: 110, alignment: .trailing); Text("最高").frame(width: 110, alignment: .trailing) }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 10)
          ForEach(model.snapshot.sensors) { sensor in
            HStack {
              Text(sensor.name).frame(maxWidth: .infinity, alignment: .leading)
              Text(sensorText(sensor.value, sensor.unit)).frame(width: 110, alignment: .trailing)
              Text(model.sensorExtrema.values[sensor.key].map { sensorText($0.minimum, sensor.unit) } ?? "—").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
              Text(model.sensorExtrema.values[sensor.key].map { sensorText($0.maximum, sensor.unit) } ?? "—").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 8)
          }
          if model.snapshot.sensors.isEmpty { Text("系统未提供传感器读数").font(.system(size: 12)).foregroundStyle(.secondary).padding(20) }
        }
      }
    }
  }
  private func sensorText(_ value: Double, _ unit: String) -> String { unit == "°C" ? Format.temperature(value) : String(format: unit == "rpm" ? "%.0f %@" : "%.1f %@", value, unit) }
  private var networkPage: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text("网卡与连接").font(.system(size: 24, weight: .semibold)); Spacer(); if network.loading { ProgressView().controlSize(.small) }; Button("刷新") { network.refresh() }.buttonStyle(AIControlButtonStyle(compact: true)).disabled(network.loading) }
      HStack(spacing: 12) {
        statusTile("Wi-Fi 信号", value: network.snapshot.wifi.rssi.map { "\($0) dBm" } ?? "—", detail: network.snapshot.wifi.interface, color: MonitorTab.network.color)
        statusTile("协商速率", value: network.snapshot.wifi.linkMbps.map { String(format: "%.0f Mbps", $0) } ?? "—", detail: "无线链路 · 非实测网速", color: MonitorTab.network.color)
        statusTile("信道 / 噪声", value: network.snapshot.wifi.channel.map(String.init) ?? "—", detail: network.snapshot.wifi.noise.map { "\($0) dBm" } ?? "—", color: MonitorTab.network.color)
      }
      Panel {
        VStack(spacing: 12) {
          HStack {
            Text("主要网卡").font(.system(size: 13, weight: .medium)); Spacer()
            Toggle("显示全部", isOn: $allInterfaces).toggleStyle(.checkbox).font(.system(size: 11))
          }
          HStack { Text("网卡").frame(width: 90, alignment: .leading); Text("下载").frame(maxWidth: .infinity, alignment: .trailing); Text("上传").frame(maxWidth: .infinity, alignment: .trailing); Text("接收 / 发送包").frame(width: 175, alignment: .trailing); Text("错误 / 丢包").frame(width: 105, alignment: .trailing) }.font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(visibleInterfaces) { item in
            HStack {
              HStack(spacing: 5) { Circle().fill(item.active ? .green : .gray).frame(width: 5, height: 5); Text(item.id) }.frame(width: 90, alignment: .leading)
              Text(Format.networkRate(item.download)).frame(maxWidth: .infinity, alignment: .trailing)
              Text(Format.networkRate(item.upload)).frame(maxWidth: .infinity, alignment: .trailing)
              Text("\(item.packetsIn) / \(item.packetsOut)").frame(width: 175, alignment: .trailing)
              Text("\(item.errorsIn + item.errorsOut) / \(item.drops)").frame(width: 105, alignment: .trailing)
            }.font(Theme.number(12, .regular)).padding(.vertical, 5)
          }
          Text("包计数累计至网卡重置；各网卡独立显示，不重复汇总。").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      HStack {
        Text("App 连接").font(.system(size: 16, weight: .semibold)); Spacer()
        TextField("过滤应用或地址", text: $filter).textFieldStyle(.roundedBorder).frame(width: 250)
      }
      Panel {
        VStack(spacing: 0) {
          if !network.snapshot.connectionsAvailable && !network.loading { Text("当前权限下无法读取连接列表").foregroundStyle(.secondary).padding(20) }
          let connections = network.snapshot.connections.filter { filter.isEmpty || friendlyName($0).localizedCaseInsensitiveContains(filter) || $0.endpoint.localizedCaseInsensitiveContains(filter) }
          if connections.isEmpty && network.snapshot.connectionsAvailable { Text("没有匹配的连接").foregroundStyle(.secondary).padding(20) }
          ForEach(connections.prefix(150)) { item in
            HStack(spacing: 12) {
              Text(friendlyName(item)).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 165, alignment: .leading)
              VStack(alignment: .leading, spacing: 4) {
                Text(item.endpoint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(item.proto) · PID \(item.pid)").font(.system(size: 10)).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
              Text(item.state.isEmpty ? "—" : item.state).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            }.padding(.vertical, 10)
            Divider().opacity(0.4)
          }
          if connections.count > 150 { Text("显示前 150 条，共 \(connections.count) 条；可用过滤缩小范围。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12) }
        }
      }
    }
  }
  private func friendlyName(_ item: NetworkConnectionReading) -> String { model.snapshot.groups.first { $0.processes.contains { $0.pid == item.pid } }?.name ?? item.name }
  private var visibleInterfaces: [NetworkInterfaceReading] {
    let items = network.snapshot.interfaces.sorted {
      if $0.id == $1.id { return false }
      if $0.id == network.snapshot.wifi.interface { return true }
      if $1.id == network.snapshot.wifi.interface { return false }
      let left = $0.received + $0.sent, right = $1.received + $1.sent
      return left == right ? $0.id < $1.id : left > right
    }
    return allInterfaces ? items : Array(items.filter { $0.received > 0 || $0.sent > 0 || $0.id == network.snapshot.wifi.interface }.prefix(5))
  }
  private func statusTile(_ title: String, value: String, detail: String, color: Color) -> some View {
    Panel {
      VStack(alignment: .leading, spacing: 9) {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        Text(value).font(Theme.number(24)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
