import CairnServices
import SwiftUI

/// The Nodes tab's list column at regular width (`ContactsTabSplit`). It mirrors the regular-width (split) path of
/// `ContactsListView`, hosting `ContactsSidebarContent` with the same toolbar, searchable,
/// sheets, and handlers. The compact (stack) path stays solely in `ContactsListView`.
///
/// Selection is driven through `appState.navigation.selectedContact` rather than view-local
/// state so the detail column can read it. `ContactsSidebarContent`'s
/// `pendingContactDetail` bridge writes through that binding; its `initial: true` resolves a
/// deep link (e.g. a notification tap) the first time Nodes is entered, and this view is
/// instantiated whenever Nodes is selected.
struct ContactsContentColumn: View {
  @Environment(\.appState) private var appState

  @State private var viewModel = ContactsViewModel()
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
    @Bindable var navigation = appState.navigation

    ContactsSidebarContent(
      viewModel: viewModel,
      // The segment and search text live on the coordinator, so a switch to the compact stack
      // (Split View, a rotation) keeps them.
      filteredContacts: actions.filteredContacts(
        searchText: navigation.nodesSearchText,
        segment: navigation.nodesSegment,
        favoritesOnly: favoritesOnly,
        sortOrder: sortOrder
      ),
      isSearching: !navigation.nodesSearchText.isEmpty,
      searchPrompt: actions.searchPrompt,
      shouldUseSplitView: true,
      selectedSegment: $navigation.nodesSegment,
      selectedContact: $navigation.selectedContact,
      searchText: $navigation.nodesSearchText,
      sortOrder: $sortOrder,
      syncSuccessTrigger: $syncSuccessTrigger,
      showShareMyContact: $showShareMyContact,
      showAddContact: $showAddContact,
      showLocationDeniedAlert: $showLocationDeniedAlert,
      showOfflineRefreshAlert: $showOfflineRefreshAlert,
      // Compact-only navigation, unused on the split path which drives selection via selectedContact.
      navigationPath: .constant(NavigationPath()),
      onLoadContacts: actions.loadContacts,
      onSyncContacts: actions.syncContacts,
      onAnnounceOfflineStateIfNeeded: actions.announceOfflineStateIfNeeded
    )
  }
}

#Preview {
  NavigationStack {
    ContactsContentColumn()
  }
  .environment(\.appState, AppState())
}
