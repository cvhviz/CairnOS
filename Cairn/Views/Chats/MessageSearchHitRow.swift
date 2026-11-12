import CairnServices
import SwiftUI

/// A radio-wide message search hit in the Chats list: the conversation it's in, who wrote it,
/// the matching text and when. Tapping opens the conversation at that message.
struct MessageSearchHitRow: View {
  let hit: MessageSearchHit
  let viewModel: ChatViewModel

  /// You for an outgoing message, the contact for a DM, the channel sender as the list previews
  /// name them; nil when a channel message carried no name.
  private var senderName: String? {
    if hit.message.isOutgoing { return L10n.Chats.Chats.Path.Receiver.you }
    switch hit.conversation {
    case let .direct(contact): return contact.displayName
    case .channel: return viewModel.listSenderNames.channelSenders.shortName(for: hit.message.senderNodeName)
    case .room: return nil
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      avatar
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(hit.conversation.displayName)
            .font(.headline)
            .lineLimit(1)
          Spacer()
          Text(hit.message.date, format: .dateTime.month().day().hour().minute())
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ConversationPreviewText(
          sender: senderName,
          text: MessagePreviewFormatter.preview(hit.message.text),
          isUnread: false
        )
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var avatar: some View {
    switch hit.conversation {
    case let .direct(contact): ContactAvatar(contact: contact, size: 44)
    case let .channel(channel): ChannelAvatar(channel: channel, size: 44)
    case let .room(session): NodeAvatar(publicKey: session.publicKey, role: .roomServer, size: 44)
    }
  }
}
