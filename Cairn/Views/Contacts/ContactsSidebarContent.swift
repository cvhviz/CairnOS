import CairnServices
import OSLog
import SwiftUI

private let sidebarLogger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodesListView")

/// The Nodes tab's root, shared by the compact stack and the iPad content column: the Saved list
/// or the Heard list in place, picked by `NodesSectionPicker` at the top of either. Title, search,
/// the tab's settings and the saved-node routes are the tab's; each list brings its own toolbar
/// items (Saved its options menu here, Heard its Select, layout, sort and More in `DiscoveryView`).
struct ContactsSidebarContent: View {
  private struct LoadID: Equatable {
    let servicesVersion: Int
    let contactsVersion: Int
  }

  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.nodesDisplayMode.rawValue) private var displayMode: NodeDisplayMode = .list
  /// Held here rather than in `DiscoveryView` so the Heard list, its sort results and a select in
  /// progress survive a switch to Saved and back.
  @State private var discoveryViewModel = DiscoveryViewModel()

  @Bindable var viewModel: ContactsViewModel
  let filteredContacts: [ContactDTO]
  let isSearching: Bool
  let searchPrompt: String
  let shouldUseSplitView: Bool

  @Binding var selectedSegment: NodeSegment
  @Binding var selectedContact: ContactDTO?
  @Binding var searchText: String
  @Binding var sortOrder: NodeSortOrder
  @AppStorage(AppStorageKey.nodesFavoritesOnly.rawValue) private var favoritesOnly = false
  @Binding var syncSuccessTrigger: Bool
  @Binding var showShareMyContact: Bool
  @Binding var showAddContact: Bool
  @Binding var showLocationDeniedAlert: Bool
  /// Set by a pull to refresh (or Sync) with no radio: shows the inline banner, not an alert.
  @Binding var showOfflineRefreshAlert: Bool
  @Binding var navigationPath: NavigationPath

  let onLoadContacts: () async -> Void
  let onSyncContacts: () async -> Void
  let onAnnounceOfflineStateIfNeeded: () -> Void

  @State private var showDeleteSelectedConfirmation = false
  @State private var showFileImporter = false
  /// Groups that existed when New Group opened, so its dismissal can find the one it made.
  @State private var groupIDsBeforeEditor: Set<UUID> = []
  @State private var groupEditor: ContactGroupEditorItem?
  /// Toggled with each offline refresh, for the warning haptic.
  @State private var offlineHapticTrigger = false

  private var section: NodesSection {
    appState.navigation.nodesSection
  }

  /// Heard's select mode takes the top bar for Select All and Done.
  private var isSelectingHeard: Bool {
    section == .heard && discoveryViewModel.isSelecting
  }

  /// Saved's select mode does the same.
  private var isSelectingSaved: Bool {
    section == .saved && viewModel.isSelecting
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch section {
    case .saved:
      ContactsListContent(
        mode: shouldUseSplitView ? .selection($selectedContact) : .navigation,
        displayMode: displayMode,
        selectedSegment: $selectedSegment,
        isSearching: isSearching,
        searchText: $searchText,
        searchPrompt: searchPrompt,
        filteredContacts: filteredContacts,
        hasLoadedOnce: viewModel.hasLoadedOnce,
        viewModel: viewModel,
        isReorderable: sortOrder == .manual,
        onRefresh: refreshNodes
      )
    case .heard:
      DiscoveryView(
        viewModel: discoveryViewModel,
        searchText: $searchText,
        searchPrompt: discoveryViewModel.searchPrompt,
        opensDetailInColumn: shouldUseSplitView
      )
    }
  }

  var body: some View {
    sectionContent
    .deviceNameTitle(pageTitle: AppTab.contacts.title)
    // Select mode takes the bottom edge for its actions, like Photos and Files.
    .toolbarVisibility(isSelectingSaved ? .hidden : .automatic, for: .tabBar)
    .toolbar {
      if isSelectingSaved {
        savedSelectionToolbar
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if showOfflineRefreshAlert {
        OfflineRefreshBanner { showOfflineRefreshAlert = false }
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: showOfflineRefreshAlert)
    .sensoryFeedback(.warning, trigger: offlineHapticTrigger)
    .onChange(of: showOfflineRefreshAlert) { _, isShown in
      guard isShown else { return }
      offlineHapticTrigger.toggle()
      // Gone on its own after a moment; a tap dismisses it sooner.
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        showOfflineRefreshAlert = false
      }
    }
    // A switch to Heard ends a Saved select; it would otherwise come back with the tab bar hidden.
    .onChange(of: section) { _, newSection in
      if newSection != .saved { viewModel.endSelecting() }
    }
    // ⌥⌘A, from any tab.
    .onChange(of: appState.navigation.addNodeRequestVersion) { _, _ in
      showAddContact = true
    }
    .contactRowConfirmations(viewModel: viewModel)
    .confirmationDialog(
      L10n.Contacts.Contacts.List.Selection.deleteTitle(viewModel.selectedContacts(in: filteredContacts).count),
      isPresented: $showDeleteSelectedConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Contacts.Contacts.Common.delete, role: .destructive) {
        deleteSelectedContacts()
      }
    } message: {
      Text(L10n.Contacts.Contacts.List.Selection.deleteMessage)
    }
    // Row context-menu pages: the node on the map, its QR code, and its name.
    .fullScreenCover(item: $viewModel.mapContact) { contact in
      NodeOnMapView(
        focus: .node(publicKey: contact.publicKey, coordinate: contact.coordinate),
        title: contact.displayName,
        isPresented: true
      )
    }
    .sheet(item: $viewModel.shareContact) { contact in
      ContactQRShareSheet(contactName: contact.name, publicKey: contact.publicKey, contactType: contact.type)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .sheet(item: $viewModel.renameContact) { contact in
      ContactNameEditSheet(contact: contact) {
        await onLoadContacts()
      }
    }
    .sheet(item: $groupEditor, onDismiss: addSelectionToNewGroup) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
    // The saved nodes as a file, and a file's nodes onto the radio.
    .sheet(isPresented: $viewModel.isSharingExport, onDismiss: { viewModel.discardExport() }) {
      if let url = viewModel.exportedFile?.url {
        ActivityView(activityItems: [url])
      }
    }
    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
      switch result {
      case let .success(url):
        importFile(at: url)
      case let .failure(error):
        viewModel.errorMessage = error.userFacingMessage
      }
    }
    .alert(
      L10n.Contacts.Contacts.List.Import.title,
      isPresented: Binding(
        get: { viewModel.importPreview != nil },
        set: { if !$0 { viewModel.cancelImport() } }
      ),
      presenting: viewModel.importPreview
    ) { preview in
      if preview.changesAnything {
        Button(L10n.Contacts.Contacts.Discovery.Import.confirm) {
          Task { _ = await viewModel.confirmImport(preview, radioID: appState.currentRadioID) }
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } else {
        Button(L10n.Localizable.Common.ok, role: .cancel) {}
      }
    } message: { preview in
      Text(ContactsViewModel.previewMessage(for: preview))
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
    .navigationDestination(for: ContactRoute.self) { route in
      switch route {
      case let .detail(contact):
        // Prefer the freshest row from the loaded list; fall back to the carried
        // payload for pushes that precede a load (e.g. a notification deep link).
        ContactDetailView(contact: viewModel.contacts.first { $0.id == contact.id } ?? contact)
          .id(contact.id)
          .onAppear {
            // Shared with the iPad split, so a resize to regular width keeps this node open.
            if !shouldUseSplitView { appState.navigation.selectedContact = contact }
          }
      }
    }
    // Search is a field above each list that a pull down reveals (`PullDownSearch`).
    .toolbar {
      if !isSelectingHeard, !isSelectingSaved {
        // In the leading corner: three buttons trailing would push the centred title aside.
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.Contacts.Contacts.Add.nodeTitle, systemImage: "plus") {
            showAddContact = true
          }
          .accessibilityIdentifier("nodes.add")
        }
      }

      if section == .saved, !isSelectingSaved {
        savedOptionsMenu
      }
    }
    // After the list's own items, so the sliders end the bar as on every tab.
    .tabSettingsToolbarItem(for: .contacts)
    .sensoryFeedback(.success, trigger: syncSuccessTrigger)
    .task {
      sidebarLogger.info("NodesListView: task started, services=\(appState.services != nil)")
      viewModel.configure(
        dataStore: { [appState] in appState.offlineDataStore },
        contactService: { [appState] in appState.services?.contactService },
        advertisementService: { [appState] in appState.services?.advertisementService }
      )
      onAnnounceOfflineStateIfNeeded()

      // Request location for distance display (only if already authorized)
      if appState.locationService.isAuthorized {
        appState.locationService.requestLocation()
      }
    }
    .task(id: LoadID(
      servicesVersion: appState.servicesVersion,
      contactsVersion: appState.contactsVersion
    )) {
      // Picks up groups written by a backup restore.
      ContactGroupStore.shared.reload()
      await onLoadContacts()
      sidebarLogger.info("NodesListView: loaded, contacts=\(viewModel.contacts.count)")
    }
    // A Remove Nodes run takes its nodes out of the list at once; the radio works through them.
    .onChange(of: appState.nodeRemoval.removingKeys, initial: true) { _, keys in
      viewModel.bulkRemovalKeys = keys
    }
    .task(id: sortOrder) {
      if sortOrder == .distance {
        if appState.locationService.isAuthorized {
          appState.locationService.requestLocation()
        } else if appState.locationService.isLocationDenied,
                  !appState.navigation.isSettingsPresented {
          // Chosen in Settings › Nodes, which says so itself; an alert here can't show over it.
          showLocationDeniedAlert = true
        } else {
          appState.locationService.requestPermissionIfNeeded()
        }
      }
    }
    // "Find in Nodes" from a chat: the Heard list opens searched for the sender's name.
    .onChange(of: appState.navigation.pendingNodesSearch, initial: true) { _, name in
      guard let name else { return }
      searchText = name
      appState.navigation.clearPendingNodesSearch()
    }
    .onChange(of: appState.navigation.pendingContactDetail, initial: true) { _, contact in
      guard let contact else { return }

      viewModel.upsert(contact)
      // A saved node's page opens from the Saved list.
      appState.navigation.nodesSection = .saved

      if shouldUseSplitView {
        selectedContact = contact
      } else {
        navigationPath.removeLast(navigationPath.count)
        navigationPath.append(ContactRoute.detail(contact))
      }

      appState.navigation.clearPendingContactDetailNavigation()
    }
    .onChange(of: appState.locationService.authorizationStatus) { _, status in
      if sortOrder == .distance {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
          appState.locationService.requestLocation()
        case .denied, .restricted:
          showLocationDeniedAlert = true
        default:
          break
        }
      }
    }
    .sheet(isPresented: $showShareMyContact) {
      if let device = appState.connectedDevice {
        ContactQRShareSheet(
          contactName: device.nodeName,
          publicKey: device.publicKey,
          contactType: .chat
        )
      }
    }
    .sheet(isPresented: $showAddContact) {
      AddContactSheet()
    }
    .sheet(isPresented: $viewModel.showManageGroups) {
      ManageContactGroupsView(contacts: viewModel.contacts)
    }
    .sheet(item: $viewModel.groupEditorRequest) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
    .sheet(item: $viewModel.broadcastGroup) { group in
      GroupBroadcastSheet(group: group, contacts: viewModel.contacts)
    }
    .alert(L10n.Contacts.Contacts.List.locationUnavailable, isPresented: $showLocationDeniedAlert) {
      Button(L10n.Contacts.Contacts.List.openSettings) {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Contacts.Contacts.List.distanceRequiresLocation)
    }
    .errorAlert($viewModel.errorMessage, title: L10n.Contacts.Contacts.Common.error)
  }

  /// Saved's own items. Heard Nodes used to be an item here that pushed a page; it is the
  /// Heard segment now.
  @ToolbarContentBuilder
  private var savedOptionsMenu: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      // Layout, sort and the node rules sit in the tab's settings sheet (sliders). The group
      // filter is a submenu here rather than its own button: its funnel glyph read too much like
      // the sliders beside it, and an active filter already shows as a pill above the list.
      Menu {
        Button(L10n.Contacts.Contacts.Discovery.select, systemImage: "checkmark.circle") {
          withAnimation(.snappy) { viewModel.beginSelecting() }
        }
        .disabled(filteredContacts.isEmpty)

        // How the list is ordered and whether it holds favorites only, within the segment picked.
        Picker(selection: $sortOrder) {
          ForEach(NodeSortOrder.allCases, id: \.self) { order in
            Text(order.localizedTitle).tag(order)
          }
        } label: {
          Label(L10n.Contacts.Contacts.List.sort, systemImage: "arrow.up.arrow.down")
        }
        .pickerStyle(.menu)

        Toggle(isOn: $favoritesOnly) {
          Label(L10n.Settings.TrustedContacts.favoritesOnly, systemImage: "star")
        }

        Divider()

        Menu {
          ContactGroupFilterMenuItems(viewModel: viewModel)
          Divider()
          Button {
            viewModel.showManageGroups = true
          } label: {
            Label(L10n.Contacts.Contacts.Groups.manage, systemImage: "person.3")
          }
        } label: {
          Label(
            L10n.Contacts.Contacts.Groups.filter,
            systemImage: viewModel.selectedGroup == nil
              ? "line.3.horizontal.decrease.circle"
              : "line.3.horizontal.decrease.circle.fill"
          )
        }

        Divider()

        Button {
          showShareMyContact = true
        } label: {
          Label(L10n.Contacts.Contacts.List.shareMyContact, systemImage: "square.and.arrow.up")
        }

        Divider()

        // The list as a file (the same nodes file Heard writes), and a file's nodes onto the radio.
        Button(L10n.Contacts.Contacts.List.export, systemImage: "square.and.arrow.up.on.square") {
          viewModel.exportContacts()
        }
        .disabled(viewModel.contacts.isEmpty || viewModel.isTransferringFile)

        Button(L10n.Contacts.Contacts.List.`import`, systemImage: "square.and.arrow.down") {
          showFileImporter = true
        }
        .disabled(appState.connectedDevice == nil || viewModel.isTransferringFile)

        Divider()

        Button {
          Task {
            if appState.connectionState != .ready {
              showOfflineRefreshAlert = true
            } else {
              await onSyncContacts()
            }
          }
        } label: {
          Label(L10n.Contacts.Contacts.List.syncNodes, systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(viewModel.isSyncing)
      } label: {
        // Filled while the list holds favorites only, so the filter shows when the menu is shut.
        Label(L10n.Contacts.Contacts.List.options, systemImage: favoritesOnly ? "star.circle.fill" : "ellipsis.circle")
      }
    }
  }

  /// Select mode's bar: Select All and Done on top, the bulk actions on the bottom edge, as on
  /// the Heard list.
  @ToolbarContentBuilder
  private var savedSelectionToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(viewModel.isAllSelected(in: filteredContacts)
        ? L10n.Contacts.Contacts.Discovery.deselectAll
        : L10n.Contacts.Contacts.Discovery.selectAll) {
        withAnimation(.snappy) { viewModel.toggleSelectAll(in: filteredContacts) }
      }
      .disabled(filteredContacts.isEmpty)
    }

    ToolbarItem(placement: .topBarTrailing) {
      Button(L10n.Contacts.Contacts.Common.done) {
        withAnimation(.snappy) { viewModel.endSelecting() }
      }
      .fontWeight(.semibold)
    }

    ToolbarItemGroup(placement: .bottomBar) {
      let selected = viewModel.selectedContacts(in: filteredContacts)
      let isConnected = appState.connectionState == .ready
      // Favorite until every picked node is one, then Unfavorite.
      let allFavorites = !selected.isEmpty && selected.allSatisfy(\.isFavorite)
      Button(
        allFavorites ? L10n.Contacts.Contacts.Action.unfavorite : L10n.Contacts.Contacts.Row.favorite,
        systemImage: allFavorites ? "star.slash" : "star.fill"
      ) {
        let targets = selected
        Task { await viewModel.setFavorite(targets, isFavorite: !allFavorites) }
      }
      .disabled(selected.isEmpty || !isConnected || viewModel.togglingFavoriteID != nil)

      Button(L10n.Contacts.Contacts.List.Selection.block, systemImage: "hand.raised") {
        let targets = selected
        Task { await viewModel.blockContacts(targets) }
      }
      .disabled(!isConnected || !selected.contains { $0.type == .chat && !$0.isBlocked })

      DiscoveryGroupMenu(publicKeys: selected.map(\.publicKey), onNewGroup: openNewGroupEditor)
        .disabled(selected.isEmpty)

      Spacer()

      Text(L10n.Contacts.Contacts.Discovery.Selection.count(selected.count))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()

      Spacer()

      Button(L10n.Contacts.Contacts.List.Selection.delete, systemImage: "trash", role: .destructive) {
        showDeleteSelectedConfirmation = true
      }
      .disabled(selected.isEmpty || !isConnected)
    }
  }

  private func deleteSelectedContacts() {
    let contacts = viewModel.selectedContacts(in: filteredContacts)
    withAnimation(.snappy) { viewModel.endSelecting() }
    Task { await viewModel.deleteContacts(contacts) }
  }

  /// The group editor takes one starting member, so it opens empty and the whole selection joins
  /// whichever group it created once it closes.
  private func openNewGroupEditor() {
    groupIDsBeforeEditor = Set(ContactGroupStore.shared.groups.map(\.id))
    groupEditor = ContactGroupEditorItem(mode: .create(initialMember: nil))
  }

  private func addSelectionToNewGroup() {
    let store = ContactGroupStore.shared
    let keys = viewModel.selectedContacts(in: filteredContacts).map(\.publicKey)
    for group in store.groups where !groupIDsBeforeEditor.contains(group.id) {
      store.add(keys, to: group.id)
    }
    groupIDsBeforeEditor = []
  }

  private func importFile(at url: URL) {
    viewModel.importFile(
      at: url,
      maxContacts: appState.connectedDevice.map { Int($0.maxContacts) },
      selfPublicKey: appState.connectedDevice?.publicKey
    )
  }

  /// SwiftUI cancels a ScrollView's `.refreshable` task when observed state mutates
  /// mid-refresh (`isSyncing`). The detached task shields the sync from that cancellation.
  private func refreshNodes() async {
    if appState.connectionState != .ready {
      showOfflineRefreshAlert = true
    } else {
      await Task { await onSyncContacts() }.value
    }
  }
}

/// Says a refresh needs the radio, across the top of the list rather than as an alert over it.
/// A tap puts it away; it goes on its own after a moment.
private struct OfflineRefreshBanner: View {
  let onDismiss: () -> Void

  var body: some View {
    Button(action: onDismiss) {
      HStack(spacing: 8) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .foregroundStyle(.orange)
        Text(L10n.Contacts.Contacts.List.offlineBanner)
          .font(.footnote)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(.rect)
      .background(Color(.systemOrange).opacity(0.12), in: .rect(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.systemOrange).opacity(0.25), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, CardStyle.pageInset)
    .padding(.vertical, 6)
    .accessibilityLabel(L10n.Contacts.Contacts.List.offlineBanner)
    .accessibilityHint(L10n.Chats.Chats.Error.Banner.dismissAccessibilityHint)
  }
}
