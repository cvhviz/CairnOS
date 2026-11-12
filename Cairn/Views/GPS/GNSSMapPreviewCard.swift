import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// A still map with the radio's pin, the phone's dot, and the mesh nodes near them with a known
/// location (contacts, repeaters, rooms and heard nodes, as the main map shows them: its filter
/// and hidden nodes apply), framed to show them all. Only the nearest few within a day's range are
/// shown and framed, so one far-off node can't zoom the preview out. It fills the size the page
/// gives it (after the compass); tapping it opens the GPS tab's Map view, where the map can be
/// moved. Nothing without a radio or phone position to centre on.
struct GNSSMapPreviewCard: View {
  let radio: CLLocationCoordinate2D?
  let phone: CLLocationCoordinate2D?
  /// The nodes the page loaded (`GNSSMapNodesLoader`).
  let nodes: MapViewModel
  let onOpen: () -> Void

  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  /// Settings > Maps > Appearance, which every map follows, this preview included.
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference
  /// The last nearby-node pick, reused until the anchor moves or the nodes change.
  @State private var nearbyMemo = NearbyMemo()

  /// One fixed id: a single radio pin, and a stable id keeps the map from re-adding it.
  private static let radioPointID = UUID(uuidString: "474E5353-5261-6469-6F50-696E00000000")!

  /// The nodes nearest the radio (or, without one, the phone). Memoized: sorting every node by
  /// distance on each phone fix is wasted work while neither the nodes nor the anchor (to about
  /// ten metres) have moved.
  private var nearbyPoints: [MapPoint] {
    guard let anchor = radio ?? phone else { return [] }
    let key = NearbyMemo.Key(anchor: anchor, pointsVersion: nodes.mapPointsVersion)
    if nearbyMemo.key != key {
      nearbyMemo.key = key
      nearbyMemo.points = GNSSMapFraming.nearby(nodes.mapPoints, coordinate: \.coordinate, around: anchor)
    }
    return nearbyMemo.points
  }

  var body: some View {
    let nearby = nearbyPoints
    let region = (radio ?? phone).flatMap { _ in
      GNSSMapFraming.region(for: [radio, phone].compactMap(\.self) + nearby.map(\.coordinate))
    }
    Group {
      if let region {
        card(region: region, nearby: nearby)
      }
    }
  }

