import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

// MARK: - Test Helpers

private func makeKey(_ byte: UInt8) -> Data {
  Data(repeating: byte, count: ProtocolLimits.publicKeySize)
}

private func makeContact(
  radioID: UUID,
  key: Data,
  name: String = "Node",
  nickname: String? = nil,
  isBlocked: Bool = false,
  lastModified: UInt32 = 0,
  lastHeardTimestamp: UInt32? = nil,
  lastMessageDate: Date? = nil,
  unreadCount: Int = 0
) -> ContactDTO {
  ContactDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: key,
    name: name,
    typeRawValue: ContactType.chat.rawValue,
    flags: 0,
    outPathLength: 0,
    outPath: Data(),
    lastAdvertTimestamp: 0,
    latitude: 0,
    longitude: 0,
    lastModified: lastModified,
    lastHeardTimestamp: lastHeardTimestamp,
    nickname: nickname,
    isBlocked: isBlocked,
    isMuted: false,
    isFavorite: false,
    lastMessageDate: lastMessageDate,
    unreadCount: unreadCount
  )
}

private func makeHeard(radioID: UUID, key: Data, name: String, lastHeard: Date) -> DiscoveredNodeDTO {
  DiscoveredNodeDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: key,
    name: name,
    typeRawValue: ContactType.repeater.rawValue,
    lastHeard: lastHeard,
    lastAdvertTimestamp: 0,
    latitude: 0,
    longitude: 0,
    outPathLength: 0,
    outPath: Data(),
    inboundHopCount: nil,
    inboundHopAdvertTimestamp: nil
  )
}

private func makeFrame(key: Data, name: String) -> ContactFrame {
  ContactFrame(
    publicKey: key,
    type: .repeater,
    flags: 0,
    outPathLength: 0,
    outPath: Data(),
    name: name,
    lastAdvertTimestamp: 1_700_000_000,
    latitude: 0,
    longitude: 0,
    lastModified: 1_700_000_000
  )
}

/// Counts the reads a reload makes, passing each on to a real store, and can hold the Chats
/// card's preview read so a test can look at the card while its read is under way.
private actor SpyHomeStore: HomeDashboardStore {
  private let base: PersistenceStore
  private(set) var calls: [String: Int] = [:]
  private var holdsPreviews = false
  private var heldPreview: CheckedContinuation<Void, Never>?

  init(base: PersistenceStore) {
    self.base = base
  }

  var isHoldingPreview: Bool {
    heldPreview != nil
  }

  func count(_ name: String) -> Int {
    calls[name, default: 0]
  }

  func holdPreviews() {
    holdsPreviews = true
  }

  func releasePreviews() {
    holdsPreviews = false
    heldPreview?.resume()
    heldPreview = nil
  }

  private func record(_ name: String) {
    calls[name, default: 0] += 1
  }

  func fetchConversations(radioID: UUID) async throws -> [ContactDTO] {
    record("conversations")
    return try await base.fetchConversations(radioID: radioID)
  }

  func fetchChannels(radioID: UUID) async throws -> [ChannelDTO] {
    record("channels")
    return try await base.fetchChannels(radioID: radioID)
  }

  func fetchRemoteNodeSessions(radioID: UUID) async throws -> [RemoteNodeSessionDTO] {
    record("rooms")
    return try await base.fetchRemoteNodeSessions(radioID: radioID)
  }

  func fetchLastMessages(contactIDs: [UUID], limit: Int) async throws -> [UUID: [MessageDTO]] {
    record("lastMessages")
    if holdsPreviews {
      await withCheckedContinuation { heldPreview = $0 }
    }
    return try await base.fetchLastMessages(contactIDs: contactIDs, limit: limit)
  }

  func fetchLastChannelMessages(
    channels: [(radioID: UUID, channelIndex: UInt8, id: UUID)],
    limit: Int
  ) async throws -> [UUID: [MessageDTO]] {
    record("lastChannelMessages")
    return try await base.fetchLastChannelMessages(channels: channels, limit: limit)
  }

  func fetchContacts(radioID: UUID) async throws -> [ContactDTO] {
    record("contacts")
    return try await base.fetchContacts(radioID: radioID)
  }

  func fetchDiscoveredNodes(radioID: UUID) async throws -> [DiscoveredNodeDTO] {
    record("discovered")
    return try await base.fetchDiscoveredNodes(radioID: radioID)
  }

  func fetchLatestRoomMessages(sessionID: UUID, limit: Int) async throws -> [RoomMessageDTO] {
    record("roomPosts")
    return try await base.fetchLatestRoomMessages(sessionID: sessionID, limit: limit)
  }
}

