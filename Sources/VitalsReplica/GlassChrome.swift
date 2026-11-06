import SwiftUI

/// Shared native glass for utility controls and short live-status capsules.
struct ChromeGlass: ViewModifier {
  var circle = false
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      if circle { content.glassEffect(.regular.interactive(), in: .circle) }
      else { content.glassEffect(.regular.interactive(), in: .capsule) }
    } else {
      if circle { content.background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5)) }
      else { content.background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5)) }
    }
  }
}
struct GlassCircleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    GlassCircleSurface(label: configuration.label, pressed: configuration.isPressed)
  }
}
private struct GlassCircleSurface<L: View>: View {
  let label: L
  let pressed: Bool
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    label.foregroundStyle(hovered ? Theme.accent : .primary)
      .background(Color.primary.opacity(pressed ? 0.12 : hovered ? 0.055 : 0), in: Circle())
      .modifier(ChromeGlass(circle: true)).contentShape(Circle())
      .scaleEffect(pressed ? 0.92 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
      .onHover { hovered = $0 }
  }
}
struct GlassStatusCapsule<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    content.padding(.horizontal, 11).padding(.vertical, 7).modifier(ChromeGlass())
  }
}

/// Native glass selection with a complete, accessible click target.
struct SettingsGlassSegments: View {
  @Binding var selection: String
  let options: [String]
  var compact = false
  var tint: Color? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 4) {
      ForEach(options, id: \.self) { option in
        Button {
          withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.84)) { selection = option }
        } label: {
          Text(option).font(.system(size: compact ? 12 : 13, weight: selection == option ? .semibold : .medium))
            .foregroundStyle(selection == option ? Theme.selectionForeground : Color.primary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 12 : 14)
            .frame(minWidth: compact ? 54 : 84, minHeight: compact ? 30 : 36)
            .background(selection == option ? (tint ?? Theme.accent) : .clear, in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(CareRowStyle())
          .accessibilityAddTraits(selection == option ? .isSelected : [])
      }
    }.padding(4).modifier(ChromeGlass())
  }
}
