import Combine
import Foundation
import SwiftUI

enum AISubscriptionDateKind: String, Codable, CaseIterable, Identifiable {
  case expires, renews, trialEnds, activeUntil
  var id: String { rawValue }
  var title: String {
    switch self {
    case .expires: return "订阅到期"
    case .renews: return "下次续费"
    case .trialEnds: return "试用到期"
    case .activeUntil: return "订阅有效至"
    }
  }
}

/// Subscription dates are independent of quota resets and cache freshness.
/// A manually entered date is never advanced or treated as a confirmed renewal.
struct AISubscriptionDate: Codable, Equatable {
  var date: Date
  var kind: AISubscriptionDateKind
  var source: String
  var dateOnly = false

  func daysRemaining(at now: Date = Date(), calendar: Calendar = .current) -> Int {
    calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
  }
  func countdown(at now: Date = Date(), calendar: Calendar = .current) -> String {
    let days = daysRemaining(at: now, calendar: calendar)
    if days < 0 || (!dateOnly && date < now) { return kind == .activeUntil ? "记录待刷新" : "日期已过" }
    return days == 0 ? "今天" : "还有 \(days) 天"
  }
  var formatted: String {
    dateOnly ? date.formatted(.dateTime.year().month().day()) : date.formatted(.dateTime.year().month().day().hour().minute())
  }
}

final class AISubscriptionStore: ObservableObject {
  static let shared = AISubscriptionStore()
  @Published private(set) var dates: [String: AISubscriptionDate]
  private let defaults: UserDefaults
  private let key = "aiSubscriptionDates.v1"
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    dates = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: AISubscriptionDate].self, from: $0) } ?? [:]
  }
  func value(for provider: ProviderUsage) -> AISubscriptionDate? { dates[provider.id] ?? provider.subscription }
  func save(provider: String, date: Date, kind: AISubscriptionDateKind) {
    guard date.timeIntervalSince1970.isFinite else { return }
    dates[provider] = AISubscriptionDate(date: date, kind: kind, source: "手动记录", dateOnly: true)
    persist()
  }
  func remove(provider: String) { dates.removeValue(forKey: provider); persist() }
  private func persist() {
    if let data = try? JSONEncoder().encode(dates) { defaults.set(data, forKey: key) }
  }
}

struct AISubscriptionRow: View {
  var provider: ProviderUsage
  @ObservedObject private var subscriptions = AISubscriptionStore.shared
  @State private var editing = false
  @State private var date = Date()
  @State private var kind = AISubscriptionDateKind.expires
  private var value: AISubscriptionDate? { subscriptions.value(for: provider) }
  var body: some View {
    Button {
      date = value?.date ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
      kind = value?.kind ?? .expires
      editing = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "calendar").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          if let value {
            Text(value.kind.title + " · " + value.formatted)
            Text(value.source).font(.system(size: 10)).foregroundStyle(.secondary)
          } else {
            Text("订阅时间未提供").foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 4)
        if let value {
          Text(value.countdown())
            .foregroundStyle(value.daysRemaining() <= 7 ? Color.orange : Color.secondary)
          Image(systemName: "pencil").foregroundStyle(.secondary)
        } else {
          Text("补充").foregroundStyle(Theme.accent)
          Image(systemName: "plus").foregroundStyle(Theme.accent)
        }
      }.font(.system(size: 11)).padding(.vertical, 9).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain)
      .accessibilityLabel(provider.id + "订阅时间")
      .accessibilityValue(value.map { $0.kind.title + "，" + $0.formatted + "，" + $0.source + "，" + $0.countdown() } ?? "未提供，可补充")
      .help("查看或补充订阅日期；额度重置时间单独显示")
      .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
  }
  private var editor: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(provider.id + " · 订阅").font(.system(size: 14, weight: .semibold))
        Spacer()
        Button { editing = false } label: {
          Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("关闭订阅日期")
      }
      Picker("类型", selection: $kind) {
        ForEach(AISubscriptionDateKind.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.menu)
      DatePicker("日期", selection: $date, displayedComponents: .date)
      Text("手动记录仅保存在本机，以服务商为准。").font(.system(size: 10)).foregroundStyle(.secondary)
      HStack {
        if subscriptions.dates[provider.id] != nil {
          Button("移除记录") { subscriptions.remove(provider: provider.id); editing = false }
            .buttonStyle(AIControlButtonStyle(compact: true))
        }
        Spacer()
        Button("保存") { subscriptions.save(provider: provider.id, date: date, kind: kind); editing = false }
          .buttonStyle(AIControlButtonStyle(prominent: true, compact: true))
      }
    }.padding(18).frame(width: 320)
  }
}