// MARK: - HomeDashboardModel Tests

@Suite("HomeDashboardModel")
@MainActor
struct HomeDashboardModelTests {
  private func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  // MARK: - Reloads

  @Test
  func `A nodes request shows a newly heard node`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    let model = HomeDashboardModel(reloadInterval: .zero)
    await model.load(dataStore: store, radioID: radioID)
    #expect(model.lastHeard == nil)
    #expect(model.newNodeCount == 0)

    _ = try await store.upsertDiscoveredNode(radioID: radioID, from: makeFrame(key: makeKey(0x11), name: "Hilltop"))
    model.requestNodes(dataStore: store, radioID: radioID)

    try await waitUntil("the Nodes card should show the new node") { model.lastHeard?.name == "Hilltop" }
    #expect(model.newNodeCount == 1)
    #expect(model.newNodeCount(now: .now) == 1)
    #expect(model.contactCount == 0)
  }

  @Test
  func `A conversations request reads no nodes, and a nodes request no conversations`() async throws {
    let store = try makeStore()
    let spy = SpyHomeStore(base: store)
    let radioID = UUID()
    let model = HomeDashboardModel(reloadInterval: .zero)
    await model.load(dataStore: spy, radioID: radioID)
    #expect(await spy.count("contacts") == 1)
    #expect(await spy.count("conversations") == 1)

    model.requestConversations(dataStore: spy, radioID: radioID)
    try await waitUntil("the Chats card should be read again") { await spy.count("rooms") == 2 }
    #expect(await spy.count("contacts") == 1)
    #expect(await spy.count("discovered") == 1)

    model.requestNodes(dataStore: spy, radioID: radioID)
    try await waitUntil("the Nodes card should be read again") { await spy.count("discovered") == 2 }
    #expect(await spy.count("conversations") == 2)
    #expect(await spy.count("rooms") == 2)
  }

  @Test
  func `The unread total changes with the conversation lines, not before them`() async throws {
    let store = try makeStore()
    let spy = SpyHomeStore(base: store)
    let radioID = UUID()
    let older = makeContact(radioID: radioID, key: makeKey(0x01), name: "Alice", lastMessageDate: Date(timeIntervalSince1970: 1_000))
    try await store.saveContact(older)
    let model = HomeDashboardModel(reloadInterval: .zero)
    await model.load(dataStore: spy, radioID: radioID)
    #expect(model.unreadTotal == 0)
    #expect(model.recentConversations.map(\.name) == ["Alice"])

    let newer = makeContact(
      radioID: radioID,
      key: makeKey(0x02),
      name: "Bob",
      lastMessageDate: Date(timeIntervalSince1970: 2_000),
      unreadCount: 3
    )
    try await store.saveContact(newer)
    await spy.holdPreviews()
    model.requestConversations(dataStore: spy, radioID: radioID)

    // The read has counted the unread messages and is fetching previews: nothing shows yet.
    try await waitUntil("the read should reach the previews") { await spy.isHoldingPreview }
    #expect(model.unreadTotal == 0)
    #expect(model.recentConversations.map(\.name) == ["Alice"])

    await spy.releasePreviews()
    try await waitUntil("the Chats card should update") { model.unreadTotal == 3 }
    #expect(model.recentConversations.map(\.name) == ["Bob", "Alice"])
  }

  @Test
  func `Another radio clears the cards at once`() async throws {
    let store = try makeStore()
    let radioID = UUID()
    _ = try await store.upsertDiscoveredNode(radioID: radioID, from: makeFrame(key: makeKey(0x11), name: "Hilltop"))
    let model = HomeDashboardModel(reloadInterval: .zero)
    await model.load(dataStore: store, radioID: radioID)
    #expect(model.lastHeard?.name == "Hilltop")

    model.requestNodes(dataStore: store, radioID: UUID())
    #expect(model.lastHeard == nil)
    #expect(model.contactCount == nil)

    model.requestNodes(dataStore: nil, radioID: nil)
    #expect(model.lastHeard == nil)
  }

  // MARK: - Last heard

  @Test
  func `Last heard names a saved node by its nickname`() {
    let radioID = UUID()
    let key = makeKey(0x01)
    let contact = makeContact(radioID: radioID, key: key, name: "NODE-1234", nickname: "Base", lastHeardTimestamp: 2_000)
    let heard = makeHeard(radioID: radioID, key: key, name: "NODE-1234", lastHeard: Date(timeIntervalSince1970: 2_000))

    let last = HomeDashboardModel.lastHeard(contacts: [contact], heard: [heard])
    #expect(last?.name == "Base")
    #expect(last?.lastHeard == Date(timeIntervalSince1970: 2_000))
  }

  @Test
  func `Last heard skips blocked nodes`() {
    let radioID = UUID()
    let blocked = makeContact(radioID: radioID, key: makeKey(0x01), name: "Noisy", isBlocked: true, lastHeardTimestamp: 3_000)
    let saved = makeContact(radioID: radioID, key: makeKey(0x02), name: "Ridge", lastHeardTimestamp: 2_000)
    let heard = [
      makeHeard(radioID: radioID, key: makeKey(0x01), name: "Noisy", lastHeard: Date(timeIntervalSince1970: 3_000)),
      makeHeard(radioID: radioID, key: makeKey(0x02), name: "Ridge", lastHeard: Date(timeIntervalSince1970: 2_000)),
    ]

    #expect(HomeDashboardModel.lastHeard(contacts: [blocked, saved], heard: heard)?.name == "Ridge")
    #expect(HomeDashboardModel.lastHeard(contacts: [blocked], heard: Array(heard.prefix(1))) == nil)
  }

  @Test
  func `Last heard orders saved nodes by recency and unsaved ones by when they were heard`() {
    let radioID = UUID()
    // Refreshed on the radio while the phone was away: newer than anything the phone heard.
    let synced = makeContact(radioID: radioID, key: makeKey(0x01), name: "Summit", lastModified: 5_000, lastHeardTimestamp: 1_000)
    let heardOnly = makeHeard(radioID: radioID, key: makeKey(0x02), name: "Valley", lastHeard: Date(timeIntervalSince1970: 4_000))
    #expect(HomeDashboardModel.lastHeard(contacts: [synced], heard: [heardOnly])?.name == "Summit")

    let newer = makeHeard(radioID: radioID, key: makeKey(0x03), name: "Creek", lastHeard: Date(timeIntervalSince1970: 6_000))
    #expect(HomeDashboardModel.lastHeard(contacts: [synced], heard: [heardOnly, newer])?.name == "Creek")

    // A saved node's own heard row never stands in for it under its broadcast name.
    let stale = makeHeard(radioID: radioID, key: makeKey(0x01), name: "SUMMIT-RAW", lastHeard: Date(timeIntervalSince1970: 7_000))
    #expect(HomeDashboardModel.lastHeard(contacts: [synced], heard: [heardOnly, stale])?.name == "Summit")
  }

  @Test
  func `Last heard is nil for a saved node never heard or changed`() {
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, key: makeKey(0x01))
    #expect(HomeDashboardModel.lastHeard(contacts: [contact], heard: []) == nil)
  }
}

