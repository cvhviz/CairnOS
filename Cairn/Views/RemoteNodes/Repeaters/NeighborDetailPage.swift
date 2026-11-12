import CoreLocation
import CairnServices
import SwiftUI

/// Which neighbour the Neighbors page opened: one heard now, or one from the last list that's
/// missing from this one. Pushed by value through `navigationDestination(item:)` on that page, so
/// it never mixes with the stack's value routes.
struct NeighborSelection: Hashable, Identifiable {
  let publicKeyPrefix: Data
  let snr: Double
  /// Seconds since the repeater heard it; nil for a past neighbour.
  let secondsAgo: Int?
  /// The SNR in the last list, for the change since.
  let previousSNR: Double?

  var id: Data { publicKeyPrefix }
  var isPast: Bool { secondsAgo == nil }
}

/// One neighbour of a repeater, with everything the app knows about it: where it is (the map
/// header, with its distance and bearing from the repeater for aiming), how the repeater hears it
/// now and over time, and who it is (key, groups, and its full contact page when it's a contact).
/// A neighbour reports only a key prefix, so a node whose advert this phone never heard has just
/// that prefix and its signal.
struct NeighborDetailPage: View {
  let neighbor: NeighborSelection
  /// The repeater it neighbours, whose position the distance and bearing are measured from.
  let session: RemoteNodeSessionDTO
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let userLocation: CLLocation?
  let keyDisplayByteCount: Int
  let maxPlausibleSecondsAgo: Int?
  let fetchSnapshots: @Sendable () async -> [NodeStatusSnapshotDTO]
  /// Takes the neighbour off the repeater's list (`neighbor.remove`); nil for a guest, who can't.
  var onRemove: (() async throws -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @State private var history: [MetricChartView.DataPoint] = []
  @State private var timeRange: HistoryTimeRange = .default
  @State private var showsRemoveConfirmation = false
  @State private var isRemoving = false
  @State private var removeError: String?
  @State private var isAddingContact = false
  @State private var addedContact = false
  @State private var addError: String?

  // MARK: - What's known

  private var contact: ContactDTO? {
    RepeaterResolver.resolve(for: neighbor.publicKeyPrefix, in: contacts, userLocation: userLocation)?.node
  }

  private var discovered: DiscoveredNodeDTO? {
    RepeaterResolver.resolve(for: neighbor.publicKeyPrefix, in: discoveredNodes, userLocation: userLocation)?.node
  }

  private var name: String {
    contact?.displayName ?? discovered?.name
      ?? NeighborNameResolver.fallbackName(for: neighbor.publicKeyPrefix, byteCount: keyDisplayByteCount)
  }

  private var publicKey: Data? {
    contact?.publicKey ?? discovered?.publicKey
  }

  private var type: ContactType {
    contact?.type ?? discovered.flatMap { ContactType(rawValue: $0.typeRawValue) } ?? .repeater
  }

  private var coordinate: CLLocationCoordinate2D? {
    if let contact, contact.hasLocation { return contact.coordinate }
    if let discovered, discovered.hasLocation { return discovered.coordinate }
    return nil
  }

  /// Meters and degrees from the repeater, when both positions are known.
  private var fromRepeater: (distance: CLLocationDistance, bearing: Double)? {
    guard let coordinate, let origin = session.coordinate else { return nil }
    let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
      .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    return (meters, GPSFormat.bearing(from: origin, to: coordinate))
  }

  private var filteredHistory: [MetricChartView.DataPoint] {
    guard let start = timeRange.startDate else { return history }
    return history.filter { $0.date >= start }
  }

  // MARK: - Body

  var body: some View {
    Group {
      if let contact {
        // A contact: its own page, the same one Nodes opens, led by how this repeater hears it.
        // Without Message: it would switch tabs underneath this sheet, where it can't be seen.
        ContactDetailView(contact: contact, showFromDirectChat: true, extraCards: cards(historyPage: true))
      } else {
        unknownNodePage
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          // The route out to the neighbour: this radio → the repeater → it, in Trace Path.
          Button {
            appState.navigation.navigateToTraceRoute([session.publicKey, publicKey ?? neighbor.publicKeyPrefix])
          } label: {
            Label(L10n.RemoteNodes.RemoteNodes.Neighbors.tracePath, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
          }
          .disabled(appState.connectionState != .ready)

          // A node heard in a scan but not yet a contact: add it from here.
          if contact == nil, let discovered {
            Button {
              Task { await addContact(discovered) }
            } label: {
              Label(
                addedContact ? L10n.RemoteNodes.RemoteNodes.Neighbors.addedContact : L10n.RemoteNodes.RemoteNodes.Neighbors.addContact,
                systemImage: addedContact ? "checkmark" : "person.badge.plus"
              )
            }
            .disabled(isAddingContact || addedContact || appState.connectionState != .ready)
          }

          if onRemove != nil {
            Divider()
            Button(role: .destructive) {
              showsRemoveConfirmation = true
            } label: {
              Label(L10n.RemoteNodes.RemoteNodes.Neighbors.remove, systemImage: "person.badge.minus")
            }
            .disabled(isRemoving)
          }
        } label: {
          Label(L10n.Contacts.Contacts.Detail.more, systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("neighbor.more")
      }
    }
    .errorAlert($addError, title: L10n.RemoteNodes.RemoteNodes.Neighbors.addContact)
    .confirmationDialog(
      L10n.RemoteNodes.RemoteNodes.Neighbors.removeConfirm(name),
      isPresented: $showsRemoveConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.RemoteNodes.RemoteNodes.Neighbors.remove, role: .destructive) {
        Task { await remove() }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    }
    .errorAlert($removeError, title: L10n.RemoteNodes.RemoteNodes.Neighbors.remove)
  }

  /// Saves a discovered node as a contact, as the Heard list does.
  private func addContact(_ node: DiscoveredNodeDTO) async {
    guard let contactService = appState.services?.contactService, !isAddingContact else { return }
    isAddingContact = true
    defer { isAddingContact = false }
    do {
      try await contactService.addOrUpdateContact(radioID: node.radioID, contact: node.makeContactFrame())
      addedContact = true
    } catch {
      addError = error.userFacingMessage
    }
  }

  /// Removes the neighbour and leaves the page: it's gone from the list behind it.
  private func remove() async {
    guard let onRemove, !isRemoving else { return }
    isRemoving = true
    defer { isRemoving = false }
    do {
      try await onRemove()
      dismiss()
    } catch {
      removeError = error.userFacingMessage
    }
  }

  /// A node this phone has no contact for: what the repeater reports, and its signal over time.
  private var unknownNodePage: some View {
    CardForm {
      NodeMapHeader(
        coordinate: coordinate,
        marker: type.pinStyle,
        markerPublicKey: publicKey,
        title: name,
        subtitle: NodeRouteFormat.joined([
          type.localizedName,
          neighbor.isPast ? L10n.RemoteNodes.RemoteNodes.History.notSeen : nil,
        ]),
        infoLine: coordinate.map(RemoteNodeHeaderFormat.coordinateText),
        footer: publicKey.map { AnyView(NodeHeaderChips(publicKey: $0)) }
      ) {
        NodeAvatar(
          publicKey: publicKey ?? neighbor.publicKeyPrefix,
          role: type == .room ? .roomServer : .repeater,
          size: NodeMapHeader<EmptyView>.avatarSize
        )
        .accessibilityHidden(true)
      }
      .contextMenu {
        if let coordinate {
          Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
            UIPasteboard.general.string = "\(coordinate.latitude), \(coordinate.longitude)"
          }
          Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
            NodeLocation.openInMaps(name: name, coordinate: coordinate)
          }
        }
      }

      NodeDashboardCardGrid(items: cards(historyPage: false))

      CardFormSection {
        VStack(alignment: .leading, spacing: 10) {
          HistoryTimeRangePicker(selection: $timeRange)
          MetricChartView(
            title: L10n.RemoteNodes.RemoteNodes.History.title,
            unit: "dB",
            dataPoints: filteredHistory,
            accentColor: .blue
          )
        }
        .cardSurface(padding: 12)
      }

    }
    .chartScrubbingScrollLock()
    .flashingNavigationTitle(name)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      let snapshots = await fetchSnapshots()
      history = snapshots.compactMap { snapshot in
        guard let match = snapshot.neighborSnapshots?.first(where: { $0.publicKeyPrefix == neighbor.publicKeyPrefix })
        else { return nil }
        return MetricChartView.DataPoint(id: snapshot.id, date: snapshot.timestamp, value: match.snr)
      }
    }
  }

