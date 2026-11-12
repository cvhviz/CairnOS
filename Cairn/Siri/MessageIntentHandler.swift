import Foundation
import Intents

/// Handles Siri's messaging intents in the app (iOS 14+ in-app handling, no extension): sending a
/// message to a contact or channel, reading recent or unread messages aloud, and marking them
/// read. CarPlay's conversation screens hand a conversation (Read with Siri), one message (a
/// message row, `SiriMessage.identifier`) or a reply (Reply, the conversation as the recipient's
/// handle) to Siri, which comes here, so a driver can hear and answer messages without the text
/// ever showing on the car's screen.
///
/// Holds no state; each request reads plain values off the intent, does its work on the main
/// actor through `SiriMessageDirectory`, and builds the response from plain values again.
final class MessageIntentHandler: NSObject, Sendable {}

// MARK: - Send

extension MessageIntentHandler: INSendMessageIntentHandling {
  func resolveRecipients(for intent: INSendMessageIntent) async -> [INSendMessageRecipientResolutionResult] {
    // A room is read-only for Siri, so it stops here, before the driver dictates a message
    // that could only fail.
    let pickedIDs = [Self.conversationID(intent.conversationIdentifier)]
      + (intent.recipients ?? []).map(Self.conversationID(of:))
    if !pickedIDs.compactMap(\.self).isEmpty {
      let conversations = await SiriMessageDirectory.conversations()
      if pickedIDs.compactMap(\.self).contains(where: { Self.isReadOnly($0, in: conversations) }) {
        return [.unsupported(forReason: .messagingServiceNotEnabledForRecipient)]
      }
    }
    // No radio within a few seconds: say so now, not after the whole message was dictated.
    guard await SiriMessageDirectory.readyToSend() != nil else {
      return [.unsupported(forReason: .offline)]
    }
    // A conversation picked from the car's list, or a channel by name, needs no person.
    if Self.conversationID(intent.conversationIdentifier) != nil || intent.speakableGroupName != nil {
      return [.notRequired()]
    }
    guard let recipients = intent.recipients, !recipients.isEmpty else {
      return [.needsValue()]
    }
    var results: [INSendMessageRecipientResolutionResult] = []
    for person in recipients {
      // CarPlay's Reply row names the conversation by its identifier: a person or a channel.
      if let id = Self.conversationID(of: person),
         let match = await SiriMessageDirectory.conversations().first(where: { $0.id == id }) {
        results.append(.success(with: Self.person(match)))
        continue
      }
      let query = person.customIdentifier ?? person.displayName
      let people = await SiriMessageDirectory.people()
      let matches: [SiriConversation] = if let id = UUID(uuidString: query), let match = people.first(where: { $0.id == id }) {
        [match]
      } else {
        SiriNameMatcher.bestMatches(person.displayName, in: people)
      }
      switch matches.count {
      // Not "no account": Siri would tell the driver to set up an account that doesn't exist.
      case 0: results.append(.unsupported())
      case 1: results.append(.success(with: Self.person(matches[0])))
      default: results.append(.disambiguation(with: matches.prefix(5).map(Self.person)))
      }
    }
    return results
  }

  func resolveSpeakableGroupName(for intent: INSendMessageIntent) async -> INSpeakableStringResolutionResult {
    guard let group = intent.speakableGroupName else { return .notRequired() }
    if let conversationID = Self.conversationID(intent.conversationIdentifier) {
      let isReadOnly = await Self.isReadOnly(conversationID, in: SiriMessageDirectory.conversations())
      return isReadOnly ? .unsupported() : .success(with: group)
    }
    guard await SiriMessageDirectory.readyToSend() != nil else { return .unsupported() }
    // A group Siri already resolved (or the driver picked) keeps its identity.
    if let id = group.vocabularyIdentifier.flatMap(UUID.init(uuidString:)),
       let channel = await SiriMessageDirectory.channels().first(where: { $0.id == id }) {
      return .success(with: Self.speakable(channel))
    }
    let matches = await SiriNameMatcher.bestMatches(group.spokenPhrase, in: SiriMessageDirectory.channels())
    switch matches.count {
    case 0: return .unsupported()
    case 1: return .success(with: Self.speakable(matches[0]))
    default: return .disambiguation(with: matches.prefix(5).map(Self.speakable))
    }
  }

