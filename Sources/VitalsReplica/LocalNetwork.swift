import AppKit
import Darwin
import SwiftUI

struct LocalIPv4Address: Identifiable, Equatable, Sendable {
  let interface: String
  let address: String
  var id: String { interface + ":" + address }
}

struct LocalNetworkSnapshot: Sendable {
  var addresses: [LocalIPv4Address] = []
  // Match `ipconfig getifaddr en0` whenever that interface has an active address.
  var primary: LocalIPv4Address? { addresses.first { $0.interface == "en0" } ?? addresses.first }
  static func read() -> Self {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return Self() }
    defer { freeifaddrs(head) }
    var found: [LocalIPv4Address] = []
    var current = head
    while let entry = current {
      defer { current = entry.pointee.ifa_next }
      let item = entry.pointee
      guard let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
            item.ifa_flags & UInt32(IFF_UP) != 0,
            item.ifa_flags & UInt32(IFF_RUNNING) != 0,
            item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
      let name = String(cString: item.ifa_name)
      guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let value = LocalIPv4Address(interface: name, address: String(cString: host))
      if !found.contains(value) { found.append(value) }
    }
    found.sort { $0.interface == $1.interface ? $0.address < $1.address : $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }
    return Self(addresses: found)
  }
}

/// Shared by the main network page and its menu panel; copies the address without a URL scheme.
struct LocalAddressView: View {
  let network: LocalNetworkSnapshot
  var compact = false
  @State private var copied: String?
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 9 : 6) {
      HStack(spacing: 6) {
        if compact { Image(systemName: "network").foregroundStyle(MonitorTab.network.color) }
        else { MetricIcon(symbol: "network", color: MonitorTab.network.color) }
        Text("局域网 IP").foregroundStyle(.secondary)
        Spacer()
        if let primary = network.primary {
          Text(primary.interface).foregroundStyle(.secondary).font(.system(size: 11, design: .monospaced))
        }
      }.font(.system(size: 12))
      if let primary = network.primary {
        addressButton(primary, size: compact ? 21 : 23)
        if compact {
          ForEach(network.addresses.filter { $0.id != primary.id }) { address in
            HStack { Text(address.interface).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary); Spacer(); addressButton(address, size: 13) }
          }
        }
        Text(copied == nil ? "点击复制地址" : "已复制").font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        Text("未连接局域网").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
        Text("连接 Wi-Fi 或以太网后自动显示").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: network.primary) { _, _ in copied = nil }
  }
  private func addressButton(_ address: LocalIPv4Address, size: CGFloat) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(address.address, forType: .string)
      copied = address.id
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == address.id { copied = nil } }
    } label: {
      HStack(spacing: 8) {
        Text(address.address).font(.system(size: size, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
        Spacer(minLength: 0)
        Image(systemName: copied == address.id ? "checkmark" : "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).help("复制 \(address.interface) 的局域网 IP：\(address.address)")
      .accessibilityLabel("复制局域网 IP \(address.address)，\(address.interface)")
  }
}
