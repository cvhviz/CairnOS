import CoreLocation
import CairnServices
import SwiftUI
import UniformTypeIdentifiers

/// The Nodes tab's Heard list: nodes heard by advert that aren't saved on the radio. Shown in
/// place under the tab's Saved | Heard picker (`ContactsSidebarContent`), which owns the title,
/// the search field and the view model, so the list survives a switch to Saved and back. This
/// view brings Heard's own toolbar items: Select, layout, sort and More.
struct DiscoveryView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: DiscoveryViewModel
  /// The tab's search text, applied while this list shows, and typed in the field above the list.
  @Binding var searchText: String
  let searchPrompt: String
  /// At regular width (the iPad split) a tapped node opens in the detail column beside the list
  /// (`NavigationCoordinator.selectedHeardNode`) rather than as a sheet over it.
  var opensDetailInColumn = false
  @State private var selectedSegment: DiscoverSegment = .all
  /// Bumped after the search field has been scrolled into view, so the field takes focus (⌘F).
  @State private var searchFocusRequest = 0
  /// The filter header's height, so the empty state centres in the space under it.
  @State private var headerHeight: CGFloat = 0
  @AppStorage(AppStorageKey.discoverySortOrder.rawValue) private var sortOrder: NodeSortOrder = .lastHeard
  /// One layout for both lists, set in the tab's settings sheet, so switching Saved | Heard keeps it.
  @AppStorage(AppStorageKey.nodesDisplayMode.rawValue) private var displayMode: NodeDisplayMode = .list
  @State private var addingNodeID: UUID?
  /// The heard node whose page is open (a tap on its row or card).
  @State private var nodeForDetail: DiscoveredNodeDTO?
  @State private var showClearConfirmation = false
  @State private var showFileImporter = false
  @State private var showRemoveSelectedConfirmation = false
  @State private var isAddingSelection = false
  @State private var groupEditor: ContactGroupEditorItem?
  /// Groups that existed when New Group opened, so its dismissal can find the one it made.
  @State private var groupIDsBeforeEditor: Set<UUID> = []

  private var isSearching: Bool {
    !searchText.isEmpty
  }

  /// Sort orders that recompute when the user location sample changes.
  private var consumesLocation: Bool {
    switch sortOrder {
    case .distance, .hops: true
    case .lastHeard, .name, .manual: false
    }
  }

  /// Value-typed projection of `bestAvailableLocation` so `onChange` compares
  /// coordinates, not `CLLocation` identity (radio-GPS fallback allocates fresh).
  private var locationSample: LocationSample? {
    guard let location = appState.bestAvailableLocation else { return nil }
    return LocationSample(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
  }

  private var effectiveSortOrder: NodeSortOrder {
    (sortOrder == .distance && appState.bestAvailableLocation == nil) ? .lastHeard : sortOrder
  }

  /// Saved | Heard on top, then Heard's own kind filter as pills beneath it.
  private var filterHeader: some View {
    VStack(spacing: 0) {
      NodesSectionPicker()
      DiscoverSegmentPicker(selection: $selectedSegment, isSearching: isSearching)
    }
    .frame(maxWidth: .infinity)
    .nodeListHeaderBackground(theme)
    .measuringHeight($headerHeight)
  }

  private var emptyState: some View {
    Group {
      if isSearching {
        DiscoverySearchEmptyView(searchText: searchText)
      } else {
        DiscoveryEmptyView()
      }
    }
    .emptyStateFrame(below: headerHeight)
  }

  var body: some View {
    Group {
      if !viewModel.hasLoadedOnce {
        loadingBody
      } else {
        loadedBody
      }
    }
    // Cards are the grouped secondary color; on a plain page they would vanish.
    .cardCanvas(theme)
    .toolbar {
      if viewModel.isSelecting {
        selectionToolbar
      } else {
        browsingToolbar
      }
    }
    // Select mode takes the bottom edge for its actions, like Photos and Files.
    .toolbarVisibility(viewModel.isSelecting ? .hidden : .automatic, for: .tabBar)
    .onChange(of: searchText) { oldValue, newValue in
      if oldValue.isEmpty, !newValue.isEmpty {
        AccessibilityNotification.Announcement(L10n.Contacts.Contacts.Discovery.searchingAllTypes).post()
      }
      refreshVisibleNodes()
    }
    .onChange(of: selectedSegment) { _, _ in
      refreshVisibleNodes()
    }
    .onChange(of: sortOrder) { _, _ in
      refreshVisibleNodes()
    }
    .onChange(of: locationSample) { _, _ in
      guard consumesLocation else { return }
      refreshVisibleNodes()
    }
    .task {
      configureViewModel()
      await viewModel.loadDiscoveredNodes()
      // Seed filter inputs with the view's restored @AppStorage sort synchronously
      // after load so the first painted frame uses the correct order.
      refreshVisibleNodes()
    }
    .onChange(of: appState.servicesVersion) { _, _ in
      configureViewModel()
      viewModel.scheduleCoalescedReload()
    }
    .onChange(of: appState.contactsVersion) { _, _ in
      viewModel.scheduleCoalescedReload()
    }
    .errorAlert($viewModel.errorMessage, title: L10n.Contacts.Contacts.Common.error)
    // A tapped node's page: how it was heard, where it is, and Add.
    .detailPresentation(item: $nodeForDetail, route: {
      .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: false)
    }) { node in
      DiscoveredNodeDetailSheet(
        node: node,
        isAdding: addingNodeID == node.id,
        onAdd: { addNode(node) },
        showsMap: true
      )
      .presentationDetents([.medium, .large])
    }
    .confirmationDialog(
      L10n.Contacts.Contacts.Discovery.Clear.title,
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Contacts.Contacts.Discovery.Clear.confirm, role: .destructive) {
        Task {
          await clearAllDiscoveredNodes()
        }
      }
    } message: {
      Text(L10n.Contacts.Contacts.Discovery.Clear.message)
    }
    .confirmationDialog(
      L10n.Contacts.Contacts.Discovery.Selection.removeTitle(viewModel.selectedNodeIDs.count),
      isPresented: $showRemoveSelectedConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Contacts.Contacts.Discovery.remove, role: .destructive) {
        removeSelectedNodes()
      }
    } message: {
      Text(L10n.Contacts.Contacts.Discovery.Selection.removeMessage)
    }
    .sheet(item: $groupEditor, onDismiss: addSelectionToNewGroup) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
    .sheet(isPresented: $viewModel.isSharingExport) {
      if let url = viewModel.exportedFile?.url {
        ActivityView(activityItems: [url])
      }
    }
    .onDisappear {
      viewModel.discardExport()
      // Switching to Saved (or leaving the tab) ends a select; it would otherwise come back
      // with the tab bar hidden.
      viewModel.endSelecting()
    }
    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
      switch result {
      case let .success(url):
        viewModel.importFile(at: url)
      case let .failure(error):
        viewModel.errorMessage = error.userFacingMessage
      }
    }
    // Mac / iPad: a nodes file dragged in takes the same path as the file picker.
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      viewModel.importFile(at: url)
      return true
    }
    .alert(
      L10n.Contacts.Contacts.Discovery.Import.title,
      isPresented: Binding(
        get: { viewModel.importPreview != nil },
        set: { if !$0 { viewModel.cancelImport() } }
      ),
      presenting: viewModel.importPreview
    ) { preview in
      if preview.summary.changesAnything {
        Button(L10n.Contacts.Contacts.Discovery.Import.confirm) {
          Task { await importNodes(from: preview) }
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } else {
        Button(L10n.Localizable.Common.ok, role: .cancel) {}
      }
    } message: { preview in
      Text(DiscoveryViewModel.previewMessage(for: preview))
    }
    .alert(
      L10n.Settings.Settings.Backup.Import.Success.title,
      isPresented: Binding(
        get: { viewModel.importResult != nil },
        set: { if !$0 { viewModel.importResult = nil } }
      )
    ) {
      Button(L10n.Localizable.Common.ok) {}
    } message: {
      Text(viewModel.importResult ?? "")
    }
  }

  // MARK: - Toolbars

  /// One menu, as Saved has, so the bar reads the same on both lists (options, sliders, search)
  /// and keeps room for the device's name: switching lists doesn't move anything.
  @ToolbarContentBuilder
  private var browsingToolbar: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      DiscoveryMoreMenu(
        isEmpty: viewModel.discoveredNodes.isEmpty,
        canSelect: !viewModel.visibleNodes.isEmpty,
        canImport: appState.connectedDevice != nil,
        isTransferringFile: viewModel.isTransferringFile,
        sortOrder: $sortOrder,
        showClearConfirmation: $showClearConfirmation,
        onSelect: { withAnimation(.snappy) { viewModel.beginSelecting() } },
        onExport: { Task { await viewModel.exportDiscoveredNodes() } },
        onImport: { showFileImporter = true }
      )
    }
  }

  /// Select mode's bar: Select All and Done on top, the bulk actions on the bottom edge.
  @ToolbarContentBuilder
  private var selectionToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(viewModel.isAllSelected
        ? L10n.Contacts.Contacts.Discovery.deselectAll
        : L10n.Contacts.Contacts.Discovery.selectAll) {
        withAnimation(.snappy) { viewModel.toggleSelectAll() }
      }
      .disabled(viewModel.visibleNodes.isEmpty)
    }

    ToolbarItem(placement: .topBarTrailing) {
      Button(L10n.Contacts.Contacts.Common.done) {
        withAnimation(.snappy) { viewModel.endSelecting() }
      }
      .fontWeight(.semibold)
    }

    ToolbarItemGroup(placement: .bottomBar) {
      let selected = viewModel.selectedNodes
      Button(L10n.Contacts.Contacts.Discovery.Selection.add, systemImage: "person.badge.plus") {
        addSelectedNodes()
      }
      .disabled(
        isAddingSelection || appState.services?.contactService == nil
          || !selected.contains { !viewModel.isAdded($0) }
      )

      DiscoveryGroupMenu(publicKeys: selected.map(\.publicKey), onNewGroup: openNewGroupEditor)
        .disabled(selected.isEmpty)

      Spacer()

      Text(L10n.Contacts.Contacts.Discovery.Selection.count(selected.count))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()

      Spacer()

      Button(
        L10n.Contacts.Contacts.Discovery.Selection.remove,
        systemImage: "trash",
        role: .destructive
      ) {
        showRemoveSelectedConfirmation = true
      }
      .disabled(selected.isEmpty)
    }
  }

  private var loadingBody: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        Section {} header: { filterHeader }
      }
    }
    .overlay { ProgressView() }
  }

  /// The rows in their container: a `ScrollView` with the swipe container from iOS 27 on, a plain
  /// `List` before, where row swipe actions work nowhere else (`NodeListHosting`).
  private var loadedBody: some View {
    ScrollViewReader { proxy in
      Group {
        if NodeListHosting.usesList {
          List {
            PullDownSearchRows(text: $searchText, prompt: searchPrompt, proxy: proxy, focusRequest: searchFocusRequest)
            filterHeader
              .nodeListRow()
            loadedItems
          }
          .nodeListStyle(spacing: CardStyle.spacing)
        } else {
          ScrollView {
            // Search waits above the list until it's pulled down.
            PullDownSearch(text: $searchText, prompt: searchPrompt, proxy: proxy, focusRequest: searchFocusRequest) {
              // One card per node in either layout, with the card gap between them.
              LazyVStack(spacing: CardStyle.spacing) {
                filterHeader
                loadedItems
              }
            }
          }
          .swipeActionsContainerIfAvailable()
        }
      }
      // ⌘F: the field back into view, then focused once it's there.
      .onChange(of: appState.navigation.nodesSearchRequestVersion) { _, version in
        withAnimation(.snappy) {
          proxy.scrollTo(PullDownSearch<EmptyView>.fieldID, anchor: .top)
        }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250))
          searchFocusRequest = version
        }
      }
    }
  }

  @ViewBuilder
  private var loadedItems: some View {
    if viewModel.visibleNodes.isEmpty {
      emptyState
        .nodeListRow()
    } else if displayMode == .cards {
      cards
    } else {
      rows
    }
  }

  /// Opens a node's page: beside the list at regular width, as a sheet otherwise.
  private func open(_ node: DiscoveredNodeDTO) {
    if opensDetailInColumn {
      appState.navigation.selectedHeardNode = node
    } else {
      nodeForDetail = node
    }
  }

  /// The list layout: compact rows joined into one inset group with hairline separators (see
  /// `CompactNodeList`).
  private var rows: some View {
    let firstID = viewModel.visibleNodes.first?.id
    let lastID = viewModel.visibleNodes.last?.id
    return ForEach(viewModel.visibleNodes) { node in
      let position = CompactNodeRowPosition(isFirst: node.id == firstID, isLast: node.id == lastID)
      DiscoveryNodeRow(
        node: node,
        isAdded: viewModel.isAdded(node),
        isAdding: addingNodeID == node.id || isAddingSelection,
        selection: selectionState(for: node),
        position: position,
        isOpen: opensDetailInColumn && appState.navigation.selectedHeardNode?.id == node.id,
        onOpen: { open(node) },
        onAdd: { addNode(node) },
        onDelete: {
          Task {
            await viewModel.deleteDiscoveredNode(node)
          }
        }
      )
      .discoverySelectable(selectionState(for: node), shape: position.shape) { toggleSelection(node) }
      .padding(.horizontal, CardStyle.pageInset)
      // The `List` spaces its rows itself; the stack needs the gap after the last row.
      .padding(.bottom, position.isLast && !NodeListHosting.usesList ? CardStyle.spacing : 0)
      .transition(.opacity)
      .nodeListRow()
    }
  }

  /// The card layout, inside the same section so the filter header stays pinned above it.
  private var cards: some View {
    LazyCardGrid {
      ForEach(viewModel.visibleNodes) { node in
        DiscoveryNodeCard(
          node: node,
          isAdded: viewModel.isAdded(node),
          isAdding: addingNodeID == node.id || isAddingSelection,
          selection: selectionState(for: node),
          isOpen: opensDetailInColumn && appState.navigation.selectedHeardNode?.id == node.id,
          onOpen: { open(node) },
          onAdd: { addNode(node) },
          onDelete: {
            Task {
              await viewModel.deleteDiscoveredNode(node)
            }
          }
        )
        .discoverySelectable(selectionState(for: node), shape: CardStyle.shape) { toggleSelection(node) }
        .transition(.opacity)
      }
    }
    .padding(.horizontal, CardStyle.pageInset)
    .padding(.bottom, CardStyle.spacing)
    .nodeListRow()
  }

  private func configureViewModel() {
    viewModel.configure(
      dataStore: { [appState] in appState.offlineDataStore },
      radioID: { [appState] in appState.connectedDevice?.radioID },
      selfPublicKey: { [appState] in appState.connectedDevice?.publicKey },
      onNodesChanged: { [appState] in appState.noteDiscoveredNodesChanged() }
    )
  }

  private func refreshVisibleNodes() {
    viewModel.updateVisibleNodes(
      searchText: searchText,
      segment: selectedSegment,
      sortOrder: effectiveSortOrder,
      userLocation: appState.bestAvailableLocation
    )
  }

  private func addNode(_ node: DiscoveredNodeDTO) {
    // Without a radio the add has nowhere to go; said, rather than a tap that does nothing.
    guard let contactService = appState.services?.contactService else {
      viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }

    addingNodeID = node.id
    Task {
      do {
        try await contactService.addOrUpdateContact(
          radioID: node.radioID,
          contact: node.makeContactFrame()
        )
        // Saved, it leaves Heard, so its page goes too.
        if nodeForDetail?.id == node.id { nodeForDetail = nil }
        if appState.navigation.selectedHeardNode?.id == node.id { appState.navigation.selectedHeardNode = nil }
        await viewModel.loadDiscoveredNodes()
      } catch {
        reportAddFailure(error)
      }
      addingNodeID = nil
    }
  }

  /// A full node list gets its own message with the radio's limit; anything else reads as is.
  private func reportAddFailure(_ error: Error) {
    if case ContactServiceError.contactTableFull = error {
      if let maxContacts = appState.connectedDevice?.maxContacts {
        viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFull(Int(maxContacts))
      } else {
        viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      }
    } else {
      viewModel.errorMessage = error.userFacingMessage
    }
  }

  // MARK: - Selection

  private func selectionState(for node: DiscoveredNodeDTO) -> DiscoverySelectionState {
    guard viewModel.isSelecting else { return .off }
    return viewModel.isSelected(node) ? .selected : .unselected
  }

  private func toggleSelection(_ node: DiscoveredNodeDTO) {
    withAnimation(.snappy(duration: 0.2)) { viewModel.toggleSelection(node) }
  }

  /// Adds the picked nodes that aren't on the radio yet, one radio write at a time. Stops at the
  /// first failure: a full node list fails every later add the same way.
  private func addSelectedNodes() {
    guard let contactService = appState.services?.contactService else {
      viewModel.errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    let nodes = viewModel.selectedNodes.filter { !viewModel.isAdded($0) }
    guard !nodes.isEmpty else { return }

    isAddingSelection = true
    Task {
      do {
        for node in nodes {
          try await contactService.addOrUpdateContact(
            radioID: node.radioID,
            contact: node.makeContactFrame()
          )
        }
      } catch {
        reportAddFailure(error)
      }
      await viewModel.loadDiscoveredNodes()
      isAddingSelection = false
    }
  }

  private func removeSelectedNodes() {
    let nodes = viewModel.selectedNodes
    withAnimation(.snappy) { viewModel.endSelecting() }
    Task { await viewModel.deleteDiscoveredNodes(nodes) }
  }

  /// The group editor takes one starting member, so it opens empty and the whole selection joins
  /// whichever group it created once it closes.
  private func openNewGroupEditor() {
    groupIDsBeforeEditor = Set(ContactGroupStore.shared.groups.map(\.id))
    groupEditor = ContactGroupEditorItem(mode: .create(initialMember: nil))
  }

  private func addSelectionToNewGroup() {
    let store = ContactGroupStore.shared
    let keys = viewModel.selectedNodes.map(\.publicKey)
    for group in store.groups where !groupIDsBeforeEditor.contains(group.id) {
      store.add(keys, to: group.id)
    }
    groupIDsBeforeEditor = []
  }

  private func importNodes(from preview: DiscoveredNodesImportPreview) async {
    guard await viewModel.confirmImport(preview) else { return }
    // Other mounted screens that show discovered nodes, such as the map, reload on this counter.
    appState.contactsVersion += 1
  }

  private func clearAllDiscoveredNodes() async {
    await viewModel.clearAllDiscoveredNodes()

    AccessibilityNotification.Announcement(L10n.Contacts.Contacts.Discovery.clearedAllNodes).post()
  }
}

