import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("MessagePathViewModel")
@MainActor
struct MessagePathViewModelTests {
  private func createContact(
    prefix: [UInt8],
    name: String,
    type: ContactType = .chat,
    lastAdvertTimestamp: UInt32 = 0,
    latitude: Double = 0,
    longitude: Double = 0,
    isBlocked: Bool = false
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(prefix + Array(repeating: UInt8(0), count: 32 - prefix.count)),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: lastAdvertTimestamp,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: isBlocked,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func createMessage(
    senderKeyPrefix: Data?,
    senderNodeName: String? = nil,
    channelIndex: UInt8? = nil,
    direction: MessageDirection = .incoming
  ) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: channelIndex == nil ? UUID() : nil,
      channelIndex: channelIndex,
      text: "Test",
      timestamp: 0,
      createdAt: Date(),
      direction: direction,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: senderKeyPrefix,
      senderNodeName: senderNodeName,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  // MARK: - senderName

  @Test
  func `sender name uses full key prefix match`() {
    let viewModel = MessagePathViewModel()

    let contactA = createContact(prefix: [0xAA, 0x00, 0x00, 0x00, 0x00, 0x00], name: "Alpha")
    let contactB = createContact(prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00], name: "Bravo")

    viewModel.contacts = [contactA, contactB]

    let message = createMessage(senderKeyPrefix: contactB.publicKeyPrefix)

    #expect(viewModel.senderName(for: message, localDeviceName: "") == "Bravo")
  }

  @Test
  func `sender resolution marks short prefix match as fallback`() {
    let viewModel = MessagePathViewModel()
    let older = createContact(prefix: [0xAA, 0x01], name: "Older", lastAdvertTimestamp: 100)
    let newer = createContact(prefix: [0xAA, 0x02], name: "Newer", lastAdvertTimestamp: 200)
    viewModel.contacts = [older, newer]

    let message = createMessage(senderKeyPrefix: Data([0xAA]))
    let result = viewModel.senderResolution(for: message, localDeviceName: "")

    #expect(result.displayName == "Newer")
    #expect(result.matchKind == .fallback)
  }

  @Test
  func `sender resolution marks unique short prefix match as exact`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(prefix: [0xAA, 0x01], name: "Alpha")
    viewModel.contacts = [contact]

    let message = createMessage(senderKeyPrefix: Data([0xAA]))
    let result = viewModel.senderResolution(for: message, localDeviceName: "")

