import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

@Suite("RxLogService batched saves")
struct RxLogServiceBatchingTests {
  private static let secret = Data(repeating: 0x42, count: 16)

  // MARK: - Burst Delivery

  @Test
  func `a 500-event burst is yielded at once, kept whole and saved in batches`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(transport: MockTransport())
    let writer = RecordingEntryWriter(saveDelay: .milliseconds(50))
    let service = RxLogService(
      session: session, dataStore: MockPersistenceStore(), heardRepeatsService: nil, entryWriter: writer
    )
    let collector = EntryCollector()
    let stream = service.entryStream()
    let collecting = Task {
      for await entry in stream {
        await collector.record(entry)
      }
    }
    defer { collecting.cancel() }

    await service.startEventMonitoring(radioID: radioID)
    try await waitUntil("the RX log subscribed") { await session.subscriberCountForTest > 0 }

    for index in 0..<500 {
      await session.dispatchForTesting(.rxLogData(Self.relay(index)))
    }

    try await waitUntil("every entry yielded") { await collector.count == 500 }
    #expect(await writer.savedCount < 500, "entries reach the stream before their batches are saved")

    try await waitUntil("every entry saved") { await writer.savedCount == 500 }
    #expect(await session.eventDropCount(label: RxLogService.eventLabel) == 0)

    let batches = await writer.batches
    #expect(batches.allSatisfy { $0.count <= RxLogRetention.batchSize })
    #expect(batches.count <= 500 / RxLogRetention.batchSize + 2, "saves are batched, not one per packet")
    let savedOrder = batches.flatMap { $0 }.map(\.packetPayload)
    #expect(savedOrder == (0..<500).map { Self.relayPayload($0) })
    #expect(await collector.entries.map(\.packetPayload) == savedOrder)

