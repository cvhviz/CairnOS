import CairnServices

/// Determines which actions a room message exposes in its actions sheet.
/// Computed once at presentation so the buttons stay stable if the session's
/// permission changes while the sheet is open.
struct RoomMessageActionAvailability {
  let canReply: Bool
  let canSendDM: Bool
  let canSendAgain: Bool

  /// - Parameter author: The post's author resolved from its key prefix now. Reply needs the name
  ///   the author advertises (a mention goes on air); Send DM needs the one contact on this radio
  ///   the key matches, not a name saved when the post arrived.
  init(
    message: RoomMessageDTO,
    session: RemoteNodeSessionDTO,
    author: RoomAuthorIdentity
  ) {
    canReply = !message.isFromSelf && session.canPost && author.advertisedName != nil
    canSendDM = !message.isFromSelf && author.contactID != nil && author.kind != .room
    canSendAgain = message.isFromSelf
  }
}
