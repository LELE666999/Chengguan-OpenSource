import Darwin
import SwiftUI

enum ProcessAccess {
  static func reason(_ error: Int32) -> String {
    if error == EPERM || error == EACCES { return "系统权限限制" }
    return error == 0 ? "暂不可读取" : "暂不可读取（\(error)）"
  }
}

struct ProcessAccessView: View {
  let snapshot: MonitorSnapshot
  @Environment(\.colorScheme) private var scheme
  private var restricted: [ProcessSample] {
    snapshot.processes.filter { !$0.measured }.sorted { $0.name == $1.name ? $0.pid < $1.pid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("进程测量范围", systemImage: "info.circle").font(.system(size: 15, weight: .semibold))
      Text("macOS 限制了其他用户及部分系统服务的逐进程资源读取。整机统计仍包含这些进程，App 列表仅合计可读取的读数。")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 24) {
        SmallStat(title: "可测量", value: "\(snapshot.processes.filter(\.measured).count)")
        SmallStat(title: "受限或不可用", value: "\(restricted.count)")
      }
      Divider()
      HStack { Text("进程"); Spacer(); Text("PID").frame(width: 48, alignment: .trailing); Text("原因").frame(width: 108, alignment: .trailing) }
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if restricted.isEmpty {
        Text("当前进程均可测量").font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(restricted) { process in
              HStack(spacing: 10) {
                Text(process.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text(String(process.pid)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                Text(ProcessAccess.reason(process.measurementError)).foregroundStyle(.secondary).frame(width: 108, alignment: .trailing)
              }.font(.system(size: 11)).frame(height: 26)
            }
          }
        }.frame(height: 220)
      }
      Text("列表中的“—”表示读数不可用，不代表占用为零。系统音频权限与这些进程指标的访问权限分别管理。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(20).frame(width: 430).foregroundStyle(scheme == .dark ? Color.white : Color.black)
  }
}
