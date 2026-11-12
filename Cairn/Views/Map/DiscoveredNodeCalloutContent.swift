import CairnServices
import SwiftUI

/// A discovered (not yet added) map pin's callout: its name (which opens its details, where it can
/// also be hidden from the map) over its kind, with Add.
struct DiscoveredNodeCalloutContent: View {
  @Environment(\.appState) private var appState
  let node: DiscoveredNodeDTO
  let isAdding: Bool
  let onDetail: () -> Void
  let onAdd: () -> Void
  /// In the map's navigation panel, under its name and distance: no title of its own, an info button.
  var inPanel = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !inPanel {
        MapCalloutTitleButton(
          prefix: idPrefixHex,
          name: node.name,
          accessibilityName: "\(L10n.Map.Map.Callout.discovered), \(node.name)",
          action: onDetail
        )
      }

      HStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: node.nodeType.iconSystemName)
            .foregroundStyle(node.nodeType.displayColor)
          Text("\(typeDisplayName) · \(L10n.Map.Map.Callout.discovered)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(typeDisplayName), \(L10n.Map.Map.Pin.Accessibility.discovered)")
        Spacer(minLength: 12)

        if inPanel {
          Button(action: onDetail) { Label { Text(L10n.Map.Map.Callout.details) } icon: { MapCalloutIcon(systemImage: "info") } }
            .mapCalloutIconButton()
            .accessibilityHint(node.name)
        }

        Button(action: onAdd) { Label { Text(L10n.Map.Map.Callout.add) } icon: { MapCalloutIcon(systemImage: "plus") } }
          .mapCalloutIconButton()
          .disabled(isAdding)
          .accessibilityHint(node.name)

        MapCalloutActionsMenu(name: node.name, coordinate: node.coordinate)
      }
    }
    .padding(inPanel ? 0 : 12)
    .frame(minWidth: 160)
  }

  private var idPrefixHex: String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    return node.publicKey.prefix(hashSize).uppercaseHexString()
  }

  private var typeDisplayName: String {
    switch node.nodeType {
    case .chat:
      L10n.Map.Map.Callout.NodeKind.contact
    case .repeater:
      L10n.Map.Map.Callout.NodeKind.repeater
    case .room:
      L10n.Map.Map.Callout.NodeKind.room
    }
  }
}
