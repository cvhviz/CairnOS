import CairnServices
import SwiftUI

struct ChatsView: View {
  @Environment(\.appState) private var appState

  @State private var viewModel = ChatViewModel()
  @State private var searchText = ""
  @State private var selectedFilter: ChatFilter = .all
  @State private var showingNewChat = false
  @State private var showingChannelOptions = false

  @State private var navigationPath = NavigationPath()
  @State private var activeRoute: ChatRoute?
  /// The open chat as "kind:uuid", so a restored scene reopens it (`ChatRoutePersistence`).
  @SceneStorage(SceneStorageKey.chatsOpenRoute.rawValue) private var persistedRoute = ""

  @State private var roomToAuthenticate: RemoteNodeSessionDTO?
  @State private var roomToDelete: RemoteNodeSessionDTO?
  @State private var showRoomDeleteAlert = false
  @State private var showChannelDeleteFailed = false
  @State private var channelDeleteFailure: ChatConversationActions.Failure?
  @State private var pendingChatContact: ContactDTO?
  @State private var pendingChannel: ChannelDTO?
  @State private var conversationToDelete: Conversation?

  private var filteredFavorites: [Conversation] {
    viewModel.favoriteConversations.filtered(by: selectedFilter, searchText: searchText)
  }

  private var filteredOthers: [Conversation] {
    viewModel.nonFavoriteConversations.filtered(by: selectedFilter, searchText: searchText)
  }

  private var emptyStateMessage: (title: String, description: String, systemImage: String) {
    switch selectedFilter {
    case .all:
      (L10n.Chats.Chats.EmptyState.NoConversations.title, L10n.Chats.Chats.EmptyState.NoConversations.description, "message")
    case .unread:
      (L10n.Chats.Chats.EmptyState.NoUnread.title, L10n.Chats.Chats.EmptyState.NoUnread.description, "checkmark.circle")
    case .directMessages:
      (L10n.Chats.Chats.EmptyState.NoDirectMessages.title, L10n.Chats.Chats.EmptyState.NoDirectMessages.description, "person")
    case .channels:
      (L10n.Chats.Chats.EmptyState.NoChannels.title, L10n.Chats.Chats.EmptyState.NoChannels.description, "number")
    case .rooms:
      (L10n.Chats.Chats.EmptyState.NoRooms.title, L10n.Chats.Chats.EmptyState.NoRooms.description, "door.left.hand.open")
    }
  }

  private var actions: ChatListActions {
    ChatListActions(
      viewModel: viewModel,
      appState: appState,
      roomToDelete: $roomToDelete,
      showRoomDeleteAlert: $showRoomDeleteAlert,
      channelDeleteFailure: $channelDeleteFailure,
      showChannelDeleteFailed: $showChannelDeleteFailed,
      roomToAuthenticate: $roomToAuthenticate,
      conversationToDelete: $conversationToDelete,
      navigate: { navigate(to: $0) },
      clearNavigationIfActive: clearNavigationIfActive
    )
  }

