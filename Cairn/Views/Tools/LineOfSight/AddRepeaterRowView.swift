import SwiftUI

/// Offers a relay between A and B, as a card in the relay's place in the path.
struct AddRepeaterRowView: View {
  let onAdd: () -> Void

  var body: some View {
    Button(action: onAdd) {
      HStack(spacing: 12) {
        LOSPointBadge(letter: "R", color: .purple)
        Text(L10n.Tools.Tools.LineOfSight.addRepeater)
          .font(.body)
          .foregroundStyle(Color.purple)
        Spacer(minLength: 0)
        Image(systemName: "plus.circle.fill")
          .font(.title3)
          .foregroundStyle(.purple)
      }
      .cardSurface()
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
  }
}
