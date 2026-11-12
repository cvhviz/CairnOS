import SwiftUI

/// An action card for work that takes a moment (export, import, sign, generate): like `ActionCard`,
/// but its icon turns into a spinner while the action runs, and it can name a file format on the
/// trailing edge.
/// The caller wraps it in a `Button` with `.buttonStyle(.plain)`.
struct BusyActionCardLabel: View {
  let title: String
  var subtitle: String?
  var trailing: String?
  let systemImage: String
  let color: Color
  let isBusy: Bool

  /// Matches `IconTile`'s scaled size so the title doesn't shift when the spinner swaps in.
  @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 28

  var body: some View {
    HStack(spacing: 12) {
      if isBusy {
        ProgressView()
          .frame(width: tileSize, height: tileSize)
      } else {
        IconTile(systemImage: systemImage, color: color)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(Color.accentColor)
        if let subtitle {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      if let trailing {
        Text(trailing)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
      }
    }
    .cardSurface(padding: 12)
    .cardInteractionShape()
    .dimmedWhenDisabled()
  }
}
