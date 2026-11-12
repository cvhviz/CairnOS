import SwiftUI

/// A card that opens a page: its icon tile, its name, and an optional line of current state
/// ("Bluetooth", "Not sharing"), with a chevron. Hub pages lay these out in a `MetricTileGrid`
/// in place of a list of navigation rows. Wrap it in the `NavigationLink` or `Button`; this is
/// only the label, so it works with value links, selection buttons and closure links alike.
struct NavigationTile: View {
  let title: String
  let systemImage: String
  let color: Color
  let detail: String?
  /// The page open in the iPad detail column, for hubs that drive a split view's selection.
  let isSelected: Bool
  /// How much of its colour the card takes (`Wash`).
  let wash: Wash
  /// A least height, so a grid of tiles comes out even and any line it shows can wrap instead of
  /// cutting off. `nil` sizes the tile to its title, with its detail kept to one line.
  let height: CGFloat?

  /// A card in its own colour: a faint wash so a grid of tools reads by colour, or a stronger one
  /// with a hairline of the colour round the edge for the one or two actions a page leads with.
  enum Wash {
    case none
    case soft
    case prominent

    var fillOpacity: Double {
      switch self {
      case .none: 0
      case .soft: 0.07
      case .prominent: 0.14
      }
    }

    var strokeOpacity: Double {
      self == .prominent ? 0.45 : 0
    }
  }

  init(
    _ title: String,
    systemImage: String,
    color: Color,
    detail: String? = nil,
    isSelected: Bool = false,
    wash: Wash = .none,
    height: CGFloat? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.detail = detail
    self.isSelected = isSelected
    self.wash = wash
    self.height = height
  }

  @Environment(\.isGroupedRow) private var isGroupedRow

  var body: some View {
    if isGroupedRow {
      row
    } else {
      tile
    }
  }

  /// A row of a Settings group, as the iPhone's Settings draws one: icon, name, the current value
  /// on the right, chevron.
  private var row: some View {
    HStack(spacing: 12) {
      IconTile(systemImage: systemImage, color: color)
        .accessibilityHidden(true)
      Text(title)
        .font(.body)
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.body)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color(.tertiaryLabel))
        .accessibilityHidden(true)
    }
    .cardSurface(isSelected: isSelected, padding: 10)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(detail ?? "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var tile: some View {
    HStack(spacing: 10) {
      IconTile(systemImage: systemImage, color: color)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.primary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(height == nil ? 1 : 2)
            .fixedSize(horizontal: false, vertical: height != nil)
        }
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.tertiaryLabel))
        .accessibilityHidden(true)
    }
    .frame(maxHeight: .infinity)
    .frame(minHeight: height.map { max(0, $0 - 20) })
    .cardSurface(isSelected: isSelected, padding: 10)
    .overlay {
      if wash != .none {
        CardStyle.shape
          .fill(color.opacity(wash.fillOpacity))
          .overlay { CardStyle.shape.strokeBorder(color.opacity(wash.strokeOpacity), lineWidth: 1) }
          .allowsHitTesting(false)
      }
    }
    .cardInteractionShape()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(detail ?? "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
