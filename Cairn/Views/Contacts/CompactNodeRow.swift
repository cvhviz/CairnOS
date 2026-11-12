import CoreLocation
import CairnServices
import SwiftUI

// MARK: - Compact List Grouping

/// The List layout of the node lists (Saved and Heard): one compact card per node, with the card
/// gap between them as Network Health's rows have, rather than the Cards layout's taller cards.
/// List is for scanning a lot of nodes at once, many more per screen.
///
/// Each row paints its own card, so the rows stay direct children of the `LazyVStack` (lazy, and
/// each with its own swipe actions and context menu). `CompactNodeRowPosition` is kept for the
/// callers but no longer changes the shape.
@MainActor
enum CompactNodeList {
  /// Vertical padding inside a row; with a 41 pt avatar a row comes to about 65 pt.
  static let rowVerticalPadding: CGFloat = 11.5
  static let rowHorizontalPadding: CGFloat = 12
  static let avatarSize: CGFloat = 41
  /// Avatar to text.
  static let avatarSpacing: CGFloat = 11

  /// The row's card: every corner rounded, whatever its place in the list.
  static func shape(isFirst _: Bool, isLast _: Bool) -> UnevenRoundedRectangle {
    let top = CardStyle.cornerRadius
    let bottom = CardStyle.cornerRadius
    return UnevenRoundedRectangle(
      topLeadingRadius: top,
      bottomLeadingRadius: bottom,
      bottomTrailingRadius: bottom,
      topTrailingRadius: top,
      style: .continuous
    )
  }
}

/// Where a row sits in its compact group.
struct CompactNodeRowPosition: Equatable {
  let isFirst: Bool
  let isLast: Bool

  @MainActor var shape: UnevenRoundedRectangle {
    CompactNodeList.shape(isFirst: isFirst, isLast: isLast)
  }
}

private struct CompactNodeRowBackground: ViewModifier {
  let position: CompactNodeRowPosition
  let isSelected: Bool
  /// Kept for callers from when rows shared hairline separators; cards have none.
  let separatorLeadingExtra: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, CompactNodeList.rowHorizontalPadding)
      .padding(.vertical, CompactNodeList.rowVerticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background { CardBackground(isSelected: isSelected, shape: position.shape) }
  }
}

extension View {
  /// Pads the row and paints its slice of the compact group, with the hairline under it.
  func compactNodeRowBackground(
    _ position: CompactNodeRowPosition,
    isSelected: Bool = false,
    separatorLeadingExtra: CGFloat = 0
  ) -> some View {
    modifier(CompactNodeRowBackground(
      position: position,
      isSelected: isSelected,
      separatorLeadingExtra: separatorLeadingExtra
    ))
  }

  /// Taps, the pointer hover and the context-menu lift follow the row's slice of the group.
  /// The compact counterpart of `cardInteractionShape()`.
  func compactNodeRowInteractionShape(_ position: CompactNodeRowPosition) -> some View {
    contentShape(.interaction, position.shape)
      .contentShape(.contextMenuPreview, position.shape)
      .contentShape(.hoverEffect, position.shape)
      .hoverEffect(.highlight)
  }
}

// MARK: - Saved Node Row

/// A saved node in the compact List layout: a small avatar, the name on one line with the time
/// last heard and the favorite star trailing, and one short line of hash prefix, route and distance. The roomier
/// `ContactRowView` stays for other lists that show a single node row.
struct ContactCompactRowView: View {
  @Environment(\.appState) private var appState
  let contact: ContactDTO
  let showTypeLabel: Bool
  let userLocation: CLLocation?
  let isTogglingFavorite: Bool
  let inboundHopCount: Int?

  var body: some View {
    HStack(spacing: CompactNodeList.avatarSpacing) {
      ContactTypeAvatar(contact: contact, size: CompactNodeList.avatarSize)
        .nodeBlockedBadge(contact.isBlocked)

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(contact.displayName)
            .compactNodeNameFont()
            .nodeNameFit(lineLimit: 1)
            .frame(maxWidth: .infinity, alignment: .leading)

          RelativeTimestampText(timestamp: contact.recencyTimestamp)
            .layoutPriority(1)

          FavoriteStar(isFavorite: contact.isFavorite, isToggling: isTogglingFavorite, label: L10n.Contacts.Contacts.Row.favorite)
        }

        HStack(spacing: 4) {
          // The radio's short id for the node, as it appears in routes; hex is noise to VoiceOver.
          if contact.showsShortID(names: appState.nodeAppearance.names) {
            Text(idPrefixHex)
              .monospaced()
              .accessibilityHidden(true)
            Text(verbatim: "\u{00B7}")
              .accessibilityHidden(true)
          }
          Text(details)
        }
        .compactNodeDetailFont()
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      // Name first when the row reads as one element, ahead of the avatar's badge.
      .accessibilitySortPriority(1)
    }
  }

  /// Type only in search results, where every kind is mixed together.
  private var details: String {
    NodeRouteFormat.joined([
      showTypeLabel ? contact.type.localizedName : nil,
      routeLabel,
      distance,
    ])
  }

  private var idPrefixHex: String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    return contact.publicKey.prefix(hashSize).uppercaseHexString()
  }

  private var routeLabel: String {
    NodeRouteFormat.routeLabel(
      isFloodRouted: contact.isFloodRouted,
      pathHopCount: contact.pathHopCount,
      displayedHopCount: contact.displayedHopCount(inboundHopCount: inboundHopCount)
    )
  }

  private var distance: String? {
    guard contact.hasLocation else { return nil }
    return NodeRouteFormat.distanceAway(from: userLocation, latitude: contact.latitude, longitude: contact.longitude)
  }
}

// MARK: - Compact Row Text

/// The List rows' text, a point above the system's body and caption so the dense rows stay easy
/// to read, still scaling with Dynamic Type.
private struct CompactNodeNameFont: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: .medium))
  }
}

private struct CompactNodeDetailFont: ViewModifier {
  @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 13.5

  func body(content: Content) -> some View {
    content.font(.system(size: size))
  }
}

extension View {
  /// A List row's node name.
  func compactNodeNameFont() -> some View { modifier(CompactNodeNameFont()) }
  /// A List row's second line.
  func compactNodeDetailFont() -> some View { modifier(CompactNodeDetailFont()) }
}
