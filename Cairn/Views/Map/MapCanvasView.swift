import MapKit
import MapLibre
import CairnServices
import SwiftUI

/// Canvas wrapping the map content with an offline badge and floating controls.
struct MapCanvasView: View {
  @Environment(\.appState) private var appState
  @Bindable var viewModel: MapViewModel
  @Binding var mapStyleSelection: MapStyleSelection
  @Binding var showLabels: Bool
  @Binding var clusteringEnabled: Bool
  @Binding var isNorthLocked: Bool
  @Binding var selectedCallout: MapCalloutSelection?
  @Binding var selectedPointScreenPosition: CGPoint?
  @Binding var isStyleLoaded: Bool
  let isAddingDiscovered: Bool
  var filter: MapFilterControl
  let onShowContactDetail: (ContactDTO) -> Void
  let onNavigateToChat: (ContactDTO) -> Void
  let onShowDiscoveredDetail: (DiscoveredNodeDTO) -> Void
  let onAddDiscovered: (DiscoveredNodeDTO) -> Void
  let onCenterOnUser: () -> Bool
  let onClearSelection: () -> Void
  let onPersistCamera: (MKCoordinateRegion) -> Void
  /// Selects a node found by the map's search, as a tap on its pin would.
  var onSelectNode: ((_ publicKey: Data, _ coordinate: CLLocationCoordinate2D) -> Void)?
  /// Opens the chat with the user's own position typed in (a contact callout's Send My Location).
  var onSendMyLocation: ((ContactDTO) -> Void)?
  /// A pin to select as if tapped, fired once per bump of the version (see `CairnMapView`).
  var selectionRequestID: UUID?
  var selectionRequestVersion = 0
  /// Opens Line of Sight from where you are to the target; nil leaves the readout's button out.
  var onCheckLineOfSight: ((LineOfSightRequest) -> Void)?

  /// Apple Maps' following: off, follow, follow with heading, cycled by the location button.
  @State private var trackingMode: MapTrackingMode = .none
  /// The selected pin the navigation readout measures to.
  @State private var navigationTarget: MapNavigationTarget?
  /// The phone faces the target, as the readout works it out; colours the guide line.
  @State private var isOnTarget = false
  /// The camera's rotation and tilt, which show and turn the compass.
  @State private var cameraOrientation = MapCameraOrientation()
  @State private var resetOrientationVersion = 0
  /// The phone's fix and compass for the readout, running only while the map shows and the
  /// readout has a job (see `needsLive`). Made on first appear: a `@State` default would build
  /// (and throw away) a location manager on every init of this view.
  @State private var live: GPSLiveLocation?
  @State private var isOnScreen = false
  /// Live traffic, switched from the map's controls: drawn by the map, its ticker shown here.
  @AppStorage(AppStorageKey.mapShowsTraffic.rawValue)
  private var showsTraffic = AppStorageKey.defaultMapShowsTraffic
  @State private var traffic = TrafficLayer()
  /// The ticker's top edge (global y), so MapLibre's logo and credits sit above it rather than
  /// under it.
  @State private var tickerTop: CGFloat?
  /// The bottom of the map's uncovered area (global y): above a floating tab bar, which the
  /// full-bleed map's own safe area doesn't count, so the logo and credits sit above that too.
  @State private var contentBottom: CGFloat?
  /// The packet list, opened by tapping the ticker.
  @State private var showsTrafficList = false
  /// Where the navigation readout and the controls float (global), so a pin's callout hangs
  /// under its pin rather than behind them.
  @State private var hudFrame: CGRect?
  @State private var controlsFrame: CGRect?
  /// Put away by a tap on the bare map (with nothing selected), back with the next, for a clear
  /// look at the map. Always shown to VoiceOver, which has no bare map to tap.
  @State private var hidesControls = false
  @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
  /// The location button's failure: Location off for the app, or no fix yet.
  @State private var locateFeedback: MapLocateFeedback?
  /// The empty map's card, put away for this showing of the map once dismissed.
  @State private var dismissedEmptyState: MapEmptyStateCard.Reason?
  @State private var showsSearch = false
  @State private var showsAdvertChoice = false
  @State private var showsDeviceSelection = false
  @State private var showsDownloadArea = false

