import SwiftUI

struct BatchSizeChip: View {
  @Environment(\.appTheme) private var theme
  let size: Int
  @Binding var selectedSize: Int

  private var isSelected: Bool {
    selectedSize == size
  }

  var body: some View {
    Button {
      selectedSize = size
    } label: {
      Text("\(size)×")
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? theme.accentColor : Color.secondary.opacity(0.2), in: .capsule)
        .foregroundStyle(isSelected ? theme.outgoingTextColor : .primary)
        .contentShape(MinimumHitShape())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
