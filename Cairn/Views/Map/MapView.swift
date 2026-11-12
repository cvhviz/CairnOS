import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// Map view displaying contacts and optionally discovered nodes with their locations
struct MapView: View {
  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.mapStyleSelection.rawValue) private var mapStyleSelection: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapShowLabels.rawValue) private var showLabels = AppStorageKey.defaultMapShowLabels
  @AppStorage(AppStorageKey.mapClusteringEnabled.rawValue)
  private var clusteringEnabled = AppStorageKey.defaultMapClusteringEnabled
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @AppStorage(AppStorageKey.mapFilterMainMap.rawValue)
  private var mapFilterRaw: String = ""
  @AppStorage(AppStorageKey.hiddenMapNodes.rawValue) private var hiddenMapNodesData = Data()
  @SceneStorage(SceneStorageKey.mapCameraRegion.rawValue) private var savedCameraRegion = ""
  @State private var viewModel = MapViewModel()
  @State private var selectedCallout: MapCalloutSelection?
  @State private var selectedPointScreenPosition: CGPoint?
  @State private var selectedContactForDetail: ContactDTO?
  @State private var selectedDiscoveredForDetail: DiscoveredNodeDTO?
  @State private var addingDiscoveredNodeID: UUID?
  @State private var isStyleLoaded = false
  @State private var showingHiddenNodes = false
  /// Public keys hidden from the current radio's map, decoded when the stored list or the radio
  /// changes rather than on every render.
  @State private var hiddenNodeKeys: Set<Data> = []
  /// The pin `focus` resolved to, selected once the map data and style are both loaded.
  @State private var focusPointID: UUID?
  @State private var focusSelectionVersion = 0
  @State private var hasSelectedFocus = false
  /// Line of Sight opened from the readout, pushed onto this map's stack.
  @State private var lineOfSight: LineOfSightRequest?

  private var isAddingDiscovered: Bool {
    addingDiscoveredNodeID != nil
  }

  private var mapFilter: MapFilterState {
    MapFilterPreferences.state(fromRaw: mapFilterRaw, host: .mainMap)
  }

  private var mapFilterBinding: Binding<MapFilterState> {
    MapFilterPreferences.binding(raw: $mapFilterRaw, host: .mainMap)
  }

  private func decodeHiddenNodeKeys() -> Set<Data> {
    guard let radioID = appState.currentRadioID else { return [] }
    return HiddenMapNodesStorage.decode(hiddenMapNodesData).publicKeys(for: radioID)
  }

  /// Re-reads the hidden keys; the map follows only when they really changed.
  private func refreshHiddenNodeKeys() {
    let keys = decodeHiddenNodeKeys()
    guard keys != hiddenNodeKeys else { return }
    hiddenNodeKeys = keys
    clearSelection()
    viewModel.setHiddenKeys(keys)
  }

  /// Hosted inside another tab's `NavigationStack` (the GPS tab's Map segment), which supplies
  /// the stack, the radio status item and the title. Standalone, the map brings its own.
  var isEmbedded = false

  /// The GPS tab's way back to its readings, as a back button in place of the refresh button.
  /// The map reloads on its own as nodes change, so refresh is the one to give up.
  var onShowData: (() -> Void)?
  /// What VoiceOver calls `onShowData`'s button: the GPS tab's readings by default, "Back" on a
  /// node's map, where the same chevron closes it.
  var showDataTitle: String?

  /// A node to open on, selected as if tapped (see `MapNodeFocus`). The camera then starts on it
  /// rather than where the GPS tab's map was left, and moving it isn't saved for that map.
  var focus: MapNodeFocus?

  var body: some View {
    if isEmbedded {
      mapContent
    } else {
      NavigationStack {
        mapContent
          .deviceNameTitle(pageTitle: L10n.Localizable.Tabs.map, floatsOverContent: true)
      }
    }
  }

  private var mapContent: some View {
    Group {
      MapCanvasView(
        viewModel: viewModel,
        mapStyleSelection: $mapStyleSelection,
        showLabels: $showLabels,
        clusteringEnabled: $clusteringEnabled,
        isNorthLocked: $isNorthLocked,
        selectedCallout: $selectedCallout,
        selectedPointScreenPosition: $selectedPointScreenPosition,
        isStyleLoaded: $isStyleLoaded,
        isAddingDiscovered: isAddingDiscovered,
        filter: MapFilterControl(
          host: .mainMap,
          state: mapFilterBinding,
          hiddenNodeCount: viewModel.hiddenNodes.count,
          onShowHiddenNodes: { showHiddenNodes() }
        ),
        onShowContactDetail: { showContactDetail($0) },
        onNavigateToChat: { navigateToChat(with: $0) },
        onShowDiscoveredDetail: { showDiscoveredDetail($0) },
        onAddDiscovered: { addDiscoveredNode($0) },
        onCenterOnUser: { centerOnUserLocation() },
        onClearSelection: { clearSelection() },
        onPersistCamera: { region in
          guard focus == nil else { return }
          savedCameraRegion = MapCameraStore.encode(region)
        },
        onSelectNode: { publicKey, coordinate in selectSearched(publicKey: publicKey, coordinate: coordinate) },
        onSendMyLocation: { sendMyLocation(to: $0) },
        selectionRequestID: focusPointID,
        selectionRequestVersion: focusSelectionVersion,
        onCheckLineOfSight: { lineOfSight = $0 }
      )
      .navigationDestination(item: $lineOfSight) { request in
        LineOfSightView(
          from: request.origin,
          to: request.target,
          contact: request.contact,
          discovered: request.discovered
        )
        .flashingNavigationTitle(L10n.Tools.Tools.lineOfSight)
        .navigationBarTitleDisplayMode(.inline)
      }
      .toolbar {
        // On the Map tab, back to its readings on the left, the title centred and the sliders on the
        // right, as a button each side of it on every page.
        if let onShowData {
          ToolbarItem(placement: .topBarLeading) {
            Button(action: onShowData) {
              Label(showDataTitle ?? L10n.Map.Map.Gps.Segment.data, systemImage: "chevron.left")
                .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("gps.backToData")
          }
        } else {
          ToolbarItem(placement: .topBarTrailing) {
            MapRefreshButton(
              isLoading: viewModel.isLoading,
              onRefresh: {
                viewModel.cancelPendingReload()
                await viewModel.loadMapData(
                  filter: mapFilter,
                  showsLoadingChrome: true
                )
              }
            )
          }
        }
      }
      .task {
        appState.locationService.requestPermissionIfNeeded()
        appState.locationService.requestLocation()
        configureViewModel()
        // Empty stays empty (seed without write); corrupt loads are repaired.
        MapFilterPreferences.ensureMigrated(raw: &mapFilterRaw, host: .mainMap)
        hiddenNodeKeys = decodeHiddenNodeKeys()
        viewModel.setHiddenKeys(hiddenNodeKeys)
        await viewModel.loadMapData(
          filter: mapFilter,
          showsLoadingChrome: true
        )
        if let focus {
          // Once: coming back to the map shouldn't pull it back onto the node.
          if focusPointID == nil { resolveFocus(focus) }
          return
        }
        #if DEBUG
          // Screenshot runs open the first contact's callout: `-uiTestMapCallout YES`.
          if UserDefaults.standard.bool(forKey: "uiTestMapCallout"), focusPointID == nil,
             let point = viewModel.mapPoints.first(where: { viewModel.contact(forPointID: $0.id) != nil }),
             let contact = viewModel.contact(forPointID: point.id) {
            resolveFocus(.node(publicKey: contact.publicKey, coordinate: point.coordinate))
            return
          }
        #endif
        // On first appearance the view model has no camera region; restoring here
        // keeps the map where the user left it across launches instead of re-framing.
        viewModel.applyInitialCamera(
          saved: MapCameraStore.decode(savedCameraRegion),
          hasPendingFocus: appState.navigation.pendingMapFocus != nil
        )
      }
      .onChange(of: isStyleLoaded) { _, _ in selectFocusIfReady() }
      .onChange(of: mapFilterRaw) { _, _ in
        clearSelection()
        selectedContactForDetail = nil
        selectedDiscoveredForDetail = nil
        viewModel.scheduleFilterChange(mapFilter)
      }
      // A hide or restore here, a backup restore writing the key, or a different radio.
      .onChange(of: hiddenMapNodesData) { _, _ in refreshHiddenNodeKeys() }
      .onChange(of: appState.currentRadioID) { _, _ in refreshHiddenNodeKeys() }
      .onChange(of: viewModel.hiddenNodes.isEmpty) { _, isEmpty in
        if isEmpty { showingHiddenNodes = false }
      }
      .sheet(isPresented: $showingHiddenNodes) {
        HiddenMapNodesSheet(
          nodes: viewModel.hiddenNodes,
          onShow: { node in updateHiddenNodes { $0.show(node.publicKey, radioID: $1) } },
          onShowAll: { updateHiddenNodes { $0.showAll(radioID: $1) } }
        )
        .presentationDetents([.medium, .large])
      }
      // A Remove Nodes run takes its nodes off the map at once; the radio works through them.
      .onChange(of: appState.nodeRemoval.removingKeys, initial: true) { _, keys in
        viewModel.setRemovingKeys(keys)
      }
      .onChange(of: appState.contactsVersion) { _, _ in
        // contactsVersion also bumps after backup import; re-migrate while the tab is mounted.
        MapFilterPreferences.ensureMigrated(raw: &mapFilterRaw, host: .mainMap)
        viewModel.scheduleCoalescedReload(filter: mapFilter)
      }
      .onChange(of: appState.servicesVersion) { _, _ in
        configureViewModel()
        viewModel.scheduleCoalescedReload(filter: mapFilter)
      }
      .onChange(of: appState.navigation.pendingMapFocus, initial: true) { _, request in
        // A chat's coordinate is for the GPS tab's map, not one opened on a node.
        guard focus == nil, let request else { return }
        viewModel.focusOnCoordinate(request.coordinate)
        appState.navigation.clearPendingMapFocus()
      }
      .detailPresentation(item: $selectedContactForDetail, route: { .contact(id: $0.id, canHideFromMap: true) }) { contact in
        ContactDetailSheet(
          contact: contact,
          onMessage: { navigateToChat(with: contact) },
          onDelete: {
            Task {
              await viewModel.loadMapData(
                filter: mapFilter,
                showsLoadingChrome: false
              )
            }
          },
          onHide: { hideNode(contact.publicKey) }
        )
        .presentationDetents([.large])
      }
      .detailPresentation(item: $selectedDiscoveredForDetail, route: {
        .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: true)
      }) { node in
        DiscoveredNodeDetailSheet(
          node: node,
          isAdding: addingDiscoveredNodeID == node.id,
          onAdd: { addDiscoveredNode(node) },
          onHide: { hideNode(node.publicKey) }
        )
        .presentationDetents([.medium, .large])
      }
      .errorAlert($viewModel.errorMessage)
      .liquidGlassToolbarBackground()
    }
  }

  // MARK: - Actions

  private func configureViewModel() {
    viewModel.configure(
      dataStore: { [appState] in appState.offlineDataStore },
      radioID: { [appState] in appState.currentRadioID },
      selfPublicKey: { [appState] in appState.connectedDevice?.publicKey }
    )
  }

  private func clearSelection() {
    selectedCallout = nil
    selectedPointScreenPosition = nil
  }

  private func navigateToChat(with contact: ContactDTO) {
    clearSelection()
    appState.navigation.navigateToChat(with: contact)
  }

  private func showContactDetail(_ contact: ContactDTO) {
    clearSelection()
    selectedContactForDetail = contact
  }

  private func showDiscoveredDetail(_ node: DiscoveredNodeDTO) {
    clearSelection()
    selectedDiscoveredForDetail = node
  }

  private func showHiddenNodes() {
    clearSelection()
    showingHiddenNodes = true
  }

  private func hideNode(_ publicKey: Data) {
    clearSelection()
    selectedContactForDetail = nil
    selectedDiscoveredForDetail = nil
    updateHiddenNodes { $0.hide(publicKey, radioID: $1) }
  }

  /// Applies `update` to the stored hidden nodes for the current radio. The map follows through
  /// `hiddenNodeKeys`, the same path a restore takes.
  private func updateHiddenNodes(_ update: (inout HiddenMapNodes, UUID) -> Void) {
    guard let radioID = appState.currentRadioID else { return }
    var hidden = HiddenMapNodesStorage.decode(hiddenMapNodesData)
    update(&hidden, radioID)
    guard let data = HiddenMapNodesStorage.encode(hidden) else { return }
    hiddenMapNodesData = data
  }

  private func addDiscoveredNode(_ node: DiscoveredNodeDTO) {
    guard addingDiscoveredNodeID == nil else { return }
    guard let contactService = appState.services?.contactService else {
      viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    clearSelection()
    addingDiscoveredNodeID = node.id
    Task {
      defer { addingDiscoveredNodeID = nil }
      do {
        try await contactService.addOrUpdateContact(
          radioID: node.radioID,
          contact: node.makeContactFrame()
        )
        await viewModel.loadMapData(
          filter: mapFilter,
          showsLoadingChrome: false
        )
        selectedDiscoveredForDetail = nil
      } catch ContactServiceError.contactTableFull {
        let maxContacts = appState.connectedDevice?.maxContacts
        if let maxContacts {
          viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFull(Int(maxContacts))
        } else {
          viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
        }
      } catch {
        viewModel.errorMessage = error.userFacingMessage
      }
    }
  }

  private func centerOnUserLocation() -> Bool {
    appState.centerOnUserLocation { viewModel.setCameraRegion($0) }
  }

  /// A node picked in the map's search: centred and selected as a tap would, every time.
  private func selectSearched(publicKey: Data, coordinate: CLLocationCoordinate2D) {
    clearSelection()
    hasSelectedFocus = false
    resolveFocus(.node(publicKey: publicKey, coordinate: coordinate))
  }

  /// Send My Location from a contact's callout: the chat opens with where you are (the phone's
  /// fix, or the radio's position) already typed, as the chat's share menu would insert it.
  /// Without either there is nothing to send, and the alert says so.
  private func sendMyLocation(to contact: ContactDTO) {
    guard let location = appState.bestAvailableLocation, location.coordinate.isValidFix else {
      viewModel.errorMessage = L10n.Localizable.Error.Intent.noLocation
      return
    }
    let text = ChatShareMenu.coordinateText(for: location.coordinate)
    let id = ChatConversationID.dm(radioID: contact.radioID, contactID: contact.id)
    let existing = appState.draftStore.draft(for: id) ?? ""
    let separator = existing.isEmpty || existing.last?.isWhitespace == true ? "" : " "
    appState.draftStore.setDraft(existing + separator + text, for: id)
    navigateToChat(with: contact)
  }

  /// Centers on the focused node and picks its pin to select. A node the map doesn't show
  /// (filtered out or hidden) gets a dropped pin where it is, so there is still one to aim at.
  private func resolveFocus(_ focus: MapNodeFocus) {
    switch focus {
    case let .thisRadio(coordinate):
      // The radio's pin is where it says it is; a GPS fix it doesn't advertise has no pin.
      if let device = appState.connectedDevice, device.hasLocation {
        viewModel.focusOnNode(at: CLLocationCoordinate2D(latitude: device.latitude, longitude: device.longitude))
        focusPointID = MapCalloutSelection.thisRadioID
      } else {
        viewModel.focusOnCoordinate(coordinate)
        focusPointID = MapViewModel.focusedPinID
      }
    case let .node(publicKey, coordinate):
      if let pointID = viewModel.pointID(forPublicKey: publicKey),
         let point = viewModel.mapPoints.first(where: { $0.id == pointID }) {
        // On the pin itself, which can sit apart from a telemetry fix the page showed.
        viewModel.focusOnNode(at: point.coordinate)
        focusPointID = pointID
      } else {
        viewModel.focusOnCoordinate(coordinate)
        focusPointID = MapViewModel.focusedPinID
      }
    }
    selectFocusIfReady()
  }

  /// Selects the focused pin once, after the data has loaded and the style can draw it. The
  /// selection goes through the map's own tap path, so the callout opens and the readout and
  /// guide line aim at the node exactly as a tap would.
  private func selectFocusIfReady() {
    guard !hasSelectedFocus, focusPointID != nil, isStyleLoaded else { return }
    hasSelectedFocus = true
    focusSelectionVersion += 1
  }
}

