import Foundation

/// Store writes that keep sender and receiver names right: the node name an outgoing channel
/// message went out under, a remote node session's copy of its node's name, the user's own
/// reactions, and the cleanup of room posts once filed as direct messages.
///
/// No defaults on purpose: a default would be a candidate witness and could silently replace the
/// store's real implementation.
public protocol NameIdentityPersisting: Actor {
  /// Records the node name an outgoing channel message went out under.
  func updateMessageSentAsNodeName(id: UUID, name: String) async throws

  /// Rewrites one remote node session's copy of its node's name, leaving every other field alone.
  func updateRemoteNodeSessionName(id: UUID, name: String) async throws

  /// Marks this radio's saved reactions that are the user's own: those saved before reactions
  /// recorded it, under one of `selfNames` (the node name, the old English "Me"). Returns how many
  /// changed.
  @discardableResult
  func markOwnReactions(radioID: UUID, selfNames: Set<String>) async throws -> Int

  /// Room posts sent from a Cairn radio's own screen that older builds filed as outgoing direct
  /// messages to the room's contact. Deletes them and clears the contact's last-message date so
  /// no direct conversation with the room remains. Returns the deleted rows.
  @discardableResult
  func removeRoomPostsFiledAsDirectMessages(radioID: UUID, roomContactIDs: [UUID]) async throws -> [MessageDTO]
}

public extension ReactionPersisting {
  /// Whether the same reactor already left the same emoji on the message (`ReactionDTO.isSameReaction`).
  func hasReaction(matching reaction: ReactionDTO) async throws -> Bool {
    try await fetchReactions(for: reaction.messageID, limit: 1000).contains { $0.isSameReaction(as: reaction) }
  }
}
