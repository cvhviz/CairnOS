import CairnServices
import SwiftUI

// MARK: - Path Summary Label

/// The collapsed one-line route summary (`A3 → 7F → 42`, or `Direct`).
struct NodePathSummaryLabel: View {
  let contact: ContactDTO

  private var pathDisplayText: String {
    contact.pathHopCount == 0 ? L10n.Contacts.Contacts.Route.direct : contact.pathString
  }

  private var pathAccessibilityLabel: String {
    contact.pathHopCount == 0
      ? L10n.Contacts.Contacts.Detail.routeDirect
      : L10n.Contacts.Contacts.Detail.routePrefix(pathDisplayText)
  }

  var body: some View {
    Label {
      Text(pathDisplayText)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
        .lineLimit(nil)
    } icon: {
      Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .accessibilityLabel(pathAccessibilityLabel)
  }
}

// MARK: - Path Hop Row

/// A single expanded hop: hash hex plus the resolved repeater name, with a possible-match indicator
/// when the name was matched only by a short prefix.
struct NodePathHopRow: View {
  let hex: String
  let resolution: NodeNameResolution

  var body: some View {
    HStack(spacing: 6) {
      Text(hex)
        .font(.body.monospaced())
        .foregroundStyle(.secondary)

      Text(resolution.displayName)

      if resolution.matchKind == .fallback {
        FallbackMatchIndicatorView(
          accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.possibleMatch,
          accessibilityHint: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchExplanation,
          title: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchTitle,
          explanation: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchExplanation
        )
      }
    }
    .accessibilityElement(children: .combine)
  }
}
