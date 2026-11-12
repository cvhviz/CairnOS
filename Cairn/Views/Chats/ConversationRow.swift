import CairnServices
import SwiftUI

struct ConversationRow: View {
  let contact: ContactDTO
  let viewModel: ChatViewModel
  var referenceDate: Date?

  var body: some View {
    HStack(spacing: 12) {
      ContactAvatar(contact: contact, size: 44)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(contact.displayName)
            .font(.headline)
            .lineLimit(1)

          Spacer()

          NotificationLevelIndicator(level: contact.isMuted ? .muted : .all)

          if let date = contact.lastMessageDate {
            ConversationTimestamp(date: date, referenceDate: referenceDate)
          }

          FavoriteStar(
            isFavorite: contact.isFavorite,
            isToggling: viewModel.togglingFavoriteID == contact.id,
            label: L10n.Chats.Chats.Row.favorite
          )
        }

        HStack {
          ConversationPreviewText(
            sender: viewModel.lastMessageSender(id: contact.id),
            text: viewModel.lastMessagePreview(id: contact.id) ?? L10n.Chats.Chats.Row.noMessages,
            isUnread: contact.unreadCount > 0,
            draft: viewModel.draftPreview(id: contact.id)
          )

          Spacer()

          if viewModel.conversationHasFailedSend(contact.id) {
            FailedSendIndicator()
          }

          UnreadBadges(
            unreadCount: contact.unreadCount,
            unreadMentionCount: contact.unreadMentionCount,
            notificationLevel: contact.isMuted ? .muted : .all
          )
        }
      }
    }
    .padding(.vertical, 4)
  }
}

/// A list row's last-message line: who sent it in semibold ("You", or a channel sender's name),
/// then the message, on one line. Primary while unread, secondary once read.
struct ConversationPreviewText: View {
  let sender: String?
  let text: String
  let isUnread: Bool
  /// An unsent composer draft, shown in place of the last message with a tinted "Draft:" so
  /// the row says there is something left to send.
  var draft: String?

  var body: some View {
    Group {
      if let draft {
        Text("\(Text(L10n.Chats.Chats.Row.draftPrefix).fontWeight(.semibold).foregroundStyle(.tint)) \(draft)")
      } else if let sender {
        Text("\(Text(sender + ":").fontWeight(.semibold)) \(text)")
      } else {
        Text(text)
      }
    }
    .font(.subheadline)
    .foregroundStyle(isUnread ? .primary : .secondary)
    .lineLimit(1)
  }
}
