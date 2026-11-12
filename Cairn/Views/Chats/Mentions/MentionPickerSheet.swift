import CoreLocation
import CairnServices
import SwiftUI

/// Shown when a tapped sender name or `@mention` doesn't lead straight to one node's page:
/// a chooser when several nodes share the name (saved contacts and heard-but-not-saved nodes,
/// with type, last heard and route/distance to tell them apart), "that's you" for the user's own
/// name, or, when no advert with the name was ever heard, what the conversation itself knows
/// about the sender and the actions that still work. Presented by `MentionTapHandler` on every
/// chat surface (DMs, channels, rooms).
struct MentionPickerSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let context: MentionPickerContext
  let onSelect: (ContactDTO) -> Void
  var onSelectDiscovered: (DiscoveredNodeDTO) -> Void = { _ in }
  /// Inserts a mention of the name in the composer; nil where there is no composer to fill.
  var onMention: (() -> Void)?
  /// Blocks the sender by name (channels); nil where blocking by name doesn't apply.
  var onBlock: (() -> Void)?
  let onDismiss: () -> Void

  private static let compactDetentHeight: CGFloat = 180

  var body: some View {
    NavigationStack {
      Group {
        if context.isSelfMention {
          ContentUnavailableView {
            Label(L10n.Chats.Chats.Mention.Picker.selfTitle,
                  systemImage: "person.crop.circle")
          } description: {
            Text(L10n.Chats.Chats.Mention.Picker.selfSubtitle(context.name))
          }
        } else if context.isUnknownSender {
          UnknownSenderCard(
            name: context.name,
            activity: context.activity,
            onMention: onMention,
            onBlock: onBlock
          )
        } else {
          matchList
        }
      }
      .flashingNavigationTitle(context.isUnknownSender ? context.name : L10n.Chats.Chats.Mention.Picker.title(context.name))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.done) {
            onDismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
    .presentationDetents(detents)
    .presentationDragIndicator(.visible)
  }

  private var detents: Set<PresentationDetent> {
    if context.isSelfMention { return [.height(Self.compactDetentHeight), .medium] }
    return dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large]
  }

  private var matchList: some View {
    CardForm {
      if !context.matches.isEmpty {
        CardFormSection(L10n.Chats.Chats.Mention.Picker.matchingContacts) {
          ForEach(context.matches) { match in
            ContactMatchRow(
              contact: match,
              style: .tap,
              userLocation: appState.bestAvailableLocation,
              action: { onSelect(match) }
            )
            .cardSurface(padding: 12)
            .cardInteractionShape()
          }
        }
      }
      if !context.discoveredMatches.isEmpty {
        CardFormSection(
          L10n.Chats.Chats.Mention.Picker.heardNodes,
          footer: L10n.Chats.Chats.Mention.Picker.heardNodesFooter
        ) {
          ForEach(context.discoveredMatches) { node in
            DiscoveredMatchRow(
              node: node,
              userLocation: appState.bestAvailableLocation,
              action: { onSelectDiscovered(node) }
            )
          }
        }
      }
    }
  }
}

/// A heard-but-not-saved node in the name chooser: who it is, when it was last heard, and its
/// route or distance, so two nodes with one name can be told apart.
struct DiscoveredMatchRow: View {
  let node: DiscoveredNodeDTO
  let userLocation: CLLocation?
  let action: () -> Void

