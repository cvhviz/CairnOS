import Foundation
@testable import CairnServices
import Testing

/// Sender and receiver naming shared by every surface: channel senders by advertised name, room
/// authors by key prefix, reactors by identity, and message previews outside the bubble.
@Suite("Sender naming")
struct SenderNamingTests {
  private let radioID = UUID()

  private func key(_ first: UInt8, _ second: UInt8 = 0x00) -> Data {
    Data([first, second, 0x52, 0x53] + Array(repeating: first, count: 28))
  }

  // MARK: - Channel senders

  @Test
  func `a channel sender owned by one contact reads by its nickname`() {
    let dad = ContactDTO.testContact(radioID: radioID, publicKey: key(0x60), name: "Frank Wilson", nickname: "Dad")
    let resolver = ChannelSenderNameResolver(contacts: [dad])

    #expect(resolver.shortName(for: "Frank Wilson") == "Dad")
    #expect(resolver.labeledName(for: "Frank Wilson") == "Dad (Frank Wilson)")
    #expect(resolver.resolution(for: "frank wilson")?.unverifiedNickname == "Dad")
    #expect(resolver.resolution(for: "Frank Wilson")?.displayName == "Frank Wilson")
  }

  @Test
  func `two contacts sharing an advertised name keep the advertised name`() {
    let one = ContactDTO.testContact(radioID: radioID, publicKey: key(0x61), name: "Base", nickname: "Home")
    let two = ContactDTO.testContact(radioID: radioID, publicKey: key(0x62), name: "Base", nickname: "Cabin")
    let resolver = ChannelSenderNameResolver(contacts: [one, two])

    #expect(resolver.shortName(for: "Base") == "Base")
    #expect(resolver.labeledName(for: "Base") == "Base")
    #expect(resolver.resolution(for: "Base")?.unverifiedNickname == nil)
  }

  @Test
  func `no sender name resolves to nothing`() {
    let resolver = ChannelSenderNameResolver(contacts: [])
    #expect(resolver.shortName(for: nil) == nil)
    #expect(resolver.shortName(for: "") == nil)
    #expect(resolver.labeledName(for: nil) == nil)
    #expect(resolver.resolution(for: nil) == nil)
    #expect(resolver.shortName(for: "Stranger") == "Stranger")
  }

  @Test
  func `the labeled name uses the supplied localized form`() {
    let dad = ContactDTO.testContact(radioID: radioID, publicKey: key(0x60), name: "Frank Wilson", nickname: "Dad")
    let resolver = ChannelSenderNameResolver(contacts: [dad])
    let label = resolver.labeledName(for: "Frank Wilson") { nickname, wire in "\(nickname)（\(wire)）" }
    #expect(label == "Dad（Frank Wilson）")
  }

  // MARK: - Message previews

  @Test
  func `a preview reads a mention the way the bubble does`() {
    #expect(MessagePreviewFormatter.preview("@[Basecamp] are you there?") == "@Basecamp are you there?")
  }

  @Test
  func `a reply preview shows the reply, not the quote`() {
    let reply = MentionUtilities.buildReplyText(mentionName: "Carol Diaz", messageText: "Heading up the ridge now") + "On my way"
    #expect(MessagePreviewFormatter.preview(reply) == "On my way")
  }

  @Test
  func `a reply with no body previews as who it answers`() {
    let reply = MentionUtilities.buildReplyText(mentionName: "Carol Diaz", messageText: "Heading up")
    #expect(MessagePreviewFormatter.preview(reply) == "@Carol Diaz")
  }

  @Test
  func `text that is not a mention is left alone`() {
    #expect(MessagePreviewFormatter.preview("mail me at a@b.com [ok]") == "mail me at a@b.com [ok]")
  }

  @Test
  func `a multi-line message previews on one line`() {
    #expect(MessagePreviewFormatter.preview("first\n\nsecond\n") == "first second")
  }

  // MARK: - Room authors

  private func post(prefix: Data, storedName: String? = nil, isFromSelf: Bool = false) -> RoomMessageDTO {
    RoomMessageDTO(
      sessionID: UUID(),
      authorKeyPrefix: prefix,
      authorName: storedName,
      text: "hello",
      timestamp: 1_760_000_000,
      isFromSelf: isFromSelf
    )
  }