    #expect(result.displayName == "Alpha")
    #expect(result.matchKind == .exact)
  }

  @Test
  func `sender resolution marks full prefix match as exact`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(prefix: [0xAA, 0x01], name: "Alpha")
    viewModel.contacts = [contact]

    let message = createMessage(senderKeyPrefix: contact.publicKeyPrefix)
    let result = viewModel.senderResolution(for: message, localDeviceName: "")

    #expect(result.displayName == "Alpha")
    #expect(result.matchKind == .exact)
  }

  @Test
  func `sender name returns channel sender node name for channel messages`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    #expect(viewModel.senderName(for: message, localDeviceName: "") == "RemoteNode")
  }

  @Test
  func `sender name returns unknown when no key prefix match`() {
    let viewModel = MessagePathViewModel()
    viewModel.contacts = [
      createContact(prefix: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF], name: "Alpha")
    ]

    let message = createMessage(senderKeyPrefix: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
    #expect(viewModel.senderName(for: message, localDeviceName: "") == L10n.Chats.Chats.Path.Hop.unknown)
  }

  @Test
  func `sender resolution uses local device name for outgoing channel messages`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(
      senderKeyPrefix: nil,
      senderNodeName: nil,
      channelIndex: 0,
      direction: .outgoing
    )
    let result = viewModel.senderResolution(for: message, localDeviceName: "Radio")
    #expect(result.displayName == "Radio")
    #expect(result.matchKind == .exact)
  }

  @Test
  func `sender resolution ignores local device name for incoming channel messages`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    let result = viewModel.senderResolution(for: message, localDeviceName: "Radio")
    #expect(result.displayName == "RemoteNode")
    #expect(result.matchKind == .exact)
  }

  // MARK: - senderNodeID

  @Test
  func `senderNodeID returns hex of first prefix byte`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: Data([0xAB, 0xCD, 0xEF, 0x12]))
    #expect(viewModel.senderNodeID(for: message) == "AB")
  }

  @Test
  func `senderNodeID returns nil when no key prefix`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: nil)
    #expect(viewModel.senderNodeID(for: message) == nil)
  }

  @Test
  func `senderNodeID returns nil for empty key prefix`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: Data())
    #expect(viewModel.senderNodeID(for: message) == nil)
  }

  @Test
  func `senderNodeID formats leading zero correctly`() {
    let viewModel = MessagePathViewModel()
    let message = createMessage(senderKeyPrefix: Data([0x0A]))
    #expect(viewModel.senderNodeID(for: message) == "0A")
  }

  // MARK: - locatedSender

  private static let locatedLatitude = 37.7749
  private static let locatedLongitude = -122.4194

  @Test
  func `locatedSender matches DM by key prefix`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "Alpha",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude
    )
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(for: createMessage(senderKeyPrefix: contact.publicKeyPrefix))

    #expect(result?.id == contact.id)
  }

  @Test
  func `locatedSender returns nil for DM prefix match without location`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00], name: "Alpha")
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(for: createMessage(senderKeyPrefix: contact.publicKeyPrefix))

    #expect(result == nil)
  }

  @Test
  func `locatedSender matches unique channel sender name with location`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "RemoteNode",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude
    )
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    )

    #expect(result?.id == contact.id)
  }

  @Test
  func `locatedSender returns nil for unique channel name without location`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00], name: "RemoteNode")
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    )

    #expect(result == nil)
  }

  @Test
  func `locatedSender returns nil when two contacts share the channel sender name`() {
    let viewModel = MessagePathViewModel()
    let located = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "Alice",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude
    )
    let unlocated = createContact(prefix: [0xBB, 0x02, 0x00, 0x00, 0x00, 0x00], name: "Alice")
    viewModel.contacts = [located, unlocated]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "Alice", channelIndex: 0)
    )

    #expect(result == nil)
  }

  @Test
  func `locatedSender returns nil when no contact matches the channel sender name`() {
    let viewModel = MessagePathViewModel()
    viewModel.contacts = [
      createContact(
        prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
        name: "Alpha",
        latitude: Self.locatedLatitude,
        longitude: Self.locatedLongitude
      )
    ]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    )

    #expect(result == nil)
  }

  @Test
  func `locatedSender prefers key prefix over channel name when prefix matches`() {
    let viewModel = MessagePathViewModel()
    let prefixed = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "Alpha",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude
    )
    let named = createContact(
      prefix: [0xBB, 0x02, 0x00, 0x00, 0x00, 0x00],
      name: "RemoteNode",
      latitude: 37.8,
      longitude: -122.5
    )
    viewModel.contacts = [prefixed, named]

    let result = viewModel.locatedSender(
      for: createMessage(
        senderKeyPrefix: prefixed.publicKeyPrefix,
        senderNodeName: "RemoteNode",
        channelIndex: 0
      )
    )

    #expect(result?.id == prefixed.id)
  }

  @Test
  func `locatedSender matches channel sender name case-insensitively`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "RemoteNode",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude
    )
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "remotenode", channelIndex: 0)
    )

    #expect(result?.id == contact.id)
  }

  @Test
  func `locatedSender includes a unique blocked contact`() {
    let viewModel = MessagePathViewModel()
    let contact = createContact(
      prefix: [0xAA, 0x01, 0x00, 0x00, 0x00, 0x00],
      name: "RemoteNode",
      latitude: Self.locatedLatitude,
      longitude: Self.locatedLongitude,
      isBlocked: true
    )
    viewModel.contacts = [contact]

    let result = viewModel.locatedSender(
      for: createMessage(senderKeyPrefix: nil, senderNodeName: "RemoteNode", channelIndex: 0)
    )

    #expect(result?.id == contact.id)
  }

  // MARK: - Hops

  /// A flood arrival through `hops` (1-byte hashes), oldest first.
  private func arrival(_ hops: [UInt8], at date: Date = Date()) -> MessagePathArrival {
    MessagePathArrival(
      id: UUID(),
      pathNodes: Data(hops),
      pathLength: UInt8(hops.count),
      snr: 5,
      rssi: -90,
      receivedAt: date,
      isFirst: true
    )
  }

  private func createDiscoveredRepeater(prefix: [UInt8], name: String) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(prefix + Array(repeating: UInt8(0), count: 32 - prefix.count)),
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: Date(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  @Test
  func `a saved contact never heard here leaves its hash unknown`() throws {
    let viewModel = MessagePathViewModel()
    let hilltop = createContact(prefix: [0xA3, 0x01], name: "Hilltop", type: .repeater)
    viewModel.contacts = [hilltop]
    viewModel.observations = .heard(labels: [hilltop])
    let match = try #require(viewModel.relays(for: arrival([0xA3])).first)
    #expect(match == .unknown(Data([0xA3])))
    let resolution = viewModel.repeaterResolution(for: match)
    #expect(resolution.displayName == L10n.Chats.Chats.Path.Hop.unknown)
    #expect(resolution.matchKind == .unresolved)
  }

  @Test
  func `a hop heard here names the node and opens its contact`() throws {
    let viewModel = MessagePathViewModel()
    let repeater = createContact(prefix: [0xA3, 0x01], name: "Hilltop", type: .repeater, latitude: 37.1, longitude: -122.1)
    viewModel.contacts = [repeater]
    viewModel.observations = .heard(contacts: [repeater])

    let match = try #require(viewModel.relays(for: arrival([0xA3])).first)
    let resolution = viewModel.repeaterResolution(for: match)
    #expect(resolution.displayName == "Hilltop")
    #expect(resolution.matchKind == .exact)
    #expect(viewModel.repeaterContact(for: match)?.id == repeater.id)
    #expect(viewModel.relayCoordinate(for: match)?.latitude == 37.1)
  }

  @Test
  func `Hawaii: a saved contact never heard here never names a local relay sharing its byte`() throws {
    // Kona Hill (7F…) is a saved contact in Hawaii; this radio, in California, never heard it.
    // A message relayed by a local 7F no one has heard shows the hop as unknown, never Kona
    // Hill, with no distance rule deciding it.
    let viewModel = MessagePathViewModel()
    let konaHill = createContact(prefix: [0x7F, 0x3A], name: "Kona Hill", type: .repeater, latitude: 19.64, longitude: -155.99)
    let mtBaldy = createContact(prefix: [0xB4, 0x5D], name: "Mt Baldy", type: .repeater, latitude: 34.29, longitude: -117.65)
    viewModel.contacts = [konaHill, mtBaldy]
    viewModel.observations = .heard(contacts: [mtBaldy], labels: [konaHill, mtBaldy])

    let relays = viewModel.relays(for: arrival([0x7F, 0xB4]))
    try #require(relays.count == 2)
    #expect(relays[0] == .unknown(Data([0x7F])))
    #expect(viewModel.repeaterResolution(for: relays[0]).displayName == L10n.Chats.Chats.Path.Hop.unknown)
    #expect(viewModel.repeaterContact(for: relays[0]) == nil)
    #expect(viewModel.relayCoordinate(for: relays[0]) == nil)
    #expect(viewModel.repeaterResolution(for: relays[1]).displayName == "Mt Baldy")
  }

  @Test
  func `a hash two heard nodes share is a guess that opens no contact and places no pin`() throws {
    let viewModel = MessagePathViewModel()
    let older = createContact(prefix: [0xA3, 0x01], name: "Older", type: .repeater, latitude: 37.1, longitude: -122.1)
    let newer = createContact(prefix: [0xA3, 0x02], name: "Newer", type: .repeater, latitude: 37.2, longitude: -122.2)
    viewModel.contacts = [older, newer]
    viewModel.observations = .heard(contacts: [older, newer])

    let match = try #require(viewModel.relays(for: arrival([0xA3])).first)
    let resolution = viewModel.repeaterResolution(for: match)
    #expect(match.isUncertain)
    #expect(resolution.matchKind == .fallback)
    #expect(viewModel.repeaterContact(for: match) == nil)
    #expect(viewModel.relayCoordinate(for: match) == nil)
  }

  @Test
  func `a discovered node heard here names the hop but opens no contact`() throws {
    let viewModel = MessagePathViewModel()
    viewModel.observations = .heard(discovered: [createDiscoveredRepeater(prefix: [0xA3, 0x01], name: "Heard Only")])
    let match = try #require(viewModel.relays(for: arrival([0xA3])).first)
    #expect(viewModel.repeaterResolution(for: match).displayName == "Heard Only")
    #expect(viewModel.repeaterContact(for: match) == nil)
  }

  @Test
  func `no stored position places a hop: only the node's own advert does`() throws {
    // Saved with a position, heard advertising none: named, but not placed
    let viewModel = MessagePathViewModel()
    let saved = createContact(prefix: [0xA3, 0x01], name: "Hilltop", type: .repeater, latitude: 37.1, longitude: -122.1)
    let heardWithoutPosition = createContact(prefix: [0xA3, 0x01], name: "Hilltop", type: .repeater)
    viewModel.contacts = [saved]
    viewModel.observations = .heard(contacts: [heardWithoutPosition], labels: [saved])
    let match = try #require(viewModel.relays(for: arrival([0xA3])).first)
    #expect(viewModel.repeaterResolution(for: match).matchKind == .exact)
    #expect(viewModel.relayCoordinate(for: match) == nil)
  }

  // MARK: - loadContacts

  @Test
  func `loadContacts with nil dataStore sets isLoading false and clears data`() async {
    let viewModel = MessagePathViewModel()
    let contact = createContact(prefix: [0xAA], name: "Stale", type: .repeater)
    viewModel.contacts = [contact]
    #expect(viewModel.isLoading == true)

    await viewModel.loadContacts(dataStore: nil, radioID: UUID())

    #expect(viewModel.isLoading == false)
    #expect(viewModel.contacts.isEmpty)
  }
}
