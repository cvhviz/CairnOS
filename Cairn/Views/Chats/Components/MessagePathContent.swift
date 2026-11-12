import CoreLocation
import CairnServices
import SwiftUI

/// Hop list for one arrival: sender, hops, receiver, and copyable path hex.
struct MessagePathContent: View {
  let message: MessageDTO
  let arrival: MessagePathArrival
  let viewModel: MessagePathViewModel
  let receiverName: String
  let userLocation: CLLocation?

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var copyHapticTrigger = 0

  var body: some View {
    if viewModel.isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    } else if arrival.isDirectRoute {
      // Not sender → receiver: that would read as heard directly.
      ContentUnavailableView(
        L10n.Chats.Chats.Path.DirectRoute.title,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        description: Text(L10n.Chats.Chats.Path.DirectRoute.description)
      )
    } else if arrival.isPathUnavailable {
      ContentUnavailableView(
        L10n.Chats.Chats.Path.Unavailable.title,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        description: Text(L10n.Chats.Chats.Path.Unavailable.description)
      )
    } else {
      let senderResolution = viewModel.senderResolution(for: message, localDeviceName: receiverName)
      let pathHops = arrival.pathHops
      // Named only by what this radio heard on its channel, as the RX Log list names them
      let relays = viewModel.relays(for: arrival)

      PathHopRowView(
        hopType: .sender,
        nodeName: senderResolution.displayName,
        nodeID: viewModel.senderNodeID(for: message),
        snr: nil,
        matchKind: senderResolution.matchKind
      )

      ForEach(Array(pathHops.enumerated()), id: \.offset) { index, hop in
        let match = relays.indices.contains(index) ? relays[index] : .unknown(hop.data)
        let repeaterResolution = viewModel.repeaterResolution(for: match)
        let repeaterContact = viewModel.repeaterContact(for: match)
        PathHopRowView(
          hopType: .intermediate(index + 1),
          nodeName: repeaterResolution.displayName,
          nodeID: hop.hex,
          snr: nil,
          matchKind: repeaterResolution.matchKind,
          hint: viewModel.unknownHint(for: match, receivedAt: arrival.receivedAt),
          onOpenContact: repeaterContact.map { contact in { openContact(contact) } }
        )
      }

      PathHopRowView(
        hopType: .receiver,
        nodeName: receiverName,
        nodeID: nil,
        snr: arrival.snr
      )

      if !pathHops.isEmpty {
        HStack {
          Button(L10n.Chats.Chats.Path.copyButton, systemImage: "doc.on.doc") {
            copyHapticTrigger += 1
            UIPasteboard.general.string = arrival.pathStringForClipboard
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .accessibilityLabel(L10n.Chats.Chats.Path.copyAccessibility)
          .accessibilityHint(L10n.Chats.Chats.Path.copyHint)

          Text(arrival.pathString)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

          Spacer()

          // From this radio outward: a message heard here ran the path toward us.
          Button(L10n.Contacts.Contacts.Detail.traceRoute, systemImage: "point.3.connected.trianglepath.dotted") {
            let hops = pathHops.map(\.data)
            dismiss()
            appState.navigation.navigateToTraceRoute(message.isOutgoing ? hops : hops.reversed())
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
        }
        .padding(.top, 8)
        .sensoryFeedback(.success, trigger: copyHapticTrigger)
      }
    }
  }

  /// Same route as mention and contact-link taps. The actions sheet goes first so the
  /// detail does not open underneath it.
  private func openContact(_ contact: ContactDTO) {
    dismiss()
    appState.navigation.navigateToContactDetail(contact)
  }
}