// MARK: - Line of Sight

/// Line of Sight from where you are to the map's target, opened from the navigation readout.
struct LineOfSightRequest: Hashable {
  let id = UUID()
  let origin: CLLocationCoordinate2D
  let target: CLLocationCoordinate2D
  let contact: ContactDTO?
  let discovered: DiscoveredNodeDTO?

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Opening on a node

/// A node the GPS tab's map opens on, from the header map at the top of a node's page.
enum MapNodeFocus {
  /// A contact or heard node, by key, at the position its page shows.
  case node(publicKey: Data, coordinate: CLLocationCoordinate2D)
  /// This radio's own pin, from Device Info, at the position its page shows.
  case thisRadio(coordinate: CLLocationCoordinate2D)
}

/// The GPS tab's map, opened from a node page's header map with that node selected: the same
/// pins, navigation readout, guide line, compass and controls, so the node can be aimed at from
/// where it is shown. Pushed onto the page's stack, or presented with `isPresented` for a Done
/// button and a stack of its own.
///
/// It is the GPS tab's Map segment as that tab shows it (the user, 2026-11-07: the node's map was a
/// different, older presentation): the radio's name as the title, the chevron at the top left
/// (here closing the map), the Maps & GPS sliders at the top right, and the position readings this
/// radio's callout shows. Presented, it covers the screen (`nodeMapPresentation`), as the tab does.
struct NodeOnMapView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  /// The readings this radio's callout shows, as the GPS tab hands them to its map.
  @State private var model = GNSSDashboardModel()

