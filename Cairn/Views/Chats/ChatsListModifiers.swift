import CairnServices
import SwiftUI

/// Shared modifiers applied to the conversation list in both stack and split layouts.
struct ChatsListModifiers: ViewModifier {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let viewModel: ChatViewModel

  @Binding var searchText: String
  @Binding var showingNewChat: Bool
  @Binding var showingChannelOptions: Bool

  let onAnnounceOfflineStateIfNeeded: () -> Void
  let onHandlePendingNavigation: () -> Void
  let onHandlePendingChannelNavigation: () -> Void
  let onHandlePendingRoomNavigation: () -> Void

  /// Mark All as Read confirms once more than a few conversations would change at once.
  @State private var showingMarkAllReadConfirmation = false
  private static let markAllReadConfirmationThreshold = 3

  private func markAllAsRead() {
    if viewModel.unreadConversations.count > Self.markAllReadConfirmationThreshold {
      showingMarkAllReadConfirmation = true
    } else {
      Task { await viewModel.markAllAsRead() }
    }
  }

  func body(content: Content) -> some View {
    content
      .themedCanvas(theme)
      .deviceNameTitle(pageTitle: L10n.Chats.Chats.title)
      // Search is a field above the list that a pull down reveals (`PullDownSearch`).
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Menu {
            Button {
              showingNewChat = true
            } label: {
              Label(L10n.Chats.Chats.Compose.newChat, systemImage: "person")
            }

            Button {
              showingChannelOptions = true
            } label: {
              Label(L10n.Chats.Chats.Compose.newChannel, systemImage: "number")
            }

            Divider()

            Button {
              markAllAsRead()
            } label: {
              Label(L10n.Chats.Chats.Action.markAllAsRead, systemImage: "envelope.open")
            }
            .disabled(viewModel.unreadConversations.isEmpty)
          } label: {
            Label(L10n.Chats.Chats.Compose.newMessage, systemImage: "square.and.pencil")
          }
        }
      }
      .confirmationDialog(
        L10n.Chats.Chats.Alert.MarkAllAsRead.title,
        isPresented: $showingMarkAllReadConfirmation,
        titleVisibility: .visible
      ) {
        Button(L10n.Chats.Chats.Alert.MarkAllAsRead.confirm) {
          Task { await viewModel.markAllAsRead() }
        }
        Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Chats.Chats.Alert.MarkAllAsRead.message)
      }
      // Here rather than on each layout's root so the stack (compact) and split (iPad) lists both
      // get the Comm settings sliders, and only one of them is ever on screen.
      .tabSettingsToolbarItem(for: .chats)
      .onChange(of: appState.navigation.composeRequestVersion) { _, _ in
        switch appState.navigation.composeRequest {
        case .chat: showingNewChat = true
        case .channel: showingChannelOptions = true
        case nil: break
        }
      }
      .task {
        viewModel.configure(
          dependencies: ChatViewModel.Dependencies(
            dataStore: { appState.offlineDataStore },
            messageService: { appState.services?.messageService },
            notificationService: { appState.services?.notificationService },
            channelService: { appState.services?.channelService },
            roomServerService: { appState.services?.roomServerService },
            contactService: { appState.services?.contactService },
            syncCoordinator: { appState.syncCoordinator },
            connectionState: { appState.connectionState },
            connectedDevice: { appState.connectedDevice },
            currentRadioID: { appState.currentRadioID },
            session: { appState.services?.session },
            reactionService: { appState.services?.reactionService },
            chatSendQueueService: { appState.services?.chatSendQueueService },
            inlineImageDimensionsStore: { nil },
            prefetchDataStore: { nil }
          ),
          onNavigateToMap: { appState.navigation.navigateToMap(coordinate: $0) },
          linkPreviewCache: nil,
          chatCoordinatorRegistry: nil,
          conversation: nil
        )
        await viewModel.requestConversationReload()?.value
        viewModel.refreshDraftPreviews(from: appState.draftStore)
        onAnnounceOfflineStateIfNeeded()
        onHandlePendingNavigation()
        onHandlePendingChannelNavigation()
        onHandlePendingRoomNavigation()
      }
      .task {
        for await event in appState.messageEventStream.events() {
          if viewModel.shouldRefreshFailedSendIndicators(for: event) {
            await viewModel.refreshFailedSendIndicators()
          }
        }
      }
      .onChange(of: appState.navigation.pendingChatContact) { _, _ in
        onHandlePendingNavigation()
      }
      .onChange(of: appState.navigation.pendingChannel) { _, _ in
        onHandlePendingChannelNavigation()
      }
      .onChange(of: appState.navigation.pendingRoomSession) { _, _ in
        onHandlePendingRoomNavigation()
      }
      .onChange(of: appState.servicesVersion) { _, _ in
        viewModel.requestConversationReload()
      }
      .onChange(of: appState.conversationsVersion) { _, _ in
        viewModel.requestConversationReload()
      }
      .onChange(of: appState.connectionState) { _, newState in
        if newState == .disconnected {
          viewModel.requestConversationReload()
        }
      }
      // Every reload re-reads the drafts: a draft typed in a chat shows on its row on pop-back,
      // and one sent there stops showing. The store is not observable, so the rows can't watch it.
      .onChange(of: viewModel.isLoading, initial: true) { _, loading in
        if !loading { viewModel.refreshDraftPreviews(from: appState.draftStore) }
      }
      // Messages matching the search list under the name matches.
      .onChange(of: searchText) { _, text in
        viewModel.searchMessages(query: text, radioID: appState.currentRadioID)
      }
      // Surfaces direct-message and room delete failures; the channel retry alert lives on
      // ChatsConversationSheets, and only one can present since deletes happen one at a time.
      .errorAlert(Binding(
        get: { viewModel.errorMessage },
        set: { viewModel.errorMessage = $0 }
      ))
      // A list load that failed: a passive strip, since the user did not ask for the load.
      .errorBanner(Binding(
        get: { viewModel.errorBannerMessage },
        set: { viewModel.errorBannerMessage = $0 }
      ))
  }
}