@Suite("Home Chats card routes")
@MainActor
struct HomeChatsCardRouteTests {
  @Test
  func `A contact's line carries that contact's chat`() {
    let contact = makeContact(radioID: UUID(), key: makeKey(0x21))
    let line = HomeDashboardModel.ConversationLine(
      id: contact.id, name: "A", date: .now, preview: nil, isUnread: false, route: .direct(contact)
    )
    #expect(line.route == .direct(contact))
    #expect(line.route?.conversationID == contact.id)
  }

  @Test
  func `A name held by two contacts is shared, ignoring case, and a nickname counts`() {
    let radioID = UUID()
    let directory = ContactNameDirectory(contacts: [
      makeContact(radioID: radioID, key: makeKey(0x31), name: "Alice"),
      makeContact(radioID: radioID, key: makeKey(0x32), name: "alice"),
      makeContact(radioID: radioID, key: makeKey(0x33), name: "Bob"),
      makeContact(radioID: radioID, key: makeKey(0x34), name: "Node", nickname: "Bob"),
      makeContact(radioID: radioID, key: makeKey(0x35), name: "Carol"),
    ])
    #expect(directory.isDisplayNameShared("ALICE"))
    #expect(directory.isDisplayNameShared("Bob"))
    #expect(!directory.isDisplayNameShared("Carol"))
    #expect(!directory.isDisplayNameShared("Nobody"))
  }
}