  /// Signal, last heard, and the distance and bearing from the repeater. On a contact's page the
  /// signal card opens its history; on this page the history is already below.
  private func cards(historyPage: Bool) -> [NodeDashboardCardItem] {
    var items = [
      NodeDashboardCardItem(
        id: "neighbor.signal",
        title: L10n.Tools.Tools.Spectrum.Traffic.snr,
        systemImage: "cellularbars",
        tint: .blue,
        value: NodeDiscoveryFormat.snr(neighbor.snr),
        note: snrChangeCaption,
        destination: historyPage
          ? .page(AnyView(NeighborSNRChartView(
            name: name,
            neighborPrefix: neighbor.publicKeyPrefix,
            fetchSnapshots: fetchSnapshots
          )))
          : .none
      ),
      NodeDashboardCardItem(
        id: "neighbor.heard",
        title: L10n.Contacts.Contacts.Detail.lastHeard,
        systemImage: "ear",
        tint: .teal,
        value: lastHeardText,
        valueTint: neighbor.isPast ? .secondary : .primary,
        destination: .none
      ),
    ]
    if let fromRepeater {
      // From the repeater, not this phone: the line to aim its antenna along.
      items.append(NodeDashboardCardItem(
        id: "neighbor.distance",
        title: L10n.Map.Map.Nav.distance,
        systemImage: "location.north.line",
        tint: .orange,
        value: NodeDiscoveryFormat.distance(fromRepeater.distance),
        details: [GPSFormat.bearingText(fromRepeater.bearing)],
        destination: .none
      ))
    }
    return items
  }

  private var lastHeardText: String {
    guard let secondsAgo = neighbor.secondsAgo else { return L10n.RemoteNodes.RemoteNodes.History.notSeen }
    return NeighborRow.lastSeenText(secondsAgo: secondsAgo, maxPlausible: maxPlausibleSecondsAgo) ?? NodeStatusViewModel.emDash
  }

  /// "+1.5 dB since last" style change, when the last list had this neighbour.
  private var snrChangeCaption: String? {
    guard let previous = neighbor.previousSNR else { return nil }
    let delta = neighbor.snr - previous
    guard abs(delta) >= 0.1 else { return nil }
    return delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " dB"
  }
}
