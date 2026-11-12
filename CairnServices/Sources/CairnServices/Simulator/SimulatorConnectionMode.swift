import Foundation
import OSLog
import SwiftData

/// Connection mode for simulator and demo mode on device.
/// Provides mock data and simulated connections without requiring real hardware.
@MainActor
final class SimulatorConnectionMode {
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "SimulatorConnectionMode")

  /// Whether simulator is "connected"
  private(set) var isConnected = false

  /// The simulated device
  var device: DeviceDTO? {
    isConnected ? MockDataProvider.simulatorDevice : nil
  }

  init() {}

  /// Simulates connecting to the simulator device
  func connect() async {
    logger.info("Simulator: connecting to mock device")
    try? await Task.sleep(for: .milliseconds(200)) // Brief delay
    isConnected = true
    logger.info("Simulator: connected")
  }

  /// Simulates disconnecting
  func disconnect() async {
    logger.info("Simulator: disconnecting")
    isConnected = false
  }

  /// Seeds the data store with mock data. Each message is saved before its
  /// link-preview, reaction, and repeat rows: `saveMessage` does not persist the
  /// link-preview or `reactionSummary` columns, and `saveMessageRepeat` needs the
  /// parent present. Re-seeding upserts on each row's unique `id`, so it is idempotent.
  func seedDataStore(_ dataStore: PersistenceStore) async throws {
    try await dataStore.saveDevice(MockDataProvider.simulatorDevice)

    // Mock contacts omit the avatar photo and colour; copy any existing values onto the upsert so
    // saveContact(_:) does not apply nil.
    for contact in MockDataProvider.contacts {
      if let existing = try await dataStore.fetchContact(id: contact.id) {
        try await dataStore.saveContact(
          contact.with(avatarImageData: existing.avatarImageData).with(avatarColorRaw: existing.avatarColorRaw)
        )
      } else {
        try await dataStore.saveContact(contact)
      }
    }

    for channel in MockDataProvider.channels {
      try await dataStore.saveChannel(channel)
    }

    for contact in MockDataProvider.contacts {
      for message in MockDataProvider.messages(for: contact.id) {
        try await dataStore.saveMessage(message)
      }
    }

    for channel in MockDataProvider.channels {
      for message in MockDataProvider.channelMessages(for: channel.index) {
        try await dataStore.saveMessage(message)
      }
    }

    // Cached preview rows: the chat's preview lookup reads the store before any network
    // fetch, so these cards render offline.
    for preview in MockDataProvider.linkPreviews {
      try await dataStore.saveLinkPreview(preview)
    }

    // Reaction rows feed the reactor-detail list; the summary drives the badge.
    for reacted in MockDataProvider.reactedMessages {
      for reaction in MockDataProvider.reactions(for: reacted.messageID) {
        try await dataStore.saveReaction(reaction)
      }
      try await dataStore.updateMessageReactionSummary(
        messageID: reacted.messageID,
        summary: reacted.summary
      )
    }

    for messageID in MockDataProvider.messagesWithRepeats {
      for repeatRow in MockDataProvider.messageRepeats(for: messageID) {
        try await dataStore.saveMessageRepeat(repeatRow)
      }
    }

    try await seedRxLogEntries(dataStore)
    try await seedObservedNodes(dataStore)
    try await seedNodeStatusSnapshots(dataStore)
    try await seedDemoRoom(dataStore)

    logger.info(
      "Simulator: seeded \(MockDataProvider.contacts.count) contacts and " +
        "\(MockDataProvider.channels.count) channels with messages"
    )
  }

  /// Seeds the joined Diana's Room and refreshes it on every connect, as the DM and channel seeds
  /// are: its posts and last-activity date move to now-relative times, so the room reads as
  /// today's alongside the other demo conversations. Each post keeps its fixed id, which
  /// `RoomMessage.id` holds unique, so saving it again with a new time replaces the row rather
  /// than adding one (a new time is also a new dedup key, so `saveRoomMessage` takes it).
  ///
  /// The session is logged in again on each connect: the demo radio holds it as logged in, and
  /// answers its keep-alives (`SimulatorMockTransport`), but a disconnect marks every room
  /// session logged out. Its unread count and settings are the user's and are kept.
  ///
  /// A session for the room under another id was joined by hand; it and its posts are left alone.
  func seedDemoRoom(_ dataStore: PersistenceStore, now: Date = Date()) async throws {
    let seeded = MockDataProvider.dianasRoomSession(now: now)
    let posts = MockDataProvider.dianasRoomPosts(now: now)
    if let existing = try await dataStore.fetchRemoteNodeSession(publicKey: seeded.publicKey) {
      guard existing.id == seeded.id else { return }
      try await dataStore.saveRemoteNodeSessionDTO(MockDataProvider.dianasRoomSession(refreshing: existing, now: now))
    } else {
      try await dataStore.saveRemoteNodeSessionDTO(seeded)
    }
    for post in posts {
      try await dataStore.saveRoomMessage(post)
    }
  }

  /// Writes what the demo radio has heard on its channel (`MockDataProvider.observedNodes`),
  /// refreshed on every connect as the contacts are, so their observations stay as recent as
  /// their adverts. Each row replaces the one with its identity; rows the app observed since are
  /// kept.
  private func seedObservedNodes(_ dataStore: PersistenceStore) async throws {
    try await dataStore.saveObservedNodes(
      radioID: MockDataProvider.simulatorDeviceID,
      channelKey: MockDataProvider.simulatorChannelKey,
      upserting: MockDataProvider.observedNodes,
      removing: []
    )
  }

  /// Inserts the two flood-region RX-log fixtures when they are missing.
  /// `saveRxLogEntry` is insert-only, so a second connect must skip existing ids.
  private func seedRxLogEntries(_ dataStore: PersistenceStore) async throws {
    let existingIDs = try await Set(
      dataStore.fetchRxLogEntries(
        radioID: MockDataProvider.simulatorDeviceID
      ).map(\.id)
    )
    for entry in MockDataProvider.rxLogEntries where !existingIDs.contains(entry.id) {
      try await dataStore.saveRxLogEntry(entry)
    }
  }

  /// Seeds a node's GPS track once so the location History list and map have
  /// content to render. Skipped when the node already has a snapshot, so the
  /// now-relative timestamps aren't restacked into a duplicate track on every
  /// reconnect. Unlike the message seed, snapshot rows carry no deterministic id
  /// (their unique key is nodePublicKey + timestamp), so re-seeding would append.
  private func seedNodeStatusSnapshots(_ dataStore: PersistenceStore) async throws {
    let nodeKey = MockDataProvider.locationHistoryNodePublicKey
    guard try await dataStore.fetchLatestNodeStatusSnapshot(nodePublicKey: nodeKey) == nil else {
      return
    }
    let existingKeys = try await dataStore.existingNodeStatusSnapshotKeys()
    try await dataStore.batchInsertNodeStatusSnapshots(
      MockDataProvider.nodeStatusSnapshots,
      existingKeys: existingKeys
    )
  }
}
