import Foundation
import Intents
@testable import Cairn
import CairnServices
import Testing

@Suite("Siri messaging")
struct SiriMessagingTests {
  private func conversation(_ name: String, kind: SiriConversation.Kind = .direct) -> SiriConversation {
    SiriConversation(id: UUID(), name: name, kind: kind, unreadCount: 0, isMuted: false)
  }

  @Test
  func `Exact names win over partial ones`() {
    let bob = conversation("Bob")
    let bobby = conversation("Bobby")
    #expect(SiriNameMatcher.bestMatches("bob", in: [bob, bobby]) == [bob])
    #expect(SiriNameMatcher.bestMatches("bo", in: [bob, bobby]) == [bob, bobby])
  }

  @Test
  func `Channel hashes and accents don't matter`() {
    let channel = conversation("#Café", kind: .channel)
    #expect(SiriNameMatcher.bestMatches("cafe", in: [channel]) == [channel])
    #expect(SiriNameMatcher.bestMatches("  ", in: [channel]).isEmpty)
  }

  @Test
  func `Rooms are read-only for Siri, before any dictation`() {
    let room = conversation("Ops Room", kind: .room)
    let channel = conversation("Public", kind: .channel)
    let person = conversation("Alice")
    let all = [room, channel, person]
    #expect(MessageIntentHandler.isReadOnly(room.id, in: all))
    #expect(!MessageIntentHandler.isReadOnly(channel.id, in: all))
    #expect(!MessageIntentHandler.isReadOnly(person.id, in: all))
    #expect(!MessageIntentHandler.isReadOnly(UUID(), in: all))
  }

  @Test
  func `Message identifiers lead back to their conversation`() {
    let conversationID = UUID()
    let identifier = SiriMessage.identifier(conversationID: conversationID, messageID: UUID())
    #expect(SiriMessage.conversationID(fromIdentifier: identifier) == conversationID)
    #expect(SiriMessage.conversationID(fromIdentifier: "nonsense") == nil)
  }

  @Test
  func `Read messages carry sender, group and conversation`() {
    let message = SiriMessage(
      identifier: "x",
      conversationID: UUID(),
      content: "On my way",
      date: .now,
      senderName: "Alice",
      groupName: "Public"
    )
    let intentMessage = MessageIntentHandler.message(message)
    #expect(intentMessage.sender?.displayName == "Alice")
    #expect(intentMessage.groupName?.spokenPhrase == "Public")
    #expect(intentMessage.conversationIdentifier == message.conversationID.uuidString)
  }

  @Test
  func `The app delegate routes only the messaging intents`() async {
    await MainActor.run {
      let delegate = AppDelegate()
      #expect(delegate.application(.shared, handlerFor: INSendMessageIntent()) is MessageIntentHandler)
      #expect(delegate.application(.shared, handlerFor: INSearchForMessagesIntent()) is MessageIntentHandler)
      #expect(delegate.application(.shared, handlerFor: INSetMessageAttributeIntent()) is MessageIntentHandler)
      #expect(delegate.application(.shared, handlerFor: INStartCallIntent()) == nil)
    }
  }

  @Test
  func `A link coming up or a known radio is worth a short wait`() {
    #expect(SiriSendReadiness.of(.headlessQueue, hasRestorableRadio: true) == .ready)
    #expect(SiriSendReadiness.of(.queueAfterSync, hasRestorableRadio: false) == .ready)
    #expect(SiriSendReadiness.of(.foregroundEscalate, hasRestorableRadio: false) == .wait)
    #expect(SiriSendReadiness.of(.notConnected, hasRestorableRadio: true) == .wait)
    #expect(SiriSendReadiness.of(.notConnected, hasRestorableRadio: false) == .unavailable)
  }

  @Test
  func `Message length is checked against the conversation's limit`() {
    let direct = String(repeating: "a", count: ProtocolLimits.maxDirectMessageLength)
    #expect(SiriMessageLimits.fits(direct, kind: .direct, nodeNameByteCount: 0))
    #expect(!SiriMessageLimits.fits(direct + "a", kind: .direct, nodeNameByteCount: 0))
    let channelMax = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: 10)
    #expect(SiriMessageLimits.fits(String(repeating: "a", count: channelMax), kind: .channel, nodeNameByteCount: 10))
    #expect(!SiriMessageLimits.fits(String(repeating: "a", count: channelMax + 1), kind: .channel, nodeNameByteCount: 10))
  }

  @Test
  func `A resolved channel is sent to, never the first name match`() {
    let picked = UUID()
    let other = UUID()
    #expect(MessageIntentHandler.target(conversationID: nil, personID: nil, groupID: picked, groupMatches: [other, picked]) == picked)
    // "#test" and "Test" both match "test": a name alone never picks between them.
    #expect(MessageIntentHandler.target(conversationID: nil, personID: nil, groupID: nil, groupMatches: [other, picked]) == nil)
    #expect(MessageIntentHandler.target(conversationID: nil, personID: nil, groupID: nil, groupMatches: [picked]) == picked)
    let conversation = UUID()
    #expect(MessageIntentHandler.target(conversationID: conversation, personID: other, groupID: picked, groupMatches: []) == conversation)
  }
}
