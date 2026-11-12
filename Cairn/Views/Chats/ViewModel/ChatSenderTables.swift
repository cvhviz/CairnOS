import Foundation
import CairnServices

/// Sender-resolution inputs the item bake reads. The live view model builds this
/// from its observed contact tables; a primer builds it from a local fetch.
struct ChatSenderTables: Equatable {
  let contacts: [ContactDTO]
  let nicknamesByLoweredName: [String: String]
  /// Unique lowered contact name → channel incoming-avatar identity.
  let incomingAvatars: [String: IncomingAvatarIdentity]
  /// Unique lowered contact name → picked avatar colour, for sender names and @mentions.
  let avatarColorsByLoweredName: [String: NodeAvatarColor]

  init(
    contacts: [ContactDTO],
    nicknamesByLoweredName: [String: String],
    incomingAvatars: [String: IncomingAvatarIdentity]
  ) {
    self.contacts = contacts
    self.nicknamesByLoweredName = nicknamesByLoweredName
    self.incomingAvatars = incomingAvatars
    avatarColorsByLoweredName = incomingAvatars.compactMapValues(\.avatarColor)
  }

  static let empty = ChatSenderTables(
    contacts: [],
    nicknamesByLoweredName: [:],
    incomingAvatars: [:]
  )
}
