import CoreLocation
import CairnServices
import SwiftUI

/// The header at the top of a repeater or room server page: a small map on the node's pin with
/// its avatar, name, role and a line of current facts laid over the foot, or the identity band
/// alone when the node has no location. It replaces the large centred avatar header, so the
/// readings start right under it. A page can add a row of action cards under it (`actions`).
/// For the card pages (`CardForm`), which already inset their content to the page margins.
struct RemoteNodeHeaderSection<Actions: View>: View {
  let session: RemoteNodeSessionDTO
  /// Where to center the map; nil shows the header without one.
  let coordinate: CLLocationCoordinate2D?
  var infoLine: String?
  /// How this radio reaches the node ("Direct", "2 hops"), shown after the role.
  var route: String?
  var onTapMap: (() -> Void)?
  /// Shows the pencil beside the name, opening the node's identity settings.
  var onEditTitle: (() -> Void)?
  /// Laid over the map's bottom-right corner.
  var mapOverlay: AnyView?
  /// Against the band's trailing edge, beside "Repeater · Direct": how fresh the page's readings are
  /// (`NodeStatusCapsule`).
  var trailing: AnyView?
  /// More facts in the band's grid after the position (a logged-in repeater's firmware and clock).
  var facts: [NodeHeaderFact] = []
  @ViewBuilder var actions: () -> Actions

  @Environment(\.appState) private var appState
  /// The node's last stored telemetry, for the band's sensor row (read once per page).
  @State private var storedTelemetry: NodeStatusSnapshotDTO?

  init(
    session: RemoteNodeSessionDTO,
    coordinate: CLLocationCoordinate2D?,
    infoLine: String? = nil,
    route: String? = nil,
    onTapMap: (() -> Void)? = nil,
    onEditTitle: (() -> Void)? = nil,
    mapOverlay: AnyView? = nil,
    trailing: AnyView? = nil,
    facts: [NodeHeaderFact] = [],
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) {
    self.trailing = trailing
    self.facts = facts
    self.onEditTitle = onEditTitle
    self.mapOverlay = mapOverlay
    self.session = session
    self.coordinate = coordinate
    self.infoLine = infoLine
    self.route = route
    self.onTapMap = onTapMap
    self.actions = actions
  }

  var body: some View {
    VStack(spacing: CardStyle.spacing) {
      NodeMapHeader(
        coordinate: coordinate,
        marker: session.isRoom ? .contactRoom : .contactRepeater,
        markerPublicKey: session.publicKey,
        title: session.name,
        subtitle: subtitle,
        infoLine: nil,
        onTapMap: onTapMap,
        onEditTitle: onEditTitle,
        // As Device Info lays out the connected radio: the position and distance with the key
        // opposite, then the node's sensors from its last telemetry.
        footer: AnyView(NodeHeaderFacts(
          coordinates: coordinate.map(RemoteNodeHeaderFormat.coordinateText),
          distance: coordinate.flatMap {
            NodeRouteFormat.distance(from: appState.bestAvailableLocation, latitude: $0.latitude, longitude: $0.longitude)
          },
          facts: facts,
          sensorGroups: storedTelemetry.map { DeviceSensorChipGroup.groups(from: $0.telemetryEntries ?? []) } ?? [],
          sensorsAge: storedTelemetry.map { RelativeTimestampText.format(date: $0.timestamp, relativeTo: .now) }
        ) {
          EmptyView()
        }),
        chips: AnyView(NodeHeaderChips(publicKey: session.publicKey, compact: true)),
        mapOverlay: mapOverlay,
        trailing: trailing
      ) {
        NodeAvatar(publicKey: session.publicKey, role: session.role, size: NodeMapHeader<EmptyView>.avatarSize)
          .accessibilityHidden(true)
      }
      // The location lives on the map: its coordinates are in the info line, and a long press
      // copies them or opens them in Maps, as the Details card's Location row did.
      .contextMenu {
        if let coordinate {
          Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
            UIPasteboard.general.string = "\(coordinate.latitude), \(coordinate.longitude)"
          }
          Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
            NodeLocation.openInMaps(name: session.name, coordinate: coordinate)
          }
        }
      }
      actions()
    }
    .task(id: session.publicKey) {
      storedTelemetry = await appState.services?.nodeSnapshotService
        .fetchSnapshots(for: session.publicKey)
        .last { $0.telemetryEntries?.isEmpty == false }
    }
  }

  /// The role and the route ("Repeater · Direct"), and the guest notice the old header carried,
  /// so a guest login still says so.
  private var subtitle: String {
    let role = session.isRoom ? ContactType.room.localizedName : ContactType.repeater.localizedName
    var parts = [role]
    if let route, !route.isEmpty { parts.append(route) }
    if session.permissionLevel == .guest { parts.append(L10n.RemoteNodes.RemoteNodes.Status.guestMode) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Header Facts

/// What the header says about the node, worked out from whatever the page has loaded.
enum RemoteNodeHeaderFormat {
  /// Joins the facts that are known ("1.2 km away · 37.7749, -122.4194"), or nil when none are.
  /// The route and the battery aren't among them: the dashboard has a row for one and a card for
  /// the other.
  static func infoLine(
    coordinate: CLLocationCoordinate2D?,
    userLocation: CLLocation?
  ) -> String? {
    var facts: [String] = []
    if let coordinate {
      if let distance = NodeRouteFormat.distanceAway(
        from: userLocation,
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      ) {
        facts.append(distance)
      }
      facts.append(coordinateText(coordinate))
    }
    return facts.isEmpty ? nil : facts.joined(separator: " · ")
  }

  /// "37.7749, -122.4194": four decimals, about ten metres, as the Location row showed it.
  static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
    "\(coordinate.latitude.formatted(.number.precision(.fractionLength(4)))), "
      + "\(coordinate.longitude.formatted(.number.precision(.fractionLength(4))))"
  }

  /// A typed coordinate pair as a map location: nil while unloaded, and for the (0, 0) the
  /// firmware reports when no location is set, matching `RemoteNodeSessionDTO.hasLocation`.
  static func coordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
    guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
  }
}

extension View {
  /// Pushes the GPS map, opened on the node, when the header map is tapped. Pushed rather than
  /// presented: these pages are often sheets already, and a sheet on a sheet collapses both.
  /// Apply to the page hosting the header, not to a view inside it.
  func remoteNodeLocationMap(
    isPresented: Binding<Bool>,
    session: RemoteNodeSessionDTO,
    coordinate: CLLocationCoordinate2D?
  ) -> some View {
    navigationDestination(isPresented: isPresented) {
      if let coordinate {
        NodeOnMapView(focus: .node(publicKey: session.publicKey, coordinate: coordinate), title: session.name)
      }
    }
  }
}