  private static let avatarSize: CGFloat = 40

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        avatar
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(node.name)
            .font(.body)
            .bold()
            .foregroundStyle(.primary)
          RelativeTimestampText(date: node.lastHeard)
          Text(detailLine)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(L10n.Chats.Chats.ContactMatch.key(node.publicKey.uppercaseHexString(separator: " ")))
            .font(.caption)
            .monospaced()
            .foregroundStyle(.tertiary)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
          .font(.caption)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(node.name)
    .accessibilityValue(detailLine)
    .accessibilityAddTraits(.isButton)
  }

  private var detailLine: String {
    NodeRouteFormat.joined([
      node.nodeType.localizedName,
      L10n.Chats.Chats.Mention.Picker.notSaved,
      NodeRouteFormat.routeLabel(
        isFloodRouted: node.isFloodRouted,
        pathHopCount: node.pathHopCount,
        displayedHopCount: node.displayedHopCount
      ),
      node.hasLocation
        ? NodeRouteFormat.distanceAway(from: userLocation, latitude: node.latitude, longitude: node.longitude)
        : nil,
    ])
  }

  @ViewBuilder
  private var avatar: some View {
    switch node.nodeType {
    case .chat:
      CompanionAvatar(name: node.name, publicKey: node.publicKey, size: Self.avatarSize)
    case .repeater:
      NodeAvatar(publicKey: node.publicKey, role: .repeater, size: Self.avatarSize, name: node.name)
    case .room:
      NodeAvatar(publicKey: node.publicKey, role: .roomServer, size: Self.avatarSize, name: node.name)
    }
  }
}

/// A sender whose advert this radio never heard: says so plainly (no key, no location, so no
/// node page or DM), then what this conversation knows about them, and what can still be done.
private struct UnknownSenderCard: View {
  let name: String
  let activity: SenderChatActivity?
  let onMention: (() -> Void)?
  let onBlock: (() -> Void)?

  var body: some View {
    CardForm {
      CardFormSection(footer: L10n.Chats.Chats.Mention.Unknown.howToFind) {
        ContentCard(
          L10n.Chats.Chats.Mention.Unknown.title,
          systemImage: "person.crop.circle.badge.questionmark",
          color: .secondary
        ) {
          Text(L10n.Chats.Chats.Mention.Unknown.explanation(name))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let activity {
        CardFormSection(L10n.Chats.Chats.Mention.Unknown.inThisChat) {
          MetricTileGrid {
            SenderActivityTiles(activity: activity)
          }
        }
      }

      if onMention != nil || onBlock != nil {
        CardFormSection {
          if let onMention {
            ActionCard(
              L10n.Chats.Chats.Message.Action.mention,
              systemImage: "at",
              action: onMention
            )
          }
          if let onBlock {
            ActionCard(
              L10n.Chats.Chats.Message.Action.blockSender,
              systemImage: "hand.raised",
              role: .destructive,
              action: onBlock
            )
          }
        }
      }
    }
  }
}

/// The sender's messages in this chat as tiles: how many, the latest, and how it got here.
private struct SenderActivityTiles: View {
  let activity: SenderChatActivity

  var body: some View {
    MetricTile(
      L10n.Chats.Chats.Mention.Unknown.messages,
      systemImage: "bubble.left",
      value: activity.messageCount.formatted()
    )
    MetricTile(
      L10n.Chats.Chats.Mention.Unknown.lastMessage,
      systemImage: "clock",
      value: activity.lastMessageDate.formatted(date: .omitted, time: .shortened),
      caption: activity.lastMessageDate.formatted(.relative(presentation: .named))
    )
    MetricTile(
      L10n.Chats.Chats.Message.Info.Title.hops,
      systemImage: "arrowshape.bounce.right",
      value: SenderActivityText.route(activity),
      caption: activity.lastPathHex.isEmpty ? nil : activity.lastPathHex.joined(separator: " → ")
    )
    if let snr = activity.lastSNR {
      let quality = SNRQuality(snr: snr)
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.snr,
        systemImage: "cellularbars",
        value: "\(snr.formatted(.number.precision(.fractionLength(1)))) dB",
        caption: quality.localizedLabel,
        valueTint: quality.textColor
      )
    }
  }
}

enum SenderActivityText {
  /// "Direct Route", "Direct" (heard straight from them) or "N Hops", for their latest message.
  static func route(_ activity: SenderChatActivity) -> String {
    if activity.lastWasDirectRoute { return L10n.Chats.Chats.Path.DirectRoute.title }
    switch activity.lastHopCount ?? 0 {
    case 0: return L10n.Chats.Chats.Message.Hops.direct
    case 1: return L10n.Chats.Chats.Repeats.Hop.singular
    case let hops: return L10n.Chats.Chats.Repeats.Hop.plural(hops)
    }
  }
}
