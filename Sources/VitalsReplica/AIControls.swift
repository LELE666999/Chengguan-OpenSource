import SwiftUI

/// Keep the entire visible control, including padding, inside the button's hit region.
struct AIControlButtonStyle: ButtonStyle {
  var prominent = false
  var compact = false
  var tint: Color? = nil
  func makeBody(configuration: Configuration) -> some View {
    AIControlSurface(label: configuration.label, pressed: configuration.isPressed,
      destructive: configuration.role == .destructive, prominent: prominent, compact: compact, tint: tint)
  }
}

private struct AIControlSurface<Label: View>: View {
  let label: Label
  let pressed: Bool, destructive: Bool, prominent: Bool, compact: Bool
  let tint: Color?
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  private var color: Color { destructive ? .red : (tint ?? Theme.accent) }
  var body: some View {
    label.font(.system(size: 12, weight: .medium))
      .padding(.horizontal, compact ? 10 : 13)
      .frame(minWidth: compact ? 30 : 36, minHeight: compact ? 30 : 36)
      .foregroundStyle(prominent ? Theme.selectionForeground : color)
      .background(prominent ? color.opacity(pressed ? 0.75 : hovered ? 0.9 : 1)
        : color.opacity(pressed ? 0.18 : hovered ? 0.12 : 0.065),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .opacity(enabled ? 1 : 0.4)
      .onHover { hovered = $0 }
  }
}

/// Use an explicit full-row button so the label, padding, and trailing space all toggle.
struct AIWholeRowDisclosureStyle: DisclosureGroupStyle {
  var tint: Color? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(AIControlButtonStyle(tint: tint))
        .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
      if configuration.isExpanded {
        configuration.content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
      }
    }
  }
}