/// Equatable projection of a location for `onChange` without `CLLocation` identity comparison.
/// Raw doubles are fine: `LocationService` is one-shot `requestLocation()`, not continuous GPS.
private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}

// MARK: - Empty View

private struct DiscoveryEmptyView: View {
  @Environment(\.appState) private var appState

  /// With auto-add on, every heard node is saved as it's heard, so this list stays empty; say so
  /// rather than look broken.
  private var isAutoAdding: Bool {
    guard let mode = appState.connectedDevice?.autoAddMode else { return false }
    return mode != .manual
  }

  var body: some View {
    ContentUnavailableView(
      L10n.Contacts.Contacts.Discovery.Empty.title,
      systemImage: "antenna.radiowaves.left.and.right",
      description: Text(isAutoAdding
        ? L10n.Contacts.Contacts.Discovery.Empty.autoAdd
        : L10n.Contacts.Contacts.Discovery.Empty.description)
    )
  }
}

// MARK: - Search Empty View

private struct DiscoverySearchEmptyView: View {
  let searchText: String

  var body: some View {
    ContentUnavailableView(
      L10n.Contacts.Contacts.Discovery.Empty.Search.title,
      systemImage: "magnifyingglass",
      description: Text(L10n.Contacts.Contacts.Discovery.Empty.Search.description(searchText))
    )
  }
}