    await service.stopEventMonitoring()
  }

  @Test
  func `a record dispatched as soon as start returns reaches the log`() async throws {
    let session = MeshCoreSession(transport: MockTransport())
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: session, dataStore: MockPersistenceStore(), heardRepeatsService: nil, entryWriter: writer
    )
    let collector = EntryCollector()
    let stream = service.entryStream()
    let collecting = Task {
      for await entry in stream {
        await collector.record(entry)
      }
    }
    defer { collecting.cancel() }

    // ServiceContainer turns RX_SYNC on right after this returns; a resumed record must not be
    // dispatched before the RX log listens.
    await service.startEventMonitoring(radioID: UUID())
    #expect(await session.subscriberCountForTest > 0)
    await session.dispatchForTesting(.rxLogData(Self.relay(0).withRxSync(seq: 1, epoch: 7, radioAge: nil, isBackfill: true)))

    try await waitUntil("the resumed record reached the log") { await collector.count == 1 }
    await service.stopEventMonitoring()
    #expect(await writer.batches.flatMap { $0 }.map(\.packetPayload) == [Self.relayPayload(0)])
    #expect(await session.eventDropCount(label: RxLogService.eventLabel) == 0)
  }

  @Test
  func `heard repeats sees every entry in order and message entries save at once`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(transport: MockTransport())
    let writer = RecordingEntryWriter(saveDelay: .milliseconds(5))
    let repeatStore = RecordingRepeatStore()
    let heardRepeats = HeardRepeatsService(dataStore: repeatStore)
    await heardRepeats.configure(radioID: radioID)
    let service = RxLogService(
      session: session, dataStore: MockPersistenceStore(), heardRepeatsService: heardRepeats, entryWriter: writer
    )
    await service.startEventMonitoring(radioID: radioID)
    // After the store's (empty) channel list has loaded, which replaces the cache
    try await waitUntil("the RX log subscribed") { await session.subscriberCountForTest > 0 }
    await service.updateChannels(secrets: [0: Self.secret], names: [0: "Public"])

    let count = 200
    for index in 0..<count {
      let parsed = index % 10 == 9 ? Self.channelMessage(index) : Self.relay(index)
      await session.dispatchForTesting(.rxLogData(parsed))
    }
    try await waitUntil("every entry saved") { await writer.savedCount == count }
    try await waitUntil("heard repeats saw every channel message") { await repeatStore.checkedEntryIDs.count == count / 10 }

    let batches = await writer.batches
    let saved = batches.flatMap { $0 }
    let expectedPayloads = (0..<count).map { $0 % 10 == 9 ? Self.channelMessage($0).packetPayload : Self.relayPayload($0) }
    #expect(saved.map(\.packetPayload) == expectedPayloads, "batches save in received order")
    let channelIDs = saved.filter { $0.payloadType == .groupText }.map(\.id)
    #expect(await repeatStore.checkedEntryIDs == channelIDs, "heard repeats runs in received order")
    for batch in batches {
      let messages = batch.filter { RxLogService.needsImmediateSave($0) }
      #expect(messages.count <= 1)
      if let message = messages.first {
        #expect(batch.last?.id == message.id, "a message entry closes its batch: saved at once")
      }
    }

    await service.stopEventMonitoring()
  }

  @Test
  func `a decrypted channel message is in the store when process returns`() async throws {
    let radioID = UUID()
    let writer = RecordingEntryWriter(saveDelay: .milliseconds(20))
    let session = MeshCoreSession(transport: MockTransport())
    let service = RxLogService(
      session: session,
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: radioID)
    // After the store's (empty) channel list has loaded, which replaces the cache
    try await waitUntil("the RX log subscribed") { await session.subscriberCountForTest > 0 }
    await service.updateChannels(secrets: [0: Self.secret], names: [0: "Public"])

    await service.process(Self.relay(0))
    await service.process(Self.channelMessage(1))

    let saved = await writer.batches.flatMap { $0 }
    #expect(saved.count == 2, "the message and the relay queued before it are saved before process returns")
    #expect(saved.last?.decryptStatus == .success)
    await service.stopEventMonitoring()
  }

  @Test
  func `stopping drains a partial batch`() async throws {
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: UUID())
    for index in 0..<3 {
      await service.process(Self.relay(index))
    }
    #expect(await writer.savedCount == 0, "a partial batch waits for its timer")

    await service.stopEventMonitoring()
    #expect(await writer.savedCount == 3)
  }

  @Test
  func `a partial batch saves after the flush interval`() async throws {
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: UUID())
    await service.process(Self.relay(0))
    try await waitUntil(timeout: .seconds(5), "the timer flushed the batch") { await writer.savedCount == 1 }
    await service.stopEventMonitoring()
  }

  @Test
  func `read-backs include entries waiting for their batch`() async throws {
    let radioID = UUID()
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: radioID)
    for index in 0..<3 {
      await service.process(Self.relay(index))
    }

    #expect(await service.recentEntries(since: .distantPast).count == 3)
    #expect(await service.loadExistingEntries().count == 3)
    await service.stopEventMonitoring()
  }

  // MARK: - RX_SYNC Records

  @Test
  func `a failed save does not advance the cursor`() async throws {
    let radioID = UUID()
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: radioID)

    await writer.failNextSave()
    for seq: UInt32 in 1...3 {
      await service.process(Self.relay(Int(seq), seq: seq, epoch: 7))
    }
    await service.flushPendingEntries()
    #expect(await writer.savedCount == 0)
    #expect(await writer.cursor == nil, "nothing was saved, so the cursor stays")

    await service.process(Self.relay(4, seq: 4, epoch: 7))
    await service.flushPendingEntries()
    #expect(await writer.cursor == RxStreamCursor(epoch: 7, seq: 4))
    await service.stopEventMonitoring()
  }

  @Test
  func `a record delivered again under the same epoch and seq is ignored`() async throws {
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    let collector = EntryCollector()
    let stream = service.entryStream()
    let collecting = Task {
      for await entry in stream {
        await collector.record(entry)
      }
    }
    defer { collecting.cancel() }
    await service.startEventMonitoring(radioID: UUID())

    await service.process(Self.relay(5, seq: 5, epoch: 7))
    await service.process(Self.relay(5, seq: 5, epoch: 7, isBackfill: true))
    await service.process(Self.relay(5, seq: 5, epoch: 8))
    await service.flushPendingEntries()

    let saved = await writer.batches.flatMap { $0 }
    #expect(saved.map(\.radioEpoch) == [7, 8], "the repeat is dropped; another epoch is another record")
    try await waitUntil("both records yielded") { await collector.count == 2 }
    #expect(await writer.cursor == RxStreamCursor(epoch: 8, seq: 5))
    await service.stopEventMonitoring()
  }

  /// Records the session delivers before, or without, a SUBSCRIBE reply carry epoch 0. The radio
  /// numbers its journal from 1 every boot, so after a reboot a connection whose reply was lost
  /// again sends seqs 1, 2, 3... under epoch 0 once more. Seeded from the store, those keys used to
  /// hide every new record whose seq matched an old one: the RX log went blank.
  @Test
  func `epoch-0 records from a new radio boot are not dropped as repeats of stored ones`() async throws {
    let radioID = UUID()
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let old = (1...3).map { index in
      RxLogEntryDTO(
        radioID: radioID,
        receivedAt: Date().addingTimeInterval(-3600 + Double(index)),
        from: Self.relay(index, seq: UInt32(index), epoch: 0)
      )
    }
    try await store.saveRxLogEntries(old)

    let service = RxLogService(session: MeshCoreSession(transport: MockTransport()), dataStore: store, heardRepeatsService: nil)
    let collector = EntryCollector()
    let stream = service.entryStream()
    let collecting = Task {
      for await entry in stream {
        await collector.record(entry)
      }
    }
    defer { collecting.cancel() }
    await service.startEventMonitoring(radioID: radioID)

    for index in 10...12 {
      await service.process(Self.relay(index, seq: UInt32(index - 9), epoch: 0))
    }
    try await waitUntil("the new boot's records reach the RX log") { await collector.count == 3 }
    #expect(await collector.entries.map(\.packetPayload) == (10...12).map { Self.relayPayload($0) })
    await service.stopEventMonitoring()
  }

  @Test
  func `epoch-0 records are never deduped against each other`() async throws {
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: UUID())

    // a lost-reply connection, the radio reboots, another lost-reply connection: same seqs, new packets
    await service.process(Self.relay(1, seq: 1, epoch: 0))
    await service.process(Self.relay(2, seq: 2, epoch: 0))
    await service.process(Self.relay(3, seq: 1, epoch: 0))
    await service.process(Self.relay(4, seq: 2, epoch: 0))
    await service.flushPendingEntries()

    let saved = await writer.batches.flatMap { $0 }
    #expect(saved.map(\.packetPayload) == (1...4).map { Self.relayPayload($0) })
    #expect(await writer.cursor == nil, "epoch 0 never moves the cursor")
    await service.stopEventMonitoring()
  }

  @Test
  func `a backfilled record is dated by its radio age`() async throws {
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: UUID())

    let before = Date()
    await service.process(Self.relay(1, seq: 1, epoch: 7, radioAge: .seconds(90), isBackfill: true))
    await service.process(Self.relay(2))
    await service.flushPendingEntries()
    let after = Date()

    let saved = await writer.batches.flatMap { $0 }
    let backfill = try #require(saved.first)
    #expect(backfill.receivedAt >= before.addingTimeInterval(-90))
    #expect(backfill.receivedAt <= after.addingTimeInterval(-90))
    #expect(backfill.isBackfill)
    #expect(backfill.radioSeq == 1)
    let live = try #require(saved.last)
    #expect(live.receivedAt >= before && live.receivedAt <= after, "a stock frame is dated on arrival")
    #expect(!live.isBackfill)
    #expect(live.radioSeq == nil)
    await service.stopEventMonitoring()
  }

  @Test
  func `receivedAt subtracts the radio age`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(RxLogService.receivedAt(radioAge: nil, now: now) == now)
    #expect(RxLogService.receivedAt(radioAge: .zero, now: now) == now)
    #expect(RxLogService.receivedAt(radioAge: .milliseconds(1500), now: now) == now.addingTimeInterval(-1.5))
  }

  @Test
  func `the cursor follows the newest record of the newest epoch`() {
    let radioID = UUID()
    func entry(_ seq: UInt32?, epoch: UInt32?) -> RxLogEntryDTO {
      RxLogEntryDTO(radioID: radioID, from: Self.relay(Int(seq ?? 0), seq: seq, epoch: epoch))
    }
    let start = RxStreamCursor(epoch: 7, seq: 10)
    #expect(RxLogService.advancedCursor(start, after: [entry(12, epoch: 7), entry(11, epoch: 7)]) == RxStreamCursor(epoch: 7, seq: 12))
    #expect(RxLogService.advancedCursor(start, after: [entry(4, epoch: 7)]) == start, "a backfill below it")
    #expect(RxLogService.advancedCursor(start, after: [entry(3, epoch: 9)]) == RxStreamCursor(epoch: 9, seq: 3))
    #expect(RxLogService.advancedCursor(start, after: [entry(20, epoch: 0)]) == start, "epoch 0 is unnamed")
    #expect(RxLogService.advancedCursor(nil, after: [entry(nil, epoch: nil)]) == nil, "stock frames")
  }

  @Test
  func `the cursor stops below a record the session is still fetching`() async throws {
    let radioID = UUID()
    let writer = RecordingEntryWriter()
    let rxSync = FakeRxSyncOps()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: MockPersistenceStore(),
      heardRepeatsService: nil,
      entryWriter: writer,
      rxSync: rxSync
    )
    await service.startEventMonitoring(radioID: radioID)

    // 3 and 4 went missing on the link; 5 and 6 are saved while their FETCH is still out
    await rxSync.setStats(epoch: 7, contiguousSeq: 2)
    for seq: UInt32 in [1, 2, 5, 6] {
      await service.process(Self.relay(Int(seq), seq: seq, epoch: 7))
    }
    await service.flushPendingEntries()
    #expect(await writer.cursor == RxStreamCursor(epoch: 7, seq: 2), "a resume now still asks for 3 and 4")

    // the FETCH brought them: the cursor catches up
    await rxSync.setStats(epoch: 7, contiguousSeq: 6)
    for seq: UInt32 in [3, 4] {
      await service.process(Self.relay(Int(seq), seq: seq, epoch: 7, isBackfill: true))
    }
    await service.flushPendingEntries()
    #expect(await writer.cursor == RxStreamCursor(epoch: 7, seq: 6))
    await service.stopEventMonitoring()
  }

  @Test
  func `the capped cursor never passes the floor and never moves back`() {
    let current = RxStreamCursor(epoch: 7, seq: 10)
    let ahead = RxStreamCursor(epoch: 7, seq: 20)
    #expect(RxLogService.cappedCursor(ahead, current: current, floor: 15) == RxStreamCursor(epoch: 7, seq: 15))
    #expect(RxLogService.cappedCursor(ahead, current: current, floor: 8) == current, "never back within an epoch")
    #expect(RxLogService.cappedCursor(ahead, current: current, floor: 25) == ahead)
    #expect(RxLogService.cappedCursor(ahead, current: current, floor: nil) == ahead)
    #expect(RxLogService.cappedCursor(RxStreamCursor(epoch: 9, seq: 4), current: current, floor: 2)
      == RxStreamCursor(epoch: 9, seq: 2), "a new epoch starts from its own floor")
  }

  @Test
  func `records already stored are stored once when a resume sends them again`() async throws {
    let radioID = UUID()
    let store = MockPersistenceStore()
    for seq: UInt32 in 1...3 {
      try await store.saveRxLogEntry(RxLogEntryDTO(radioID: radioID, from: Self.relay(Int(seq), seq: seq, epoch: 7)))
    }
    let writer = RecordingEntryWriter()
    let service = RxLogService(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: store,
      heardRepeatsService: nil,
      entryWriter: writer
    )
    await service.startEventMonitoring(radioID: radioID)

    for seq: UInt32 in 2...4 {
      await service.process(Self.relay(Int(seq), seq: seq, epoch: 7, isBackfill: true))
    }
    await service.flushPendingEntries()
    #expect(await writer.batches.flatMap { $0 }.map(\.radioSeq) == [4])
    await service.stopEventMonitoring()
  }

  @Test
  func `a hole its own subscription made is asked for again, and holds the cursor`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(transport: MockTransport())
    let writer = RecordingEntryWriter()
    let rxSync = FakeRxSyncOps()
    await rxSync.setStats(epoch: 7, contiguousSeq: 100)
    let service = RxLogService(
      session: session, dataStore: MockPersistenceStore(), heardRepeatsService: nil, entryWriter: writer, rxSync: rxSync
    )
    await service.startEventMonitoring(radioID: radioID)
    // Another subscription under the RX log's label that never drains: its drops count as the log's
    let lagging = await session.events(filter: EventFilter { _ in true }, buffering: .bufferingNewest(1), label: RxLogService.eventLabel)

    await service.process(Self.relay(1, seq: 1, epoch: 7))
    // a jump with no drops is the session's own gap: it is fetching it already
    await service.process(Self.relay(3, seq: 3, epoch: 7))
    #expect(await rxSync.replays.isEmpty)

    for _ in 0..<3 {
      await session.dispatchForTesting(.ok(value: nil))
    }
    #expect(await session.eventDropCount(label: RxLogService.eventLabel) > 0)
    await service.process(Self.relay(6, seq: 6, epoch: 7))
    #expect(await rxSync.replays == [4...5])

    // while the replay is out the cursor stays below it
    await service.flushPendingEntries()
    #expect(await writer.cursor == RxStreamCursor(epoch: 7, seq: 3))
    for seq: UInt32 in [4, 5] {
      await service.process(Self.relay(Int(seq), seq: seq, epoch: 7, isBackfill: true))
    }
    await service.flushPendingEntries()
    #expect(await writer.cursor == RxStreamCursor(epoch: 7, seq: 6))
    _ = lagging
    await service.stopEventMonitoring()
  }

  @Test
  func `the replay tracker reports live jumps and forgets replays that never came`() {
    var tracker = RxReplayTracker()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    #expect(tracker.take(epoch: 7, seq: 10, isBackfill: false) == nil)
    #expect(tracker.take(epoch: 7, seq: 11, isBackfill: false) == nil)
    #expect(tracker.take(epoch: 7, seq: 3, isBackfill: true) == nil, "backfill is never a jump")
    #expect(tracker.take(epoch: 7, seq: 15, isBackfill: false) == 12...14)
    #expect(tracker.take(epoch: 8, seq: 1, isBackfill: false) == nil, "a new epoch starts again")

    tracker.noteRequested(12...14, epoch: 7, at: t0)
    #expect(tracker.lowestPending(epoch: 7, now: t0) == 12)
    _ = tracker.take(epoch: 7, seq: 12, isBackfill: true)
    #expect(tracker.lowestPending(epoch: 7, now: t0) == 13)
    #expect(tracker.lowestPending(epoch: 8, now: t0) == nil)
    #expect(tracker.lowestPending(epoch: 7, now: t0.addingTimeInterval(RxReplayTracker.giveUpAfter + 1)) == nil)
  }

  @Test
  func `the dedup ring forgets the oldest record past capacity`() {
    var dedup = RxRecordDedup(capacity: 2)
    let taken = [(1, 1), (1, 1), (1, 2), (1, 3), (1, 1), (1, 3), (2, 3)].map { epoch, seq in
      dedup.insert(epoch: UInt32(epoch), seq: UInt32(seq))
    }
    // the repeat is refused; 1/1 is forgotten once 2 and 3 fill the ring; another epoch is new
    #expect(taken == [true, false, true, true, true, false, true])
  }

  // MARK: - Persistence

  @Test
  func `RX_SYNC fields round-trip through the store`() async throws {
    let radioID = UUID()
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let record = RxLogEntryDTO(radioID: radioID, from: Self.relay(1, seq: 41, epoch: 0xDEAD_BEEF, isBackfill: true))
    let plain = RxLogEntryDTO(radioID: radioID, receivedAt: Date().addingTimeInterval(-1), from: Self.relay(2))

    try await store.saveRxLogEntries([record, plain])

    let fetched = try await store.fetchRxLogEntries(radioID: radioID)
    let storedRecord = try #require(fetched.first { $0.id == record.id })
    #expect(storedRecord.radioEpoch == 0xDEAD_BEEF)
    #expect(storedRecord.radioSeq == 41)
    #expect(!storedRecord.isBackfill, "backfill is transient")
    let storedPlain = try #require(fetched.first { $0.id == plain.id })
    #expect(storedPlain.radioEpoch == nil)
    #expect(storedPlain.radioSeq == nil)
  }

  @Test
  func `a batch save commits at once and prunes once`() async throws {
    let radioID = UUID()
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let total = RxLogRetention.keepCount + RxLogRetention.pruneThreshold + 1
    let entries = (0..<total).map { index in
      RxLogEntryDTO(radioID: radioID, receivedAt: Date(timeIntervalSince1970: TimeInterval(index)), from: Self.relay(index))
    }

    let savesBefore = await store.rxLogInitiatedSaveCount
    try await store.saveRxLogEntries(entries)

    #expect(await store.rxLogInitiatedSaveCount == savesBefore + 1)
    #expect(try await store.countRxLogEntries(radioID: radioID) == RxLogRetention.keepCount)
  }

  // MARK: - Helpers

  private static func relayPayload(_ index: Int) -> Data {
    withUnsafeBytes(of: UInt32(index).littleEndian) { Data($0) } + Data([0xA5])
  }

  private static func relay(
    _ index: Int,
    seq: UInt32? = nil,
    epoch: UInt32? = nil,
    radioAge: Duration? = nil,
    isBackfill: Bool = false
  ) -> ParsedRxLogData {
    let payload = relayPayload(index)
    return ParsedRxLogData(
      snr: 5,
      rssi: -90,
      rawPayload: payload,
      routeType: .flood,
      payloadType: .ack,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.ack.rawValue,
      transportCode: nil,
      pathLength: 1,
      pathNodes: [0x3A],
      packetPayload: payload,
      seq: seq,
      epoch: epoch,
      radioAge: radioAge,
      isBackfill: isBackfill
    )
  }

  private static func channelMessage(_ index: Int) -> ParsedRxLogData {
    let payload = RxLogDecryptionTests.channelPayload(
      timestamp: 1_700_000_000 + UInt32(index), text: "Alice: message \(index)", secret: secret
    )
    return ParsedRxLogData(
      snr: 5,
      rssi: -90,
      rawPayload: payload,
      routeType: .flood,
      payloadType: .groupText,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.groupText.rawValue,
      transportCode: nil,
      pathLength: 1,
      pathNodes: [0x3A],
      packetPayload: payload
    )
  }
}

