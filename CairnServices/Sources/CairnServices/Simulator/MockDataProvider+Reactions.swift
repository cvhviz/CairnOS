import Foundation

extension MockDataProvider {
  /// Messages that carry seeded reactions, paired with the denormalized badge
  /// summary. `saveMessage` drops `reactionSummary`, so the summary is written via
  /// `updateMessageReactionSummary`; the per-reactor rows render the detail list.
  /// Each summary's counts match the rows returned by `reactions(for:)`.
  static let reactedMessages: [(messageID: UUID, summary: String)] = [
    (aliceReactedMessageID, "👍:2,❤️:1"),
    (bayAreaReactedMessageID, "🎉:2"),
    (bayAreaMentionMessageID, "👍:1")
  ]

  /// Per-reactor reaction rows for the reactor-detail list, stored as real ones are: the reactor's
  /// name on the wire (a DM contact's advertised name, a channel sender's on-air name, the radio's
  /// node name for the user's own) with the user's own marked `isFromSelf`. The sheet names each
  /// as it is shown now ("You", the contact's nickname).
  static func reactions(for messageID: UUID) -> [ReactionDTO] {
    switch messageID {
    case aliceReactedMessageID:
      // A DM has two possible reactors: the user and the contact.
      [
        reaction("A0000000-0000-0000-0000-000000000001", messageID, "👍", "Basecamp", contactID: aliceChenID, isFromSelf: true),
        reaction("A0000000-0000-0000-0000-000000000002", messageID, "👍", "Alice Chen", contactID: aliceChenID),
        reaction("A0000000-0000-0000-0000-000000000003", messageID, "❤️", "Alice Chen", contactID: aliceChenID)
      ]
    case bayAreaReactedMessageID:
      [
        reaction("A1000000-0000-0000-0000-000000000001", messageID, "🎉", "Alice Chen", channelIndex: bayAreaChannelIndex),
        reaction("A1000000-0000-0000-0000-000000000002", messageID, "🎉", "Bob Martinez", channelIndex: bayAreaChannelIndex)
      ]
    case bayAreaMentionMessageID:
      [
        reaction("A1000000-0000-0000-0000-000000000003", messageID, "👍", "Basecamp", channelIndex: bayAreaChannelIndex, isFromSelf: true)
      ]
    default:
      []
    }
  }

  private static func reaction(
    _ id: String,
    _ messageID: UUID,
    _ emoji: String,
    _ sender: String,
    contactID: UUID? = nil,
    channelIndex: UInt8? = nil,
    isFromSelf: Bool = false
  ) -> ReactionDTO {
    ReactionDTO(
      id: UUID(uuidString: id)!,
      messageID: messageID,
      emoji: emoji,
      senderName: sender,
      messageHash: String(messageID.uuidString.prefix(8)),
      rawText: emoji,
      channelIndex: channelIndex,
      contactID: contactID,
      radioID: simulatorDeviceID,
      isFromSelf: isFromSelf
    )
  }
}
