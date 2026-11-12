import CairnServices
import SwiftUI

/// Lightweight read-only detail for a discovered node, with Add to Nodes.
struct DiscoveredNodeDetailSheet: View {
  /// `dismiss`, or on a Mac where this page is its own window, closing that window.
  @CloseDetail private var closeDetail
  @Environment(\.appState) private var appState
  let node: DiscoveredNodeDTO
  let isAdding: Bool
  let onAdd: () -> Void
  /// Hides the node from the Map tab; nil on maps that do not offer hiding.
  var onHide: (() -> Void)?
  /// Shown in the Nodes tab's iPad detail column (`ContactsDetailColumn`), inside that column's
  /// own stack: no stack or Done of its own, as a saved node's page there has none.
  var isInColumn = false
  /// The header's map at the node's position, which a tap opens full screen: on the Nodes tab, as a
  /// saved node's page has it there. Off where the page opens over a map or a tool (the Map tab,
  /// Traffic, Scan, the RX log, a mention), as a saved node's sheet is there.
  var showsMap = false

  @State private var showingHideConfirmation = false
  @State private var showFullMap = false
  /// The last packet the RX log holds from the node, for the Signal card.
  @State private var heardPacket: RxLogEntryDTO?

  var body: some View {
    if isInColumn {
      page
        .navigationBarTitleDisplayMode(.inline)
    } else {
      NavigationStack {
        page
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button(L10n.Map.Map.Common.done) {
                closeDetail()
              }
              .keyboardShortcut(.defaultAction)
            }
          }
      }
    }
  }

  /// How the node was heard ("Direct", "2 hops"), for the subtitle.
  private var discoveredRoute: String? {
    NodeRouteFormat.routeLabel(
      isFloodRouted: node.isFloodRouted,
      pathHopCount: node.pathHopCount,
      displayedHopCount: node.displayedHopCount
    )
  }

  private var page: some View {
      CardForm {
        // Who and where, then what can be done with it, as on a saved node's page: the map at its
        // position (on the Nodes tab; a tap opens it full screen), the type and route, and the
        // distance and coordinates, which a long press copies or opens in Maps. The bar's title
        // already says the node was discovered.
        VStack(spacing: CardStyle.spacing) {
          NodeMapHeader(
            coordinate: showsMap && node.hasLocation ? node.coordinate : nil,
            marker: pinStyle,
            title: node.name,
            subtitle: NodeRouteFormat.joined([node.nodeType.localizedName, discoveredRoute]),
            infoLine: nil,
            onTapMap: showsMap && node.hasLocation ? { showFullMap = true } : nil,
            // As a saved node's header has it (and Device Info's): the position and distance with
            // the key opposite; when it was heard and its route at the trailing edge.
            footer: AnyView(NodeHeaderFacts(
              coordinates: node.hasLocation ? RemoteNodeHeaderFormat.coordinateText(node.coordinate) : nil,
              distance: node.hasLocation
                ? NodeRouteFormat.distance(
                  from: appState.bestAvailableLocation,
                  latitude: node.latitude,
                  longitude: node.longitude
                )
                : nil
            ) {
              EmptyView()
            }),
            chips: AnyView(NodeHeaderChips(publicKey: node.publicKey, compact: true)),
            trailing: AnyView(NodeHeardStatus(lastHeard: node.lastHeard, route: discoveredRoute))
          ) {
            avatar
              .accessibilityHidden(true)
          }
          .contextMenu {
            if node.hasLocation {
              Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
                UIPasteboard.general.string = "\(node.latitude), \(node.longitude)"
              }
              Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
                NodeLocation.openInMaps(name: node.name, coordinate: node.coordinate)
              }
            }
          }

          NodeActionTileRow(count: onHide == nil ? 1 : 2) {
            Button {
              onAdd()
            } label: {
              NodeActionTile(L10n.Map.Map.DiscoveredDetail.add, systemImage: "plus.circle.fill", isBusy: isAdding)
            }
            .disabled(isAdding)

            // A map preference, so it works without a radio connection.
            if let onHide {
              Button {
                showingHideConfirmation = true
              } label: {
                NodeActionTile(
                  L10n.Map.Map.Detail.Action.hide,
                  systemImage: "eye.slash",
                  accessibilityTitle: L10n.Map.Map.HiddenNodes.hide
                )
              }
              .hideFromMapConfirmation(name: node.name, isPresented: $showingHideConfirmation) {
                closeDetail()
                onHide()
              }
            }
          }
          .buttonStyle(.plain)
        }

        // Status, in the Dashboard's card style: when it last advertised, and how it was heard
        // (the last packet, and both directions for a neighbour, as Scan & Traffic lists them),
        // which opens in full. An unsaved node has no stored history. The header says the type,
        // route and distance, and holds the key, so there's no Details section. No section title;
        // a section's gap under the action tiles, as on a contact's page.
        TimelineView(.everyMinute) { context in
          NodeDashboardCardGrid(items: statusCards(now: context.date))
        }
      }
      .task(id: node.publicKey) { await loadHeardPacket() }
      .flashingNavigationTitle(L10n.Map.Map.DiscoveredDetail.title)
      .navigationBarTitleDisplayMode(.inline)
      // The header map full screen, with this node selected, as a saved node's page opens it.
      .nodeMapPresentation(isPresented: $showFullMap) { presented in
        NodeOnMapView(
          focus: .node(publicKey: node.publicKey, coordinate: node.coordinate),
          title: node.name,
          isPresented: presented
        )
      }
  }

  /// The outlined pin a heard node has on the maps, by its type.
  private var pinStyle: MapPoint.PinStyle {
    switch node.nodeType {
    case .chat: .discoveredChat
    case .repeater: .discoveredRepeater
    case .room: .discoveredRoom
    }
  }

  // MARK: Status

  /// Last Advert, then Signal where the RX log or the neighbour directory heard the node.
  private func statusCards(now: Date) -> [NodeDashboardCardItem] {
    var cards = [lastAdvertCard(now: now)]
    let link = NodeLinkSignal(publicKey: node.publicKey, directory: appState.neighbourDirectory, now: now)
    if heardPacket != nil || link != nil {
      cards.append(.heardSignal(
        packet: heardPacket,
        // The relays named only by what this radio heard on the packet's channel.
        heardPath: heardPacket.flatMap {
          NodeHeardSignal.heardPath(of: $0, maxShown: .max, in: appState.observationDirectory.index(for: $0))
        },
        link: link,
        history: nil,
        now: now
      ))
    }
    return cards
  }

  /// How long ago it last advertised, with the date and time. Opens nothing.
  private func lastAdvertCard(now: Date) -> NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "lastAdvert",
      title: L10n.Map.Map.Detail.lastAdvert,
      systemImage: "antenna.radiowaves.left.and.right",
      tint: .teal,
      value: RelativeTimestampText.format(date: node.lastHeard, relativeTo: now),
      details: [node.lastHeard.formatted(date: .abbreviated, time: .shortened)],
      destination: .none
    )
  }

  private func loadHeardPacket() async {
    guard let services = appState.services else { return }
    let entries = await services.rxLogService.recentEntries(since: .distantPast)
    heardPacket = NodeHeardSignal.latest(
      in: entries,
      publicKey: node.publicKey,
      selfKey: appState.connectedDevice?.publicKey
    )
  }

  @ViewBuilder
  private var avatar: some View {
    let size = NodeMapHeader<EmptyView>.avatarSize
    switch node.nodeType {
    case .chat:
      CompanionAvatar(name: node.name, publicKey: node.publicKey, size: size)
    case .repeater:
      NodeAvatar(publicKey: node.publicKey, role: .repeater, size: size, name: node.name)
    case .room:
      NodeAvatar(publicKey: node.publicKey, role: .roomServer, size: size, name: node.name)
    }
  }
}