// MARK: - Test Doubles

private actor EntryCollector {
  var entries: [RxLogEntryDTO] = []

  func record(_ entry: RxLogEntryDTO) {
    entries.append(entry)
  }

  var count: Int {
    entries.count
  }
}

private struct InjectedSaveFailure: Error {}

/// Records each batch save (after an optional delay) and keeps the cursor in memory.
private actor RecordingEntryWriter: RxLogBatchPersisting {
  let saveDelay: Duration
  private(set) var batches: [[RxLogEntryDTO]] = []
  private(set) var cursor: RxStreamCursor?
  private var shouldFailNextSave = false

  init(saveDelay: Duration = .zero) {
    self.saveDelay = saveDelay
  }

  var savedCount: Int {
    batches.reduce(0) { $0 + $1.count }
  }

  func failNextSave() {
    shouldFailNextSave = true
  }

  func saveRxLogEntries(_ dtos: [RxLogEntryDTO]) async throws {
    if saveDelay > .zero {
      try? await Task.sleep(for: saveDelay)
    }
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw InjectedSaveFailure()
    }
    batches.append(dtos)
  }

  func fetchRxStreamCursor(radioID _: UUID) async throws -> RxStreamCursor? {
    cursor
  }

  func saveRxStreamCursor(_ cursor: RxStreamCursor?, radioID _: UUID) async throws {
    self.cursor = cursor
  }
}

