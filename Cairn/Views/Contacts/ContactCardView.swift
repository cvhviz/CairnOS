import CoreLocation
import CairnServices
import SwiftUI

/// A node in the card layout of the Nodes list: the same facts as `ContactRowView` (who, when last
/// heard, how it's routed, how far away), packed into a grid cell. The avatar, the name on one
/// line with its route under it (after the short id where one's wanted), and the favorite star at
/// the far right make the top; under them where it is, with when it was last heard at the right
/// end of that line. Every card holds the same lines, so the grid tiles evenly however long the
/// names run; blocked sits on the avatar's corner.
struct ContactCardView: View {
  @Environment(\.appState) private var appState
  let contact: ContactDTO
  let showTypeLabel: Bool
  let userLocation: CLLocation?
  let isTogglingFavorite: Bool
  let inboundHopCount: Int?
  /// The node open in the iPad detail column.
  var isSelected = false

  var body: some View {
    VStack(alignment: .leading, spacing: NodeCardLayout.sectionSpacing) {
      HStack(alignment: .center, spacing: NodeCardLayout.avatarSpacing) {
        ContactTypeAvatar(contact: contact, size: NodeCardLayout.avatarSize)
          .nodeBlockedBadge(contact.isBlocked)

        VStack(alignment: .leading, spacing: NodeCardLayout.lineSpacing) {
          NodeCardName(contact.displayName)
            // Spoken first when the card reads as one element, ahead of the avatar's badge.
            .accessibilitySortPriority(1)
          NodeCardDetailLine(
            symbol: "arrowshape.bounce.right",
            // Type only in search results, where every kind is mixed together.
            text: NodeRouteFormat.joined([showTypeLabel ? contact.type.localizedName : nil, routeLabel]),
            // The radio's short id for the node, as it appears in routes; hex is noise to VoiceOver.
            shortID: contact.showsShortID(names: appState.nodeAppearance.names) ? idPrefixHex : nil
          )
        }

        FavoriteStar(isFavorite: contact.isFavorite, isToggling: isTogglingFavorite, label: L10n.Contacts.Contacts.Row.favorite)
      }

      HStack(spacing: 8) {
        NodeCardPlaceLine(hasLocation: contact.hasLocation, distance: distance)
        NodeCardHeardLine(date: Date(timeIntervalSince1970: TimeInterval(contact.recencyTimestamp)), hugs: true)
      }
    }
    .cardSurface(isSelected: isSelected, padding: 10)
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

  /// The bare distance ("5.3 mi"): the location glyph beside it already says where it points.
  private var distance: String? {
    guard contact.hasLocation else { return nil }
    return NodeRouteFormat.distance(from: userLocation, latitude: contact.latitude, longitude: contact.longitude)
  }
}

// MARK: - Card Pieces

/// The node cards' shared measures, so a saved node's card and a heard node's tile alike.
enum NodeCardLayout {
  static let avatarSize: CGFloat = 36
  /// Avatar to name.
  static let avatarSpacing: CGFloat = 8
  /// The name line to the detail lines.
  static let sectionSpacing: CGFloat = 8
  /// Between the detail lines.
  static let lineSpacing: CGFloat = 3
}

/// A node's name beside its avatar, on one line at full size: a long name tightens a little and
/// then truncates at the tail, where its distinguishing start stays readable, never shrinking.
/// The line under it (its route) fills the avatar's height, so the top of every card is the same.
struct NodeCardName: View {
  let name: String

  init(_ name: String) {
    self.name = name
  }

  var body: some View {
    Text(name)
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
      .allowsTightening(true)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One fact on a card: a glyph in a fixed slot, so the lines' text aligns, and a line of caption
/// text that truncates rather than wraps, so every card keeps its lines. It takes the width it's
/// given, or only its own (`hugs`) at the end of a shared line.
struct NodeCardDetailLine: View {
  let symbol: String
  let text: String
  /// A short id in front of the text, monospaced and left out of VoiceOver.
  var shortID: String?
  var tint: Color = .secondary
  /// Only as wide as its text, for the right end of a shared line.
  var hugs = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: symbol)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 14)
        .accessibilityHidden(true)
      HStack(spacing: 4) {
        if let shortID {
          Text(shortID)
            .monospaced()
            .accessibilityHidden(true)
          Text(verbatim: "\u{00B7}")
            .accessibilityHidden(true)
        }
        Text(text)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: hugs ? nil : .infinity, alignment: .leading)
    }
    .fixedSize(horizontal: hugs, vertical: false)
  }
}

/// When the node was last heard, as a detail line that keeps up ("3 min ago", then "4 min ago").
struct NodeCardHeardLine: View {
  let date: Date
  /// Only as wide as its text, at the right end of the place line.
  var hugs = false

  var body: some View {
    TimelineView(.everyMinute) { context in
      NodeCardDetailLine(symbol: "clock", text: RelativeTimestampText.format(date: date, relativeTo: context.date), hugs: hugs)
    }
  }
}

/// Where the node is, as a detail line: how far away when the phone's position is known, that
/// it's on the map when it isn't, or that it has no position.
struct NodeCardPlaceLine: View {
  let hasLocation: Bool
  /// The bare distance ("5.3 mi"), when both positions are known.
  let distance: String?

  var body: some View {
    if hasLocation {
      NodeCardDetailLine(symbol: "location.fill", text: distance ?? L10n.Contacts.Contacts.Card.onMap, tint: .green)
    } else {
      NodeCardDetailLine(symbol: "location.slash", text: L10n.Contacts.Contacts.Card.noLocation)
    }
  }
}
