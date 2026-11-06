import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

/// Only values actually returned by the older system are presented.
struct LegacyNASReadings: Sendable {
  var cpu: Double?, temperature: Double?, memory: Double?, memoryUsed: Double?, memoryTotal: Double?
  var download: Double?, upload: Double?, fanPercent: Double?
  var disks: [NASDisk] = []
  var hasMetrics: Bool { cpu != nil || temperature != nil || memory != nil || download != nil || upload != nil || fanPercent != nil || !disks.isEmpty }
  static func parse(basic: NASValue, cpu: NASValue, network: NASValue, disks: NASValue, inventory: NASValue = .null) -> Self {
    let memory = basic["memory"]
    let temperatures = disks["harddisk"].list + disks["ssd"].list
    let inventoryDisks = inventory["disks"].list
    let drives: [NASDisk]
    if !inventoryDisks.isEmpty {
      drives = inventoryDisks.enumerated().map { index, item in
        let interface = item["interface"].text
        let matching = temperatures.first { $0["interface"].text != nil && $0["interface"].text == interface }
        let number = interface.flatMap { name -> String? in
          let digits = String(name.reversed().prefix(while: { $0.isNumber }).reversed())
          return digits.isEmpty ? nil : digits
        } ?? String(index + 1)
        let label = interface?.lowercased().contains("nvme") == true ? "M.2 硬盘" : "硬盘"
        return NASDisk(id: "legacy-\(interface ?? String(index))", name: "\(label) \(number)",
          model: item["model"].text ?? "", size: item["size"].nonnegative,
          temperature: matching?["disk_temp"].temperature, status: "")
      }
    } else {
      drives = temperatures.enumerated().map { index, item in
        NASDisk(id: "legacy-disk-\(index)", name: "硬盘 \(item["disk_place"].integerText ?? String(index + 1))",
          model: "", size: nil, temperature: item["disk_temp"].temperature, status: "")
      }
    }
    return Self(cpu: cpu["cpu"]["cpu_used"].percent, temperature: basic["cpu"]["cpu_temp"].temperature,
      memory: memory["mem_used"].percent, memoryUsed: memory["mem_used_size"].nonnegative,
      memoryTotal: memory["mem_total"].nonnegative, download: network["network"]["download_speed"].nonnegative,
      upload: network["network"]["upload_speed"].nonnegative, fanPercent: basic["fan"]["fan_speed"].percent, disks: drives)
  }
}

/// DH2100's older API is isolated from UGOS Pro: a failed login must never alter the other NAS.
actor LegacyNASClient {
  let config: NASConfiguration
  private let session: URLSession
  private var token = ""
  init(config: NASConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
    self.config = config
    let options = sessionConfiguration
    options.timeoutIntervalForRequest = 8; options.timeoutIntervalForResource = 15
    options.urlCache = nil
    session = URLSession(configuration: options, delegate: AINoRedirectDelegate(), delegateQueue: nil)
  }
  private func request(_ path: String, body: [String: Any]? = nil) async throws -> NASValue {
    let base = try NASConfiguration.baseURL(config.endpoint)
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw NASError.message("地址无效") }
    components.path = path
    if !token.isEmpty { components.queryItems = [URLQueryItem(name: "api_token", value: token)] }
    guard let url = components.url else { throw NASError.message("地址无效") }
    var request = URLRequest(url: url)
    if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "Api-Token") }
    if let body {
      request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) }
    catch { throw NASError.connection("无法连接旧版 NAS，请检查局域网和地址。") }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000,
          let value = try? JSONDecoder().decode(NASValue.self, from: data) else { throw NASError.message("旧版 NAS 接口未返回有效数据。") }
    guard value["code"].number == 200 else {
      let code = value["code"].integerText ?? "未知"
      if code == "8066" { throw NASError.message("本地账号或密码未通过（8066）。请核对绿联网络服务里的账号密码。") }
      throw NASError.message("旧版 NAS 请求未通过（\(code)）；请核对本地账号和固件。")
    }
    return value["data"]
  }
  func identity() async throws -> NASValue { try await request("/v1/device/info") }
  func login(_ password: String) async throws {
    func md5(_ value: String) -> String { Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    let data = try await request("/v1/user/offline/login", body: ["platform": 1, "clientType": "Mac", "loginmethod": 7,
      "offline_username": config.username, "offline_password": md5(md5(password))])
    guard let token = data["api_token"].text, !token.isEmpty else { throw NASError.message("旧版 NAS 没有返回登录凭据。") }
    self.token = token
  }
  func readings() async -> LegacyNASReadings {
    // These are the same status endpoints used by the older device's task manager.
    async let basic = try? request("/v1/system/details/status")
    async let cpu = try? request("/v1/system/details/cpu/status")
    async let network = try? request("/v1/system/details/network/status")
    async let disks = try? request("/v1/system/details/harddisk_temp/status")
    async let inventory = try? request("/v2/storage/disk/list")
    return await LegacyNASReadings.parse(basic: basic ?? .null, cpu: cpu ?? .null, network: network ?? .null, disks: disks ?? .null, inventory: inventory ?? .null)
  }
  func storage() async throws -> [NASPool] {
    let result = try await request("/v2/storage/list")
    return result["storages"].list.enumerated().compactMap { index, item in
      guard let size = item["size"].nonnegative, size > 0, let used = item["used"].nonnegative, used <= size else { return nil }
      return NASPool(id: "legacy-\(index)", name: item["label"].text ?? "存储空间 \(index + 1)",
        total: size, used: used, free: size - used, filesystem: item["filesystem"].text ?? "")
    }
  }
}

