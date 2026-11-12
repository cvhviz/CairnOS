import CoreLocation
import CryptoKit
import MapKit
import MapLibre
import CairnServices
import SwiftUI

struct MessagePathMapView: View {
  /// Span used when the path resolves to a single node, with no bounding box to fit.
  private static let singleNodeSpanDelta: CLLocationDegrees = 0.05
  /// Padding around the multi-node bounding region, wider than `boundingRegion`'s
  /// 1.5 default to keep the path clear of the floating map-controls toolbar.
  private static let pathBoundingPaddingMultiplier: Double = 2.5
  /// Stable annotation identity for the receiver pin across canvas rebuilds.
  private static let receiverPointID = pointID(namespace: "message-path-receiver", bytes: Data())
  private static let capsuleHorizontalPadding: CGFloat = 16
  private static let capsuleBottomPadding: CGFloat = 8
  /// Space above the capsules so the MapLibre logo and attribution stay visible.
  private static let legalOrnamentGap: CGFloat = 18

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let message: MessageDTO
  let arrivals: [MessagePathArrival]
  @Binding var selectedID: UUID?
  let pathViewModel: MessagePathViewModel

  @State private var cameraRegion: MKCoordinateRegion?
  @State private var cameraRegionVersion = 0
  @State private var mapStyle: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @State private var showLabels = true
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  @State private var hasInitiallyFit = false
  @State private var shareItem: PathMapShareItem?
  @State private var isRenderingShareImage = false
  @State private var capsuleBarHeight: CGFloat = 0
  @State private var bottomSafeArea: CGFloat = 0

  struct CanvasModel {
    let points: [MapPoint]
    let lines: [MapLine]
    let cameraRegion: MKCoordinateRegion?
    let locatedCount: Int
    let selectedCoordinates: [CLLocationCoordinate2D]
    let hopCount: Int
    let isDistanceIncomplete: Bool
    /// The selected arrival came over a direct route, whose hops the packet doesn't carry.
    var isDirectRoute = false

    /// Endpoint pins alone are not a path. A single hop pin with skipped hops is a shortcut, not the path.
    /// A direct route has no hops to draw, and a sender-to-radio line would read as heard directly.
    var showsPathMap: Bool {
      if isDirectRoute { return false }
      if hopCount == 0 { return locatedCount >= 1 }
      let placedHopCount = points.filter { $0.pinStyle == .repeaterHop }.count
      if placedHopCount == 0 { return false }
      if placedHopCount == 1, isDistanceIncomplete { return false }
      return true
    }
  }

  private var canvas: CanvasModel {
    Self.canvasModel(
      message: message,
      arrivals: arrivals,
      selectedID: selectedID,
      pathViewModel: pathViewModel,
      connectedDevice: appState.connectedDevice,
      userLocation: appState.bestAvailableLocation
    )
  }