  var body: some View {
    ChatsStackLayout(
      viewModel: viewModel,
      navigationPath: $navigationPath,
      activeRoute: $activeRoute
    ) {
      ChatsStackRootContent(
        viewModel: viewModel,
        filteredFavorites: filteredFavorites,
        filteredOthers: filteredOthers,
        emptyStateMessage: emptyStateMessage,
        hasLoadedOnce: viewModel.hasLoadedOnce,
        selectedFilter: $selectedFilter,
        searchText: $searchText,
        showingNewChat: $showingNewChat,
        showingChannelOptions: $showingChannelOptions,
        roomToAuthenticate: $roomToAuthenticate,
        navigationPath: $navigationPath,
        onDeleteConversation: actions.handleDeleteConversation,
        onHandlePendingNavigation: actions.handlePendingNavigation,
        onHandlePendingChannelNavigation: actions.handlePendingChannelNavigation,
        onHandlePendingRoomNavigation: actions.handlePendingRoomNavigation,
        onAnnounceOfflineStateIfNeeded: actions.announceOfflineStateIfNeeded
      )
    }
    .task {
      restoreSplitSelection()
      await restorePersistedRoute()
      actions.consumePendingRoomAuthentication()
    }
    .onChange(of: appState.navigation.chatsSelectedRoute) { _, route in
      persistedRoute = ChatRoutePersistence.encode(route)
    }
    .onChange(of: appState.navigation.pendingRoomAuthentication) { _, _ in
      actions.consumePendingRoomAuthentication()
    }
    // Keep the pushed route's payload current as the snapshot recomputes; a route
    // whose conversation was removed resolves to nil and the push unwinds.
    .onChange(of: viewModel.snapshotGeneration) { _, _ in
      activeRoute = activeRoute?.refreshedPayload(from: viewModel.allConversations)
    }
    .modifier(ChatsConversationSheets(
      viewModel: viewModel,
      showingNewChat: $showingNewChat,
      showingChannelOptions: $showingChannelOptions,
      roomToAuthenticate: $roomToAuthenticate,
      roomToDelete: $roomToDelete,
      showRoomDeleteAlert: $showRoomDeleteAlert,
      channelDeleteFailure: $channelDeleteFailure,
      showChannelDeleteFailed: $showChannelDeleteFailed,
      pendingChatContact: $pendingChatContact,
      pendingChannel: $pendingChannel,
      conversationToDelete: $conversationToDelete,
      navigate: { navigate(to: $0) },
      deleteChannelConversation: actions.deleteChannelConversation,
      deleteRoom: actions.deleteRoom,
      deleteConfirmedConversation: actions.deleteConfirmedConversation
    ))
  }

  private func navigate(to route: ChatRoute) {
    if case let .room(session) = route, !session.isConnected {
      roomToAuthenticate = session
      return
    }

    appState.navigation.tabBarVisibility = .hidden
    navigationPath.removeLast(navigationPath.count)
    navigationPath.append(route)
  }

  /// This stack is built fresh when the window narrows from the iPad split, so it reopens the chat
  /// the split had selected. A notification tap still pending opens its own chat once the list has
  /// loaded, so it is left alone. A room that has since disconnected is not reopened behind an
  /// authentication prompt. With nothing pushed the tab bar is shown, since a navigation made in
  /// the split hid it.
  private func restoreSplitSelection() {
    let navigation = appState.navigation
    guard navigationPath.isEmpty,
          navigation.pendingChatContact == nil,
          navigation.pendingChannel == nil,
          navigation.pendingRoomSession == nil else { return }
    if let route = navigation.chatsSelectedRoute, route.roomIsConnected != false {
      navigate(to: route)
    } else {
      navigation.tabBarVisibility = .visible
    }
  }

  /// After a relaunch nothing is selected, so the chat the scene last had open is re-read from
  /// the store by its persisted key and pushed; with a selection or a pending jump, nothing.
  private func restorePersistedRoute() async {
    guard navigationPath.isEmpty, appState.navigation.chatsSelectedRoute == nil,
          appState.navigation.pendingChatContact == nil,
          appState.navigation.pendingChannel == nil,
          appState.navigation.pendingRoomSession == nil,
          let store = appState.offlineDataStore,
          let route = await ChatRoutePersistence.resolve(persistedRoute, radioID: appState.currentRadioID, store: store)
    else { return }
    guard navigationPath.isEmpty, appState.navigation.chatsSelectedRoute == nil else { return }
    navigate(to: route)
  }

  private func clearNavigationIfActive(_ route: ChatRoute) {
    if activeRoute == route {
      navigationPath.removeLast(navigationPath.count)
      activeRoute = nil
      appState.navigation.tabBarVisibility = .visible
    }
  }
}

#Preview {
  ChatsView()
    .environment(\.appState, AppState())
}