  /// Checks the mesh's length limit while Siri can still ask again: a message that is too long
  /// is asked for anew, rather than failing after the driver confirmed it.
  func resolveContent(for intent: INSendMessageIntent) async -> INStringResolutionResult {
    guard let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return .needsValue()
    }
    if let target = await Self.target(of: intent) {
      let fits = await SiriMessageDirectory.fits(text, inConversation: target)
      if !fits { return .needsValue() }
    }
    return .success(with: text)
  }

  func handle(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
    guard let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
          let target = await Self.target(of: intent) else {
      return INSendMessageIntentResponse(code: .failure, userActivity: nil)
    }
    // Never "requires app launch": that would ask a driver to open the phone.
    let code: INSendMessageIntentResponseCode = switch await SiriMessageDirectory.send(text: text, toConversation: target) {
    case .queued: .success
    case .notConnected: .failureMessageServiceNotAvailable
    case .failed: .failure
    }
    return INSendMessageIntentResponse(code: code, userActivity: nil)
  }

  /// The conversation a send goes to: the one picked in the car, the resolved person, the
  /// resolved group's identifier, or else a channel named uniquely by the spoken phrase.
  static func target(of intent: INSendMessageIntent) async -> UUID? {
    // Plain values first: the intent itself never crosses to the main actor.
    let conversationID = Self.conversationID(intent.conversationIdentifier)
    let personID = intent.recipients?.first.flatMap(Self.conversationID(of:))
    let groupID = intent.speakableGroupName?.vocabularyIdentifier.flatMap(UUID.init(uuidString:))
    let groupName = intent.speakableGroupName?.spokenPhrase
    var groupMatches: [UUID] = []
    if conversationID == nil, personID == nil, groupID == nil, let groupName {
      groupMatches = await SiriNameMatcher.bestMatches(groupName, in: SiriMessageDirectory.channels()).map(\.id)
    }
    return target(conversationID: conversationID, personID: personID, groupID: groupID, groupMatches: groupMatches)
  }

  /// Pure order of preference for `target(of:)`. Channels such as "#test" and "Test" match the
  /// same phrase, so a name alone only decides when it is unique; the identifier Siri resolved
  /// (after a disambiguation, say) always wins over it.
  static func target(conversationID: UUID?, personID: UUID?, groupID: UUID?, groupMatches: [UUID]) -> UUID? {
    if let conversationID { return conversationID }
    if let personID { return personID }
    if let groupID { return groupID }
    return groupMatches.count == 1 ? groupMatches[0] : nil
  }

  /// The conversation an identifier names: a conversation's own, or one of its messages' (a
  /// CarPlay message row, `SiriMessage.identifier`).
  static func conversationID(_ identifier: String?) -> UUID? {
    identifier.flatMap(SiriMessage.conversationID(fromIdentifier:))
  }

  /// The conversation a recipient stands for: its custom identifier, or the handle CarPlay's
  /// Reply row gives it (the conversation's identifier). Nil for a spoken name.
  static func conversationID(of person: INPerson) -> UUID? {
    person.customIdentifier.flatMap(UUID.init(uuidString:))
      ?? person.personHandle?.value.flatMap(UUID.init(uuidString:))
  }

  /// Whether `id` is a conversation Siri can read but not send to: a room. Unknown IDs are left
  /// to `handle`, which fails them plainly.
  static func isReadOnly(_ id: UUID, in conversations: [SiriConversation]) -> Bool {
    conversations.first { $0.id == id }?.kind == .room
  }

  static func person(_ conversation: SiriConversation) -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: conversation.id.uuidString, type: .unknown),
      nameComponents: nil,
      displayName: conversation.name,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: conversation.id.uuidString
    )
  }

  static func speakable(_ conversation: SiriConversation) -> INSpeakableString {
    INSpeakableString(
      vocabularyIdentifier: conversation.id.uuidString,
      spokenPhrase: conversation.name,
      pronunciationHint: nil
    )
  }
}

// MARK: - Search