  /// Aiming at a pin or following the phone: the only times the readout is shown, so the only
  /// times the GPS and compass run for it. Browsing the map leaves just MapLibre's dot.
  private var needsLive: Bool { navigationTarget != nil || trackingMode != .none }
  /// The compass turns the target arrow and reads out heading-up following; plain following
  /// has no use for it.
  private var needsHeading: Bool { navigationTarget != nil || trackingMode == .followWithHeading }

  private var isOffline: Bool {
    !appState.offlineMapService.isNetworkAvailable
  }

  /// A completed pack of the shown style covers what the map shows (or the map hasn't said
  /// where it is yet, which shouldn't read as a gap).
  private var hasOfflineCoverage: Bool {
    let service = appState.offlineMapService
    let layer = mapStyleSelection.offlineMapLayer
    if let bounds = viewModel.cameraRegion?.toMLNCoordinateBounds() {
      return service.hasCompletedPack(for: layer, overlapping: bounds)
    }
    return service.hasCompletedPack(for: layer)
  }

  /// The least finished pack still downloading, for the badge's bar; nil with none.
  private var packDownloadProgress: Double? {
    appState.offlineMapService.packs
      .filter { !$0.isComplete && !$0.isPaused }
      .map(\.completedFraction)
      .min()
  }

  /// Why the map has nothing to show, if so: no radio, or no node with a position.
  private var emptyStateReason: MapEmptyStateCard.Reason? {
    if appState.currentRadioID == nil { return .noRadio }
    if viewModel.hasCompletedInitialLoad, !viewModel.isLoading, viewModel.mapPoints.isEmpty { return .noLocatedNodes }
    return nil
  }

  /// The tapped node's details in the navigation panel, under its name and distance, laid out as the
  /// Traffic map's panel has them (`TrafficNodeBrief`; the user, 2026-11-09: one section, the same size):
  /// its kind and ID, with traffic on what it has carried lately; its page, Message or Add, the menu.
  private var panelDetail: AnyView? {
    switch selectedCallout {
    case let .contact(contact):
      return AnyView(TrafficNodeBrief(
        node: TrafficMapModel.PinnedNode(
          key: contact.publicKey, name: contact.displayName, contact: contact, discovered: nil, isRadio: false
        ),
        activity: traffic.model.activity(for: contact.publicKey),
        onDetail: { onShowContactDetail(contact) },
        onMessage: contact.type == .chat ? { onNavigateToChat(contact) } : nil,
        menu: AnyView(MapCalloutActionsMenu(
          name: contact.displayName,
          coordinate: contact.coordinate,
          onSendMyLocation: contact.type == .chat ? onSendMyLocation.map { send -> () -> Void in { send(contact) } } : nil
        )),
        showsActivity: showsTraffic
      ))
    case let .discovered(node):
      return AnyView(TrafficNodeBrief(
        node: TrafficMapModel.PinnedNode(
          key: node.publicKey, name: node.name, contact: nil, discovered: node, isRadio: false
        ),
        activity: traffic.model.activity(for: node.publicKey),
        onDetail: { onShowDiscoveredDetail(node) },
        onMessage: nil,
        onAdd: { onAddDiscovered(node) },
        isAdding: isAddingDiscovered,
        menu: AnyView(MapCalloutActionsMenu(name: node.name, coordinate: node.coordinate)),
        showsActivity: showsTraffic
      ))
    default:
      return nil
    }
  }