  @Test
  func `a nickname set after the post arrived shows`() {
    let frank = ContactDTO.testContact(radioID: radioID, publicKey: key(0x60), name: "Frank Wilson", nickname: "Dad")
    let resolver = RoomAuthorResolver(contacts: [frank])
    let identity = resolver.resolve(post(prefix: key(0x60).prefix(4), storedName: "Frank Wilson"), roomPublicKey: nil, roomName: nil, selfName: "You")

    #expect(identity.displayName == "Dad")
    #expect(identity.advertisedName == "Frank Wilson")
    #expect(identity.contactID == frank.id)
    #expect(!identity.isKeyOnly)
  }

  @Test
  func `an author saved as a contact after the post arrived shows by name`() {
    let hannah = ContactDTO.testContact(radioID: radioID, publicKey: key(0x50, 0x51), name: "Hannah Lee")
    let resolver = RoomAuthorResolver(contacts: [hannah])
    let identity = resolver.resolve(post(prefix: key(0x50, 0x51).prefix(4)), roomPublicKey: nil, roomName: nil, selfName: "You")

    #expect(identity.displayName == "Hannah Lee")
    #expect(identity.keyPrefixHex == "50515253")
  }

  @Test
  func `two contacts sharing the author prefix are not attributed`() {
    var shared = key(0x70)
    let one = ContactDTO.testContact(radioID: radioID, publicKey: shared, name: "One")
    shared[31] = 0xEE
    let two = ContactDTO.testContact(radioID: radioID, publicKey: shared, name: "Two")
    let resolver = RoomAuthorResolver(contacts: [one, two])
    let identity = resolver.resolve(post(prefix: shared.prefix(4), storedName: "One"), roomPublicKey: nil, roomName: nil, selfName: "You")

    #expect(identity.kind == .ambiguous)
    #expect(identity.isKeyOnly)
    #expect(identity.displayName == "70005253")
    #expect(identity.advertisedName == nil)
  }

  @Test
  func `an author known only from another radio keeps the name saved at receipt`() {
    let resolver = RoomAuthorResolver(contacts: [])
    let identity = resolver.resolve(post(prefix: key(0x80).prefix(4), storedName: "Ivan"), roomPublicKey: nil, roomName: nil, selfName: "You")

    #expect(identity.kind == .lastKnown)
    #expect(identity.displayName == "Ivan")
    #expect(identity.advertisedName == nil)
  }

  @Test
  func `an unknown author is shown honestly by key`() {
    let identity = RoomAuthorResolver.empty.resolve(post(prefix: Data([0xDE, 0xAD, 0xBE, 0xEF])), roomPublicKey: nil, roomName: nil, selfName: "You")
    #expect(identity.kind == .unknown)
    #expect(identity.displayName == "DEADBEEF")
    #expect(identity.isKeyOnly)
  }

  @Test
  func `my own post reads as me whatever was stored`() {
    let identity = RoomAuthorResolver.empty.resolve(post(prefix: Data(repeating: 0, count: 4), storedName: "Me", isFromSelf: true), roomPublicKey: nil, roomName: nil, selfName: "You")
    #expect(identity.kind == .me)
    #expect(identity.displayName == "You")
  }

  @Test
  func `the room's own system post reads as the room`() {
    let roomKey = key(0x90)
    let room = ContactDTO.testContact(radioID: radioID, publicKey: roomKey, name: "Diana's Room", typeRawValue: ContactType.room.rawValue)
    let resolver = RoomAuthorResolver(contacts: [room])
    let identity = resolver.resolve(post(prefix: roomKey.prefix(4)), roomPublicKey: roomKey, roomName: "Diana's Room", selfName: "You")
    #expect(identity.kind == .room)
    #expect(identity.displayName == "Diana's Room")
  }

  @Test
  func `a post dates by its own timestamp once the room's clock is set`() {
    let set = RoomMessageDTO(sessionID: UUID(), authorKeyPrefix: Data([1, 2, 3, 4]), text: "x", timestamp: 1_760_000_000, createdAt: Date(timeIntervalSince1970: 1_770_000_000))
    let unset = RoomMessageDTO(sessionID: UUID(), authorKeyPrefix: Data([1, 2, 3, 4]), text: "x", timestamp: 12, createdAt: Date(timeIntervalSince1970: 1_770_000_000))
    #expect(set.postDate == Date(timeIntervalSince1970: 1_760_000_000))
    #expect(unset.postDate == Date(timeIntervalSince1970: 1_770_000_000))
  }

  // MARK: - Reactors

