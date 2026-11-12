import Foundation
import SwiftData

/// Represents an emoji reaction to a channel or DM message.
@Model
public final class Reaction {
  #Index<Reaction>(
    [\.messageID],
    [\.radioID, \.contactID, \.messageID],
    [\.messageID, \.senderName, \.emoji]
  )

  @Attribute(.unique)
  public var id: UUID

  /// Target message UUID
  public var messageID: UUID

  /// The emoji used
  public var emoji: String

  /// The reactor's name on the wire: the parsed channel sender name, the DM contact's advertised
  /// name, or for the user's own reaction the node name it went out under. Identity data, not a
  /// display label: the shown name is resolved when rendered (`ReactionDTO.displayName`). Empty when
  /// a channel reaction carried no sender. Rows saved before this rule may hold a nickname or the
  /// English literal "Unknown".
  public var senderName: String

  /// The user's own reaction. Defaults to false for rows saved before the field existed;
  /// `PersistenceStore.markOwnReactions` backfills those once per radio.
  public var isFromSelf: Bool = false

  /// Message hash from wire format (8 hex chars)
  public var messageHash: String

  /// Original raw text for fallback display
  public var rawText: String

  /// When we received this reaction
  public var receivedAt: Date

  /// Channel index where received (nil for DM reactions)
  public var channelIndex: UInt8?

  /// Contact ID for DM reactions (nil for channel reactions)
  public var contactID: UUID?

  /// Device ID this belongs to
  public var radioID: UUID

  public init(
    id: UUID = UUID(),
    messageID: UUID,
    emoji: String,
    senderName: String,
    messageHash: String,
    rawText: String,
    receivedAt: Date = Date(),
    channelIndex: UInt8? = nil,
    contactID: UUID? = nil,
    radioID: UUID,
    isFromSelf: Bool = false
  ) {
    self.id = id
    self.messageID = messageID
    self.emoji = emoji
    self.senderName = senderName
    self.messageHash = messageHash
    self.rawText = rawText
    self.receivedAt = receivedAt
    self.channelIndex = channelIndex
    self.contactID = contactID
    self.radioID = radioID
    self.isFromSelf = isFromSelf
  }

  /// Builds a model instance directly from a DTO.
  public convenience init(dto: ReactionDTO) {
    self.init(
      id: dto.id,
      messageID: dto.messageID,
      emoji: dto.emoji,
      senderName: dto.senderName,
      messageHash: dto.messageHash,
      rawText: dto.rawText,
      receivedAt: dto.receivedAt,
      channelIndex: dto.channelIndex,
      contactID: dto.contactID,
      radioID: dto.radioID,
      isFromSelf: dto.isFromSelf
    )
  }
}

// MARK: - Sendable DTO

public struct ReactionDTO: Sendable, Equatable, Hashable, Identifiable, Codable {
  public let id: UUID
  public var messageID: UUID
  public let emoji: String
  public let senderName: String
  public let messageHash: String
  public let rawText: String
  public let receivedAt: Date
  /// Mutable so backup import can rewrite it in lockstep with the parent channel
  /// message when a channel relocates to a different local slot.
  public var channelIndex: UInt8?
  public var contactID: UUID?
  public var radioID: UUID
  /// The user's own reaction (see `Reaction.isFromSelf`).
  public let isFromSelf: Bool

  public init(from reaction: Reaction) {
    id = reaction.id
    messageID = reaction.messageID
    emoji = reaction.emoji
    senderName = reaction.senderName
    messageHash = reaction.messageHash
    rawText = reaction.rawText
    receivedAt = reaction.receivedAt
    channelIndex = reaction.channelIndex
    contactID = reaction.contactID
    radioID = reaction.radioID
    isFromSelf = reaction.isFromSelf
  }

  public init(
    id: UUID = UUID(),
    messageID: UUID,
    emoji: String,
    senderName: String,
    messageHash: String,
    rawText: String,
    receivedAt: Date = Date(),
    channelIndex: UInt8? = nil,
    contactID: UUID? = nil,
    radioID: UUID,
    isFromSelf: Bool = false
  ) {
    self.id = id
    self.messageID = messageID
    self.emoji = emoji
    self.senderName = senderName
    self.messageHash = messageHash
    self.rawText = rawText
    self.receivedAt = receivedAt
    self.channelIndex = channelIndex
    self.contactID = contactID
    self.radioID = radioID
    self.isFromSelf = isFromSelf
  }

  private enum CodingKeys: String, CodingKey {
    case id, messageID, emoji, senderName, messageHash, rawText, receivedAt,
         channelIndex, contactID, radioID, isFromSelf
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    messageID = try container.decode(UUID.self, forKey: .messageID)
    emoji = try container.decode(String.self, forKey: .emoji)
    senderName = try container.decode(String.self, forKey: .senderName)
    messageHash = try container.decode(String.self, forKey: .messageHash)
    rawText = try container.decode(String.self, forKey: .rawText)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    channelIndex = try container.decodeIfPresent(UInt8.self, forKey: .channelIndex)
    contactID = try container.decodeIfPresent(UUID.self, forKey: .contactID)
    radioID = try container.decode(UUID.self, forKey: .radioID)
    // Absent from backups made before the field existed; `markOwnReactions` backfills it.
    isFromSelf = try container.decodeIfPresent(Bool.self, forKey: .isFromSelf) ?? false
  }
}

// MARK: - Identity And Display

public extension ReactionDTO {
  /// The English literal older builds saved for a channel reaction with no parsed sender.
  static let legacyUnknownSenderName = "Unknown"
  /// The English literal older builds saved for the user's own reaction when no radio was known.
  static let legacySelfSenderName = "Me"

  /// Whether `other` is the same reactor's same emoji on the same message, for deduplication.
  /// The user's own reactions match each other; a DM reactor is the conversation's one contact;
  /// a channel reactor is known only by the name on air.
  func isSameReaction(as other: ReactionDTO) -> Bool {
    guard messageID == other.messageID, emoji == other.emoji, isFromSelf == other.isFromSelf else {
      return false
    }
    if isFromSelf { return true }
    if let contactID, contactID == other.contactID { return true }
    return contactID == nil && other.contactID == nil && senderName == other.senderName
  }

  /// The reactor's name as shown now: "You" for the user's own reaction; a DM reactor by the
  /// contact's current name (nickname first); a channel reactor as the bubble names a channel
  /// sender (`labelChannelSender`); else the localized unknown label. Never the stored literal.
  func displayName(
    selfName: String,
    unknownName: String,
    contactName: (UUID) -> String?,
    labelChannelSender: (String) -> String?
  ) -> String {
    if isFromSelf { return selfName }
    if let contactID, let name = contactName(contactID) { return name }
    let wireName = senderName == Self.legacyUnknownSenderName && channelIndex != nil ? "" : senderName
    guard !wireName.isEmpty else { return unknownName }
    if contactID == nil, let label = labelChannelSender(wireName) { return label }
    return wireName
  }
}
