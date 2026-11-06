import AppKit
import SwiftUI

enum Theme {
  static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) {
      $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
  }
  static let menuCard = adaptive(light: NSColor(white: 0.94, alpha: 1), dark: NSColor(white: 0.19, alpha: 1))
  static let panel = adaptive(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.19, alpha: 1))
  static let accent = adaptive(light: NSColor(srgbRed: 0, green: 122/255, blue: 1, alpha: 1),
                               dark: NSColor(srgbRed: 118/255, green: 215/255, blue: 1, alpha: 1))
  static let selectionForeground = adaptive(light: .white, dark: NSColor(white: 0.08, alpha: 1))
  static let secondary = Color.secondary
  static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    let style = UserDefaults.standard.string(forKey: "numberFont") ?? "rounded"
    let preference = UserDefaults.standard.object(forKey: "numberWeight") as? Double
    let adjusted: Font.Weight
    if let preference {
      let level = preference + (weight == .bold ? 0.15 : weight == .regular ? -0.25 : 0)
      adjusted =
        level < 0.2
        ? .light : level < 0.4 ? .regular : level < 0.6 ? .medium : level < 0.85 ? .semibold : .bold
    } else {
      adjusted = weight
    }
    return .system(
      size: size, weight: adjusted,
      design: style == "mono"
        ? .monospaced : (style == "system" ? .default : style == "serif" ? .serif : .rounded))
  }
}
struct Panel<Content: View>: View {
  var padding: CGFloat = 16
  var background: Color? = nil
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(padding).contentShape(RoundedRectangle(cornerRadius: 18)).background(
      background ?? Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
struct MetricIcon: View {
  let symbol: String, color: Color
  var body: some View {
    Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
      .frame(width: 29, height: 29).background(
        color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
  }
}
struct ValueText: View {
  let text: String
  var size: CGFloat = 43
  var body: some View {
    let pair = Format.split(text)
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(pair.0).font(Theme.number(size, .bold)).contentTransition(.numericText())
      if !pair.1.isEmpty {
        Text(pair.1).font(Theme.number(size * 0.46)).foregroundStyle(.secondary)
      }
    }.lineLimit(1).minimumScaleFactor(0.5).monospacedDigit()
  }
}
struct SmallStat: View {
  let title: String, value: String
  var color: Color? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        if let color { Circle().fill(color).frame(width: 6, height: 6) }
        Text(title).foregroundStyle(.secondary).font(.system(size: 11))
      }
      Text(value).font(Theme.number(13)).lineLimit(1).minimumScaleFactor(0.65)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct HistoryGraph: View {
  let values: [Double]
  var secondary: [Double] = []
  var color: Color = Theme.accent
  var secondaryColor: Color = .orange
  var ceiling: Double? = nil
  var bars = false, grid = false
  @State private var hover: CGPoint?
  private var maxValue: Double {
    max(ceiling ?? max(values.max() ?? 0, secondary.max() ?? 0) * 1.12, 1)
  }
  var body: some View {
    GeometryReader { g in
      let w = g.size.width
      let h = g.size.height
      ZStack(alignment: .topLeading) {
        if grid {
          Path { p in
            for y in [0.0, 0.5, 1.0] {
              p.move(to: CGPoint(x: 0, y: h * y))
              p.addLine(to: CGPoint(x: w, y: h * y))
            }
          }.stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
        }
        if values.count > 1 {
          if bars {
            HStack(alignment: .bottom, spacing: 2) {
              ForEach(Array(Self.buckets(values, count: max(1, Int(w / 6))).enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                  Capsule().fill(color.opacity(0.10))
                  Capsule().fill(color).frame(height: max(1, h * min(1, v / maxValue)))
                }
              }
            }.frame(height: h, alignment: .bottom)
          } else {
            graphPath(values, w: w, h: h, fill: true).fill(
              LinearGradient(
                colors: [color.opacity(0.20), color.opacity(0.015)], startPoint: .top,
                endPoint: .bottom))
            graphPath(values, w: w, h: h, fill: false).stroke(
              color,
              style: StrokeStyle(lineWidth: grid ? 1.8 : 1.6, lineCap: .round, lineJoin: .round))
          }
          if secondary.count > 1 {
            graphPath(secondary, w: w, h: h, fill: false).stroke(secondaryColor, lineWidth: 1.4)
          }
        } else {
          Text("正在积累采样…").font(.system(size: 11)).foregroundStyle(.tertiary).frame(
            width: w, height: h)
        }
        if let hover, grid, !values.isEmpty {
          let i = min(values.count - 1, max(0, Int(hover.x / max(w, 1) * Double(values.count - 1))))
          Path { p in
            p.move(to: CGPoint(x: hover.x, y: 0))
            p.addLine(to: CGPoint(x: hover.x, y: h))
          }.stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          Text(String(format: "%.1f", values[i])).font(
            .system(size: 11, weight: .medium, design: .monospaced)
          ).padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5)).offset(
            x: min(max(0, hover.x - 20), max(0, w - 65)), y: 4)
        }
      }.onContinuousHover { phase in
        switch phase {
        case .active(let point): hover = point
        case .ended: hover = nil
        }
      }
    }.accessibilityLabel("实时历史曲线，\(values.count)个采样点")
  }
  static func buckets(_ values: [Double], count: Int) -> [Double] {
    guard count > 0, values.count > count else { return values }
    return (0..<count).map { i in
      let start = i * values.count / count, end = (i + 1) * values.count / count
      return values[start..<max(start + 1, end)].max() ?? 0
    }
  }
  private func graphPath(_ a: [Double], w: CGFloat, h: CGFloat, fill: Bool) -> Path {
    Path { p in
      guard !a.isEmpty else { return }
      for (i, n) in a.enumerated() {
        let x = CGFloat(i) / CGFloat(max(a.count - 1, 1)) * w
        let y = h * (1 - min(1, max(0, n / maxValue)))
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
      }
      if fill {
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
      }
    }
  }
}

struct AppIcon: View {
  let path: String?
  var size: CGFloat = 20
  private static var cache: [String: NSImage] = [:]
  var body: some View {
    Group {
      if let path {
        Image(nsImage: Self.icon(path)).resizable()
      } else {
        Image(systemName: "apple.logo").resizable().scaledToFit().padding(2).foregroundStyle(
          .secondary)
      }
    }.frame(width: size, height: size)
  }
  private static func icon(_ path: String) -> NSImage {
    if let i = cache[path] { return i }
    let i = NSWorkspace.shared.icon(forFile: path)
    cache[path] = i
    return i
  }
}
struct EmptyState: View {
  let symbol: String, title: String, detail: String
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
      Text(title).font(.system(size: 18, weight: .semibold))
      Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(
        .center
      ).frame(maxWidth: 440)
    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
  }
}
struct GaugeBar: View {
  let value: Double, color: Color
  var height: CGFloat = 4
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.13))
        Capsule().fill(color).frame(width: max(0, g.size.width * min(1, max(0, value))))
      }
    }.frame(height: height)
  }
}
