import CairnServices
import SwiftUI

struct RoomConversationRow: View {
  @Environment(\.appState) private var appState
  let session: RemoteNodeSessionDTO
  let viewModel: ChatViewModel
  var referenceDate: Date?

  var body: some View {
    HStack(spacing: 12) {
      NodeAvatar(publicKey: session.publicKey, role: .roomServer, size: 44)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(session.name)
            .font(.headline)
            .lineLimit(1)

          Spacer()

          NotificationLevelIndicator(level: session.notificationLevel)

          if let date = session.lastMessageDate {
            ConversationTimestamp(date: date, referenceDate: referenceDate)
          }

          FavoriteStar(isFavorite: session.isFavorite, label: L10n.Chats.Chats.Row.favorite)
        }

        HStack {
          if let preview = viewModel.lastMessagePreview(id: session.id) {
            // The last post, "Author: text" as channels show it, with the connection state as a
            // glyph so it doesn't take the preview's place.
            connectionGlyph
            ConversationPreviewText(
              sender: viewModel.lastMessageSender(id: session.id),
              text: preview,
              isUnread: session.unreadCount > 0
            )
          } else if isConnected {
            Label(L10n.Chats.Chats.Room.connected, systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
          } else {
            Text(L10n.Chats.Chats.Room.tapToReconnect)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }

          Spacer()

          if viewModel.conversationHasFailedSend(session.id) {
            FailedSendIndicator()
          }

          UnreadBadges(
            unreadCount: session.unreadCount,
            notificationLevel: session.notificationLevel
          )
        }
      }

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 4)
    .contentShape(.rect)
  }

  private var isConnected: Bool {
    session.isConnected && appState.connectionState == .ready
  }

  /// Connected (green check) or needing a tap to reconnect, beside the last post.
  private var connectionGlyph: some View {
    Image(systemName: isConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
      .font(.caption)
      .foregroundStyle(isConnected ? Color.green : Color.secondary)
      .accessibilityLabel(isConnected ? L10n.Chats.Chats.Room.connected : L10n.Chats.Chats.Room.tapToReconnect)
  }
}
