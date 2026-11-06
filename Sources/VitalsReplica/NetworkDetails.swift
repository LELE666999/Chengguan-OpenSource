import Combine
import CoreWLAN
import Darwin
import Foundation

struct NetworkInterfaceReading: Identifiable, Sendable {
  let id: String
  let received: UInt64, sent: UInt64, packetsIn: UInt64, packetsOut: UInt64, errorsIn: UInt64, errorsOut: UInt64, drops: UInt64
  let active: Bool
  var download: Double?, upload: Double?
}
struct WiFiReading: Sendable {
  var interface = "", ssid: String?, rssi: Int?, noise: Int?, linkMbps: Double?, channel: Int?
}
struct NetworkConnectionReading: Identifiable, Equatable, Sendable {
  let pid: Int32, name: String, proto: String, endpoint: String, state: String
  var id: String { "\(pid):\(proto):\(endpoint):\(state)" }
}
struct NetworkDetailsSnapshot: Sendable {
  var time: Date?
  var interfaces: [NetworkInterfaceReading] = []
  var wifi = WiFiReading()
  var connections: [NetworkConnectionReading] = []
  var connectionsAvailable = false
}
final class NetworkDetailsStore: ObservableObject {
  static let shared = NetworkDetailsStore()
  @Published private(set) var snapshot = NetworkDetailsSnapshot()
  @Published private(set) var loading = false
  private let queue = DispatchQueue(label: "studio.lele.network-details", qos: .utility)
  func refresh() {
    guard !loading else { return }
    loading = true
    let previous = snapshot
    queue.async {
      var result = NetworkDetailsSnapshot(time: Date())
      result.interfaces = NetworkDetailsReader.interfaces()
      if let previousTime = previous.time {
        let elapsed = Date().timeIntervalSince(previousTime)
        for index in result.interfaces.indices {
          let current = result.interfaces[index]
          guard let old = previous.interfaces.first(where: { $0.id == current.id }), elapsed > 0, elapsed < 30,
                current.received >= old.received, current.sent >= old.sent else { continue }
          result.interfaces[index].download = CounterMath.rate(current: current.received, previous: old.received, elapsed: elapsed)
          result.interfaces[index].upload = CounterMath.rate(current: current.sent, previous: old.sent, elapsed: elapsed)
        }
      }
      if let wifi = CWWiFiClient.shared().interface() {
        result.wifi = WiFiReading(interface: wifi.interfaceName ?? "", ssid: wifi.ssid(),
          rssi: wifi.powerOn() && wifi.rssiValue() != 0 ? wifi.rssiValue() : nil,
          noise: wifi.powerOn() && wifi.noiseMeasurement() != 0 ? wifi.noiseMeasurement() : nil,
          linkMbps: wifi.transmitRate() > 0 ? wifi.transmitRate() : nil, channel: wifi.wlanChannel()?.channelNumber)
      }
      let sockets = Command.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-iUDP", "-FpcfPnT"], timeout: 4)
      result.connectionsAvailable = sockets.status == 0
      if result.connectionsAvailable { result.connections = NetworkDetailsReader.connections(sockets.text) }
      DispatchQueue.main.async { self.snapshot = result; self.loading = false }
    }
  }
}
enum NetworkDetailsReader {
  static func interfaces() -> [NetworkInterfaceReading] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result: [NetworkInterfaceReading] = [], next = head
    while let pointer = next {
      defer { next = pointer.pointee.ifa_next }
      let item = pointer.pointee
      guard let address = item.ifa_addr, address.pointee.sa_family == AF_LINK, let data = item.ifa_data else { continue }
      let id = String(cString: item.ifa_name)
      guard !id.hasPrefix("lo"), item.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
      let counters = data.assumingMemoryBound(to: if_data.self).pointee
      result.append(NetworkInterfaceReading(id: id, received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes),
        packetsIn: UInt64(counters.ifi_ipackets), packetsOut: UInt64(counters.ifi_opackets), errorsIn: UInt64(counters.ifi_ierrors),
        errorsOut: UInt64(counters.ifi_oerrors), drops: UInt64(counters.ifi_iqdrops), active: item.ifa_flags & UInt32(IFF_RUNNING) != 0))
    }
    return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
  static func connections(_ text: String) -> [NetworkConnectionReading] {
    var pid: Int32 = 0, name = "", proto = "", endpoint = "", state = ""
    var result: [NetworkConnectionReading] = []
    func flush() {
      guard pid > 0, !endpoint.isEmpty, ["TCP", "UDP"].contains(proto) else { return }
      result.append(NetworkConnectionReading(pid: pid, name: name, proto: proto, endpoint: endpoint, state: state))
    }
    for line in text.split(separator: "\n") {
      guard let prefix = line.first else { continue }
      let value = String(line.dropFirst())
      switch prefix {
      case "p": flush(); endpoint = ""; proto = ""; state = ""; pid = Int32(value) ?? 0
      case "c": name = value
      case "f": flush(); endpoint = ""; state = ""; proto = ""
      case "P": proto = value
      case "n": endpoint = value
      case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
      default: break
      }
    }
    flush()
    var seen = Set<String>()
    return result.filter { seen.insert($0.id).inserted }.sorted { $0.name == $1.name ? $0.endpoint < $1.endpoint : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
