import SwiftUI

/// A small card over the map when there is nothing to show on it: no radio connected, or no
/// node with a position yet, each with what would change that. The map stays usable behind it,
/// and it can be put away.
struct MapEmptyStateCard: View {
  enum Reason: Equatable {
    case noRadio
    case noLocatedNodes
  }

  let reason: Reason
  let onSendAdvert: () -> Void
  let onScan: () -> Void
  let onConnect: () -> Void
  let onDismiss: () -> Void

  private var title: String {
    switch reason {
    case .noRadio: L10n.Map.Map.Empty.NoRadio.title
    case .noLocatedNodes: L10n.Map.Map.Empty.NoNodes.title
    }
  }

  private var message: String {
    switch reason {
    case .noRadio: L10n.Map.Map.Empty.NoRadio.message
    case .noLocatedNodes: L10n.Map.Map.Empty.NoNodes.message
    }
  }

  private var symbol: String {
    switch reason {
    case .noRadio: "antenna.radiowaves.left.and.right.slash"
    case .noLocatedNodes: "mappin.slash"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 4)
        Button(action: onDismiss) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Map.Map.Empty.dismiss)
      }

      HStack(spacing: 8) {
        switch reason {
        case .noRadio:
          Button(L10n.Settings.Device.connect, systemImage: "antenna.radiowaves.left.and.right", action: onConnect)
            .buttonStyle(.borderedProminent)
        case .noLocatedNodes:
          Button(L10n.Map.Map.Callout.sendAdvert, systemImage: "megaphone.fill", action: onSendAdvert)
            .buttonStyle(.borderedProminent)
          Button(L10n.Tools.Tools.nodeDiscovery, systemImage: "dot.radiowaves.left.and.right", action: onScan)
            .buttonStyle(.bordered)
        }
      }
      .controlSize(.small)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
    }
    .padding(14)
    .frame(maxWidth: 360)
    .liquidGlass(in: .rect(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
  }
}

#Preview {
  VStack(spacing: 20) {
    MapEmptyStateCard(reason: .noLocatedNodes, onSendAdvert: {}, onScan: {}, onConnect: {}, onDismiss: {})
    MapEmptyStateCard(reason: .noRadio, onSendAdvert: {}, onScan: {}, onConnect: {}, onDismiss: {})
  }
  .padding()
  .background(Color.gray.opacity(0.3))
}
