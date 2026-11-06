import AppKit
import SwiftUI

struct CodexResetSection: View {
  private let tint = AIQuotaPresentation.color("Codex")
  @ObservedObject private var store = CodexResetStore.shared
  @AppStorage("codexResetEnabled") private var enabled = true
  @State private var details = false
  private var event: CodexResetEvent? { store.events.first }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Divider().opacity(0.5)
      HStack(spacing: 7) {
        Image(systemName: "gift").foregroundStyle(tint)
        Text("特别重置").font(.system(size: 12, weight: .medium))
        Spacer()
        if store.loading { ProgressView().controlSize(.mini) }
        Toggle("Codex 特别重置提醒", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(tint)
      }
      if enabled {
        if let event {
          Button { details.toggle() } label: {
            HStack(spacing: 8) {
              Text(event.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
              Spacer(minLength: 4)
              Text((event.scheduled ?? event.time).formatted(.dateTime.month().day()) + (store.stale ? " · 上次" : ""))
                .font(.system(size: 10)).foregroundStyle(.secondary)
              Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(9).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(RoundedRectangle(cornerRadius: 10))
          }.buttonStyle(StorageActionButtonStyle(tint: tint)).accessibilityLabel("Codex 重置公告详情")
            .popover(isPresented: $details) { announcement(event) }
        } else {
          Text(store.loading ? "正在检查公开预告…" : "暂无可核验的新预告")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }.onAppear { store.refresh() }
      .onChange(of: enabled) { _, value in if value { store.refresh(force: true) } else { store.disabled() } }
  }
  private func timing(_ event: CodexResetEvent) -> String {
    let date = event.scheduled ?? event.time
    let value = date.formatted(.dateTime.month().day().hour().minute())
    if event.kind == .scheduled || event.kind == .bankedScheduled {
      return event.scheduled == nil ? "时间待公布 · 查看原帖" : value + (date > Date() ? " · 预计，按本地时区" : " · 等待完成确认")
    }
    return value + " · " + (store.stale ? "上次记录" : event.kind == .watch ? "尚未确认" : "公开信息，非个人到账")
  }
  private func announcement(_ event: CodexResetEvent) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(event.title).font(.system(size: 16, weight: .semibold))
      Text(timing(event)).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(event.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
      if let analysis = store.analysis[event.fingerprint] {
        Label(analysis.summary, systemImage: "sparkles").font(.system(size: 12))
      }
      ScrollView { Text(event.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
      HStack {
        Link("Tibo 原帖 ↗", destination: event.source)
        Spacer()
        Link("Codex Resets ↗", destination: CodexResetParser.attribution)
      }.font(.system(size: 11))
      if let card = store.events.first(where: { $0.kind == .banked && $0.id != event.id }) {
        Link("重置卡公告 · " + card.time.formatted(.dateTime.month().day()) + " ↗", destination: card.source)
          .font(.system(size: 11))
      }
      HStack {
        Text(store.stale && store.snapshot != nil ? "上次记录" : "每 15 分钟检查")
        Spacer()
        Button { store.refresh(force: true) } label: {
          Image(systemName: "arrow.clockwise").frame(width: 25, height: 23).contentShape(Rectangle())
        }.buttonStyle(StorageActionButtonStyle(tint: tint)).disabled(store.loading).help("刷新 Codex 公开预告").accessibilityLabel("刷新 Codex 重置公告")
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      if let error = store.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
    }.padding(20).frame(width: 350).tint(tint)
  }
}
