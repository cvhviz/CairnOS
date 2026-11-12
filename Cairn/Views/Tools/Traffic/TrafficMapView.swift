import CairnServices
import CoreLocation
import MapKit
import SwiftUI

/// Scan & Traffic's map: the nodes this radio heard on its channel, the links it observed lately
/// glowing between them, and a laser for every packet this radio hears, retracing its route from
/// repeater to repeater as it arrives. Over that, the current scan's neighbours as Scan for Nodes
/// pins them (`NodeDiscoveryMapBuilder`): each linked by an SNR line to where this radio heard it
/// best, and picked together with its card in the panel. Shares the RX log the Packets list
/// shows, its route filter, and the index it names nodes from (`AppState.observationDirectory`).
/// The camera follows the panel's section: around the radio and its neighbours for Nodes, as Scan
/// opens and follows a probe, or fitting the packets' routes for Packets, as the Traffic map did.
/// Its rail is four controls: Locate, Fit, Replay, and ⋯ (quiet nodes, the nodes not on the map,
/// and the map's own options), with the compass under them; Send Advert is the page's top-right button. Scan and Wardrive are on the sheet, never over the map.
struct TrafficMapView: View {
  /// The log's entries passing the page's route filter, oldest first.
  let entries: ArraySlice<RxLogEntryDTO>
  /// Changes when the filter does, so the map rebuilds its history from the new set.
  let filterKey: String
  /// The stored log has been read in: until then an empty `entries` may just be still loading.
  let hasLoadedHistory: Bool
  let isConnected: Bool
  /// Opens the packet list, from a tap on the ticker.
  var onOpenList: (() -> Void)?
  /// What the radio's firmware never passes on (`RxLogViewModel.longPacketNote`), under the empty
  /// card's description and as the ticker's hint while it listens. Nil says nothing.
  var stockNote: String?
  /// The scan whose neighbours are pinned here; its pick is the panel's.
  let scan: NodeDiscoveryViewModel
  /// The panel's section, which the camera follows.
  let section: NodeDiscoverySection
  /// The results sheet is lowered to its header (the map has the screen), for the neighbours' refit.
  var isFullScreen = false
  /// Room is short (a phone's map above its results sheet): the controls drop their captions and
  /// the ticker stays off, as on Scan for Nodes' map, so the neighbours keep the room.
  var isCompact = false
  /// How far the results sheet covers the map's bottom; the overlays, the camera and its fits
  /// keep clear of it. The map itself runs full height under the sheet, so moving it is cheap.
  var bottomInset: CGFloat = 0
  /// The packet ticker along the map's bottom. Off where a phone's lowered sheet says the same under
  /// its mini spectrum.
  var showsTicker = true
  /// The traffic drawn here, owned by the page so its sheet can say the packet now flying.
  let model: TrafficMapModel
  /// A tap on the map away from any pin or link: the page hides its list.
  var onMapBackgroundTap: (() -> Void)?

  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @AppStorage(AppStorageKey.mapStyleSelection.rawValue) private var mapStyle: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapShowLabels.rawValue) private var showLabels = AppStorageKey.defaultMapShowLabels
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference
  /// Which nodes the map pins besides the routes' (`TrafficMapNodes`); stored raw.
  @AppStorage(AppStorageKey.trafficMapNodes.rawValue) private var mapNodesRaw = 0
  /// The camera when the page was last left, where it opens until a position is known.
  @SceneStorage(SceneStorageKey.scanTrafficCameraRegion.rawValue) private var savedCameraRegion = ""

  @State private var projection = MapProjection()
  @State private var cameraRegion: MKCoordinateRegion?
  @State private var cameraRegionVersion = 0
  @State private var cameraFitPadding: MapCameraFitPadding?
  @State private var isStyleLoaded = false
  @State private var isCenteredOnUser = false
  /// The routes have been framed once, on first showing the packets.
  @State private var hasFitCamera = false
  /// The colour key in the bottom corner, so the camera fits and MapLibre's logo keep clear.
  @State private var bottomOverlayHeight: CGFloat = 0
  /// The ticker strip along the top (iPad), so the readout, the controls and the camera fits
  /// start under it.
  @State private var topOverlayHeight: CGFloat = 0
  /// The tapped pin while its callout is open, and where it is on screen.
  @State private var selectedPointID: UUID?
  @State private var calloutAnchor: CGPoint?
  /// The tapped link while its callout is open, by `MapLine.id`. Its callout rides on the
  /// model's anchor point at the link's middle, selected as a pin is (`lineAnchorID`).
  @State private var selectedLineID: String?
  @State private var contactForDetail: ContactDTO?
  @State private var discoveredForDetail: DiscoveredNodeDTO?
  /// The "not on map" list, and the node page picked from it, opened once the list has closed.
  @State private var showsOffMap = false
  @State private var offMapDetail: (contact: ContactDTO?, discovered: DiscoveredNodeDTO?)?
  @State private var addingDiscoveredID: UUID?
  /// The rail's width, to centre it under the bar's top-right button.
  @State private var railWidth: CGFloat = 0
  /// The colour key's chip at most this wide: its six entries then wrap into two rows of three.
  private static let legendMaxWidth: CGFloat = 300

  @State private var errorMessage: String?
  /// A pin to select as if tapped (screenshot runs), fired once per bump of the version.
  @State private var selectionRequestID: UUID?
  @State private var selectionRequestVersion = 0

  // The neighbours' camera and aiming, as on Scan for Nodes' map.
  @State private var traceFit = TraceCameraFitScheduler()
  /// Apple Maps' following: off, follow, follow with heading, cycled by the location button.
  @State private var trackingMode: MapTrackingMode = .none
  /// The camera's rotation and tilt, which show and turn the compass.
  @State private var cameraOrientation = MapCameraOrientation()
  @State private var resetOrientationVersion = 0
  /// The phone's fix and compass for the aiming readout and guide line, running only while the
  /// map shows and a neighbour is picked. Made on first appear, so an init doesn't build a
  /// location manager.
  @State private var live: GPSLiveLocation?
  @State private var isOnScreen = false
  /// The phone faces the picked neighbour, as the readout works it out; colours the guide line.
  @State private var isOnTarget = false
  /// The camera is still where the Nodes section opened: no drag, pick, fit, or following has
  /// moved it since. A better position landing meanwhile (the phone's first fix) moves it once.
  @State private var isAtOpeningCamera = false
  /// What the opening camera was put on, so only a better position moves it again.
  @State private var openingSource: NodeDiscoveryOpeningCamera.Source?

  /// How far the navigation bar's top-right button (Send Advert) sits its centre from the window's
  /// trailing edge: the system's bar margin plus half its glass circle, which differs between the
  /// iPhone's and the iPad's bars. The map always reaches that edge, so the rail centres on it.
  static func barTrailingButtonCenterInset(idiom: UIUserInterfaceIdiom) -> CGFloat {
    idiom == .phone ? 38 : 32.5
  }

  /// The rail's trailing margin, centring its glass (the rail less its 16 pt leading pad) under the
  /// bar's top-right button.
  private var railTrailingPadding: CGFloat {
    guard railWidth > 0 else { return 16 }
    let glassWidth = railWidth - 16
    return max(0, Self.barTrailingButtonCenterInset(idiom: UIDevice.current.userInterfaceIdiom) - glassWidth / 2)
  }

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  /// What the nodes depend on: the observations every screen names packets from and their labels,
  /// what a Remove Nodes run is taking off, and this radio and where it is.
  private var directoryKey: String {
    TrafficDirectory.reloadKey(appState: appState)
  }

  /// The scan's neighbours, pinned as Scan for Nodes pins them. The map has no filter of its own
  /// here (Quiet chooses the channel's nodes), so every neighbour with a position is drawn.
  private var neighbours: NodeDiscoveryMapBuilder.Plotted {
    NodeDiscoveryMapBuilder.build(
      results: scan.sortedResults,
      contacts: scan.contactsByKey,
      discovered: scan.discoveredByKey,
      filter: MapFilterPreferences.state(fromRaw: "", host: .nodeDiscovery),
      overridesFilter: true,
      selectedKey: scan.selectedKey
    )
  }

  /// The traffic's pins less the nodes a neighbour pin already marks, so each node shows once, as
  /// the neighbour whose card it opens.
  private func trafficPoints(besides neighbours: NodeDiscoveryMapBuilder.Plotted) -> [MapPoint] {
    let keys = Set(scan.sortedResults.compactMap { result in
      neighbours.coordinatesByKey[result.key] != nil ? result.publicKey : nil
    })
    guard !keys.isEmpty else { return model.points }
    return model.points.filter { point in
      model.key(forPointID: point.id).map { !keys.contains($0) } ?? true
    }
  }

  /// The camera follows the neighbours while a probe listens and while names are still being
  /// looked up, unless a neighbour is picked.
  private var isFollowingTraces: Bool {
    scan.selectedKey == nil && (scan.isProbing || !scan.resolvingNameKeys.isEmpty)
  }

  var body: some View {
    let neighbours = neighbours
    let target = aimTarget(neighbours)
    ZStack {
      CairnMapView(
        points: trafficPoints(besides: neighbours) + neighbours.points,
        lines: model.lines + neighbours.lines + aimLines(to: target),
        mapStyle: mapStyle,
        isDarkMode: mapIsDark,
        isOffline: !appState.offlineMapService.isNetworkAvailable,
        showLabels: showLabels,
        // Overlapping quiet pins group into a count that a tap zooms open (`MapPoint.isClusterable`).
        clusteringEnabled: true,
        showsUserLocation: true,
        isInteractive: true,
        showsScale: true,
        isNorthLocked: isNorthLocked,
        cameraRegion: $cameraRegion,
        cameraRegionVersion: cameraRegionVersion,
        cameraBottomSheetFraction: 0,
        cameraFitPadding: cameraFitPadding,
        // Behind a phone's results sheet the map runs full height; its viewport ends at the sheet.
        contentBottomInset: bottomInset > 0 ? bottomInset : nil,
        // Above the ticker where it shows. The map's viewport already ends at the results sheet
        // (`contentBottomInset`), and MapLibre places its logo inside it.
        legalOrnamentBottomMargin: bottomOverlayHeight > 0 ? bottomOverlayHeight + 24 : nil,
        legalOrnamentsAtTrailing: !isCompact && showsTicker,
        selectionRequestID: selectionRequestID,
        selectionRequestVersion: selectionRequestVersion,
        selectedPointID: neighbours.pointID(for: scan.selectedKey) ?? selectedPointID,
        // The callout rides on its pin as the map is panned or zoomed.
        onSelectedPointMove: { calloutAnchor = $0 },
        onPointTap: { point, anchor in tap(point, anchor: anchor, neighbours: neighbours) },
        onMapTap: { _ in
          closeCallout()
          scan.selectedKey = nil
          onMapBackgroundTap?()
        },
        onLineTap: { id in
          // A second tap on the open link closes it; a link's callout replaces a pin's.
          if id == selectedLineID {
            closeCallout()
          } else {
            scan.selectedKey = nil
            selectedLineID = id
            model.selectLine(id: id)
            selectedPointID = TrafficMapModel.lineAnchorID
            calloutAnchor = model.linkDetail(forLineID: id).flatMap { projection.point(for: $0.midpoint) }
              .map { CGPoint(x: $0.x, y: $0.y - PinSpriteRenderer.calloutLift(for: .badge)) }
          }
        },
        onCameraRegionChange: { region in
          cameraRegion = region
          savedCameraRegion = MapCameraStore.encode(region)
        },
        onUserGestureChange: { isActive in
          if isActive { isAtOpeningCamera = false }
          traceFit.setGestureActive(isActive)
        },
        isStyleLoaded: $isStyleLoaded,
        isCenteredOnUser: $isCenteredOnUser,
        userTrackingMode: $trackingMode,
        showsUserHeadingIndicator: true,
        hidesCompassOrnament: true,
        // Bottom right, as on the GPS tab's map (above the logo where that shares the corner).
        scaleBarAtBottomTrailing: true,
        onCameraOrientationChange: { cameraOrientation = $0 },
        resetOrientationVersion: resetOrientationVersion,
        onFollowingCameraChange: { cameraRegion = $0 },
        projection: projection
      )
      .overlay {
        TrafficLaserOverlay(flights: model.flights, projection: projection, isDark: mapIsDark)
      }
      .preference(key: MapCalloutPreferenceKey.self, value: callout)
      // The map runs under the navigation bar and to the screen's sides, and beside the panel
      // (iPad, Mac) under the tab bar too; its overlays stay inside the safe area.
      .ignoresSafeArea(edges: bottomInset > 0 ? [.top, .horizontal] : .all)

      // The controls down the trailing side; the picked neighbour's readout top-leading, and the
      // ticker along the bottom where there's room, kept clear of them.
      VStack(spacing: 12) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 8) {
            // The picked node's aiming readout, as on the Map tab, with a traffic node's facts
            // under it on the same card rather than in a callout over the map.
            // A traffic node's facts, or the scan's picked neighbour's, with Details to its page.
            let brief = scan.selectedKey == nil ? selectedNodeBrief : scanSelectedBrief
            if let target, let live {
              MapNavigationHUD(
                live: live,
                target: target,
                fallbackOrigin: appState.bestAvailableLocation?.coordinate,
                onTargetChange: { isOnTarget = $0 },
                targetDetail: brief.map { AnyView($0.brief) }
              ) {
                if scan.selectedKey != nil {
                  scan.selectedKey = nil
                } else {
                  closeCallout()
                }
              }
              .layoutPriority(1)
            } else if let brief {
              // Nothing to aim at (this radio, or no phone location): the facts on their own.
              TrafficNodeCard(name: brief.name, brief: brief.brief) {
                scan.selectedKey = nil
                closeCallout()
              }
              .layoutPriority(1)
              .transition(.opacity)
            }
          }
          Spacer(minLength: TraceCameraFit.controlsToolbarWidth)
        }
        .animation(.snappy, value: target)
        .animation(.snappy, value: selectedPointID)
        Spacer(minLength: 0)
        if !isCompact, model.hasLoadedDirectory, model.points.isEmpty, neighbours.points.isEmpty {
          emptyCard
          Spacer(minLength: 0)
        }
        // The lasers' colour key on a chip in the bottom-right corner, inside the safe area so it
        // sits above the tab bar, and narrow enough to wrap into even rows; MapLibre's logo over
        // it (`legalOrnamentsAtTrailing`). A phone's short map above its results leaves it out.
        if !isCompact, showsTicker {
          HStack {
            Spacer(minLength: 0)
            TrafficLegendChip()
              .frame(maxWidth: Self.legendMaxWidth)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomOverlayHeight = $0 }
              .onDisappear { bottomOverlayHeight = 0 }
          }
        }
      }
      .padding(.horizontal)
      .padding(.top, 8 + topOverlayHeight)
      // Close over the safe area's bottom (the tab bar), so the colour key tucks into the corner.
      .padding(.bottom, 6 + bottomInset)

      // The ticker along the whole top edge, a strip the map fades into, growing downward as a
      // packet's lines come and go. A phone's short map above its results leaves it out: the
      // Packets list is right below, and lowering the sheet brings it back.
      if !isCompact, showsTicker {
        TrafficTickerCard(
          flights: model.flights,
          lastFinished: model.lastFinished,
          onOpenList: onOpenList,
          stockNote: stockNote,
          isStrip: true
        )
        // Measured before it is pinned to the top of the whole map, so the height is the strip's.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topOverlayHeight = $0 }
        .onDisappear { topOverlayHeight = 0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .avoidsFold()
      }

      replayingChip
        .padding(.top, 8 + topOverlayHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      VStack(alignment: .trailing, spacing: 8) {
        controls(neighbours)
        // Always up, north-up and flat too (the user, 2026-11-08); a tap cycles north up →
        // heading up → north locked (`compassTapped`). The GPS tab's shows only while rotated.
        MapCompassButton(orientation: cameraOrientation, mode: compassMode, action: compassTapped)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { railWidth = $0 }
      .padding(.trailing, railTrailingPadding)
      .padding(.top, 8 + topOverlayHeight)
      .padding(.bottom, bottomInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
    // The pins are reachable from the results list, where every neighbour is a card; VoiceOver
    // users get the same selection there without hunting for pins.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("nodeDiscovery.map")
    // Over the controls and the ticker, not under them: a callout is read while it's up. The
    // stack starts where the map does, so the pin's position reads the same in both.
    .mapCallout(fillsScreen: false)
    .onChange(of: directoryKey, initial: true) {
      // The observations as they now stand (a node heard, a label changed, another channel): the
      // history is rebuilt against them without lasers at once, then at most once a second
      // through a burst, from the entries as they are by then.
      let ranNow = model.reload(TrafficDirectory(appState: appState), entries: entries)
      if ranNow {
        fitCameraIfNeeded()
        replayIfNeeded()
      }
    }
    .task {
      // Lasers that have landed go, and links and rings fade, once a second while the map shows.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        model.tick()
      }
    }
    #if DEBUG
    .task(id: isStyleLoaded) {
      // `-uiTestTrafficCallout YES`: once traffic has flowed, open the busiest repeater's callout.
      guard isStyleLoaded, UserDefaults.standard.bool(forKey: "uiTestTrafficCallout") else { return }
      try? await Task.sleep(for: .seconds(8))
      let busiest = model.points
        .filter { $0.pinStyle == .repeaterRingGreen || $0.pinStyle == .repeater }
        .max { lhs, rhs in
          let left = model.node(forPointID: lhs.id).map { model.activity(for: $0.key).packets } ?? 0
          let right = model.node(forPointID: rhs.id).map { model.activity(for: $0.key).packets } ?? 0
          return left < right
        }
      selectionRequestID = busiest?.id
      selectionRequestVersion += 1
    }
    .task {
      // `-uiTestTrafficDemo YES`: a made-up packet every second or so, for screenshots.
      guard UserDefaults.standard.bool(forKey: "uiTestTrafficDemo") else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(Int.random(in: 700...1600)))
        model.launchDemoFlight()
      }
    }
    #endif
    .onChange(of: entries.last?.id) {
      model.ingest(entries)
    }
    .onChange(of: hasLoadedHistory) { replayIfNeeded() }
    .onChange(of: filterKey) {
      model.resetHistory()
      model.ingest(entries)
    }
    .onChange(of: mapNodesRaw, initial: true) { _, raw in model.nodes = TrafficMapNodes(rawValue: raw) ?? .scan }
    // A selected node's links stay drawn and carry their packet counts while its callout is open.
    .onChange(of: selectedPointID, initial: true) { _, id in model.select(pointID: id) }
    // A pin that goes (a node no longer placed) takes its callout with it.
    .onChange(of: model.points.map(\.id)) { _, ids in
      if let selectedPointID, selectedPointID != TrafficMapModel.lineAnchorID, !ids.contains(selectedPointID) { closeCallout() }
    }
    .modifier(neighbourCamera(neighbours, hasTarget: target != nil))
    .detailPresentation(item: $contactForDetail, route: { .contact(id: $0.id, canHideFromMap: false) }) { contact in
      ContactDetailSheet(
        contact: contact,
        onMessage: { appState.navigation.navigateToChat(with: contact) },
        onDelete: { contactForDetail = nil }
      )
      .presentationDetents([.large])
    }
    .detailPresentation(item: $discoveredForDetail, route: {
      .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: false)
    }) { node in
      DiscoveredNodeDetailSheet(
        node: node,
        isAdding: addingDiscoveredID == node.id,
        onAdd: { add(node) }
      )
      .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showsOffMap, onDismiss: openOffMapDetail) {
      TrafficOffMapSheet(model: model) { contact, discovered in
        offMapDetail = (contact, discovered)
        showsOffMap = false
      }
    }
    .errorAlert($errorMessage)
  }

  /// A neighbour's pin picks its card (a second tap lets go); any other pin opens its callout, as
  /// on the Traffic map. A neighbour's SNR badge does nothing.
  private func tap(_ point: MapPoint, anchor: CGPoint, neighbours: NodeDiscoveryMapBuilder.Plotted) {
    if let key = neighbours.keysByPointID[point.id] {
      closeCallout()
      scan.selectedKey = scan.selectedKey == key ? nil : key
      return
    }
    guard !neighbours.points.contains(where: { $0.id == point.id }) else { return }
    scan.selectedKey = nil
    // A second tap on the open pin closes it.
    if point.id == selectedPointID {
      closeCallout()
    } else {
      selectedLineID = nil
      model.selectLine(id: nil)
      selectedPointID = point.id
      calloutAnchor = anchor
    }
  }

  /// The node page picked from the "not on map" list, once the list has gone.
  private func openOffMapDetail() {
    guard let detail = offMapDetail else { return }
    offMapDetail = nil
    if let contact = detail.contact {
      contactForDetail = contact
    } else if let discovered = detail.discovered {
      discoveredForDetail = discovered
    }
  }

  // MARK: - Callout

  /// The open link's callout, handed to the map to draw on the link.
  private var callout: MapCallout? {
    if let selectedLineID {
      guard let calloutAnchor, let detail = model.linkDetail(forLineID: selectedLineID) else { return nil }
      return MapCallout(anchor: calloutAnchor, content: AnyView(TrafficLinkCalloutContent(detail: detail, onClose: closeCallout)))
    }
    // A node's facts go on the top-left card (`selectedNodeBrief`), not over the map.
    return nil
  }

  /// The tapped traffic node's facts, for the top-left card; nil for a link or nothing picked.
  private var selectedNodeBrief: (name: String, brief: TrafficNodeBrief)? {
    guard let selectedPointID, selectedPointID != TrafficMapModel.lineAnchorID,
          let node = model.node(forPointID: selectedPointID) else { return nil }
    let brief = TrafficNodeBrief(
      node: node,
      activity: model.activity(for: node.key),
      onDetail: detailAction(for: node),
      onMessage: node.contact.flatMap { contact in
        contact.type == .chat ? { closeCallout(); appState.navigation.navigateToChat(with: contact) } : nil
      }
    )
    return (node.name, brief)
  }

  /// The scan's picked neighbour's facts for the top-left card, as a traffic node's: its saved or
  /// heard record's page behind Details, and Message for a saved chat contact.
  private var scanSelectedBrief: (name: String, brief: TrafficNodeBrief)? {
    guard let key = scan.selectedKey else { return nil }
    let stored = model.storedNode(forKey: key)
    let name = scan.results.first { $0.publicKey == key }?.name
      ?? stored.contact?.displayName ?? stored.discovered?.name ?? key.prefix(3).uppercaseHexString()
    let node = TrafficMapModel.PinnedNode(key: key, name: name, contact: stored.contact, discovered: stored.discovered, isRadio: false)
    let brief = TrafficNodeBrief(
      node: node,
      activity: model.activity(for: key),
      onDetail: detailAction(for: node),
      onMessage: stored.contact.flatMap { contact in
        contact.type == .chat ? { closeCallout(); appState.navigation.navigateToChat(with: contact) } : nil
      }
    )
    return (name, brief)
  }

  private func detailAction(for node: TrafficMapModel.PinnedNode) -> (() -> Void)? {
    if let contact = node.contact {
      return { closeCallout(); contactForDetail = contact }
    }
    if let discovered = node.discovered {
      return { closeCallout(); discoveredForDetail = discovered }
    }
    return nil
  }

  private func closeCallout() {
    selectedPointID = nil
    calloutAnchor = nil
    selectedLineID = nil
    model.selectLine(id: nil)
  }

  /// Saves a heard node to the radio's list, from its page, as the Map tab does.
  private func add(_ node: DiscoveredNodeDTO) {
    guard addingDiscoveredID == nil else { return }
    guard let contactService = appState.services?.contactService else {
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    addingDiscoveredID = node.id
    Task {
      defer { addingDiscoveredID = nil }
      do {
        try await contactService.addOrUpdateContact(radioID: node.radioID, contact: node.makeContactFrame())
        discoveredForDetail = nil
      } catch ContactServiceError.contactTableFull {
        errorMessage = appState.connectedDevice.map { L10n.Contacts.Contacts.Add.Error.nodeListFull(Int($0.maxContacts)) }
          ?? L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  /// The rail: Locate (center, then follow, then turn with the heading), Fit (what the section is
  /// about), Replay (the latest traffic again), and ⋯ with the rest above the map's own options:
  /// the quiet nodes heard on the channel and the nodes the map can't place. Send Advert is the page's
  /// top-right button.
  private func controls(_ neighbours: NodeDiscoveryMapBuilder.Plotted) -> some View {
    MapControlsToolbar(
      onLocationTap: cycleTracking,
      isCenteredOnUser: isCenteredOnUser,
      trackingMode: trackingMode,
      isNorthLocked: $isNorthLocked,
      showLabels: $showLabels,
      mapStyleSelection: $mapStyle,
      viewportBounds: cameraRegion?.toMLNCoordinateBounds(),
      hugsTrailingEdge: true,
      // No captions: the rail stays one glass circle wide, the toolbar button's width above it.
      showsCaptions: false,
      optionsMenuItems: AnyView(moreItems)
    ) {
      // Zooms out to the region around the mesh, a state's worth of map: the locate button beside
      // it stays close in, so the two read as different reaches.
      Button(L10n.Tools.Tools.Traffic.Map.fit, systemImage: "map") {
        zoomToRegion(neighbours)
      }
      .mapControlButton(tint: .primary, caption: nil)
      .accessibilityIdentifier("traffic.map.fit")

      // Replays the latest traffic as lasers, on the map rather than in ⋯ (the user, 2026-11-08).
      Button(L10n.Tools.Tools.Traffic.Map.replay, systemImage: "play.circle") {
        model.replay(entries)
      }
      .mapControlButton(tint: .primary, caption: nil)
      .disabled(entries.isEmpty)
      .accessibilityIdentifier("traffic.map.replay")

      if ProcessInfo.processInfo.isiOSAppOnMac {
        MapZoomButtons(isEnabled: cameraRegion != nil) { direction in
          guard let region = cameraRegion else { return }
          isCenteredOnUser = false
          isAtOpeningCamera = false
          setCameraRegion(MapZoomStep.region(from: region, direction: direction))
        }
      }
    }
  }

  /// The ⋯ menu's own items, above the map's options.
  @ViewBuilder
  private var moreItems: some View {
    // Which nodes are pinned: the scan's, every heard node, every contact, or all of them.
    Picker(selection: $mapNodesRaw) {
      ForEach(TrafficMapNodes.allCases) { choice in
        Text(choice.title).tag(choice.rawValue)
      }
    } label: {
      Label(L10n.Tools.Tools.Traffic.Map.nodesOnMap, systemImage: "person.2")
    }
    .accessibilityIdentifier("traffic.map.nodes")
    if !model.offMapNodes.isEmpty || !model.unknownRelays.isEmpty {
      Button(
        model.offMapCount > 0 ? L10n.Tools.Tools.Traffic.Map.unplaced(model.offMapCount) : L10n.Tools.Tools.Traffic.Map.OffMap.title,
        systemImage: "mappin.slash"
      ) {
        showsOffMap = true
      }
      .accessibilityHint(L10n.Tools.Tools.Traffic.Map.OffMap.hint)
      .accessibilityIdentifier("traffic.map.offMap")
    }
  }



  private var emptyCard: some View {
    VStack(spacing: 8) {
      Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(L10n.Tools.Tools.Traffic.Map.Empty.title)
        .font(.headline)
      Text(L10n.Tools.Tools.Traffic.Map.Empty.observedDescription)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let stockNote {
        Text(stockNote)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(20)
    .frame(maxWidth: 360)
    .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  // MARK: - Aiming

  /// The picked neighbour, or the traffic node whose callout is open, as the navigation readout's
  /// target: tapping any node draws the line to it, as on the Map tab. This radio's own pin and a
  /// link's anchor get none.
  private func aimTarget(_ neighbours: NodeDiscoveryMapBuilder.Plotted) -> MapNavigationTarget? {
    if let key = scan.selectedKey {
      guard let pointID = neighbours.pointID(for: key),
            let coordinate = neighbours.coordinatesByKey[key] else { return nil }
      let name = scan.sortedResults.first { $0.key == key }?.name ?? coordinate.formattedString
      return MapNavigationTarget(pointID: pointID, name: name, coordinate: coordinate)
    }
    guard let selectedPointID, selectedPointID != TrafficMapModel.lineAnchorID,
          let node = model.node(forPointID: selectedPointID), !node.isRadio,
          let point = model.points.first(where: { $0.id == selectedPointID }),
          point.coordinate.isValidFix else { return nil }
    return MapNavigationTarget(pointID: selectedPointID, name: node.name, coordinate: point.coordinate)
  }

  /// A dashed guide from the phone (or, without a phone fix, this radio) to the picked neighbour:
  /// the line to point the antenna along, from where the phone is now.
  private func aimLines(to target: MapNavigationTarget?) -> [MapLine] {
    guard let target,
          let origin = (live?.location?.coordinate ?? appState.bestAvailableLocation?.coordinate)
            .flatMap({ $0.isValidFix ? $0 : nil }) else { return [] }
    return [.aim(id: "discovery-aim", from: origin, to: target.coordinate, isOnTarget: isOnTarget)]
  }

  /// Runs the aiming readout's location and compass only while the map shows with a node picked.
  private func syncLive(hasTarget: Bool) {
    if isOnScreen, hasTarget {
      live?.start()
    } else {
      live?.stop()
    }
  }

  // MARK: - Camera

  /// The camera's rules for the neighbours and the section, as one modifier so the body stays
  /// within what the type checker takes at once.
  private func neighbourCamera(_ neighbours: NodeDiscoveryMapBuilder.Plotted, hasTarget: Bool) -> NeighbourCameraRules {
    NeighbourCameraRules(
      section: section,
      selectedKey: scan.selectedKey,
      isProbing: scan.isProbing,
      hasNeighbours: !scan.sortedResults.isEmpty,
      points: neighbours.points,
      lines: neighbours.lines,
      openingSource: openingCamera(neighbours)?.source,
      isAuthorized: appState.locationService.isAuthorized,
      isStyleLoaded: isStyleLoaded,
      isFullScreen: isFullScreen,
      hasTarget: hasTarget,
      onAppear: { onAppear(neighbours, hasTarget: hasTarget) },
      onDisappear: {
        traceFit.cancel()
        isOnScreen = false
        syncLive(hasTarget: false)
      },
      onStyleLoaded: {
        if section == .packets {
          if canFitRoutes {
            fitCameraIfNeeded()
          } else if isAtOpeningCamera {
            applyOpeningCamera(neighbours)
          }
        } else if isAtOpeningCamera {
          applyOpeningCamera(neighbours)
        } else {
          fitNeighbours(to: neighbours.fitRegion)
        }
      },
      onOpeningSourceChange: { source in
        guard NodeDiscoveryOpeningCamera.shouldRecenter(
          isAtOpeningCamera: isAtOpeningCamera, current: openingSource, new: source
        ) else { return }
        applyOpeningCamera(neighbours)
      },
      onAuthorized: {
        if isAtOpeningCamera { appState.locationService.requestLocation() }
      },
      onNeighboursChange: {
        if section == .nodes, isFollowingTraces { traceFit.request(neighbours.fitRegion) }
      },
      onProbeEnd: {
        if section == .nodes, scan.selectedKey == nil { traceFit.request(neighbours.fitRegion) }
      },
      onNeighboursCleared: { traceFit.cancel() },
      onSelectionChange: { key in
        isAtOpeningCamera = false
        if let key {
          closeCallout()
          traceFit.cancel()
          center(on: neighbours.coordinatesByKey[key], neighbours: neighbours)
        } else if section == .nodes {
          traceFit.request(neighbours.fitRegion)
        }
      },
      onFullScreenChange: {
        guard section == .nodes else { return }
        if let key = scan.selectedKey {
          center(on: neighbours.coordinatesByKey[key], neighbours: neighbours)
        } else {
          traceFit.request(neighbours.fitRegion)
        }
      },
      onSectionChange: { showSection(neighbours) },
      onTargetChange: { syncLive(hasTarget: $0) }
    )
  }

  private func onAppear(_ neighbours: NodeDiscoveryMapBuilder.Plotted, hasTarget: Bool) {
    // MapLibre's dot already runs a best-accuracy manager here; this one asks for less.
    if live == nil { live = GPSLiveLocation(desiredAccuracy: kCLLocationAccuracyNearestTenMeters) }
    isOnScreen = true
    syncLive(hasTarget: hasTarget)
    traceFit.apply = { region in
      // Following the phone wins over framing the neighbours.
      guard trackingMode == .none else { return }
      isCenteredOnUser = false
      isAtOpeningCamera = false
      fitNeighbours(to: region)
    }
    switch section {
    case .packets:
      // The routes once they're in; until then (or with none to fit) the opening camera, so the
      // page never opens on the whole world.
      if canFitRoutes {
        fitCameraIfNeeded()
      } else {
        isAtOpeningCamera = true
        openingSource = nil
        applyOpeningCamera(neighbours)
      }
    case .nodes:
      // Back from another tab with a neighbour still picked: keep it in view, as before.
      if let key = scan.selectedKey {
        isAtOpeningCamera = false
        center(on: neighbours.coordinatesByKey[key], neighbours: neighbours)
        return
      }
      // Open on the current position, as the location button would show it; a running probe's
      // trace-follow takes over from there as replies land. Forget the last visit's source, so a
      // position that lands later still counts as better.
      isAtOpeningCamera = true
      openingSource = nil
      applyOpeningCamera(neighbours)
    }
  }

  /// The section changed: frame what it is about (`NodeDiscoverySectionCamera`).
  private func showSection(_ neighbours: NodeDiscoveryMapBuilder.Plotted) {
    let selected = scan.selectedKey.flatMap { neighbours.coordinatesByKey[$0] }
    let choice = NodeDiscoverySectionCamera.target(
      for: section,
      hasSelection: selected != nil,
      hasNeighbours: neighbours.fitRegion != nil
    )
    traceFit.cancel()
    isAtOpeningCamera = false
    switch choice {
    case .fitRoutes:
      // Before the map has its size and style a fit lands on the whole world: open on the
      // position meanwhile, and frame the routes once it's ready (`onStyleLoaded`).
      if isStyleLoaded {
        hasFitCamera = true
        fitCamera()
      } else {
        isAtOpeningCamera = true
        openingSource = nil
        applyOpeningCamera(neighbours)
      }
    case .centerOnSelection:
      center(on: selected, neighbours: neighbours)
    case .fitNeighbours:
      trackingMode = .none
      isCenteredOnUser = false
      fitNeighbours(to: neighbours.fitRegion)
    case .opening:
      isAtOpeningCamera = true
      openingSource = nil
      applyOpeningCamera(neighbours)
    }
  }

  /// A state's worth of map around the mesh (the neighbours or the routes, else the phone or
  /// wherever the map is), so the bar's zoom-out button reaches well past the locate button's
  /// close view.
  static let regionSpanDegrees: CLLocationDegrees = 5

  private func zoomToRegion(_ neighbours: NodeDiscoveryMapBuilder.Plotted) {
    trackingMode = .none
    isCenteredOnUser = false
    isAtOpeningCamera = false
    traceFit.cancel()
    let centre = neighbours.fitRegion?.center
      ?? NodeDiscoveryOpeningCamera.routeRegion(fitting: model.fitCoordinates())?.center
      ?? appState.bestAvailableLocation?.coordinate
      ?? cameraRegion?.center
    guard let centre else {
      applyOpeningCamera(neighbours)
      return
    }
    setCameraRegion(MKCoordinateRegion(
      center: centre,
      span: MKCoordinateSpan(latitudeDelta: Self.regionSpanDegrees, longitudeDelta: Self.regionSpanDegrees)
    ))
  }

  /// `CairnMapView` ignores a region whose version matches the last applied one, so move both together.
  private func setCameraRegion(_ region: MKCoordinateRegion?) {
    guard let region else { return }
    cameraRegion = region
    cameraRegionVersion += 1
  }

  /// Frames the routes once, when the packets show and both the map and its nodes are ready, and
  /// they're close enough together to frame.
  private func fitCameraIfNeeded() {
    guard section == .packets, !hasFitCamera, canFitRoutes else { return }
    hasFitCamera = true
    fitCamera()
  }

  /// The routes can be framed now: the map and its nodes are in, and they fit without zooming
  /// out to the whole world.
  private var canFitRoutes: Bool {
    isStyleLoaded && model.hasLoadedDirectory && NodeDiscoveryOpeningCamera.routeRegion(fitting: model.fitCoordinates()) != nil
  }

  /// Frames the routes the packets took, as the Traffic map does; with none to fit, or only too
  /// far apart to frame, the opening camera (the phone, else the radio, else the last camera).
  private func fitCamera() {
    trackingMode = .none
    isCenteredOnUser = false
    guard let region = NodeDiscoveryOpeningCamera.routeRegion(fitting: model.fitCoordinates()) else {
      isAtOpeningCamera = true
      openingSource = nil
      applyOpeningCamera(neighbours)
      return
    }
    isAtOpeningCamera = false
    setCameraRegion(region)
  }

  /// Where the page opens: the phone (when location is allowed), else this radio, else the
  /// neighbours, else the camera when the page was last left; never the map's whole-world start.
  private func openingCamera(_ neighbours: NodeDiscoveryMapBuilder.Plotted) -> NodeDiscoveryOpeningCamera.Target? {
    let location = appState.locationService
    let radio = appState.connectedDevice.flatMap { device in
      device.hasLocation ? CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude) : nil
    }
    // Opens a state's worth of map around you, the Zoom to Region button's view, rather than the
    // locate button's close one.
    return NodeDiscoveryOpeningCamera.target(
      phone: location.isAuthorized ? location.currentLocation?.coordinate : nil,
      radio: radio,
      traces: neighbours.fitRegion,
      saved: MapCameraStore.decode(savedCameraRegion),
      span: Self.regionSpanDegrees
    )
  }

  /// Puts the camera where the Nodes section opens, inside the part of the map the overlays
  /// leave clear. With no position and no neighbours it leaves the camera alone.
  private func applyOpeningCamera(_ neighbours: NodeDiscoveryMapBuilder.Plotted) {
    guard let target = openingCamera(neighbours) else { return }
    openingSource = target.source
    isCenteredOnUser = target.source != .traces
    fitNeighbours(to: target.region)
  }

  /// Pans to a picked neighbour, keeping the zoom so its link to this radio stays in context.
  /// While following the phone the camera stays put; the guide line and readout point the way.
  private func center(on coordinate: CLLocationCoordinate2D?, neighbours: NodeDiscoveryMapBuilder.Plotted) {
    guard let coordinate, trackingMode == .none else { return }
    isCenteredOnUser = false
    let span = cameraRegion?.span ?? neighbours.fitRegion?.span
      ?? MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    setCameraRegion(MKCoordinateRegion(center: coordinate, span: span))
  }

  /// Frames the neighbours inside the part of the map the readout, the controls and the ticker
  /// leave clear. The results sheet is already outside the viewport (`contentBottomInset`), which
  /// the fit counts as the bottom of the safe area.
  private func fitNeighbours(to region: MKCoordinateRegion?) {
    guard let region else { return }
    setCameraRegion(region)
    var overlays = TraceCameraFit.overlayInsets(hasStatusPill: true)
    overlays.bottom += bottomOverlayHeight
    overlays.top += topOverlayHeight
    cameraFitPadding = MapCameraFitPadding(regionVersion: cameraRegionVersion, overlays: overlays)
  }

  /// The location button, as on the GPS map: center and follow, then turn with the heading, then
  /// stop. Without the phone's own position it stays a one-shot recenter (which falls back to the
  /// radio's position).
  private func cycleTracking() {
    let isHeadingAvailable = live?.isHeadingAvailable ?? false
    let next = trackingMode.next(isNorthLocked: isNorthLocked, isHeadingAvailable: isHeadingAvailable)
    if trackingMode == .none {
      traceFit.cancel()
      isAtOpeningCamera = false
      isCenteredOnUser = appState.centerOnUserLocation { setCameraRegion($0) }
      guard isCenteredOnUser, canFollowPhone else { return }
    }
    trackingMode = next
  }

  /// Which of the compass's three modes the map is in.
  private var compassMode: MapCompassButton.Mode {
    if isNorthLocked { return .northLocked }
    return trackingMode == .followWithHeading ? .headingUp : .northUp
  }

  /// The compass tap: north up → heading up → north locked → north up. A map turned or tilted by
  /// hand in north-up first goes back to north-up and flat. Heading up needs the phone's compass
  /// and location; without them the cycle skips it.
  private func compassTapped() {
    switch compassMode {
    case .northUp:
      if cameraOrientation.isRotatedOrTilted {
        resetOrientationVersion += 1
      } else if !startHeadingUp() {
        isNorthLocked = true
      }
    case .headingUp:
      trackingMode = .follow
      isNorthLocked = true
      resetOrientationVersion += 1
    case .northLocked:
      isNorthLocked = false
    }
  }

  /// Centres on the phone and follows it with the map turned to its heading, as the location
  /// button's last step does. False when the phone has no compass or the map can't follow it.
  private func startHeadingUp() -> Bool {
    guard live?.isHeadingAvailable ?? false, canFollowPhone else { return false }
    if trackingMode == .none {
      traceFit.cancel()
      isAtOpeningCamera = false
      isCenteredOnUser = appState.centerOnUserLocation { setCameraRegion($0) }
      guard isCenteredOnUser else { return false }
    }
    trackingMode = .followWithHeading
    return true
  }

  private var canFollowPhone: Bool {
    switch live?.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }

  /// A first look replays the latest traffic, so the map shows how the mesh's packets flow
  /// before the next one arrives. Only the first look this app session for the radio
  /// (`TrafficAutoReplay`), once both the nodes and the stored log are in: not when the device
  /// turns or the page is opened again, and a log that was empty then stays unreplayed, so a later
  /// node reload (an advert's echoes, the radio's position read back) never retraces packets
  /// already seen live.
  private func replayIfNeeded() {
    guard model.hasLoadedDirectory, hasLoadedHistory,
          TrafficAutoReplay.claim(for: appState.currentRadioID) else { return }
    guard !reduceMotion, !entries.isEmpty else { return }
    model.replay(entries)
  }

  /// "Replaying" over the top of the map while a replay retraces the latest traffic.
  private var replayingChip: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      if model.isReplaying(at: context.date) {
        Label(L10n.Tools.Tools.Traffic.Map.replaying, systemImage: "play.circle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.85), in: Capsule())
          .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
          .transition(.scale(scale: 0.9).combined(with: .opacity))
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .animation(.snappy, value: model.replayEndsAt)
    .allowsHitTesting(false)
  }
}

/// When the neighbours' camera moves, as Scan for Nodes' map moved it: on appear, once the style
/// loads, as a better opening position lands, while a probe's replies land, on a pick, when the
/// map changes size, and when the section changes. The map hands each its action.
private struct NeighbourCameraRules: ViewModifier {
  let section: NodeDiscoverySection
  let selectedKey: Data?
  let isProbing: Bool
  let hasNeighbours: Bool
  let points: [MapPoint]
  let lines: [MapLine]
  let openingSource: NodeDiscoveryOpeningCamera.Source?
  let isAuthorized: Bool
  let isStyleLoaded: Bool
  let isFullScreen: Bool
  let hasTarget: Bool
  let onAppear: () -> Void
  let onDisappear: () -> Void
  let onStyleLoaded: () -> Void
  let onOpeningSourceChange: (NodeDiscoveryOpeningCamera.Source?) -> Void
  let onAuthorized: () -> Void
  let onNeighboursChange: () -> Void
  let onProbeEnd: () -> Void
  let onNeighboursCleared: () -> Void
  let onSelectionChange: (Data?) -> Void
  let onFullScreenChange: () -> Void
  let onSectionChange: () -> Void
  let onTargetChange: (Bool) -> Void

  func body(content: Content) -> some View {
    content
      .onAppear(perform: onAppear)
      .onDisappear(perform: onDisappear)
      .onChange(of: isStyleLoaded) { _, loaded in
        if loaded { onStyleLoaded() }
      }
      // The phone's first fix (or the radio's position) can land a moment after the map opens:
      // move there once, unless the camera has been moved since.
      .onChange(of: openingSource) { _, source in onOpeningSourceChange(source) }
      // Location allowed only now, from the prompt the screen raised as it opened: ask for the fix
      // the opening camera is waiting on.
      .onChange(of: isAuthorized) { _, authorized in
        if authorized { onAuthorized() }
      }
      // Keep this radio and every neighbour in frame while a probe listens, refitting as replies,
      // positions and names update. Bursts are coalesced and a fit waits out a drag or pinch.
      .onChange(of: points) { _, _ in onNeighboursChange() }
      .onChange(of: lines) { _, _ in onNeighboursChange() }
      // One more fit once the probe finishes.
      .onChange(of: isProbing) { wasProbing, probing in
        if wasProbing, !probing { onProbeEnd() }
      }
      .onChange(of: hasNeighbours) { _, has in
        if !has { onNeighboursCleared() }
      }
      .onChange(of: selectedKey) { _, key in onSelectionChange(key) }
      .onChange(of: isFullScreen) { _, _ in onFullScreenChange() }
      .onChange(of: section) { _, _ in onSectionChange() }
      .onChange(of: hasTarget) { _, has in onTargetChange(has) }
  }
}

// MARK: - Overlays

/// The ticker under the map: the packet whose laser is running now, following each as it
/// starts, else the last to land; its route scrolling past when it's too long for the card, with
/// how it came (flood or direct, hops), how strongly it was heard and how long ago. Then the
/// colour key for the lasers. Also under the main map while its traffic layer is on.
struct TrafficTickerCard: View {
  let flights: [TrafficFlight]
  let lastFinished: TrafficFlight?
  /// Opens the packet list: the card becomes a button, with a chevron by the colour key.
  var onOpenList: (() -> Void)?
  /// What the radio's firmware never passes on, as the listening line's hint. Nil says nothing.
  var stockNote: String?
  /// Drawn as two lines inside a sheet (Scan & Traffic's lowered sheet, under its mini spectrum):
  /// the packet and its figures, without the card, the colour key, or the lines the map shows.
  var isInline = false
  /// Drawn as a strip along the whole top of the map (Scan & Traffic on an iPad): the packet
  /// and its lines over a dark fade into the map, no card and no colour key (`TrafficLegendChip`
  /// sits in the bottom corner).
  var isStrip = false

  /// "Flood 2", "Direct", or "Direct 3", as the Spectrum traffic table says it; for a send, what
  /// the radio answered.
  private static func routeTitle(_ flight: TrafficFlight) -> String {
    // Just sent from here: nothing heard back yet.
    if flight.isSent { return sendTitle(flight.transmission) }
    if flight.isFlood { return L10n.Tools.Tools.Spectrum.Route.flood(flight.hopCount) }
    return flight.hopCount > 0 ? L10n.Tools.Tools.Spectrum.Route.directHops(flight.hopCount) : L10n.Tools.Tools.RxLog.direct
  }

  /// "Radio accepted · flood", "The radio didn't send this", "Radio didn't confirm", or "Sent"
  /// while the radio hasn't answered.
  static func sendTitle(_ transmission: TrafficFlight.Transmission?) -> String {
    switch transmission {
    case let .accepted(route)?:
      guard let route else { return L10n.Chats.Chats.Message.Status.sent }
      return L10n.Tools.Tools.Traffic.Sent.accepted(
        route == .flood ? L10n.Tools.Tools.Traffic.Sent.routeFlood : L10n.Tools.Tools.Traffic.Sent.routeDirect
      )
    case .rejected?: return L10n.Tools.Tools.Traffic.Sent.rejected
    case .unconfirmed?: return L10n.Tools.Tools.Traffic.Sent.unconfirmed
    case .pending?, nil: return L10n.Chats.Chats.Message.Status.sent
    }
  }

  /// "Heard from Claremont · 6.5 dB", or the transmitter's hash when no node heard on this
  /// channel has it: the one link this radio observed. Nil when the packet doesn't say who
  /// transmitted it.
  static func heardFromLine(_ flight: TrafficFlight) -> String? {
    guard !flight.isSent, let name = flight.transmitterName else { return nil }
    guard let snr = flight.snr else { return L10n.Tools.Tools.Traffic.Link.heardFrom(name) }
    return L10n.Tools.Tools.Traffic.Link.heardFromSignal(name, "\(SpectrumPacketFormat.snr(snr)) dB")
  }

  /// "Flood 4 · -92 dBm · SNR 6.5 · 2 not on map · 4s"
  private static func detailLine(_ flight: TrafficFlight, now: Date) -> String {
    [
      routeTitle(flight),
      flight.rssi.map { SpectrumFormat.dBm(Double($0)) },
      flight.snr.map { L10n.Tools.Tools.Spectrum.Detail.snr(SpectrumPacketFormat.snr($0)) },
      flight.unplacedHops > 0 ? L10n.Tools.Tools.Traffic.Map.unplaced(flight.unplacedHops) : nil,
      SpectrumPacketFormat.age(now.timeIntervalSince(flight.receivedAt)),
    ].compactMap(\.self).joined(separator: " · ")
  }

  /// "Not on map: Claremont, Alex", as the RX Log list names them; nil when the map placed every
  /// node the packet names.
  private static func offMapLine(_ flight: TrafficFlight) -> String? {
    guard !flight.offMap.isEmpty else { return nil }
    let names = flight.offMap.map(\.displayName).formatted(.list(type: .and, width: .narrow))
    return L10n.Tools.Tools.Traffic.Map.OffMap.flight(names)
  }

  /// The newest laser to have left its first stop; a replay's later ones wait their turn.
  private func current(at now: Date) -> TrafficFlight? {
    flights.filter { $0.startTime <= now }.max { $0.startTime < $1.startTime } ?? lastFinished
  }

  var body: some View {
    if let onOpenList {
      card
        .contentShape(isStrip ? .rect(cornerRadius: 0) : .rect(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onOpenList)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L10n.Tools.Tools.Spectrum.Traffic.seeAllHint)
        .accessibilityAction { onOpenList() }
    } else {
      card
    }
  }

  @ViewBuilder
  private var card: some View {
    if isInline {
      currentPacket
    } else if isStrip {
      HStack(alignment: .bottom, spacing: 12) {
        currentPacket
        if onOpenList != nil {
          Image(systemName: "chevron.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      // The map shows through: a fade from dark at the top edge, under the bar too, to nothing
      // where the map takes over; the text in light on it whatever the appearance.
      .background {
        LinearGradient(
          colors: [.black.opacity(0.7), .black.opacity(0.45), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea(edges: [.horizontal, .top])
      }
      .environment(\.colorScheme, .dark)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        currentPacket
        TrafficLaserLegend()
      }
      .padding(14)
      .frame(maxWidth: 520)
      // The thinnest material, so the map shows through the Map tab's footer.
      .background(.ultraThinMaterial, in: .rect(cornerRadius: 18, style: .continuous))
      .clipShape(.rect(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 1)
      }
    }
  }

  /// The packet's signal, size and age line under the route.
  private func detailText(_ flight: TrafficFlight, now: Date) -> some View {
    Text(Self.detailLine(flight, now: now))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
  }

  private var currentPacket: some View {
      TimelineView(.periodic(from: .now, by: 0.5)) { context in
        let flight = current(at: context.date)
        Group {
          if let flight {
            // The route has the first row to itself, the whole width to scroll in (the user,
            // 2026-11-07); the kind's badge leads the row under it.
            let heardFrom = isInline ? nil : Self.heardFromLine(flight)
            VStack(alignment: .leading, spacing: 3) {
              MarqueeText(text: flight.routeLine, font: .subheadline.weight(.medium))
              HStack(spacing: 8) {
                SpectrumKindPill(kind: flight.kind, showsName: true)
                if let heardFrom {
                  Text(heardFrom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                  detailText(flight, now: context.date)
                }
              }
              if heardFrom != nil {
                detailText(flight, now: context.date)
              }
              // The nodes the packet names that the map can't place, by name, as it lands.
              if !isInline, let offMap = Self.offMapLine(flight) {
                Label(offMap, systemImage: "mappin.slash")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .id(flight.id)
            .transition(.push(from: .bottom).combined(with: .opacity))
          } else {
            Label(L10n.Tools.Tools.Traffic.Map.listening, systemImage: "antenna.radiowaves.left.and.right")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityHint(stockNote ?? "")
          }
        }
        .animation(.snappy, value: flight?.id)
        // The outgoing line slides away inside the card, not over the map above it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
      }
  }

}

/// The lasers' colour key: every packet type by name, as many to a line as fit.
struct TrafficLaserLegend: View {
  var body: some View {
    FlowRow(spacing: 8) {
      ForEach(SpectrumPacketKind.legendOrder, id: \.self) { kind in
        HStack(spacing: 4) {
          Capsule()
            .fill(TrafficLaserTiming.color(for: kind).gradient)
            .frame(width: 12, height: 4)
          Text(kind.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
      }
    }
  }
}

/// The colour key on its own small chip, for the map's bottom-right corner (Scan & Traffic on an
/// iPad), under MapLibre's logo and over the ticker strip.
struct TrafficLegendChip: View {
  var body: some View {
    TrafficLaserLegend()
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("nodeDiscovery.map.legend")
  }
}
