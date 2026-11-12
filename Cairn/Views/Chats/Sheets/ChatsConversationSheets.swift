import CairnServices
import SwiftUI

/// The deep-link sheets, conversation sheets, and destructive-action alerts shared by the compact
/// `ChatsView` (stack) and the iPad `ChatsContentColumn` (split). Both attach an identical surface;
/// only the navigation glue (`navigate` and the delete handlers) differs between
/// the stack and split paths, so those are injected as closures.
struct ChatsConversationSheets: ViewModifier {
  @Environment(\.appState) private var appState

  let viewModel: ChatViewModel

  @Binding var showingNewChat: Bool
  @Binding var showingChannelOptions: Bool
  @Binding var roomToAuthenticate: RemoteNodeSessionDTO?
  @Binding var roomToDelete: RemoteNodeSessionDTO?
  @Binding var showRoomDeleteAlert: Bool
  @Binding var channelDeleteFailure: ChatConversationActions.Failure?
  @Binding var showChannelDeleteFailed: Bool
  @Binding var pendingChatContact: ContactDTO?
  @Binding var pendingChannel: ChannelDTO?
  @Binding var conversationToDelete: Conversation?

  let navigate: (ChatRoute) -> Void
  let deleteChannelConversation: (ChannelDTO) -> Void
  let deleteRoom: (RemoteNodeSessionDTO) async -> Void
  /// Runs the staged direct or channel delete once confirmed.
  let deleteConfirmedConversation: (Conversation) -> Void

  /// Title and message of the delete confirmation for a direct or channel conversation.
  private func deleteConfirmation(for conversation: Conversation) -> (title: String, message: String) {
    switch conversation {
    case let .direct(contact):
      (L10n.Chats.Chats.Alert.DeleteConversation.title,
       L10n.Chats.Chats.Alert.DeleteConversation.message(contact.displayName))
    case .channel:
      (L10n.Chats.Chats.ChannelInfo.DeleteConfirm.title,
       L10n.Chats.Chats.ChannelInfo.DeleteConfirm.message)
    case .room:
      (L10n.Chats.Chats.Alert.LeaveRoom.title, L10n.Chats.Chats.Alert.LeaveRoom.message)
    }
  }

  func body(content: Content) -> some View {
    content
      .environment(\.openURL, OpenURLAction { url in
        ChatLinkRouter.route(url, appState: appState) ? .handled : .systemAction
      })
      .sheet(item: Binding(
        get: { appState.navigation.pendingHashtag },
        set: { appState.navigation.pendingHashtag = $0 }
      )) { request in
        JoinHashtagFromMessageView(channelName: request.id) { channel in
          appState.navigation.clearPendingHashtag()
          if let channel {
            navigate(.channel(channel))
          }
        }
        .presentationDetents([.medium])
      }
      .sheet(item: Binding(
        get: { appState.navigation.pendingContactLink },
        set: { appState.navigation.pendingContactLink = $0 }
      )) { result in
        AddContactConfirmationSheet(contactResult: result) { addedContact in
          appState.navigation.clearPendingContactLink()
          if let addedContact {
            appState.navigation.navigateToContactDetail(addedContact)
          }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationSizing(.page)
      }
      .sheet(item: Binding(
        get: { appState.navigation.pendingChannelLink },
        set: { appState.navigation.pendingChannelLink = $0 }
      )) { result in
        JoinChannelConfirmationSheet(channelResult: result) { newChannel in
          appState.navigation.clearPendingChannelLink()
          if let newChannel {
            navigate(.channel(newChannel))
          }
        }
        .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showingNewChat, onDismiss: {
        if let contact = pendingChatContact {
          pendingChatContact = nil
          navigate(.direct(contact))
        }
      }) {
        NewChatView { contact in
          pendingChatContact = contact
          showingNewChat = false
        }
      }
      .sheet(isPresented: $showingChannelOptions, onDismiss: {
        viewModel.requestConversationReload()
        if let channel = pendingChannel {
          pendingChannel = nil
          navigate(.channel(channel))
        }
      }) {
        ChannelOptionsSheet { channel in
          pendingChannel = channel
        }
      }
      .sheet(item: $roomToAuthenticate) { session in
        RoomAuthenticationSheet(session: session) { authenticatedSession in
          roomToAuthenticate = nil
          navigate(.room(authenticatedSession))
        }
        .presentationSizing(.page)
      }
      // Direct and channel deletes confirm like a room leave does, in the same words the
      // channel's info sheet uses; the swipe or menu tap only stages the conversation.
      .confirmationDialog(
        conversationToDelete.map { deleteConfirmation(for: $0).title } ?? "",
        isPresented: Binding(
          get: { conversationToDelete != nil },
          set: { if !$0 { conversationToDelete = nil } }
        ),
        titleVisibility: .visible,
        presenting: conversationToDelete
      ) { conversation in
        Button(L10n.Chats.Chats.Alert.DeleteConversation.confirm, role: .destructive) {
          conversationToDelete = nil
          deleteConfirmedConversation(conversation)
        }
        Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {
          conversationToDelete = nil
        }
      } message: { conversation in
        Text(deleteConfirmation(for: conversation).message)
      }
      .alert(L10n.Chats.Chats.Alert.LeaveRoom.title, isPresented: $showRoomDeleteAlert) {
        Button(L10n.Chats.Chats.Common.cancel, role: .cancel) {
          roomToDelete = nil
        }
        Button(L10n.Chats.Chats.Alert.LeaveRoom.confirm, role: .destructive) {
          Task {
            if let session = roomToDelete { await deleteRoom(session) }
            roomToDelete = nil
          }
        }
      } message: {
        Text(L10n.Chats.Chats.Alert.LeaveRoom.message)
      }
      .alert(
        L10n.Chats.Chats.ChannelInfo.DeleteFailed.title,
        isPresented: $showChannelDeleteFailed,
        presenting: channelDeleteFailure
      ) { failure in
        Button(L10n.Localizable.Common.tryAgain) {
          deleteChannelConversation(failure.channel)
        }
        Button(L10n.Chats.Chats.Common.ok, role: .cancel) {}
      } message: { failure in
        Text(failure.message)
      }
  }
}