// MARK: - Node Row

/// A heard node in the compact List layout: a small avatar, the name on one line, one short line
/// of kind, route and distance, and the time last heard beside Add. The public key and hop path
/// are left to the Cards layout and the node's own page.
private struct DiscoveryNodeRow: View {
  @Environment(\.appState) private var appState
  let node: DiscoveredNodeDTO
  let isAdded: Bool
  let isAdding: Bool
  let selection: DiscoverySelectionState
  let position: CompactNodeRowPosition
  /// The node open in the iPad detail column, drawn with the selected wash as a saved node's row.
  var isOpen = false
  let onOpen: () -> Void
  let onAdd: () -> Void
  let onDelete: () -> Void

  /// The selection mark's width plus its spacing, so the separator still starts under the text.
  private static let selectionMarkInset: CGFloat = 32

  var body: some View {
    // Built once per pass: the distance formatting is shared by the visible line and VoiceOver.
    let summary = DiscoveryNodeSummary(node: node, userLocation: appState.bestAvailableLocation)
    HStack(spacing: CompactNodeList.avatarSpacing) {
      // One VoiceOver stop for the node's details; Add stays its own element.
      HStack(spacing: CompactNodeList.avatarSpacing) {
        if selection != .off {
          DiscoverySelectionMark(isSelected: selection == .selected)
        }

        summary.avatar(size: CompactNodeList.avatarSize)

        VStack(alignment: .leading, spacing: 0) {
          Text(node.name)
            .compactNodeNameFont()
            .nodeNameFit(lineLimit: 1)

          Text(NodeRouteFormat.joined([summary.typeLabel, summary.routeLabel, summary.bareDistance]))
            .compactNodeDetailFont()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(node.name)
      .accessibilityValue(summary.accessibilityDetails)
      .accessibilityAddTraits(selection == .off ? .isButton : [])
      .accessibilityAction(.default) { if selection == .off { onOpen() } }

      RelativeTimestampText(date: node.lastHeard)
        .accessibilityHidden(true)

      // Select mode turns a tap into picking the node, so Add steps aside until it ends.
      if selection == .off {
        DiscoveryAddButton(isAdded: isAdded, isAdding: isAdding, onAdd: onAdd)
          .controlSize(.small)
      }
    }
    .compactNodeRowBackground(
      position,
      isSelected: selection == .selected || (selection == .off && isOpen),
      separatorLeadingExtra: selection == .off ? 0 : Self.selectionMarkInset
    )
    // A tap anywhere but Add opens the node's page; select mode's overlay takes taps instead.
    .contentShape(position.shape)
    .onTapGesture(perform: onOpen)
    .contentShape(.contextMenuPreview, position.shape)
    .contextMenu {
      DiscoveryNodeMenuItems(isAdded: isAdded, onOpen: onOpen, onAdd: onAdd, onDelete: onDelete)
    }
    // As on Saved: Add from the leading edge (a full swipe adds), Remove from the trailing edge,
    // which needs the tap. None while picking nodes.
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if selection == .off, !isAdded, !isAdding {
        Button(action: onAdd) {
          Label(L10n.Contacts.Contacts.Discovery.add, systemImage: "person.badge.plus")
        }
        .tint(.accentColor)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if selection == .off {
        Button(role: .destructive, action: onDelete) {
          Label(L10n.Contacts.Contacts.Discovery.remove, systemImage: "trash")
        }
      }
    }
  }

}

// MARK: - Node Summary

/// The wording a discovered node's row and card share: its avatar, kind, route, distance, and
/// the spoken summary. Main-actor, like the views that use it: it builds avatar views and formats
/// with the main-actor timestamp formatter.
@MainActor
private struct DiscoveryNodeSummary {
  let node: DiscoveredNodeDTO

  /// The distance without "away", for a card line where the location glyph says it. Formatted
  /// once here since the visible line and the spoken summary both use it.
  let bareDistance: String?

  init(node: DiscoveredNodeDTO, userLocation: CLLocation?) {
    self.node = node
    bareDistance = node.hasLocation
      ? NodeRouteFormat.distance(from: userLocation, latitude: node.latitude, longitude: node.longitude)
      : nil
  }

  @ViewBuilder
  func avatar(size: CGFloat) -> some View {
    switch node.nodeType {
    case .chat:
      CompanionAvatar(name: node.name, publicKey: node.publicKey, size: size)
    case .repeater:
      NodeAvatar(publicKey: node.publicKey, role: .repeater, size: size, name: node.name)
    case .room:
      NodeAvatar(publicKey: node.publicKey, role: .roomServer, size: size, name: node.name)
    }
  }

  var typeLabel: String {
    switch node.nodeType {
    // A heard companion is someone's radio, not a conversation (the user, 2026-11-08).
    case .chat: L10n.Contacts.Contacts.NodeKind.radio
    case .repeater: L10n.Contacts.Contacts.NodeKind.repeater
    case .room: L10n.Contacts.Contacts.NodeKind.room
    }
  }

  var routeLabel: String {
    NodeRouteFormat.routeLabel(
      isFloodRouted: node.isFloodRouted,
      pathHopCount: node.pathHopCount,
      displayedHopCount: node.displayedHopCount
    )
  }

  /// `bareDistance` as "1.2 km away", matching `NodeRouteFormat.distanceAway`.
  var distance: String? {
    bareDistance.map { L10n.Contacts.Contacts.Row.away($0) }
  }

  /// Spoken summary of the node. Leaves out the public key and the hop path, which
  /// read as long runs of hex digits.
  var accessibilityDetails: String {
    var details = [typeLabel, routeLabel]
    if let distance {
      details.append(distance)
    }
    details.append(RelativeTimestampText.format(date: node.lastHeard, relativeTo: .now))
    return details.joined(separator: ", ")
  }
}

// MARK: - Add Button

/// Add, or a disabled Added once the node is on the radio. Its own VoiceOver element beside the
/// node's details.
private struct DiscoveryAddButton: View {
  let isAdded: Bool
  let isAdding: Bool
  let onAdd: () -> Void

  var body: some View {
    if isAdded {
      Button(L10n.Contacts.Contacts.Discovery.added) {}
        .buttonStyle(.bordered)
        .disabled(true)
        .accessibilityLabel(L10n.Contacts.Contacts.Discovery.addedAccessibility)
    } else {
      Button(L10n.Contacts.Contacts.Discovery.add) {
        onAdd()
      }
      .buttonStyle(.borderedProminent)
      .disabled(isAdding)
    }
  }
}

// MARK: - Node Card

/// A discovered node in the card layout, tiled like a saved node's card (`ContactCardView`): the
/// avatar, the name on one line with when it was last heard under it, and Add at the far right
/// (the selection mark in select mode); under them a line each for its kind and route, and where
/// it is. Every card holds the same lines, so the cards stay one height.
private struct DiscoveryNodeCard: View {
  @Environment(\.appState) private var appState
  let node: DiscoveredNodeDTO
  let isAdded: Bool
  let isAdding: Bool
  let selection: DiscoverySelectionState
  /// The node open in the iPad detail column, drawn with the selected wash as a saved node's card.
  var isOpen = false
  let onOpen: () -> Void
  let onAdd: () -> Void
  let onDelete: () -> Void

  var body: some View {
    let summary = DiscoveryNodeSummary(node: node, userLocation: appState.bestAvailableLocation)
    VStack(alignment: .leading, spacing: NodeCardLayout.sectionSpacing) {
      HStack(alignment: .center, spacing: NodeCardLayout.avatarSpacing) {
        summary.avatar(size: NodeCardLayout.avatarSize)
          .accessibilityHidden(true)
        // Spoken with the details below, as one element.
        VStack(alignment: .leading, spacing: NodeCardLayout.lineSpacing) {
          NodeCardName(node.name)
          NodeCardDetailLine(
            symbol: "arrowshape.bounce.right",
            text: NodeRouteFormat.joined([summary.typeLabel, summary.routeLabel])
          )
        }
        .accessibilityHidden(true)
        if selection == .off {
          DiscoveryAddButton(isAdded: isAdded, isAdding: isAdding, onAdd: onAdd)
            .controlSize(.small)
        } else {
          DiscoverySelectionMark(isSelected: selection == .selected)
        }
      }

      // One VoiceOver stop for the node, read before Add; Add stays its own element.
      HStack(spacing: 8) {
        NodeCardPlaceLine(hasLocation: node.hasLocation, distance: summary.bareDistance)
        NodeCardHeardLine(date: node.lastHeard, hugs: true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(node.name)
      .accessibilityValue(summary.accessibilityDetails)
      .accessibilityAddTraits(selection == .off ? .isButton : [])
      .accessibilityAction(.default) { if selection == .off { onOpen() } }
      .accessibilitySortPriority(1)
    }
    .cardSurface(isSelected: selection == .selected || (selection == .off && isOpen), padding: 10)
    // A tap anywhere but Add opens the node's page; select mode's overlay takes taps instead.
    .contentShape(CardStyle.shape)
    .onTapGesture(perform: onOpen)
    .contentShape(.contextMenuPreview, CardStyle.shape)
    .contextMenu {
      DiscoveryNodeMenuItems(isAdded: isAdded, onOpen: onOpen, onAdd: onAdd, onDelete: onDelete)
    }
  }
}

// MARK: - Menu

/// A heard node's long-press menu: its page, Add while it isn't saved, and Remove.
private struct DiscoveryNodeMenuItems: View {
  let isAdded: Bool
  let onOpen: () -> Void
  let onAdd: () -> Void
  let onDelete: () -> Void

  var body: some View {
    Button(L10n.Map.Map.Callout.details, systemImage: "info.circle", action: onOpen)
    if !isAdded {
      Button(L10n.Contacts.Contacts.Discovery.add, systemImage: "person.badge.plus", action: onAdd)
    }
    Divider()
    Button(role: .destructive, action: onDelete) {
      Label(L10n.Contacts.Contacts.Discovery.remove, systemImage: "trash")
    }
  }
}

// MARK: - Selection

/// Where a node stands in select mode; `off` outside it. Shared with the Saved list's select mode.
enum DiscoverySelectionState {
  case off
  case unselected
  case selected
}

/// The selection circle a row or card shows in select mode, filled with the accent when picked.
struct DiscoverySelectionMark: View {
  let isSelected: Bool

  var body: some View {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      .font(.title2)
      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityHidden(true)
  }
}

/// In select mode a tap anywhere on the node picks it, rather than reaching Add or the context
/// menu, and VoiceOver reads the node as one selectable button.
struct DiscoverySelectableModifier<S: Shape>: ViewModifier {
  let selection: DiscoverySelectionState
  /// The row's or card's own outline, so the tap target matches what's drawn.
  let shape: S
  let onToggle: () -> Void

  func body(content: Content) -> some View {
    if selection == .off {
      content
    } else {
      content
        .overlay {
          Color.clear
            .contentShape(shape)
            .onTapGesture(perform: onToggle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == .selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onToggle)
    }
  }
}

extension View {
  func discoverySelectable(
    _ selection: DiscoverySelectionState,
    shape: some Shape,
    onToggle: @escaping () -> Void
  ) -> some View {
    modifier(DiscoverySelectableModifier(selection: selection, shape: shape, onToggle: onToggle))
  }
}

/// Select mode's group menu. A group is checked when it already holds every picked node;
/// choosing an unchecked one adds the rest without touching existing members, and unchecking
/// takes the picked nodes back out.
struct DiscoveryGroupMenu: View {
  let publicKeys: [Data]
  let onNewGroup: () -> Void

  private let store = ContactGroupStore.shared

  var body: some View {
    Menu {
      ForEach(store.groups) { group in
        Toggle(isOn: Binding(
          get: { !publicKeys.isEmpty && publicKeys.allSatisfy { group.contains($0) } },
          set: { isOn in
            if isOn {
              store.add(publicKeys, to: group.id)
            } else {
              store.remove(publicKeys, from: group.id)
            }
          }
        )) {
          Label(group.name, systemImage: group.symbol)
        }
      }
      // Where groups live, said in the menu that changes them, as on a node's own groups row.
      Section(L10n.Contacts.Contacts.Groups.footer) {
        Button(L10n.Contacts.Contacts.Groups.new, systemImage: "plus", action: onNewGroup)
      }
    } label: {
      Label(L10n.Contacts.Contacts.Discovery.Selection.addToGroup, systemImage: "person.3")
    }
  }
}

// MARK: - More Menu

/// Heard's one toolbar menu: select, sort, and the list's file and clear actions. Layout and the
/// node rules are in the tab's settings sheet (the sliders beside it), as on Saved.
private struct DiscoveryMoreMenu: View {
  let isEmpty: Bool
  let canSelect: Bool
  let canImport: Bool
  let isTransferringFile: Bool
  @Binding var sortOrder: NodeSortOrder
  @Binding var showClearConfirmation: Bool
  let onSelect: () -> Void
  let onExport: () -> Void
  let onImport: () -> Void

  var body: some View {
    Menu {
      Button(L10n.Contacts.Contacts.Discovery.select, systemImage: "checkmark.circle", action: onSelect)
        .disabled(!canSelect)

      Picker(selection: $sortOrder) {
        ForEach(NodeSortOrder.heardOrders, id: \.self) { order in
          Text(order.localizedTitle).tag(order)
        }
      } label: {
        Label(L10n.Contacts.Contacts.List.sort, systemImage: "arrow.up.arrow.down")
      }
      .pickerStyle(.menu)
      .accessibilityHint(L10n.Contacts.Contacts.Discovery.sortMenuHint)

      Divider()

      Button(L10n.Contacts.Contacts.Discovery.export, systemImage: "square.and.arrow.up", action: onExport)
        .disabled(isEmpty || isTransferringFile)

      Button(L10n.Contacts.Contacts.Discovery.import, systemImage: "square.and.arrow.down", action: onImport)
        .disabled(!canImport || isTransferringFile)

      Divider()

      Button(role: .destructive) {
        showClearConfirmation = true
      } label: {
        Label(L10n.Contacts.Contacts.Discovery.clear, systemImage: "trash")
      }
      .disabled(isEmpty)
    } label: {
      Label(L10n.Contacts.Contacts.Discovery.menu, systemImage: "ellipsis.circle")
    }
  }
}

#Preview {
  NavigationStack {
    DiscoveryView(viewModel: DiscoveryViewModel(), searchText: .constant(""), searchPrompt: "")
  }
  .environment(\.appState, AppState())
}