  let focus: MapNodeFocus
  let title: String
  var isPresented = false

  var body: some View {
    if isPresented {
      NavigationStack { map }
    } else {
      map
        // The map's own chevron is the way back, as on the GPS tab.
        .navigationBarBackButtonHidden(true)
    }
  }

  private var map: some View {
    MapView(isEmbedded: true, onShowData: { dismiss() }, showDataTitle: L10n.Localizable.Common.back, focus: focus)
      .environment(model)
      .deviceNameTitle(pageTitle: L10n.Localizable.Tabs.map)
      .tabSettingsToolbarItem(for: .gps)
      .accessibilityLabel(title)
      .task {
        model.loadPreferences(for: appState.connectedDevice)
        await model.refresh(appState: appState, isActive: true)
      }
  }
}

extension View {
  /// A node's map, full screen as the GPS tab's map is; on a Mac (an iPad app there), pushed onto
  /// the page's stack, as node pages are.
  @ViewBuilder
  func nodeMapPresentation<Content: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping (_ isPresented: Bool) -> Content
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      navigationDestination(isPresented: isPresented) { content(false) }
    } else {
      fullScreenCover(isPresented: isPresented) { content(true) }
    }
  }

  /// `nodeMapPresentation(isPresented:)` for a presenter that holds the item to show.
  @ViewBuilder
  func nodeMapPresentation<Item: Identifiable & Hashable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (_ item: Item, _ isPresented: Bool) -> Content
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      navigationDestination(item: item) { content($0, false) }
    } else {
      fullScreenCover(item: item) { content($0, true) }
    }
  }
}

// MARK: - Map Refresh Button

private struct MapRefreshButton: View {
  let isLoading: Bool
  let onRefresh: () async -> Void

  var body: some View {
    Button(L10n.Map.Map.Controls.refresh, systemImage: "arrow.clockwise") {
      Task {
        await onRefresh()
      }
    }
    .labelStyle(.iconOnly)
    .disabled(isLoading)
    .opacity(isLoading ? 0 : 1)
    .overlay {
      if isLoading {
        ProgressView()
      }
    }
  }
}

// MARK: - Preview

#Preview {
  MapView()
    .environment(\.appState, AppState())
}
