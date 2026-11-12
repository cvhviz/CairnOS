import CairnServices
import Foundation

/// One hit of the Chats list's radio-wide message search: the message and the listed
/// conversation it belongs to, so the row can name the conversation and open it.
struct MessageSearchHit: Identifiable, Equatable {
  let message: MessageDTO
  let conversation: Conversation

  var id: UUID { message.id }

  var route: ChatRoute { ChatRoute(conversation: conversation) }

  /// Pairs each stored hit with its listed conversation: a direct message by `contactID`, a
  /// channel message by its radio and slot. Hits whose conversation isn't listed (a blocked
  /// contact, a cleared slot) are dropped, since there is no row to open. Order is kept.
  static func resolve(messages: [MessageDTO], conversations: [Conversation]) -> [MessageSearchHit] {
    var contactsByID: [UUID: Conversation] = [:]
    var channelsBySlot: [ChannelSlot: Conversation] = [:]
    for conversation in conversations {
      switch conversation {
      case let .direct(contact):
        contactsByID[contact.id] = conversation
      case let .channel(channel):
        channelsBySlot[ChannelSlot(radioID: channel.radioID, index: channel.index)] = conversation
      case .room:
        break
      }
    }
    return messages.compactMap { message in
      let conversation: Conversation? = if let contactID = message.contactID {
        contactsByID[contactID]
      } else if let index = message.channelIndex {
        channelsBySlot[ChannelSlot(radioID: message.radioID, index: index)]
      } else {
        nil
      }
      guard let conversation else { return nil }
      return MessageSearchHit(message: message, conversation: conversation)
    }
  }

  private struct ChannelSlot: Hashable {
    let radioID: UUID
    let index: UInt8
  }
}