@MainActor final class LegacyNASMonitor: ObservableObject {
  static let shared = LegacyNASMonitor()
  @Published private(set) var configuration: NASConfiguration
  @Published private(set) var model = ""
  @Published private(set) var firmware = ""
  @Published private(set) var deviceName = ""
  @Published private(set) var online = false
  @Published private(set) var busy = false
  @Published private(set) var authenticated = false
  @Published private(set) var error: String?
  @Published private(set) var storage: [NASPool]?
  @Published private(set) var readings: LegacyNASReadings?
  @Published var showConnection = false
  private let defaults: UserDefaults
  private let key = "nas.legacy.configuration.v1"
  private var client: LegacyNASClient?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var started = false
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    configuration = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NASConfiguration.self, from: $0) } ?? NASConfiguration()
  }
  func start() {
    guard !started else { return }; started = true
    guard configuration.isConfigured else { return }
    let api = LegacyNASClient(config: configuration); client = api
    let id = generation
    task = Task { [weak self] in
      guard let self else { return }
      do { let secret = try await NASVault.read(configuration); try await api.login(secret); authenticated = true }
      catch { authenticated = false }
      await loop(api, id: id)
    }
  }
  func stop() { generation = UUID(); task?.cancel(); task = nil; client = nil; started = false }
  func connect(_ config: NASConfiguration, password: String, remember: Bool) async throws {
    guard !busy else { return }; busy = true; defer { busy = false }
    var candidate = config
    candidate.endpoint = try NASConfiguration.baseURL(candidate.endpoint).absoluteString
    candidate.username = candidate.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.username.isEmpty, !password.isEmpty else { throw NASError.message("请输入本地账号和密码。") }
    let api = LegacyNASClient(config: candidate)
    let identity = try await api.identity()
    guard (identity["model"].text ?? "").uppercased().hasPrefix("DH2100") else { throw NASError.message("此设备不是 DH2100 系列。") }
    try await api.login(password)
    let sample = try? await api.storage()
    let readings = await api.readings()
    if remember { try await NASVault.save(password, config: candidate) }
    defaults.set(try JSONEncoder().encode(candidate), forKey: key)
    stop(); configuration = candidate; client = api; authenticated = true; storage = sample; self.readings = readings; accept(identity); started = true
    let id = generation
    task = Task { [weak self] in await self?.loop(api, id: id) }
  }
  private func accept(_ identity: NASValue) {
    model = identity["model"].text ?? "DH2100+"
    deviceName = identity["name"].text ?? model
    firmware = identity["softversion"].text ?? ""
    online = true; error = nil
  }
  private func loop(_ api: LegacyNASClient, id: UUID) async {
    while !Task.isCancelled && generation == id {
      do {
        let identity = try await api.identity()
        guard generation == id, !Task.isCancelled else { return }
        accept(identity)
        if authenticated {
          let nextStorage = try? await api.storage()
          let nextReadings = await api.readings()
          guard generation == id, !Task.isCancelled else { return }
          storage = nextStorage; readings = nextReadings
        }
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        online = false; self.error = error.localizedDescription
      }
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
    }
  }
  func forget() async throws {
    let old = configuration
    stop(); try await NASVault.remove(old)
    defaults.removeObject(forKey: key); configuration = NASConfiguration()
    model = ""; firmware = ""; deviceName = ""; online = false; authenticated = false; storage = nil; readings = nil; error = nil
  }
  func openConsole() { if let url = try? NASConfiguration.baseURL(configuration.endpoint) { NSWorkspace.shared.open(url) } }
}