/// The session's RX_SYNC delivery as the RX log reads it: a contiguous mark the test sets, and
/// the replays asked for.
private actor FakeRxSyncOps: CairnRxSyncSessionOps {
  private(set) var replays: [ClosedRange<UInt32>] = []
  private var epoch: UInt32?
  private var contiguousSeq: UInt32?

  func setStats(epoch: UInt32, contiguousSeq: UInt32) {
    self.epoch = epoch
    self.contiguousSeq = contiguousSeq
  }

  func setCairnRxSync(
    on _: Bool, resumeEpoch _: UInt32, resumeSeq _: UInt32, resumeMax _: UInt16, timeout _: TimeInterval?
  ) async throws -> CairnRxSubscribeResult {
    throw MeshCoreError.timeout
  }

  func cairnRxSyncState(timeout _: TimeInterval?) async throws -> CairnRxSyncState {
    throw MeshCoreError.timeout
  }

  func beginRxSyncHold() {}

  func releaseRxSyncHold() async {}

  func expectRxBacklog(_: CairnRxBacklog) {}

  func requestRxReplay(from seq: UInt32, count: Int) -> Bool {
    replays.append(seq...(seq + UInt32(count) - 1))
    return true
  }

  var rxDeliveryStats: RxDeliveryStats {
    RxDeliveryStats(
      isActive: true, epoch: epoch, lastSeq: nil, delivered: 0, recovered: 0, lostAtRadio: 0,
      unrecovered: 0, missing: 0, duplicates: 0, contiguousSeq: contiguousSeq
    )
  }
}

/// Records the RX entries heard repeats checks, in order; no message matches.
private actor RecordingRepeatStore: HeardRepeatPersisting {
  private(set) var checkedEntryIDs: [UUID] = []

  func findSentChannelMessage(radioID _: UUID, channelIndex _: UInt8, timestamp _: UInt32, text _: String) async throws -> MessageDTO? {
    nil
  }

  func fetchMessage(deduplicationKey _: String, radioID _: UUID) async throws -> MessageDTO? {
    nil
  }

  func saveMessageRepeat(_: MessageRepeatDTO) async throws {}

  func fetchMessageRepeats(messageID _: UUID) async throws -> [MessageRepeatDTO] {
    []
  }

  func deleteMessageRepeats(messageID _: UUID) async throws {}

  func messageRepeatExists(rxLogEntryID: UUID) async throws -> Bool {
    checkedEntryIDs.append(rxLogEntryID)
    return false
  }

  func incrementMessageHeardRepeats(id _: UUID) async throws -> Int {
    0
  }

  func adoptIncomingPathIfUnknown(id _: UUID, pathNodes _: Data, pathLength _: UInt8) async throws -> Bool {
    false
  }

  func incrementMessageSendCount(id _: UUID) async throws -> Int {
    0
  }
}
