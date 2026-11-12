import CairnServices
import SwiftUI

struct ChannelConversationRow: View {
  private typealias Strings = L10n.Chats.Chats.Row
  let channel: ChannelDTO
  let viewModel: ChatViewModel
  var referenceDate: Date?

  var body: some View {
    HStack(spacing: 12) {
      ChannelAvatar(channel: channel, size: 44)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(channel.displayName)
            .font(.headline)
            .lineLimit(1)

          Spacer()

          NotificationLevelIndicator(level: channel.notificationLevel)

          if let date = channel.lastMessageDate {
            ConversationTimestamp(date: date, referenceDate: referenceDate)
          }

          FavoriteStar(isFavorite: channel.isFavorite, label: Strings.favorite)
        }

        HStack {
          ConversationPreviewText(
            sender: viewModel.lastMessageSender(id: channel.id),
            text: viewModel.lastMessagePreview(id: channel.id) ?? Strings.noMessages,
            isUnread: channel.unreadCount > 0,
            draft: viewModel.draftPreview(id: channel.id)
          )

          Spacer()

          if viewModel.conversationHasFailedSend(channel.id) {
            FailedSendIndicator()
          }

          UnreadBadges(
            unreadCount: channel.unreadCount,
            unreadMentionCount: channel.unreadMentionCount,
            notificationLevel: channel.notificationLevel
          )
        }
      }
    }
    .padding(.vertical, 4)
  }
}