struct LegacyNASPanel: View {
  @ObservedObject private var nas = LegacyNASMonitor.shared
  var compact = false
  var open: (() -> Void)? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "server.rack").font(.system(size: compact ? 20 : 27)).foregroundStyle(Theme.accent)
        VStack(alignment: .leading, spacing: 4) {
          Text(nas.deviceName.isEmpty ? "DH2100+" : nas.deviceName).font(.system(size: compact ? 15 : 23, weight: .semibold))
          Text([nas.model.isEmpty ? "旧版绿联 NAS" : nas.model, nas.firmware].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 5) {
          Circle().fill(nas.online ? .green : Color.secondary).frame(width: 6, height: 6)
          Text(nas.online ? "在线" : nas.configuration.isConfigured ? "离线" : "未连接")
        }.font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if nas.configuration.isConfigured {
        if !nas.authenticated {
          Text("请重新登录本地账号，以读取运行状态。")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
          if let readings = nas.readings, readings.hasMetrics {
            HStack(spacing: 10) {
              metric("CPU", symbol: "cpu", value: Format.percent(readings.cpu), detail: readings.temperature.map(Format.temperature) ?? "温度未提供", color: NASPalette.cpu)
              metric("内存", symbol: "memorychip", value: Format.percent(readings.memory), detail: readings.memoryTotal.map { "\(nasBytes(readings.memoryUsed)) / \(nasBytes($0))" } ?? "容量未提供", color: NASPalette.memory)
            }
            HStack(spacing: 10) {
              metric("网络", symbol: "arrow.down.arrow.up", value: "↓ " + nasRate(readings.download), detail: "↑ " + nasRate(readings.upload), color: NASPalette.network)
              metric("风扇", symbol: "fanblades.fill", value: Format.percent(readings.fanPercent), detail: readings.fanPercent == 0 ? "绿联上报 0%，转速未知" : "绿联上报比例", color: NASPalette.fan)
            }
            if !readings.disks.isEmpty {
              NASMatrix(items: readings.disks, columns: compact ? 1 : 2) { disk in NASDiskCard(disk: disk, compact: compact) }
            }
          } else {
            Text("运行状态暂不可用").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          if let pools = nas.storage, !pools.isEmpty {
            NASMatrix(items: pools, columns: compact ? 1 : min(2, pools.count)) { pool in
              NASPoolCard(pool: pool, compact: compact)
            }
          } else { Panel(padding: 14) {
            HStack {
              Label("存储信息", systemImage: "externaldrive").font(.system(size: 12, weight: .medium))
              Spacer()
              Text("暂不可读").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
          } }
        }
        if let error = nas.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        HStack {
          Button { nas.openConsole() } label: { Label("打开绿联", systemImage: "arrow.up.right") }
          if compact { Button("详情") { open?() } }
          else { Button("连接设置") { nas.showConnection = true } }
        }.buttonStyle(AIControlButtonStyle(compact: compact))
      } else {
        Text("将旧版绿联 NAS 加入这里，和现有设备分开查看。")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Button("连接 DH2100+") { if compact { open?() } else { nas.showConnection = true } }
          .buttonStyle(AIControlButtonStyle(prominent: true, compact: compact))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func metric(_ title: String, symbol: String, value: String, detail: String, color: Color) -> some View {
    Panel(padding: compact ? 12 : 16) {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
        Text(value).font(Theme.number(compact ? 21 : 27, .bold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
      }.frame(maxWidth: .infinity, minHeight: compact ? 75 : 90, alignment: .topLeading)
    }
  }
}

struct LegacyNASConnectionSheet: View {
  @ObservedObject private var nas = LegacyNASMonitor.shared
  @Environment(\.dismiss) private var dismiss
  @State private var config = LegacyNASMonitor.shared.configuration
  @State private var password = ""
  @State private var remember = true
  @State private var failure: String?
  @State private var confirmingRemoval = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Text("连接 DH2100+").font(.system(size: 21, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.disabled(nas.busy) }
      VStack(alignment: .leading, spacing: 15) {
        field("地址") { TextField("http://nas.local:9999", text: $config.endpoint) }
        field("本地账号") { TextField("绿联离线账号", text: $config.username) }
        field("密码") { SecureField("本地账号密码", text: $password) }
        Toggle("保存到本机钥匙串", isOn: $remember).toggleStyle(.checkbox)
      }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
      Text("使用绿联设置的本地账号连接，只读取设备运行状态和存储信息。")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if nas.configuration.isConfigured { Button("移除连接", role: .destructive) { confirmingRemoval = true }.disabled(nas.busy) }
        Spacer()
        if nas.busy { ProgressView().controlSize(.small) }
        Button("连接并测试") { connect() }.buttonStyle(AIControlButtonStyle(prominent: true))
          .disabled(nas.busy || config.endpoint.isEmpty || config.username.isEmpty || password.isEmpty)
      }
    }.padding(26).frame(width: 480).buttonStyle(AIControlButtonStyle())
      .interactiveDismissDisabled(nas.busy)
      .confirmationDialog("移除 DH2100+ 连接？", isPresented: $confirmingRemoval) {
        Button("移除连接", role: .destructive) { Task { do { try await nas.forget(); dismiss() } catch { failure = error.localizedDescription } } }
      } message: { Text("只移除这台 Mac 保存的连接，不影响另一台 NAS。") }
  }
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); content().textFieldStyle(.roundedBorder).controlSize(.large) }
  }
  private func connect() {
    failure = nil
    Task {
      do { try await nas.connect(config, password: password, remember: remember); password = ""; dismiss() }
      catch { failure = error.localizedDescription }
    }
  }
}
