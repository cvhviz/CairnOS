import CairnServices
import SwiftUI

/// A map pin's callout: the node's name (which opens its details, where it can also be hidden
/// from the map) over its kind, with Message for a chat contact.
struct ContactCalloutContent: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  let contact: ContactDTO
  let onDetail: () -> Void
  let onMessage: () -> Void
  /// Opens the chat with the user's own position typed in; nil leaves the item out.
  var onSendMyLocation: (() -> Void)?
  /// In the map's navigation panel, under its name and distance (the user, 2026-11-09: one section, as
  /// the Traffic map has it): no title of its own, an info button to the node's page instead, and the
  /// panel's padding.
  var inPanel = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !inPanel {
        MapCalloutTitleButton(prefix: idPrefixHex, name: contact.displayName, action: onDetail)
      }

      HStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: contact.type.iconSystemName)
            .foregroundStyle(contact.type.displayColor)
          Text(inPanel ? NodeRouteFormat.joined([typeDisplayName, idPrefixHex]) : typeDisplayName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 12)

        if inPanel {
          Button(action: onDetail) { Label { Text(L10n.Map.Map.Callout.details) } icon: { MapCalloutIcon(systemImage: "info") } }
            .mapCalloutIconButton()
            .accessibilityHint(contact.displayName)
        }

        if contact.type == .chat {
          Button {
            dismiss()
            onMessage()
          } label: {
            Label { Text(L10n.Map.Map.Callout.message) } icon: { MapCalloutIcon(systemImage: "message.fill") }
          }
          .mapCalloutIconButton()
          .accessibilityHint(contact.displayName)
        }

        MapCalloutActionsMenu(
          name: contact.displayName,
          coordinate: contact.coordinate,
          onSendMyLocation: contact.type == .chat ? onSendMyLocation : nil
        )
      }
    }
    .padding(inPanel ? 0 : 12)
    .frame(minWidth: 160)
  }

  // MARK: - Computed Properties

  private var idPrefixHex: String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    return contact.publicKey.prefix(hashSize).uppercaseHexString()
  }

  private var typeDisplayName: String {
    switch contact.type {
    case .chat:
      L10n.Map.Map.Callout.NodeKind.contact
    case .repeater:
      L10n.Map.Map.Callout.NodeKind.repeater
    case .room:
      L10n.Map.Map.Callout.NodeKind.room
    }
  }
}

// MARK: - Callout Parts

/// A node callout's title: the ID prefix and name, opening the node's details as a list row
/// would, with the chevron that says so. The callout's one way to Details, so it needs no button.
struct MapCalloutTitleButton: View {
  let prefix: String
  let name: String
  var accessibilityName: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        (Text(prefix)
          .monospaced()
          .foregroundStyle(.secondary)
          + Text(" \(name)"))
          .font(.headline)
          .foregroundStyle(Color.primary)
          .lineLimit(2)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityName ?? name)
    .accessibilityHint(L10n.Map.Map.Callout.details)
    .accessibilityAddTraits(.isHeader)
  }
}

extension View {
  /// A callout's own action (message, add) as a small round icon beside the node's
  /// kind, still named for VoiceOver.
  func mapCalloutIconButton() -> some View {
    labelStyle(.iconOnly)
      // one glyph size in one frame, so "i", "•••", "+" and the bubble come out the same size (the
      // user, 2026-11-09: the info and more buttons differed)
      .font(.footnote.weight(.semibold))
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .controlSize(.small)
  }
}

/// A map callout button's glyph, in a fixed square, so every icon button is the same size whatever
/// its symbol's own width ("i" is narrow, "•••" wide).
struct MapCalloutIcon: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .frame(width: 18, height: 18)
  }
}

// MARK: - Preview

#Preview {
  ContactCalloutContent(
    contact: ContactDTO(
      from: Contact(
        radioID: UUID(),
        publicKey: Data(repeating: 0x01, count: 32),
        name: "Alice",
        typeRawValue: 0,
        latitude: 37.7749,
        longitude: -122.4194,
        lastHeardTimestamp: 0,
        isFavorite: true
      )
    ),
    onDetail: {},
    onMessage: {}
  )
  .background(Color(.systemBackground))
}