  var body: some View {
    ZStack {
      MapContentView(
        viewModel: viewModel,
        mapStyleSelection: mapStyleSelection,
        showLabels: showLabels,
        clusteringEnabled: clusteringEnabled,
        isNorthLocked: isNorthLocked,
        selectedCallout: $selectedCallout,
        selectedPointScreenPosition: $selectedPointScreenPosition,
        isStyleLoaded: $isStyleLoaded,
        trackingMode: $trackingMode,
        navigationTarget: $navigationTarget,
        nodeDetailsInPanel: live != nil,
        // Read only with a target, so fixes don't re-render the map while there is no guide line.
        userCoordinate: navigationTarget == nil ? nil : live?.location?.coordinate,
        resetOrientationVersion: resetOrientationVersion,
        onCameraOrientationChange: { cameraOrientation = $0 },
        isAddingDiscovered: isAddingDiscovered,
        onShowContactDetail: onShowContactDetail,
        onNavigateToChat: onNavigateToChat,
        onShowDiscoveredDetail: onShowDiscoveredDetail,
        onAddDiscovered: onAddDiscovered,
        onSendMyLocation: onSendMyLocation,
        onPersistCamera: onPersistCamera,
        selectionRequestID: selectionRequestID,
        selectionRequestVersion: selectionRequestVersion,
        isOnTarget: isOnTarget,
        traffic: traffic,
        legalOrnamentTopLimit: showsTraffic ? tickerTop ?? contentBottom : contentBottom,
        onBareMapTap: {
          guard !isVoiceOverEnabled else { return }
          withAnimation(.snappy) { hidesControls.toggle() }
        }
      )
      .ignoresSafeArea()
      // The pin's callout on the map, under the readout and the controls, and kept clear of them.
      .mapCallout(avoiding: [hudFrame, controlsFrame].compactMap(\.self))

      // Navigation readout (top-left); the map's controls top-right, where the Traffic map has
      // them, with the offline badge and compass under them, laid out together so nothing covers
      // anything else at any width or text size.
      HStack(alignment: .top) {
        if let live, needsLive {
          MapNavigationHUD(
            live: live,
            target: navigationTarget,
            onCheckLineOfSight: lineOfSightAction,
            onTargetChange: { isOnTarget = $0 },
            targetDetail: panelDetail
          ) {
            navigationTarget = nil
            selectedCallout = nil
          }
          // Ahead of the spacer, so it gets its full width whenever the screen has it.
          .layoutPriority(1)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hudFrame = $0 }
          .onDisappear { hudFrame = nil }
        }
        Spacer(minLength: 8)
        if !hidesControls || isVoiceOverEnabled {
          VStack(alignment: .trailing, spacing: 0) {
            MapCanvasControls(
              isNorthLocked: $isNorthLocked,
              showLabels: $showLabels,
              clusteringEnabled: $clusteringEnabled,
              mapStyleSelection: $mapStyleSelection,
              trackingMode: trackingMode,
              viewportBounds: viewModel.cameraRegion?.toMLNCoordinateBounds(),
              centerAllEmpty: !viewModel.hasPinsForCenterAll,
              canZoom: viewModel.cameraRegion != nil,
              filter: filter,
              onZoom: { direction in
                viewModel.zoom(direction)
              },
              onLocationTap: cycleTracking,
              onClearSelection: onClearSelection,
              onCenterAll: {
                viewModel.centerOnAllContacts()
              },
              onSearch: { showsSearch = true },
              onDownloadArea: { showsDownloadArea = true }
            )
            VStack(alignment: .trailing, spacing: 8) {
              if isOffline {
                OfflineBadge(
                  placesItself: false,
                  hasCoverage: hasOfflineCoverage,
                  downloadProgress: packDownloadProgress,
                  action: { appState.navigation.navigateToSetting(.gps) }
                )
                .fixedSize()
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
              }
              if cameraOrientation.isRotatedOrTilted {
                MapCompassButton(orientation: cameraOrientation) {
                  resetOrientationVersion += 1
                }
                .transition(.scale.combined(with: .opacity))
              }
            }
            // The toolbar pads itself but on the trailing side; this lines them up under it.
            .padding(.leading)
          }
          // Sized before the readout, which takes what is left (up to its own width).
          .layoutPriority(2)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsFrame = $0 }
          .onDisappear { controlsFrame = nil }
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.2), value: cameraOrientation.isRotatedOrTilted)
      .animation(.snappy, value: navigationTarget)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      // Nothing on the map: a card saying so and what would change it, over the bottom, where
      // the controls aren't, until put away. The map behind it still works.
      if let reason = emptyStateReason, reason != dismissedEmptyState {
        VStack {
          Spacer()
          MapEmptyStateCard(
            reason: reason,
            onSendAdvert: { showsAdvertChoice = true },
            onScan: { appState.navigation.navigateToTool(.nodeDiscovery) },
            onConnect: { showsDeviceSelection = true },
            onDismiss: { withAnimation(.snappy) { dismissedEmptyState = reason } }
          )
          .padding()
          .padding(.bottom, showsTraffic ? 72 : 0)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      // The traffic ticker along the bottom while traffic is on, as on the Traffic map.
      VStack {
        Spacer()
        if showsTraffic {
          TrafficTickerCard(
            flights: traffic.model.flights,
            lastFinished: traffic.model.lastFinished,
            onOpenList: { showsTrafficList = true }
          )
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { tickerTop = $0 }
          .padding()
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: showsTraffic)
      // Fills the safe area, so its bottom is where the tab bar (or the home indicator) starts.
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { contentBottom = $0 }
    }
    .animation(.snappy, value: emptyStateReason)
    .mapLocateFeedback($locateFeedback)
    .sheet(isPresented: $showsTrafficList) {
      TrafficListSheet()
    }
    .sheet(isPresented: $showsSearch) {
      MapSearchSheet(viewModel: viewModel) { publicKey, coordinate in
        onSelectNode?(publicKey, coordinate)
      }
    }
    .sheet(isPresented: $showsAdvertChoice) {
      AdvertChoiceSheet { flood in
        Task { try? await appState.sendSelfAdvert(flood: flood) }
      }
    }
    .sheet(isPresented: $showsDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showsDownloadArea) {
      RegionPickerSheet(initialRegion: viewModel.cameraRegion)
    }
    .onAppear {
      // MapLibre's dot already runs a best-accuracy manager on this map, which keeps the GPS on;
      // this one asks for less rather than adding a second.
      if live == nil { live = GPSLiveLocation(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, tracksHeading: false) }
      isOnScreen = true
      syncLive()
    }
    .onDisappear {
      isOnScreen = false
      syncLive()
    }
    .onChange(of: needsLive) { syncLive() }
    .onChange(of: needsHeading) { syncLive() }
    // A rotation to or from landscape turns the screen against the compass; keep headings in step.
    .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
      live?.syncHeadingOrientation()
    }
  }

