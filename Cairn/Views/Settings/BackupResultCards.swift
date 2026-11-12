import CairnServices
import SwiftUI

// Cards shared by the backup sheets (import preview, import result, export result), so the three
// read as one family on the card canvas.

/// The headline card of a backup sheet: a status glyph, a title, and a line or two under it.
struct BackupResultHero: View {
  let systemImage: String
  let tint: Color
  let title: String
  let lines: [String]

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(.largeTitle))
        .imageScale(.large)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
        .multilineTextAlignment(.center)
      VStack(spacing: 2) {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
          Text(line)
            .font(index == 0 ? .subheadline : .footnote)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .cardSurface(padding: 12)
    .accessibilityElement(children: .combine)
  }
}

/// One count tile per kind with a non-zero count: the figures a backup holds or an import added.
struct BackupCountGrid: View {
  let count: (BackupModelKind) -> Int

  var body: some View {
    MetricTileGrid {
      ForEach(BackupModelKind.allCases.filter { count($0) > 0 }, id: \.self) { kind in
        MetricTile(kind.label, systemImage: kind.systemImage, value: count(kind).formatted())
      }
    }
  }
}

/// A full-width button closing a backup sheet, sitting under the cards rather than on one.
struct BackupSheetButton: View {
  let title: String
  var isProminent = true
  let action: () -> Void

  var body: some View {
    let button = Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
    }
    Group {
      if isProminent {
        button.liquidGlassProminentButtonStyle()
      } else {
        button.liquidGlassButtonStyle()
      }
    }
    .controlSize(.large)
  }
}