  private func card(region: MKCoordinateRegion, nearby: [MapPoint]) -> some View {
    Button(action: onOpen) {
      ZStack(alignment: .topLeading) {
        CairnMapView(
          points: nearby + (radio.map { coordinate in
            [MapPoint(
              id: Self.radioPointID,
              coordinate: coordinate,
              pinStyle: .contactChat,
              label: nil,
              isClusterable: false,
              hopIndex: nil,
              badgeText: nil,
              // The radio's own avatar, as its Device Info header shows it.
              avatar: appState.connectedDevice.map { MapPinAvatar(device: $0, store: appState.radioAvatars) }
            )]
          } ?? []),
          lines: [],
          mapStyle: .standard,
          isDarkMode: resolvedMapIsDark(
          preference: AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system,
          colorScheme: colorScheme
        ),
          isOffline: !appState.offlineMapService.isNetworkAvailable,
          showLabels: false,
          showsUserLocation: phone != nil,
          isInteractive: false,
          showsScale: false,
          hidesAttribution: true,
          isMuted: true,
          cameraRegion: .constant(region),
          cameraRegionVersion: Self.version(of: region),
          onPointTap: { _, _ in onOpen() },
          onMapTap: { _ in onOpen() },
          onCameraRegionChange: nil,
          // The page's own live location already runs at best accuracy; the dot rides on it.
          userLocationAccuracy: kCLLocationAccuracyHundredMeters
        )
        .allowsHitTesting(false)

        HStack(spacing: 5) {
          Image(systemName: "map")
          Text(L10n.Localizable.Tabs.map)
          if !nearby.isEmpty {
            Text("· \(nearby.count)")
              .monospacedDigit()
          }
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(CardStyle.shape)
      .background { CardBackground() }
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Map.Map.Preview.accessibilityLabel)
    .accessibilityValue(nearby.isEmpty ? "" : L10n.Map.Map.Gps.MapPreview.nodeCount(nearby.count))
    .accessibilityHint(L10n.Map.Map.Gps.MapPreview.hint)
    .accessibilityAddTraits(.isButton)
    // Shared with the Map card the page shows without a position: the ways onto the map.
    .accessibilityIdentifier("gps.openMap")
  }

  /// Re-frames the map when either position moves by more than a few metres, not on every fix.
  private static func version(of region: MKCoordinateRegion) -> Int {
    var hasher = Hasher()
    hasher.combine((region.center.latitude * 10_000).rounded())
    hasher.combine((region.center.longitude * 10_000).rounded())
    hasher.combine((region.span.latitudeDelta * 1_000).rounded())
    return hasher.finalize()
  }
}

/// A plain reference box, so the preview can remember its last nearby pick during a render
/// without the write itself invalidating the view.
private final class NearbyMemo {
  struct Key: Equatable {
    /// The anchor to about ten metres (four decimal places).
    let latitude: Double
    let longitude: Double
    let pointsVersion: Int

    init(anchor: CLLocationCoordinate2D, pointsVersion: Int) {
      latitude = (anchor.latitude * 10_000).rounded()
      longitude = (anchor.longitude * 10_000).rounded()
      self.pointsVersion = pointsVersion
    }
  }

  var key: Key?
  var points: [MapPoint] = []
}

/// Keeps a `MapViewModel` on the nodes the main map shows (its filter and hidden nodes apply), for
/// the map preview.
struct GNSSMapNodesLoader: ViewModifier {
  let nodes: MapViewModel

  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.mapFilterMainMap.rawValue) private var mapFilterRaw: String = ""
  @AppStorage(AppStorageKey.hiddenMapNodes.rawValue) private var hiddenMapNodesData = Data()
  /// The hidden nodes' keys for this radio, decoded once per change of the stored list.
  @State private var hiddenNodeKeys: Set<Data> = []

  /// Read only: the Map view migrates and writes the stored filter; this just follows it.
  private var mapFilter: MapFilterState {
    MapFilterPreferences.state(fromRaw: mapFilterRaw, host: .mainMap)
  }

  private func decodeHiddenNodeKeys() -> Set<Data> {
    guard let radioID = appState.currentRadioID else { return [] }
    return HiddenMapNodesStorage.decode(hiddenMapNodesData).publicKeys(for: radioID)
  }

  func body(content: Content) -> some View {
    content
      .task(id: appState.currentRadioID) {
        nodes.configure(
          dataStore: { [appState] in appState.offlineDataStore },
          radioID: { [appState] in appState.currentRadioID },
          selfPublicKey: { [appState] in appState.connectedDevice?.publicKey }
        )
        hiddenNodeKeys = decodeHiddenNodeKeys()
        nodes.setHiddenKeys(hiddenNodeKeys)
        await nodes.loadMapData(filter: mapFilter, showsLoadingChrome: false)
      }
      // New adverts and edits land here; bursts are coalesced by the view model.
      .onChange(of: appState.contactsVersion) { _, _ in
        nodes.scheduleCoalescedReload(filter: mapFilter)
      }
      .onChange(of: mapFilterRaw) { _, _ in
        nodes.scheduleFilterChange(mapFilter)
      }
      .onChange(of: hiddenMapNodesData) { _, _ in
        let keys = decodeHiddenNodeKeys()
        guard keys != hiddenNodeKeys else { return }
        hiddenNodeKeys = keys
        nodes.setHiddenKeys(keys)
      }
      .onDisappear {
        nodes.cancelPendingReload()
      }
  }
}
