import CairnServices
import OSLog
import SwiftUI

private let nodesListLogger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodesListView")

/// The Nodes tab on iPhone: the Saved and Heard lists (see `ContactsSidebarContent`) in one stack.
struct ContactsListView: View {
  @Environment(\.appState) private var appState

  @State private var viewModel = ContactsViewModel()
  @State private var navigationPath = NavigationPath()
  @AppStorage(AppStorageKey.nodesSortOrder.rawValue) private var sortOrder: NodeSortOrder = .lastHeard
  @AppStorage(AppStorageKey.nodesFavoritesOnly.rawValue) private var favoritesOnly = false
  @State private var syncSuccessTrigger = false
  @State private var showShareMyContact = false
  @State private var showAddContact = false
  @State private var showLocationDeniedAlert = false
  @State private var showOfflineRefreshAlert = false

  private var actions: ContactListActions {
    ContactListActions(viewModel: viewModel, appState: appState, syncSuccessTrigger: $syncSuccessTrigger)
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      sidebarContent
        // The bar's backdrop always drawn, so it doesn't come and go with the pulled-down search
        // and every tab's top reads alike (the user, 2026-11-08).
        .tabTopBarBackdrop()
    }
    // A switch to the iPad columns builds a fresh stack; the segment and search text live on
    // the coordinator so they survive it.
    .task { restoreSplitSelection() }
    .onChange(of: navigationPath) { _, newPath in
      if newPath.isEmpty { appState.navigation.selectedContact = nil }
    }
  }

  /// This stack is built fresh when the window narrows from the iPad split, so it reopens the node
  /// the split had selected, unless a node page asked for elsewhere already pushed its own.
  private func restoreSplitSelection() {
    let navigation = appState.navigation
    guard navigationPath.isEmpty,
          navigation.pendingContactDetail == nil,
          navigation.nodesSection == .saved,
          let contact = navigation.selectedContact else { return }
    navigationPath.append(ContactRoute.detail(contact))
  }

  private var sidebarContent: some View {
    @Bindable var navigation = appState.navigation
    return ContactsSidebarContent(
      viewModel: viewModel,
      filteredContacts: actions.filteredContacts(
        searchText: navigation.nodesSearchText,
        segment: navigation.nodesSegment,
        favoritesOnly: favoritesOnly,
        sortOrder: sortOrder
      ),
      isSearching: !navigation.nodesSearchText.isEmpty,
      searchPrompt: actions.searchPrompt,
      shouldUseSplitView: false,
      selectedSegment: $navigation.nodesSegment,
      // Split-only: the compact stack navigates via navigationPath, so it has no selection.
      selectedContact: .constant(nil),
      searchText: $navigation.nodesSearchText,
      sortOrder: $sortOrder,
      syncSuccessTrigger: $syncSuccessTrigger,
      showShareMyContact: $showShareMyContact,
      showAddContact: $showAddContact,
      showLocationDeniedAlert: $showLocationDeniedAlert,
      showOfflineRefreshAlert: $showOfflineRefreshAlert,
      navigationPath: $navigationPath,
      onLoadContacts: actions.loadContacts,
      onSyncContacts: actions.syncContacts,
      onAnnounceOfflineStateIfNeeded: actions.announceOfflineStateIfNeeded
    )
  }
}

#Preview {
  ContactsListView()
    .environment(\.appState, AppState())
}