extension MessageIntentHandler: INSearchForMessagesIntentHandling {
  func handle(intent: INSearchForMessagesIntent) async -> INSearchForMessagesIntentResponse {
    guard await SiriMessageDirectory.isAvailable() else {
      return INSearchForMessagesIntentResponse(code: .failureMessageServiceNotAvailable, userActivity: nil)
    }
    // A CarPlay message row names one message: Siri reads just that one.
    let pinned = (intent.conversationIdentifiers ?? []).compactMap(SiriMessage.pinnedMessage(fromIdentifier:))
    if !pinned.isEmpty {
      var found: [SiriMessage] = []
      for pin in pinned {
        if let message = await SiriMessageDirectory.message(pin.messageID, inConversation: pin.conversationID) {
          // Tagged so marking it read can't clear unread messages Siri never spoke.
          found.append(SiriMessage(
            identifier: SiriMessage.pinnedReadIdentifier(conversationID: pin.conversationID, messageID: pin.messageID),
            conversationID: message.conversationID,
            content: message.content,
            date: message.date,
            senderName: message.senderName,
            groupName: message.groupName
          ))
        }
      }
      let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
      response.messages = found.sorted { $0.date < $1.date }.map(Self.message)
      return response
    }
    let conversationIDs = (intent.conversationIdentifiers ?? []).compactMap(UUID.init(uuidString:))
    let groupNames = (intent.speakableGroupNames ?? []).map(\.spokenPhrase)
    let senderNames = (intent.senders ?? []).map(\.displayName)
    let senderIDs = (intent.senders ?? []).compactMap { $0.customIdentifier.flatMap(UUID.init(uuidString:)) }
    let wantsUnread = intent.attributes.contains(.unread)

    var scope: Set<UUID>?
    if !conversationIDs.isEmpty {
      scope = Set(conversationIDs)
    } else if !groupNames.isEmpty || !senderNames.isEmpty {
      let channels = await SiriMessageDirectory.channels()
      let people = await SiriMessageDirectory.people()
      var ids = Set(senderIDs)
      for name in groupNames {
        ids.formUnion(SiriNameMatcher.bestMatches(name, in: channels).map(\.id))
      }
      for name in senderNames {
        ids.formUnion(SiriNameMatcher.bestMatches(name, in: people).map(\.id))
      }
      scope = ids
    }
    // "Read my messages" with nothing named means the unread ones.
    let unreadOnly = wantsUnread || scope == nil
    if let scope, scope.isEmpty {
      return INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
    }

    let found = await SiriMessageDirectory.messages(inConversations: scope, unreadOnly: unreadOnly)
    let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
    response.messages = found.map(Self.message)
    return response
  }

  static func message(_ message: SiriMessage) -> INMessage {
    let sender = message.senderName.map { name in
      INPerson(
        personHandle: INPersonHandle(value: name, type: .unknown),
        nameComponents: nil,
        displayName: name,
        image: nil,
        contactIdentifier: nil,
        customIdentifier: nil,
        isMe: false
      )
    }
    return INMessage(
      identifier: message.identifier,
      conversationIdentifier: message.conversationID.uuidString,
      content: message.content,
      dateSent: message.date,
      sender: sender,
      recipients: nil,
      groupName: message.groupName.map { INSpeakableString(spokenPhrase: $0) },
      messageType: .text,
      serviceName: nil
    )
  }
}

// MARK: - Mark read

extension MessageIntentHandler: INSetMessageAttributeIntentHandling {
  func resolveAttribute(for intent: INSetMessageAttributeIntent) async -> INMessageAttributeResolutionResult {
    intent.attribute == .read ? .success(with: .read) : .unsupported()
  }

  func handle(intent: INSetMessageAttributeIntent) async -> INSetMessageAttributeIntentResponse {
    guard intent.attribute == .read else {
      return INSetMessageAttributeIntentResponse(code: .failureMessageAttributeNotSet, userActivity: nil)
    }
    let marks = (intent.identifiers ?? []).compactMap(SiriMessage.readMark(fromIdentifier:))
    guard !marks.isEmpty else {
      return INSetMessageAttributeIntentResponse(code: .failureMessageNotFound, userActivity: nil)
    }
    // A message read from a CarPlay row clears its conversation only when it was the newest
    // incoming one; otherwise newer unread messages stay unread.
    var ids = Set<UUID>()
    for mark in marks {
      switch mark {
      case let .conversation(id):
        ids.insert(id)
      case let .pinned(conversationID, messageID):
        if await SiriMessageDirectory.isNewestIncoming(messageID, inConversation: conversationID) {
          ids.insert(conversationID)
        }
      }
    }
    guard !ids.isEmpty else {
      return INSetMessageAttributeIntentResponse(code: .success, userActivity: nil)
    }
    let didMark = await SiriMessageDirectory.markRead(conversations: ids)
    return INSetMessageAttributeIntentResponse(code: didMark ? .success : .failureMessageNotFound, userActivity: nil)
  }
}