@Suite("Support prompt schedule")
struct SupportPromptScheduleTests {
  private static let now = Date(timeIntervalSince1970: 1_000_000_000)
  private static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 60 * 60) }

  @Test
  func `not before real use`() {
    #expect(!SupportPromptSchedule.shouldShow(firstUse: Self.daysAgo(30), connections: 4, lastShown: nil, now: Self.now))
    #expect(!SupportPromptSchedule.shouldShow(firstUse: Self.daysAgo(6), connections: 50, lastShown: nil, now: Self.now))
    #expect(SupportPromptSchedule.shouldShow(firstUse: Self.daysAgo(7), connections: 5, lastShown: nil, now: Self.now))
  }

  @Test
  func `rarely after that`() {
    #expect(!SupportPromptSchedule.shouldShow(firstUse: Self.daysAgo(300), connections: 90, lastShown: Self.daysAgo(100), now: Self.now))
    #expect(SupportPromptSchedule.shouldShow(firstUse: Self.daysAgo(300), connections: 90, lastShown: Self.daysAgo(120), now: Self.now))
  }

  @Test
  @MainActor
  func `a connection counts, it stays due until shown, and showing it starts the wait`() throws {
    let defaults = try #require(UserDefaults(suiteName: "SupportPromptScheduleTests-\(UUID().uuidString)"))
    for _ in 0..<4 {
      #expect(!SupportPromptSchedule.noteConnection(in: defaults, now: Self.daysAgo(30)))
    }
    #expect(!SupportPromptSchedule.noteConnection(in: defaults, now: Self.daysAgo(30)), "the first week still counts as new")
    #expect(SupportPromptSchedule.noteConnection(in: defaults, now: Self.now))
    #expect(SupportPromptSchedule.noteConnection(in: defaults, now: Self.now), "put off, it's still due")
    SupportPromptSchedule.markShown(in: defaults, now: Self.now)
    #expect(!SupportPromptSchedule.noteConnection(in: defaults, now: Self.now))
  }
}

@Suite("GPS details formats")
struct GPSDetailsFormatTests {
  @Test
  func `degrees, minutes and seconds carry over and keep their hemisphere`() {
    #expect(GPSFormat.dmsText(CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232)) == "41°52'56.3\" N, 87°37'23.5\" W")
    #expect(GPSFormat.dmsText(CLLocationCoordinate2D(latitude: -0.99999, longitude: 0)) == "1°0'0.0\" S, 0°0'0.0\" E")
  }

  @Test
  func `the grid square matches known locators`() {
    #expect(GPSFormat.gridSquare(CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232)) == "EN61ev")
    #expect(GPSFormat.gridSquare(CLLocationCoordinate2D(latitude: 51.4779, longitude: -0.0015)) == "IO91xl")
    #expect(GPSFormat.gridSquare(CLLocationCoordinate2D(latitude: 90, longitude: 180)).count == 6)
  }

  @Test
  func `a radio without details has no sections, and rows follow what it says`() throws {
    #expect(GNSSDetails.radioSections(nil).isEmpty)
    let noFix = try #require(RadioGPSDetails(customVar: "0/4/-1/2000/9000/100/0"))
    let sections = GNSSDetails.radioSections(noFix)
    #expect(sections.count == 1, "no fix: its speed and course mean nothing")
    #expect(sections[0].rows.contains { $0.value == "4" })
    let fix = try #require(RadioGPSDetails(customVar: "8/12/9/2000/9000/100/1"))
    #expect(GNSSDetails.radioSections(fix).count == 2)
  }

  @Test
  func `a phone fix with no course or speed has no movement rows`() {
    let fix = CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
      altitude: 10,
      horizontalAccuracy: 5,
      verticalAccuracy: 3,
      course: -1,
      speed: -1,
      timestamp: .now
    )
    let sections = GNSSDetails.phoneSections(fix, heading: nil, headingAccuracy: nil, now: .now)
    #expect(sections.count == 1)
    #expect(GNSSDetails.phoneSections(nil, heading: 10, headingAccuracy: 1, now: .now).isEmpty)
  }
}
