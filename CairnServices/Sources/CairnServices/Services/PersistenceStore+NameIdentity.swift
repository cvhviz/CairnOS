import Foundation
import SwiftData

// MARK: - Sender And Receiver Name Identity

public extension PersistenceStore {
  /// Records the node name an outgoing channel message went out under.
  func updateMessageSentAsNodeName(id: UUID, name: String) throws {
    let targetID = id
    var descriptor = FetchDescriptor(predicate: #Predicate<Message> { $0.id == targetID })
    descriptor.fetchLimit = 1
    guard let message = try modelContext.fetch(descriptor).first,
          message.sentAsNodeName != name else { return }
    message.sentAsNodeName = name
    try modelContext.save()
  }

  /// Rewrites one remote node session's copy of its node's name, leaving every other field alone,
  /// so it can't race unread counts or connection state written meanwhile.
  func updateRemoteNodeSessionName(id: UUID, name: String) throws {
    let targetID = id
    var descriptor = FetchDescriptor(predicate: #Predicate<RemoteNodeSession> { $0.id == targetID })
    descriptor.fetchLimit = 1
    guard let session = try modelContext.fetch(descriptor).first, session.name != name else { return }
    session.name = name
    try modelContext.save()
  }

  /// Marks this radio's saved reactions that are the user's own. Older builds stored the user's
  /// reaction under the node name (or "Me" when no radio was known) with nothing else to tell it
  /// apart, so a reaction under one of `selfNames` is taken as the user's own.
  @discardableResult
  func markOwnReactions(radioID: UUID, selfNames: Set<String>) throws -> Int {
    let names = selfNames.filter { !$0.isEmpty }
    guard !names.isEmpty else { return 0 }
    let targetRadioID = radioID
    let candidates = try modelContext.fetch(FetchDescriptor(predicate: #Predicate<Reaction> {
      $0.radioID == targetRadioID && $0.isFromSelf == false
    }))
    var changed = 0
    for reaction in candidates where names.contains(reaction.senderName) {
      reaction.isFromSelf = true
      changed += 1
    }
    if changed > 0 { try modelContext.save() }
    return changed
  }

  /// Deletes outgoing radio-sent rows filed under room contacts (a room post written on a Cairn
  /// radio's own screen, which older builds stored as a DM to the room) and clears those contacts'
  /// last-message date, so the stray "DM with the room" conversation disappears.
  @discardableResult
  func removeRoomPostsFiledAsDirectMessages(radioID: UUID, roomContactIDs: [UUID]) throws -> [MessageDTO] {
    guard !roomContactIDs.isEmpty else { return [] }
    let targetRadioID = radioID
    var removed: [MessageDTO] = []
    for contactID in roomContactIDs {
      let targetContactID: UUID? = contactID
      let rows = try modelContext.fetch(FetchDescriptor(predicate: #Predicate<Message> {
        $0.radioID == targetRadioID && $0.contactID == targetContactID
      }))
      // Only clean a room contact whose every row is an outgoing radio-sent echo: anything else
      // (a CLI exchange stored as messages, say) is left alone.
      guard !rows.isEmpty,
            rows.allSatisfy({ $0.sentFromRadio && $0.directionRawValue == MessageDirection.outgoing.rawValue })
      else { continue }
      removed += rows.map { MessageDTO(from: $0) }
      for row in rows {
        try deleteMessage(id: row.id)
      }
      let contactKey = contactID
      var contactDescriptor = FetchDescriptor(predicate: #Predicate<Contact> { $0.id == contactKey })
      contactDescriptor.fetchLimit = 1
      if let contact = try modelContext.fetch(contactDescriptor).first {
        contact.lastMessageDate = nil
        contact.unreadCount = 0
      }
    }
    if !removed.isEmpty { try modelContext.save() }
    return removed
  }
}