  @Test
  func `my own reactions match each other whatever name they went out under`() {
    let messageID = UUID()
    let before = ReactionDTO(messageID: messageID, emoji: "👍", senderName: "OldName", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID, isFromSelf: true)
    let after = ReactionDTO(messageID: messageID, emoji: "👍", senderName: "NewName", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID, isFromSelf: true)
    let stranger = ReactionDTO(messageID: messageID, emoji: "👍", senderName: "NewName", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)
    #expect(before.isSameReaction(as: after))
    #expect(!after.isSameReaction(as: stranger))
  }

  @Test
  func `a DM reactor is the same reactor after a nickname change`() {
    let messageID = UUID()
    let contactID = UUID()
    let old = ReactionDTO(messageID: messageID, emoji: "❤️", senderName: "Dad", messageHash: "h", rawText: "r", contactID: contactID, radioID: radioID)
    let new = ReactionDTO(messageID: messageID, emoji: "❤️", senderName: "Frank Wilson", messageHash: "h", rawText: "r", contactID: contactID, radioID: radioID)
    #expect(old.isSameReaction(as: new))
  }

  @Test
  func `a reactor is shown by who they are now`() {
    let contactID = UUID()
    let mine = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Basecamp", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID, isFromSelf: true)
    let dm = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Frank Wilson", messageHash: "h", rawText: "r", contactID: contactID, radioID: radioID)
    let channel = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Frank Wilson", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)
    let legacyUnknown = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "Unknown", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)
    let noName = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "", messageHash: "h", rawText: "r", channelIndex: 1, radioID: radioID)

    func name(_ reaction: ReactionDTO) -> String {
      reaction.displayName(
        selfName: "You",
        unknownName: "Desconocido",
        contactName: { $0 == contactID ? "Dad" : nil },
        labelChannelSender: { $0 == "Frank Wilson" ? "Dad (Frank Wilson)" : nil }
      )
    }
    #expect(name(mine) == "You")
    #expect(name(dm) == "Dad")
    #expect(name(channel) == "Dad (Frank Wilson)")
    #expect(name(legacyUnknown) == "Desconocido")
    #expect(name(noName) == "Desconocido")
  }

  @Test
  func `a reaction from a backup made before isFromSelf decodes`() throws {
    let reaction = ReactionDTO(messageID: UUID(), emoji: "👍", senderName: "A", messageHash: "h", rawText: "r", radioID: radioID, isFromSelf: true)
    let encoded = try JSONEncoder().encode(reaction)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["isFromSelf"] as? Bool == true)
    object.removeValue(forKey: "isFromSelf")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ReactionDTO.self, from: legacy)
    #expect(decoded.isFromSelf == false)
    #expect(decoded.senderName == "A")
  }

  // MARK: - On-air names

  @Test
  func `my outgoing channel message is known by the name it went out under`() {
    var mine = MessageDTO.testChannelMessage(radioID: radioID, direction: .outgoing)
    #expect(mine.onAirSenderName(currentSelfName: "NewName") == "NewName")
    mine.sentAsNodeName = "OldName"
    #expect(mine.onAirSenderName(currentSelfName: "NewName") == "OldName")
    let theirs = MessageDTO.testChannelMessage(radioID: radioID, direction: .incoming, senderNodeName: "Carol")
    #expect(theirs.onAirSenderName(currentSelfName: "NewName") == "Carol")
    let dm = MessageDTO.testDirectMessage(radioID: radioID)
    #expect(dm.onAirSenderName(currentSelfName: "NewName") == nil)
  }

  @Test
  func `a session takes its contact's current name`() {
    let roomKey = key(0x90)
    let room = ContactDTO.testContact(radioID: radioID, publicKey: roomKey, name: "Diana's Room", nickname: "Trail Room")
    let stale = RemoteNodeSessionDTO(radioID: radioID, publicKey: roomKey, name: "Diana's Room", role: .roomServer)
    let current = RemoteNodeSessionDTO(radioID: radioID, publicKey: key(0x91), name: "Same", role: .repeater)
    let orphan = RemoteNodeSessionDTO(radioID: radioID, publicKey: key(0x92), name: "Gone", role: .roomServer)
    let renames = SyncCoordinator.sessionRenames(
      sessions: [stale, current, orphan],
      contacts: [room, ContactDTO.testContact(radioID: radioID, publicKey: key(0x91), name: "Same")]
    )
    #expect(renames.count == 1)
    #expect(renames.first?.sessionID == stale.id)
    #expect(renames.first?.name == "Trail Room")
  }
}
