import CoreLocation
import CairnServices
import SwiftUI

struct ContactRowView: View {
  @Environment(\.appState) private var appState
  let contact: ContactDTO
  let showTypeLabel: Bool
  let userLocation: CLLocation?
  let isTogglingFavorite: Bool
  let inboundHopCount: Int?

  init(
    contact: ContactDTO,
    showTypeLabel: Bool = false,
    userLocation: CLLocation? = nil,
    isTogglingFavorite: Bool = false,
    inboundHopCount: Int? = nil
  ) {
    self.contact = contact
    self.showTypeLabel = showTypeLabel
    self.userLocation = userLocation
    self.isTogglingFavorite = isTogglingFavorite
    self.inboundHopCount = inboundHopCount
  }

  /// Name on its own line at full width, with the time last heard and the favorite star after it;
  /// the route and distance on the line under it, after the short id where one's wanted
  /// (`showsShortID`). Blocked sits on the avatar's corner.
  var body: some View {
    HStack(spacing: 12) {
      ContactTypeAvatar(contact: contact, size: 44)
        .nodeBlockedBadge(contact.isBlocked)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(contact.displayName)
            .font(.body.weight(.medium))
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

          // Type only in search results, where every kind is mixed together.
          if showTypeLabel {
            Text("\(contactTypeLabel) \u{00B7}")
          }

          Text(routeLabel)

          if contact.hasLocation {
            Label(L10n.Contacts.Contacts.Row.location, systemImage: "location.fill")
              .labelStyle(.iconOnly)
              .foregroundStyle(.green)

            if let distance = distanceToContact {
              Text(distance)
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      // Name first when the row reads as one element, ahead of the avatar's badge.
      .accessibilitySortPriority(1)
    }
    .padding(.vertical, 4)
  }

  private var idPrefixHex: String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    return contact.publicKey.prefix(hashSize).uppercaseHexString()
  }

  private var contactTypeLabel: String {
    contact.type.localizedName
  }

  private var routeLabel: String {
    NodeRouteFormat.routeLabel(
      isFloodRouted: contact.isFloodRouted,
      pathHopCount: contact.pathHopCount,
      displayedHopCount: contact.displayedHopCount(inboundHopCount: inboundHopCount)
    )
  }

  private var distanceToContact: String? {
    guard contact.hasLocation else { return nil }
    return NodeRouteFormat.distanceAway(from: userLocation, latitude: contact.latitude, longitude: contact.longitude)
  }
}

/// A node's avatar by type: the contact's picture, or the radio / repeater / room glyph on its colour.
/// Shared by the node rows and node cards.
struct ContactTypeAvatar: View {
  let contact: ContactDTO
  let size: CGFloat

  var body: some View {
    switch contact.type {
    case .chat:
      ContactAvatar(contact: contact, size: size)
    case .repeater:
      NodeAvatar(
        publicKey: contact.publicKey,
        role: .repeater,
        size: size,
        name: contact.displayName,
        photo: contact.avatarImageData,
        color: contact.avatarColor
      )
    case .room:
      NodeAvatar(
        publicKey: contact.publicKey,
        role: .roomServer,
        size: size,
        name: contact.displayName,
        photo: contact.avatarImageData,
        color: contact.avatarColor
      )
    }
  }
}

// MARK: - Short ID

extension ContactDTO {
  /// Whether a row shows the radio's short id for this node: on a repeater, whose id is how routes
  /// name it, and where it's the only way to tell two nodes of one name apart.
  func showsShortID(names: ContactNameDirectory) -> Bool {
    type == .repeater || names.isDisplayNameShared(displayName)
  }
}

// MARK: - Node Name and Badges

extension View {
  /// Fits a node name: up to `lineLimit` lines, tightening and then shrinking a little before it
  /// truncates, at the tail where a name's distinguishing start stays readable.
  func nodeNameFit(lineLimit: Int) -> some View {
    self
      .lineLimit(lineLimit)
      .allowsTightening(true)
      .minimumScaleFactor(0.85)
      .truncationMode(.tail)
  }

  /// Blocked as a small hand badge on a node's avatar's top-trailing corner, so it marks the node
  /// without taking width from its name. The badge keeps its spoken label.
  func nodeBlockedBadge(_ isBlocked: Bool) -> some View {
    overlay(alignment: .topTrailing) {
      if isBlocked {
        Image(systemName: "hand.raised.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.orange)
          .frame(width: 16, height: 16)
          // A material disc behind the glyph, so it reads against any avatar on a solid or glass card.
          .background(.regularMaterial, in: Circle())
          .offset(x: 4, y: -4)
          .accessibilityLabel(L10n.Contacts.Contacts.Row.blocked)
      }
    }
  }
}

/// The favorite star at the far right of a row's name line, after the time, so stars line up down
/// a list. A spinner takes the star's place, in the same width, while a favorite change is in
/// flight; a row that isn't a favorite shows nothing and keeps its time flush right.
struct FavoriteStar: View {
  let isFavorite: Bool
  var isToggling = false
  let label: String

  /// Fits the star and the mini spinner.
  static let slotWidth: CGFloat = 16

  var body: some View {
    Group {
      if isToggling {
        ProgressView()
          .controlSize(.mini)
      } else if isFavorite {
        Image(systemName: "star.fill")
          .font(.caption)
          .foregroundStyle(.yellow)
          .accessibilityLabel(label)
      }
    }
    .frame(width: Self.slotWidth)
  }
}
