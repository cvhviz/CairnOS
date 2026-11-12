@testable import CairnServices
import Foundation
import MeshCore
import SwiftData
import Testing

@Suite("Neighbour persistence")
struct NeighbourPersistenceTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let key = Data([0x3A, 0x7F] + [UInt8](repeating: 0x21, count: 30))
  private static let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5).key
  private static let otherChannel = RadioChannelConfig(frequencyKHz: 915_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5).key

  private static func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  /// A record with every field set.
  private static func fullRecord() -> NeighbourRecord {
    NeighbourRecord(
      identity: .fullKey(key),
      firstHeard: t0,
      lastHeard: t0.addingTimeInterval(90),
      heardCount: 7,
      lastSNR: 4.25,
      bestSNR: 9.5,
      snrEWMA: 5.125,
      lastRSSI: -97,
      uplinkSNR: -2.5,
      uplinkAt: t0.addingTimeInterval(30),
      hearsYouAt: t0.addingTimeInterval(30),
      sources: [
        .relay: NeighbourSourceStats(count: 5, firstHeard: t0, lastHeard: t0.addingTimeInterval(90)),
        .replyToUs: NeighbourSourceStats(count: 1, firstHeard: t0.addingTimeInterval(30), lastHeard: t0.addingTimeInterval(30)),
        .advert: NeighbourSourceStats(count: 1, firstHeard: t0.addingTimeInterval(60), lastHeard: t0.addingTimeInterval(60))
      ],
      nodeTypeRaw: 2,
      name: "Hilltop",
      latitude: 47.6,
      longitude: -122.3,
      heardFrom: NeighbourHeardFrom(
        fix: NeighbourFix(latitude: 47.61, longitude: -122.31, horizontalAccuracy: 12, timestamp: t0),
        snr: 9.5
      )
    )
  }

  private static func hashRecord(_ hash: UInt8, lastHeard: Date, count: Int = 1) -> NeighbourRecord {
    NeighbourRecord(
      identity: .hash(Data([hash])),
      firstHeard: lastHeard,
      lastHeard: lastHeard,
      heardCount: count,
      lastSNR: 3,
      sources: [.relay: NeighbourSourceStats(count: count, firstHeard: lastHeard, lastHeard: lastHeard)]
    )
  }

  // MARK: - Round Trip

  @Test
  func `every field round-trips`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let record = Self.fullRecord()
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [record], removing: [])

    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [record])
  }

  @Test
  func `each identity kind round-trips`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let identities: [NeighbourIdentity] = [.fullKey(Self.key), .keyPrefix(Data(Self.key.prefix(8))), .hash(Data([0x3A, 0x7F]))]
    let records = identities.enumerated().map { index, identity in
      NeighbourRecord(identity: identity, firstHeard: Self.t0, lastHeard: Self.t0.addingTimeInterval(TimeInterval(index)))
    }
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: records, removing: [])

    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel).map(\.identity) == identities.reversed())
  }

  @Test
  func `a batch replaces rows by identity and deletes removed ones`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    try await store.saveNeighbourRecords(
      radioID: radioID,
      channelKey: Self.channel,
      upserting: [Self.hashRecord(0xAA, lastHeard: Self.t0), Self.hashRecord(0xBB, lastHeard: Self.t0)],
      removing: []
    )

    let updated = Self.hashRecord(0xAA, lastHeard: Self.t0.addingTimeInterval(60), count: 3)
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [updated], removing: [.hash(Data([0xBB]))])

    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [updated])
  }

  @Test
  func `radios keep separate rows`() async throws {
    let store = try Self.makeStore()
    let radioA = UUID()
    let radioB = UUID()
    let record = Self.hashRecord(0xAA, lastHeard: Self.t0)
    try await store.saveNeighbourRecords(radioID: radioA, channelKey: Self.channel, upserting: [record], removing: [])
    try await store.saveNeighbourRecords(radioID: radioB, channelKey: Self.channel, upserting: [Self.hashRecord(0xAA, lastHeard: Self.t0, count: 9)], removing: [])
    try await store.saveNeighbourRecords(radioID: radioB, channelKey: Self.channel, upserting: [], removing: [.hash(Data([0xAA]))])

    #expect(try await store.fetchNeighbourRecords(radioID: radioA, channelKey: Self.channel) == [record])
    #expect(try await store.fetchNeighbourRecords(radioID: radioB, channelKey: Self.channel).isEmpty)
  }

  @Test
  func `each channel keeps its own rows`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let here = Self.hashRecord(0xAA, lastHeard: Self.t0)
    let there = Self.hashRecord(0xAA, lastHeard: Self.t0, count: 4)
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [here], removing: [])
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel, upserting: [there], removing: [])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [here])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel) == [there])

    // Removing a row on one channel leaves the other's
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel, upserting: [], removing: [here.identity])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [here])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel).isEmpty)
  }

  @Test
  func `a prune with no channel reaches every channel`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let old = Self.t0.addingTimeInterval(-8 * 24 * 3600)
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [Self.hashRecord(0xAA, lastHeard: old)], removing: [])
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel, upserting: [Self.hashRecord(0xBB, lastHeard: old)], removing: [])

    let pruned = try await store.pruneNeighbourRecords(radioID: radioID, channelKey: nil, notHeardSince: Self.t0)
    #expect(pruned == 2)
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel).isEmpty)
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.otherChannel).isEmpty)
  }

  @Test
  func `rows stored before channels were recorded are deleted, never read`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let radioID = UUID()
    // A row as an earlier build wrote it: no channel
    let context = ModelContext(container)
    let legacy = NeighbourLink(radioID: radioID, channelKey: Self.channel, record: Self.hashRecord(0xCC, lastHeard: Self.t0))
    legacy.channelKey = nil
    context.insert(legacy)
    try context.save()

    let store = PersistenceStore(modelContainer: container)
    let kept = Self.hashRecord(0xAA, lastHeard: Self.t0)
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [kept], removing: [])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [kept])

    #expect(try await store.deleteUnstampedNeighbourRecords(radioID: radioID) == 1)
    #expect(try await store.deleteUnstampedNeighbourRecords(radioID: radioID) == 0)
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [kept])
  }

  @Test
  func `prune deletes only rows not heard since the cutoff`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    let fresh = Self.hashRecord(0xAA, lastHeard: Self.t0)
    try await store.saveNeighbourRecords(
      radioID: radioID,
      channelKey: Self.channel,
      upserting: [fresh, Self.hashRecord(0xBB, lastHeard: Self.t0.addingTimeInterval(-8 * 24 * 3600))],
      removing: []
    )

    let pruned = try await store.pruneNeighbourRecords(radioID: radioID, channelKey: Self.channel, notHeardSince: Self.t0.addingTimeInterval(-7 * 24 * 3600))
    #expect(pruned == 1)
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [fresh])

    try await store.clearNeighbourRecords(radioID: radioID)
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel).isEmpty)
  }

  @Test
  func `unreadable source stats load as none`() {
    #expect(NeighbourLink.unpackSources(Data("not json".utf8)).isEmpty)
    #expect(NeighbourLink.unpackSources(Data()).isEmpty)
    let sources = Self.fullRecord().sources
    #expect(NeighbourLink.unpackSources(NeighbourLink.packSources(sources)) == sources)
    #expect(NeighbourLink.packSources(sources) == NeighbourLink.packSources(sources))
  }

  @Test
  func `erasing a radio's data deletes its neighbours and its RX_SYNC cursor`() async throws {
    let store = try Self.makeStore()
    let device = DeviceDTO.testDevice()
    let otherRadio = UUID()
    try await store.saveDevice(device)
    try await store.saveRxStreamCursor(RxStreamCursor(epoch: 7, seq: 120), radioID: device.radioID)
    try await store.saveNeighbourRecords(radioID: device.radioID, channelKey: Self.channel, upserting: [Self.fullRecord()], removing: [])
    let kept = Self.hashRecord(0xAA, lastHeard: Self.t0)
    try await store.saveNeighbourRecords(radioID: otherRadio, channelKey: Self.channel, upserting: [kept], removing: [])

    try await store.deleteDeviceData(id: device.id)

    #expect(try await store.fetchNeighbourRecords(radioID: device.radioID, channelKey: Self.channel).isEmpty)
    #expect(try await store.fetchRxStreamCursor(radioID: device.radioID) == nil)
    #expect(try await store.fetchDevice(id: device.id) != nil)
    #expect(try await store.fetchNeighbourRecords(radioID: otherRadio, channelKey: Self.channel) == [kept])
  }

  // MARK: - Replay

  @Test
  func `the replay read returns the newest entries in the window, oldest first`() async throws {
    let store = try Self.makeStore()
    let radioID = UUID()
    func entry(_ index: Int, radio: UUID = radioID, channel: ChannelKey? = Self.channel) -> RxLogEntryDTO {
      let payload = Data([0x10, UInt8(index)])
      var parsed = ParsedRxLogData(
        snr: Double(index), rssi: -100, rawPayload: payload, routeType: .flood, payloadType: .textMessage,
        payloadVersion: 0, payloadTypeBits: PayloadType.textMessage.rawValue, transportCode: nil,
        pathLength: 0x01, pathNodes: [0xB0 + UInt8(index)], packetPayload: payload
      )
      parsed.channel = channel.flatMap(RadioChannelConfig.init(key:))
      return RxLogEntryDTO(radioID: radio, receivedAt: Self.t0.addingTimeInterval(TimeInterval(index * 60)), from: parsed)
    }
    for index in 0..<6 {
      try await store.saveRxLogEntry(entry(index))
    }
    try await store.saveRxLogEntry(entry(5, radio: UUID()))
    // Heard on another channel, or before channels were recorded: never this channel's evidence
    try await store.saveRxLogEntry(entry(7, channel: Self.otherChannel))
    try await store.saveRxLogEntry(entry(8, channel: nil))
    try await store.flushPendingRxLogEntries()

    let replay = try await store.fetchNeighbourReplay(radioID: radioID, channelKey: Self.channel, since: Self.t0.addingTimeInterval(60), limit: 3)
    #expect(replay.map(\.receivedAt) == [3, 4, 5].map { Self.t0.addingTimeInterval(TimeInterval($0 * 60)) })
    #expect(replay.map(\.fields) == [3, 4, 5].map { RxPacketFields(entry($0)) })
    #expect(replay.allSatisfy { $0.channelKey == Self.channel })

    let other = try await store.fetchNeighbourReplay(radioID: radioID, channelKey: Self.otherChannel, since: Self.t0, limit: 10)
    #expect(other.map(\.receivedAt) == [Self.t0.addingTimeInterval(7 * 60)])
  }

  // MARK: - Migration

  @Test
  func `a store written before the neighbour table opens with it`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("legacy.store")
    let radioID = UUID()

    // Write a row with every entity the store had before NeighbourLink.
    do {
      let schema = Schema([
        Device.self,
        Contact.self,
        Message.self,
        MessageRepeat.self,
        Reaction.self,
        Channel.self,
        RemoteNodeSession.self,
        RoomMessage.self,
        SavedTracePath.self,
        TracePathRun.self,
        RxLogEntry.self,
        DebugLogEntry.self,
        LinkPreviewData.self,
        DiscoveredNode.self,
        NodeStatusSnapshot.self,
        BlockedChannelSender.self,
        PendingSend.self
      ])
      let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
      let context = ModelContext(container)
      context.insert(DiscoveredNode(
        radioID: radioID,
        publicKey: Self.key,
        name: "Legacy",
        typeRawValue: 2,
        lastHeard: Self.t0,
        lastAdvertTimestamp: 1
      ))
      try context.save()
    }

    // Open it with today's full schema: SwiftData's inferred lightweight migration adds the entity.
    let container = try ModelContainer(
      for: PersistenceStore.schema,
      configurations: [ModelConfiguration(schema: PersistenceStore.schema, url: storeURL)]
    )
    let store = PersistenceStore(modelContainer: container)
    #expect(try await store.fetchDiscoveredNodes(radioID: radioID).map(\.name) == ["Legacy"])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel).isEmpty)

    let record = Self.fullRecord()
    try await store.saveNeighbourRecords(radioID: radioID, channelKey: Self.channel, upserting: [record], removing: [])
    #expect(try await store.fetchNeighbourRecords(radioID: radioID, channelKey: Self.channel) == [record])
  }
}