  /// Line of Sight from the phone (or, without a fix, this radio) to the target, once both are
  /// known and the target isn't where you already are.
  private var lineOfSightAction: (() -> Void)? {
    guard let onCheckLineOfSight, let target = navigationTarget,
          let origin = (live?.location?.coordinate ?? appState.bestAvailableLocation?.coordinate)
            .flatMap({ $0.isValidFix ? $0 : nil }),
          MapNavigationMath.distance(from: origin, to: target.coordinate) >= 1 else { return nil }
    return {
      onCheckLineOfSight(LineOfSightRequest(
        origin: origin,
        target: target.coordinate,
        contact: viewModel.contact(forPointID: target.pointID),
        discovered: viewModel.discovered(forPointID: target.pointID)
      ))
    }
  }

  /// Starts the readout's location and compass while the map shows and something needs them,
  /// and stops them otherwise.
  private func syncLive() {
    guard let live else { return }
    live.tracksHeading = needsHeading
    if isOnScreen, needsLive {
      live.start()
    } else {
      live.stop()
    }
  }

  /// The location button, as in Apple Maps: center and follow, then turn with the heading, then
  /// stop. Starting needs a location; without one (or permission) it stays off, as "center on me"
  /// always has. The recenter lands first and following takes over once it settles.
  private func cycleTracking() {
    let isHeadingAvailable = live?.isHeadingAvailable ?? false
    let next = trackingMode.next(isNorthLocked: isNorthLocked, isHeadingAvailable: isHeadingAvailable)
    if trackingMode == .none {
      guard onCenterOnUser() else {
        // Nothing to center on: say why, rather than a tap that does nothing. Location off for
        // the app gets the way to Settings; allowed but no fix yet, a word while it's sought.
        locateFeedback = appState.locationService.isLocationDenied ? .denied : .searching
        return
      }
      // "Center on me" also falls back to the radio's position. Following needs the phone's own,
      // so without location permission the tap stays a one-shot recenter.
      guard canFollowPhone else { return }
    }
    trackingMode = next
  }

