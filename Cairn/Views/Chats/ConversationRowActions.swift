import SwiftUI

/// Shared menu and swipe buttons for a conversation row. `edge` picks the full set or one swipe side.
struct ConversationRowActions: View {
  enum Edge {
    case all
    case leading
    case trailing
  }

  @Environment(\.appState) private var appState
  @Environment(\.openWindow) private var openWindow
  @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

  let conversation: Conversation
  let viewModel: ChatViewModel
  let onDelete: () -> Void
  let edge: Edge

  private var isConnected: Bool {
    appState.connectionState == .ready
  }

  /// Nil when the conversation cannot open in its own window: rooms, and the conversation the
  /// main window is showing. The timeline has a single writer, so a second view of that
  /// conversation would revoke the main window's and its sent messages would stop appearing.
  private var newWindowID: ConversationWindowID? {
    let route = ChatRoute(conversation: conversation)
    guard appState.navigation.chatsSelectedRoute != route else { return nil }
    return ConversationWindowID(route: route)
  }

  private var isTogglingFavorite: Bool {
    guard case let .direct(contact) = conversation else { return false }
    return viewModel.togglingFavoriteID == contact.id
  }

  var body: some View {
    // Menu only: opening a window is a pointer/keyboard affordance, not a swipe.
    if edge == .all, supportsMultipleWindows, let windowID = newWindowID {
      Button(L10n.Chats.Chats.Row.openInNewWindow, systemImage: "macwindow.badge.plus") {
        openWindow(value: windowID)
      }
      Divider()
    }
    if edge != .leading {
      deleteButton
      muteButton
    }
    if edge != .trailing {
      // The leading swipe's full swipe stays Favorite (the first button); unread follows it.
      favoriteButton
      if conversation.unreadCount > 0 {
        markAsReadButton
      } else {
        markAsUnreadButton
      }
    }
  }

  private var markAsReadButton: some View {
    Button {
      Task {
        await viewModel.markAsRead(conversation)
      }
    } label: {
      Label(L10n.Localizable.Notifications.Action.markAsRead, systemImage: "envelope.open")
    }
  }

  private var markAsUnreadButton: some View {
    Button {
      Task {
        await viewModel.markAsUnread(conversation)
      }
    } label: {
      Label(L10n.Chats.Chats.Action.markAsUnread, systemImage: "envelope.badge")
    }
  }

  private var deleteButton: some View {
    Button(role: .destructive) {
      onDelete()
    } label: {
      Label(L10n.Chats.Chats.Action.delete, systemImage: "trash")
    }
    .disabled(!isConnected || viewModel.isDeletePending(conversation.id))
  }

  /// Mute is an app-only store write, so it stays available while the radio is away.
  private var muteButton: some View {
    Button {
      Task {
        await viewModel.toggleMute(conversation)
      }
    } label: {
      Label(
        conversation.isMuted ? L10n.Chats.Chats.Action.unmute : L10n.Chats.Chats.Action.mute,
        systemImage: conversation.isMuted ? "bell" : "bell.slash"
      )
    }
  }

  /// Only a contact's favorite flag lives on the radio; channel and room favorites are app-only.
  private var favoriteNeedsRadio: Bool {
    if case .direct = conversation { return !isConnected }
    return false
  }

  private var favoriteButton: some View {
    Button {
      Task {
        await viewModel.toggleFavorite(conversation, disableAnimation: true)
      }
    } label: {
      Label(
        conversation.isFavorite ? L10n.Chats.Chats.Action.unfavorite : L10n.Chats.Chats.Action.favorite,
        systemImage: conversation.isFavorite ? "star.slash" : "star.fill"
      )
    }
    .disabled(favoriteNeedsRadio || isTogglingFavorite)
  }
}

extension View {
  func conversationContextMenu(
    conversation: Conversation,
    viewModel: ChatViewModel,
    onDelete: @escaping () -> Void
  ) -> some View {
    contextMenu {
      ConversationRowActions(
        conversation: conversation,
        viewModel: viewModel,
        onDelete: onDelete,
        edge: .all
      )
    }
  }

  func conversationSwipeActions(
    conversation: Conversation,
    viewModel: ChatViewModel,
    onDelete: @escaping () -> Void
  ) -> some View {
    swipeActions(edge: .leading, allowsFullSwipe: true) {
      ConversationRowActions(
        conversation: conversation,
        viewModel: viewModel,
        onDelete: onDelete,
        edge: .leading
      )
    }
    // Full-swipe off so Delete cannot fire without a tap.
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      ConversationRowActions(
        conversation: conversation,
        viewModel: viewModel,
        onDelete: onDelete,
        edge: .trailing
      )
    }
  }
}
