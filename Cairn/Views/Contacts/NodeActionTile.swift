import SwiftUI

/// A compact action card for the row of primary actions under a node page's header (Message,
/// Telemetry, Ping…), in the manner of the Contacts app's action buttons: a tinted glyph over a
/// short title. Wrap it in a `Button`, `NavigationLink` or `Menu` with `.buttonStyle(.plain)`;
/// this is only the label. Lay several out in a `NodeActionTileRow`.
struct NodeActionTile: View {
  @Environment(\.isEnabled) private var isEnabled

  let title: String
  let systemImage: String
  /// The full name VoiceOver reads when the visible title is a short form ("Ping" for
  /// "Zero-Hop Ping").
  let accessibilityTitle: String?
  /// Shows a spinner in place of the glyph while the action runs.
  let isBusy: Bool

  init(_ title: String, systemImage: String, accessibilityTitle: String? = nil, isBusy: Bool = false) {
    self.title = title
    self.systemImage = systemImage
    self.accessibilityTitle = accessibilityTitle
    self.isBusy = isBusy
  }

  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        // The glyph keeps its space while busy so the tile doesn't change height.
        Image(systemName: systemImage)
          .font(.title3)
          .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
          .opacity(isBusy ? 0 : 1)
        if isBusy {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(minHeight: 24)

      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 2)
    .cardSurface(padding: 8)
    .cardInteractionShape()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityTitle ?? title)
    .accessibilityAddTraits(.isButton)
  }
}

/// Lays out `NodeActionTile`s in one row of equal widths, wrapping to two rows past five tiles,
/// and to two columns at accessibility text sizes so titles never shrink away.
struct NodeActionTileRow<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// How many tiles the row holds; sets the column count.
  let count: Int
  @ViewBuilder let content: () -> Content

  private static var maxColumns: Int { 5 }

  init(count: Int, @ViewBuilder content: @escaping () -> Content) {
    self.count = count
    self.content = content
  }

  var body: some View {
    LazyVGrid(columns: columns, spacing: CardStyle.spacing) {
      content()
    }
  }

  private var columns: [GridItem] {
    let perRow: Int
    if dynamicTypeSize.isAccessibilitySize {
      perRow = 2
    } else if count > Self.maxColumns {
      perRow = (count + 1) / 2
    } else {
      perRow = max(count, 1)
    }
    return Array(repeating: GridItem(.flexible(), spacing: CardStyle.spacing, alignment: .top), count: perRow)
  }
}