  private var canFollowPhone: Bool {
    switch live?.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }
}

// MARK: - Traffic List

/// The traffic ticker's packet list: the RX Log over the map, half height at first so the lasers
/// stay in view and the map can still be moved.
private struct TrafficListSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      RxLogView()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
    }
    .presentationDetents([.medium, .large])
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
  }
}

// MARK: - Map Controls

private struct MapCanvasControls: View {
  @Binding var isNorthLocked: Bool
  @Binding var showLabels: Bool
  @Binding var clusteringEnabled: Bool
  @Binding var mapStyleSelection: MapStyleSelection
  let trackingMode: MapTrackingMode
  let viewportBounds: MLNCoordinateBounds?
  let centerAllEmpty: Bool
  let canZoom: Bool
  var filter: MapFilterControl
  let onZoom: (MapZoomStep.Direction) -> Void
  let onLocationTap: () -> Void
  let onClearSelection: () -> Void
  let onCenterAll: () -> Void
  let onSearch: () -> Void
  let onDownloadArea: () -> Void

  @Environment(\.appState) private var appState

  var body: some View {
    MapControlsToolbar(
      onLocationTap: onLocationTap,
      trackingMode: trackingMode,
      isNorthLocked: $isNorthLocked,
      showLabels: $showLabels,
      clusteringEnabled: $clusteringEnabled,
      mapStyleSelection: $mapStyleSelection,
      viewportBounds: viewportBounds,
      filter: filter,
      // As on the Traffic map: an advert shows the mesh at work, more so with traffic on.
      showsAdvertButton: true,
      showsTrafficToggle: true,
      hugsTrailingEdge: true,
      showsCaptions: true,
      // The shown area as an offline pack, while there is a network to fetch it over.
      optionsMenuItems: AnyView(
        Button(L10n.Map.Map.Controls.downloadArea, systemImage: "arrow.down.circle", action: onDownloadArea)
          .disabled(!appState.offlineMapService.isNetworkAvailable || viewportBounds == nil)
      )
    ) {
      Button(L10n.Map.Map.Search.title, systemImage: "magnifyingglass", action: onSearch)
        .mapControlButton(tint: .primary, caption: L10n.Map.Map.Controls.Caption.search)
        .accessibilityIdentifier("map.search")
      CenterAllButton(
        isEmpty: centerAllEmpty,
        onClearSelection: onClearSelection,
        onCenterAll: onCenterAll
      )
      // Pointer devices have no pinch; touch already does, and the toolbar is tall enough.
      if ProcessInfo.processInfo.isiOSAppOnMac {
        MapZoomButtons(isEnabled: canZoom, onZoom: onZoom)
      }
    }
  }
}

// MARK: - Control Buttons

/// Mac-only + / − map buttons, shared by every full map surface.
struct MapZoomButtons: View {
  let isEnabled: Bool
  let onZoom: (MapZoomStep.Direction) -> Void

  var body: some View {
    Button(L10n.Map.Map.Controls.zoomIn, systemImage: "plus") { onZoom(.zoomIn) }
      .mapControlButton(tint: isEnabled ? .primary : .secondary)
      .disabled(!isEnabled)
    Button(L10n.Map.Map.Controls.zoomOut, systemImage: "minus") { onZoom(.zoomOut) }
      .mapControlButton(tint: isEnabled ? .primary : .secondary)
      .disabled(!isEnabled)
  }
}

private struct CenterAllButton: View {
  let isEmpty: Bool
  let onClearSelection: () -> Void
  let onCenterAll: () -> Void

  var body: some View {
    Button(L10n.Map.Map.Controls.centerAll, systemImage: "arrow.up.left.and.arrow.down.right") {
      onClearSelection()
      onCenterAll()
    }
    .mapControlButton(tint: isEmpty ? .secondary : .primary)
    .disabled(isEmpty)
  }
}
