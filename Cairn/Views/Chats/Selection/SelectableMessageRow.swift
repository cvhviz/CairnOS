import SwiftUI

/// Wraps a message row so it can be picked in multi-select mode. While selecting,
/// a full-row tap target sits above the bubble (so links, images, and long-press
/// don't fire) and a checkmark shows in the row's free edge strip: bubbles never
/// span the full width, so the mark fits without changing the row's height.
struct SelectableMessageRow<Content: View>: View {
  let messageID: UUID
  let isOutgoing: Bool
  let selection: MessageSelectionModel?
  @ViewBuilder let content: () -> Content

  var body: some View {
    if let selection, selection.isSelecting {
      let isSelected = selection.isSelected(messageID)
      content()
        .overlay(alignment: isOutgoing ? .leading : .trailing) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: SelectableMessageRowMetrics.checkmarkSize))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, SelectableMessageRowMetrics.edgeInset)
            .accessibilityHidden(true)
        }
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
          Color.clear
            .contentShape(.rect)
            .onTapGesture { selection.toggle(messageID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    } else {
      content()
    }
  }
}

/// Outside the generic row: a generic type cannot hold static stored properties.
private enum SelectableMessageRowMetrics {
  static let checkmarkSize: CGFloat = 24
  static let edgeInset: CGFloat = 14
}