  var body: some View {
    // Built once per pass: the model resolves a contact or repeater for every hop, and
    // camera updates re-run this body on each frame of a pan.
    let canvas = canvas
    NavigationStack {
      Group {
        if pathViewModel.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !canvas.showsPathMap {
          ContentUnavailableView(
            pathMapUnavailableTitle(for: canvas),
            systemImage: "map",
            description: Text(pathMapUnavailableDescription(for: canvas))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          mapCanvas(canvas)
        }
      }
      .toolbar {
        if canvas.showsPathMap {
          ToolbarItem(placement: .principal) {
            PathDistanceBanner(
              hopCount: canvas.hopCount,
              totalPathDistance: canvas.selectedCoordinates.totalDistance(),
              isDistanceIncomplete: canvas.isDistanceIncomplete
            )
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
          .keyboardShortcut(.defaultAction)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .sheet(item: $shareItem) { item in
        ActivityView(activityItems: [item.image])
      }
      .onChange(of: pathViewModel.isLoading) { _, isLoading in
        guard !isLoading else { return }
        completeInitialFitIfNeeded()
      }
      .onChange(of: isStyleLoaded) { _, loaded in
        guard loaded else { return }
        completeInitialFitIfNeeded()
      }
      .onChange(of: canvas.selectedCoordinates.count) { _, _ in
        completeInitialFitIfNeeded()
      }
      .onChange(of: capsuleBarHeight) { _, _ in
        completeInitialFitIfNeeded()
      }
      .onChange(of: bottomSafeArea) { _, _ in
        completeInitialFitIfNeeded()
      }
    }
  }

  /// Renders the path as it is framed now (pins, line, and the current camera)
  /// into an image and hands it to the share sheet.
  private func shareMapImage() async {
    isRenderingShareImage = true
    defer { isRenderingShareImage = false }
    let image = await MapSnapshotRenderer().render(
      points: canvas.points,
      line: canvas.lines.first,
      region: cameraRegion ?? canvas.cameraRegion,
      size: PathMapShareItem.imageSize,
      isDark: colorScheme == .dark,
      isOffline: !appState.offlineMapService.isNetworkAvailable,
      appearance: MapAvatarAppearance(theme: theme, colorScheme: colorScheme, contrast: colorSchemeContrast)
    )
    if let image {
      shareItem = PathMapShareItem(image: image)
    }
  }

  private func pathMapUnavailableTitle(for canvas: CanvasModel) -> String {
    if canvas.isDirectRoute { return L10n.Chats.Chats.Path.DirectRoute.title }
    return canvas.hopCount == 0
      ? L10n.Chats.Chats.Path.Unavailable.title
      : L10n.Chats.Chats.Path.Unplaceable.title
  }

  private func pathMapUnavailableDescription(for canvas: CanvasModel) -> String {
    if canvas.isDirectRoute { return L10n.Chats.Chats.Path.DirectRoute.description }
    return canvas.hopCount == 0
      ? L10n.Chats.Chats.Path.Unavailable.description
      : L10n.Chats.Chats.Path.Unplaceable.description
  }

  private func mapCanvas(_ canvas: CanvasModel) -> some View {
    ZStack(alignment: .bottom) {
      CairnMapView(
        points: canvas.points,
        lines: canvas.lines,
        mapStyle: mapStyle,
        isDarkMode: colorScheme == .dark,
        showLabels: showLabels,
        clusteringEnabled: false,
        showsUserLocation: false,
        isInteractive: true,
        showsScale: true,
        isNorthLocked: isNorthLocked,
        cameraRegion: $cameraRegion,
        cameraRegionVersion: cameraRegionVersion,
        cameraEdgePadding: pathCameraEdgePadding,
        legalOrnamentBottomMargin: pathLegalOrnamentBottomMargin,
        onPointTap: nil,
        onMapTap: nil,
        onCameraRegionChange: { cameraRegion = $0 },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser
      )
      // Path swaps must not run inside the capsule selection animation.
      .transaction { $0.animation = nil }
      .ignoresSafeArea()

      VStack(spacing: 0) {
        HStack {
          Spacer()
          MapControlsToolbar(
            onLocationTap: centerOnUserLocation,
            isCenteredOnUser: isCenteredOnUser,
            isNorthLocked: $isNorthLocked,
            showLabels: $showLabels,
            mapStyleSelection: $mapStyle,
            viewportBounds: cameraRegion?.toMLNCoordinateBounds()
          ) {
            if canvas.showsPathMap {
              Button(L10n.Chats.Chats.Path.centerOnPath, systemImage: "arrow.up.left.and.arrow.down.right") {
                isCenteredOnUser = false
                fitCameraToSelectedPath()
              }
              .mapControlButton(tint: .primary)

              Button(L10n.Chats.Chats.Path.shareImage, systemImage: "square.and.arrow.up") {
                Task { await shareMapImage() }
              }
              .mapControlButton(tint: isRenderingShareImage ? .secondary : .primary)
              .disabled(isRenderingShareImage)
            }
          }
        }
        if showsArrivalCapsules {
          MessagePathArrivalCapsules(
            arrivals: arrivals,
            selectedID: $selectedID,
            reduceMotion: reduceMotion,
            chrome: .glass
          )
          .padding(.horizontal, Self.capsuleHorizontalPadding)
          .padding(.bottom, Self.capsuleBottomPadding)
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
          } action: { height in
            guard height > 0, height != capsuleBarHeight else { return }
            capsuleBarHeight = height
          }
        }
      }
      .safeAreaPadding(.bottom)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.safeAreaInsets.bottom
    } action: { bottom in
      guard bottom != bottomSafeArea else { return }
      bottomSafeArea = bottom
    }
  }

  private var showsArrivalCapsules: Bool {
    arrivals.count > 1
  }

  private var capsuleOverlayHeight: CGFloat {
    capsuleBarHeight > 0 ? capsuleBarHeight : Self.estimatedCapsuleBarHeight
  }

  private var pathLegalOrnamentBottomMargin: CGFloat? {
    guard showsArrivalCapsules else { return nil }
    return Self.legalOrnamentBottomMargin(capsuleBarHeight: capsuleOverlayHeight)
  }

  private var pathCameraEdgePadding: UIEdgeInsets {
    guard showsArrivalCapsules else { return .zero }
    return UIEdgeInsets(
      top: 0,
      left: 0,
      bottom: Self.pathCameraBottomInset(
        safeAreaBottom: bottomSafeArea,
        capsuleBarHeight: capsuleOverlayHeight
      ),
      right: 0
    )
  }

  private static var estimatedCapsuleBarHeight: CGFloat {
    let title = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
    let subtitle = UIFont.preferredFont(forTextStyle: .caption2).lineHeight
    return MessagePathArrivalCapsules.pillVerticalPadding * 2
      + title
      + subtitle
      + MessagePathArrivalCapsules.subtitleSpacing
      + capsuleBottomPadding
  }

  private static func legalOrnamentBottomMargin(capsuleBarHeight: CGFloat) -> CGFloat {
    capsuleBarHeight + legalOrnamentGap
  }

  private static func pathCameraBottomInset(safeAreaBottom: CGFloat, capsuleBarHeight: CGFloat) -> CGFloat {
    safeAreaBottom + capsuleBarHeight
  }

  /// Frames the selected path once after style load. Later path taps leave the camera.
  private func completeInitialFitIfNeeded() {
    guard !hasInitiallyFit, isStyleLoaded else { return }
    guard !canvas.selectedCoordinates.isEmpty else { return }
    // Camera edge padding uses the measured capsule bar; fitting first puts the path under the pills.
    if showsArrivalCapsules, capsuleBarHeight == 0 { return }
    hasInitiallyFit = true
    fitCameraToSelectedPath()
  }

  private func fitCameraToSelectedPath() {
    let coords = canvas.selectedCoordinates
    if coords.count == 1 {
      cameraRegion = MKCoordinateRegion(
        center: coords[0],
        span: MKCoordinateSpan(
          latitudeDelta: Self.singleNodeSpanDelta,
          longitudeDelta: Self.singleNodeSpanDelta
        )
      )
    } else if let region = coords.boundingRegion(paddingMultiplier: Self.pathBoundingPaddingMultiplier) {
      cameraRegion = region
    } else {
      return
    }
    cameraRegionVersion += 1
  }

  private func centerOnUserLocation() {
    guard let location = appState.bestAvailableLocation else {
      appState.locationService.requestLocation()
      return
    }
    isCenteredOnUser = true
    cameraRegion = MKCoordinateRegion(
      center: location.coordinate,
      span: MKCoordinateSpan(
        latitudeDelta: Self.singleNodeSpanDelta,
        longitudeDelta: Self.singleNodeSpanDelta
      )
    )
    cameraRegionVersion += 1
  }

  static func canvasModel(
    message: MessageDTO,
    arrivals: [MessagePathArrival],
    selectedID: UUID?,
    pathViewModel: MessagePathViewModel,
    connectedDevice: DeviceDTO?,
    userLocation: CLLocation?
  ) -> CanvasModel {
    let selected = MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals)
    let sender = pathViewModel.locatedSender(for: message)
    let receiverLocation: CLLocation? = if let device = connectedDevice, device.hasLocation {
      CLLocation(latitude: device.latitude, longitude: device.longitude)
    } else {
      userLocation
    }

    var points: [MapPoint] = []
    var seenKeys = Set<Data>()
    let start: CLLocationCoordinate2D?
    if message.isOutgoing, let device = connectedDevice, device.hasLocation {
      let coord = CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude)
      start = coord
      points.append(MapPoint(
        id: device.id,
        coordinate: coord,
        pinStyle: .pointA,
        label: device.nodeName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ))
      seenKeys.insert(device.publicKey)
    } else if let sender {
      let coord = CLLocationCoordinate2D(latitude: sender.latitude, longitude: sender.longitude)
      start = coord
      points.append(MapPoint(
        id: sender.id,
        coordinate: coord,
        pinStyle: .pointA,
        label: sender.displayName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ))
      seenKeys.insert(sender.publicKey)
    } else {
      start = nil
    }

    var lines: [MapLine] = []
    var selectedCoordinates: [CLLocationCoordinate2D] = []
    var selectedHopCount = 0
    var isDistanceIncomplete = false
    var isDirectRoute = false

    if let selectedArrival = arrivals.first(where: { $0.id == selected }) {
      let path = locatedPath(
        arrival: selectedArrival,
        start: start,
        pathViewModel: pathViewModel,
        receiverLocation: receiverLocation
      )
      selectedCoordinates = path.coordinates
      selectedHopCount = selectedArrival.hopCount ?? 0
      isDistanceIncomplete = path.isDistanceIncomplete
      isDirectRoute = selectedArrival.isDirectRoute
      if path.coordinates.count >= 2, !isDirectRoute {
        lines.append(MapLine(
          id: "message-path-\(selectedArrival.id)",
          coordinates: path.coordinates,
          style: .messagePath,
          opacity: 1.0
        ))
      }
      for point in path.hopPoints where seenKeys.insert(point.key).inserted {
        points.append(point.point)
      }
    }

    if let loc = receiverLocation {
      let coord = loc.coordinate
      points.append(MapPoint(
        id: receiverPointID,
        coordinate: coord,
        pinStyle: .pointB,
        label: connectedDevice?.nodeName,
        isClusterable: false,
        hopIndex: nil,
        badgeText: nil
      ))
    }

    let camera: MKCoordinateRegion? = if selectedCoordinates.count == 1 {
      MKCoordinateRegion(
        center: selectedCoordinates[0],
        span: MKCoordinateSpan(
          latitudeDelta: singleNodeSpanDelta,
          longitudeDelta: singleNodeSpanDelta
        )
      )
    } else {
      selectedCoordinates.boundingRegion(paddingMultiplier: pathBoundingPaddingMultiplier)
    }

    return CanvasModel(
      points: points,
      lines: lines,
      cameraRegion: camera,
      locatedCount: points.count,
      selectedCoordinates: selectedCoordinates,
      hopCount: selectedHopCount,
      isDistanceIncomplete: isDistanceIncomplete,
      isDirectRoute: isDirectRoute
    )
  }

  private struct LocatedPath {
    let coordinates: [CLLocationCoordinate2D]
    let hopPoints: [(key: Data, point: MapPoint)]
    let isDistanceIncomplete: Bool
  }

  private static func locatedPath(
    arrival: MessagePathArrival,
    start: CLLocationCoordinate2D?,
    pathViewModel: MessagePathViewModel,
    receiverLocation: CLLocation?
  ) -> LocatedPath {
    var coordinates: [CLLocationCoordinate2D] = []
    var hopPoints: [(key: Data, point: MapPoint)] = []

    if let start {
      coordinates.append(start)
    }

    var seenKeys = Set<Data>()
    var isDistanceIncomplete = false
    // Resolved as the hop list resolves them: only by what this radio heard on its channel
    let relays = pathViewModel.relays(for: arrival)
    for (index, match) in relays.enumerated() {
      let hopNumber = index + 1
      // Same match as PathHopRowView: a guess or an unknown hop is never a pin, and a node is
      // placed only where it advertised itself in a packet this radio received
      guard let entry = match.entry, let coord = pathViewModel.relayCoordinate(for: match) else {
        isDistanceIncomplete = true
        continue
      }
      let key = entry.publicKey
      if seenKeys.insert(key).inserted {
        coordinates.append(coord)
        hopPoints.append((key, MapPoint(
          id: hopPointID(publicKey: key),
          coordinate: coord,
          pinStyle: .repeaterHop,
          label: pathViewModel.repeaterResolution(for: match).displayName,
          isClusterable: false,
          hopIndex: hopNumber,
          badgeText: nil
        )))
      }
    }

    if let loc = receiverLocation {
      let coord = loc.coordinate
      let differsFromLast = coordinates.last.map {
        $0.latitude != coord.latitude || $0.longitude != coord.longitude
      } ?? true
      if differsFromLast {
        coordinates.append(coord)
      }
    }

    return LocatedPath(
      coordinates: coordinates,
      hopPoints: hopPoints,
      isDistanceIncomplete: isDistanceIncomplete
    )
  }

  private static func hopPointID(publicKey: Data) -> UUID {
    pointID(namespace: "message-path-hop", bytes: publicKey)
  }

  private static func pointID(namespace: String, bytes: Data) -> UUID {
    let digest = Array(SHA256.hash(data: Data(namespace.utf8) + bytes))
    return UUID(uuid: (
      digest[0], digest[1], digest[2], digest[3],
      digest[4], digest[5], digest[6], digest[7],
      digest[8], digest[9], digest[10], digest[11],
      digest[12], digest[13], digest[14], digest[15]
    ))
  }
}

/// A rendered path map waiting in the share sheet.
private struct PathMapShareItem: Identifiable {
  let id = UUID()
  let image: UIImage

  /// Point size of the exported image; the renderer multiplies by the screen scale.
  static let imageSize = CGSize(width: 800, height: 600)
}
