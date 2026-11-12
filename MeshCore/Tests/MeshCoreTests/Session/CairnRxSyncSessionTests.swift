import Foundation
@testable import MeshCore
import Testing

@Suite("Cairn RX_SYNC session delivery")
struct CairnRxSyncSessionTests {
  private static let epoch: UInt32 = 0xDEAD_BEEF

  @Test
  func `a gap is fetched and every record is delivered exactly once`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)

    for seq: UInt32 in [1, 2, 5] {
      await transport.simulateReceive(record(seq: seq))
    }
    try await waitUntil("the gap should be fetched") { await transport.sentData.count == 3 }
    #expect(await transport.sentData[2] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 2, max: 2))

    await transport.simulateReceive(fetchReply(first: 1, last: 5, count: 2))
    await transport.simulateReceive(record(seq: 3, flags: 0x01))
    await transport.simulateReceive(record(seq: 4, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 5, sent: 2))
    // a live repeat of a record already delivered
    await transport.simulateReceive(record(seq: 5))

    try await waitUntil("five records should arrive") { await collector.records.count == 5 }
    try await Task.sleep(for: .milliseconds(400))
    let records = await collector.records
    #expect(records.map(\.seq) == [1, 2, 5, 3, 4])
    #expect(records.map(\.isBackfill) == [false, false, false, true, true])
    #expect(records.allSatisfy { $0.epoch == Self.epoch && $0.radioAge == .milliseconds(250) })
    #expect(records.map(\.packetPayload) == [UInt8]([1, 2, 5, 3, 4]).map { Data([$0]) })

    let stats = await session.rxDeliveryStats
    #expect(stats.isActive)
    #expect(stats.epoch == Self.epoch)
    #expect(stats.lastSeq == 5)
    #expect(stats.delivered == 5)
    #expect(stats.recovered == 2)
    #expect(stats.missing == 0)
    #expect(stats.duplicates == 1)
    // nothing else was asked for
    #expect(await transport.sentData.count == 3)
    await session.stop()
  }

  @Test
  func `a 255-byte packet split over MORE and CONT is delivered whole`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)

    let raw = Data([0x15, 0x00]) + Data((0..<253).map { UInt8($0 & 0xFF) })
    #expect(raw.count == 255)
    var head = Data([0xC8, 0x02]) + le32(1) + le32(250) + Data([0x14, 0xA6])
    head.append(raw.prefix(160))
    var tail = Data([0xC8, 0x04]) + le32(1) + Data([160])
    tail.append(raw.suffix(95))
    await transport.simulateReceive(head)
    await transport.simulateReceive(tail)

    try await waitUntil("the packet should arrive") { await collector.records.count == 1 }
    let records = await collector.records
    #expect(records.first?.rawPayload == raw)
    #expect(records.first?.seq == 1)
    #expect(records.first?.snr == 5)
    #expect(records.first?.rssi == -90)
    #expect(await session.rxDeliveryStats.missing == 0)
    await session.stop()
  }

  @Test
  func `unsupported on SUBSCRIBE leaves the link on stock 0x88 frames`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)

    let task = Task {
      try await session.setCairnRxSync(on: true, resumeEpoch: 0, resumeSeq: 0, resumeMax: 512)
    }
    try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == 2 }
    // a 0x88 frame while the answer is pending is held, then passed on
    await transport.simulateReceive(stockFrame(payloadByte: 9))
    await transport.simulateError(code: ErrorCode.unsupportedCommand.rawValue)

    let error = await #expect(throws: MeshCoreError.self) { try await task.value }
    #expect(error?.deviceErrorCode == .unsupportedCommand)

    await transport.simulateReceive(stockFrame(payloadByte: 10))
    try await waitUntil("both 0x88 frames should arrive") { await collector.records.count == 2 }
    let records = await collector.records
    #expect(records.map(\.packetPayload) == [Data([9]), Data([10])])
    #expect(records.allSatisfy { $0.seq == nil && $0.epoch == nil && !$0.isBackfill })
    #expect(await session.rxDeliveryStats.isActive == false)

    // an APP_START now asks for nothing more
    let refresh = Task { try await session.sendAppStart() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(makeRxSelfInfoPacket())
    _ = try await refresh.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.sentData.count == 3)
    await session.stop()
  }

  @Test
  func `APP_START renews the SUBSCRIBE after the last record, and frames sent meanwhile come once`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)
    await transport.simulateReceive(record(seq: 1))
    await transport.simulateReceive(record(seq: 2))
    try await waitUntil("two records should arrive") { await collector.records.count == 2 }

    let refresh = Task { try await session.sendAppStart() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count == 3 }
    await transport.simulateReceive(makeRxSelfInfoPacket())
    _ = try await refresh.value
    try await waitUntil("the opt-in should be renewed") { await transport.sentData.count == 4 }
    #expect(await transport.sentData[3]
      == PacketBuilder.cairnRxSyncSubscribe(on: true, resumeEpoch: Self.epoch, resumeSeq: 2, resumeMax: 512))

    // the radio sends packet 3 as a stock frame before it has the renewal, then again as a record
    await transport.simulateReceive(stockFrame(payloadByte: 3))
    await transport.simulateReceive(subscribeReply(resumed: true, first: 1, last: 3, cursor: 3))
    await transport.simulateReceive(record(seq: 3))

    try await waitUntil("the third record should arrive") { await collector.records.count == 3 }
    try await Task.sleep(for: .milliseconds(100))
    let records = await collector.records
    #expect(records.map(\.seq) == [1, 2, 3])
    #expect(await session.rxDeliveryStats.isActive)
    await session.stop()
  }

  @Test
  func `0x88 frames held for a SUBSCRIBE that starts live are passed on before the records`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)

    let task = Task {
      try await session.setCairnRxSync(on: true, resumeEpoch: 0, resumeSeq: 0, resumeMax: 512)
    }
    try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(stockFrame(payloadByte: 7))
    await transport.simulateReceive(subscribeReply(resumed: false, first: 1, last: 40, cursor: 41))
    await transport.simulateReceive(record(seq: 41))
    let result = try await task.value
    #expect(result.isOn)
    #expect(result.cursor == 41)

    try await waitUntil("both should arrive") { await collector.records.count == 2 }
    let records = await collector.records
    #expect(records.map(\.seq) == [nil, 41])
    #expect(await session.rxDeliveryStats.lostAtRadio == 0)
    await session.stop()
  }

  @Test
  func `a replay sends delivered records again, marked backfill`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    #expect(await session.requestRxReplay(from: 1, count: 2) == false)
    try await subscribe(session, transport, cursor: 1)
    for seq: UInt32 in [1, 2, 3] {
      await transport.simulateReceive(record(seq: seq))
    }
    try await waitUntil("three records should arrive") { await collector.records.count == 3 }

    #expect(await session.requestRxReplay(from: 2, count: 2))
    try await waitUntil("the replay should be fetched") { await transport.sentData.count == 3 }
    #expect(await transport.sentData[2] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 1, max: 2))
    await transport.simulateReceive(fetchReply(first: 1, last: 3, count: 2))
    await transport.simulateReceive(record(seq: 2, flags: 0x01))
    await transport.simulateReceive(record(seq: 3, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 3, sent: 2))
    // the same backfill again is not a replay any more
    await transport.simulateReceive(record(seq: 3, flags: 0x01))

    try await waitUntil("the replay should arrive") { await collector.records.count == 5 }
    try await Task.sleep(for: .milliseconds(100))
    let records = await collector.records
    #expect(records.map(\.seq) == [1, 2, 3, 2, 3])
    #expect(records.map(\.isBackfill) == [false, false, false, true, true])
    await session.stop()
  }

  @Test
  func `a GAP flag counts the overwritten records lost and fetches nothing`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)
    await transport.simulateReceive(record(seq: 1))
    await transport.simulateReceive(record(seq: 6, flags: 0x08))

    try await waitUntil("two records should arrive") { await collector.records.count == 2 }
    try await Task.sleep(for: .milliseconds(400))
    #expect(await session.rxDeliveryStats.lostAtRadio == 4)
    #expect(await transport.sentData.count == 2)
    await session.stop()
  }

  @Test
  func `a FETCH with no records still waits for its FETCH_END, and the next FETCH waits for it too`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)
    await transport.simulateReceive(record(seq: 1))
    await transport.simulateReceive(record(seq: 4))
    try await waitUntil("the gap should be fetched") { await transport.sentData.count == 3 }
    // the journal no longer holds 2 and 3: no records, and the FETCH_END comes on a later pump
    await transport.simulateReceive(fetchReply(first: 4, last: 4, count: 0))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await session.rxDeliveryStats.lostAtRadio == 2)

    // a new gap while that FETCH_END is still owed: no FETCH goes out until it arrives
    await transport.simulateReceive(record(seq: 7))
    try await Task.sleep(for: .milliseconds(600))
    #expect(await transport.sentData.count == 3)
    await transport.simulateReceive(fetchEnd(first: 4, last: 4, sent: 0))
    try await waitUntil("the second gap should be fetched") { await transport.sentData.count == 4 }
    #expect(await transport.sentData[3] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 4, max: 2))

    // the second FETCH ends on its own FETCH_END, after its records
    await transport.simulateReceive(fetchReply(first: 4, last: 7, count: 2))
    await transport.simulateReceive(record(seq: 5, flags: 0x01))
    await transport.simulateReceive(record(seq: 6, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 4, last: 7, sent: 2))
    try await waitUntil("every record should arrive") { await collector.records.count == 5 }
    try await Task.sleep(for: .milliseconds(400))
    let stats = await session.rxDeliveryStats
    #expect(stats.recovered == 2)
    #expect(stats.unrecovered == 0)
    #expect(stats.missing == 0)
    #expect(await transport.sentData.count == 4)
    await session.stop()
  }

  @Test
  func `another link's APP_START, answered on this link too, renews nothing`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    try await subscribe(session, transport, cursor: 1)
    await transport.simulateReceive(record(seq: 1))

    // a stock app on USB sent APP_START: the radio's selfInfo reaches every link
    await transport.simulateReceive(makeRxSelfInfoPacket())
    await transport.simulateReceive(record(seq: 2))
    try await waitUntil("both records should arrive") { await collector.records.count == 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await transport.sentData.count == 2)
    #expect(await session.rxDeliveryStats.isActive)
    await session.stop()
  }

  @Test
  func `0x88 frames held from the probe on are dropped when the resumed journal sends them again`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)

    // the probe starts holding before STATE; a packet heard meanwhile comes as a stock frame
    await session.beginRxSyncHold()
    await transport.simulateReceive(stockFrame(payloadByte: 3))
    let task = Task {
      try await session.setCairnRxSync(on: true, resumeEpoch: Self.epoch, resumeSeq: 2, resumeMax: 512)
    }
    try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(subscribeReply(resumed: true, first: 1, last: 3, cursor: 3))
    await transport.simulateReceive(record(seq: 3))
    _ = try await task.value

    try await waitUntil("the record should arrive") { await collector.records.count == 1 }
    try await Task.sleep(for: .milliseconds(100))
    let records = await collector.records
    #expect(records.map(\.seq) == [3])
    await session.stop()
  }

  @Test
  func `frames held for a probe that fails are passed on`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    await session.beginRxSyncHold()
    await transport.simulateReceive(stockFrame(payloadByte: 9))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await collector.records.isEmpty)

    await session.releaseRxSyncHold()
    await transport.simulateReceive(stockFrame(payloadByte: 10))
    try await waitUntil("both frames should arrive") { await collector.records.count == 2 }
    #expect(await collector.records.map(\.packetPayload) == [Data([9]), Data([10])])
    await session.stop()
  }

  @Test
  func `the backlog a resumed SUBSCRIBE sends is delivered as backfill`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    let task = Task {
      try await session.setCairnRxSync(on: true, resumeEpoch: Self.epoch, resumeSeq: 2, resumeMax: 512)
    }
    try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(subscribeReply(resumed: true, first: 1, last: 5, cursor: 3))
    for seq: UInt32 in [3, 4, 5, 6] {
      await transport.simulateReceive(record(seq: seq))
    }
    _ = try await task.value

    try await waitUntil("four records should arrive") { await collector.records.count == 4 }
    let records = await collector.records
    #expect(records.map(\.seq) == [3, 4, 5, 6])
    #expect(records.map(\.isBackfill) == [true, true, true, false])
    await session.stop()
  }

  @Test
  func `the contiguous mark stops below a record still being fetched`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    try await subscribe(session, transport, cursor: 1)
    #expect(await session.rxDeliveryStats.contiguousSeq == 0)
    for seq: UInt32 in [1, 2, 5] {
      await transport.simulateReceive(record(seq: seq))
    }
    try await waitUntil("the gap should be fetched") { await transport.sentData.count == 3 }
    #expect(await session.rxDeliveryStats.lastSeq == 5)
    #expect(await session.rxDeliveryStats.contiguousSeq == 2)

    await transport.simulateReceive(fetchReply(first: 1, last: 5, count: 2))
    await transport.simulateReceive(record(seq: 3, flags: 0x01))
    await transport.simulateReceive(record(seq: 4, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 5, sent: 2))
    try await waitUntil("the gap should fill") { await session.rxDeliveryStats.contiguousSeq == 5 }
    await session.stop()
  }

  /// A resumed SUBSCRIBE that got no reply is sent again live (its held frames were passed on):
  /// the records it would have resumed with, heard before those frames, are fetched instead.
  @Test
  func `a live retry fetches the catch-up its lost resume would have sent, as backfill`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    await session.beginRxSyncHold()
    await session.expectRxBacklog(CairnRxBacklog(epoch: Self.epoch, afterSeq: 2, throughSeq: 4, limit: 512))
    try await subscribe(session, transport, cursor: 7)
    #expect(await session.rxDeliveryStats.contiguousSeq == 2, "the cursor can't pass the catch-up")
    await transport.simulateReceive(record(seq: 7))

    try await waitUntil("the catch-up should be fetched") { await transport.sentData.count == 3 }
    #expect(await transport.sentData[2] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 2, max: 2))
    await transport.simulateReceive(fetchReply(first: 1, last: 7, count: 2))
    await transport.simulateReceive(record(seq: 3, flags: 0x01))
    await transport.simulateReceive(record(seq: 4, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 7, sent: 2))

    try await waitUntil("three records should arrive") { await collector.records.count == 3 }
    let records = await collector.records
    #expect(records.map(\.seq) == [7, 3, 4])
    #expect(records.map(\.isBackfill) == [false, true, true])
    let stats = await session.rxDeliveryStats
    #expect(stats.recovered == 2)
    #expect(stats.lostAtRadio == 0)
    #expect(stats.contiguousSeq == 7)
    await session.stop()
  }

  @Test
  func `records the radio pushed behind a lost reply are not owed again`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    // the first SUBSCRIBE resumed after 2; its reply was lost but the radio sent its backlog
    await transport.simulateReceive(record(seq: 3))
    await transport.simulateReceive(record(seq: 4))
    await session.beginRxSyncHold()
    await session.expectRxBacklog(CairnRxBacklog(epoch: Self.epoch, afterSeq: 2, throughSeq: 4, limit: 512))
    try await subscribe(session, transport, cursor: 5)

    try await Task.sleep(for: .milliseconds(400))
    #expect(await session.rxDeliveryStats.missing == 0)
    #expect(await transport.sentData.count == 2, "no FETCH")
    await session.stop()
  }

  @Test
  func `a gap behind a lost reply and the records a live retry skipped are fetched`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    let collector = try await RxCollector(session: session)
    // the first SUBSCRIBE resumed after 2; its reply was lost, and of its pushes 4 was dropped
    await transport.simulateReceive(record(seq: 3))
    await transport.simulateReceive(record(seq: 5))
    try await waitUntil("two records should arrive") { await collector.records.count == 2 }
    await session.beginRxSyncHold()
    await session.expectRxBacklog(CairnRxBacklog(epoch: Self.epoch, afterSeq: 2, throughSeq: 4, limit: 512))
    // the retry starts live after 7: 6 and 7 were never pushed
    try await subscribe(session, transport, cursor: 8)
    #expect(await session.rxDeliveryStats.missing == 3)
    #expect(await session.rxDeliveryStats.contiguousSeq == 3, "the cursor can't pass the gap")

    try await waitUntil("the gap should be fetched") { await transport.sentData.count == 3 }
    #expect(await transport.sentData[2] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 3, max: 1))
    await transport.simulateReceive(fetchReply(first: 1, last: 7, count: 1))
    await transport.simulateReceive(record(seq: 4, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 7, sent: 1))

    try await waitUntil("the skipped records should be fetched") { await transport.sentData.count == 4 }
    #expect(await transport.sentData[3] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 5, max: 2))
    await transport.simulateReceive(fetchReply(first: 1, last: 7, count: 2))
    await transport.simulateReceive(record(seq: 6, flags: 0x01))
    await transport.simulateReceive(record(seq: 7, flags: 0x01))
    await transport.simulateReceive(fetchEnd(first: 1, last: 7, sent: 2))

    try await waitUntil("five records should arrive") { await collector.records.count == 5 }
    #expect(await collector.records.map(\.seq) == [3, 5, 4, 6, 7])
    let stats = await session.rxDeliveryStats
    #expect(stats.recovered == 3)
    #expect(stats.lostAtRadio == 0)
    #expect(stats.missing == 0)
    #expect(stats.contiguousSeq == 7)
    await session.stop()
  }

  @Test
  func `records behind a lost reply the journal no longer holds count lost`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    await transport.simulateReceive(record(seq: 3))
    await transport.simulateReceive(record(seq: 5))
    await session.beginRxSyncHold()
    // by the retry's reply the journal holds only 7...9
    let task = Task {
      try await session.setCairnRxSync(on: true, resumeEpoch: 0, resumeSeq: 0, resumeMax: 512)
    }
    try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == 2 }
    await transport.simulateReceive(subscribeReply(resumed: false, first: 7, last: 9, cursor: 10))
    _ = try await task.value

    var stats = await session.rxDeliveryStats
    #expect(stats.lostAtRadio == 2, "4 and 6 were overwritten")
    #expect(stats.missing == 3)
    #expect(stats.contiguousSeq == 6)
    try await waitUntil("the rest should be fetched") { await transport.sentData.count == 3 }
    #expect(await transport.sentData[2] == PacketBuilder.cairnRxSyncFetch(sinceSeq: 6, max: 3))
    await transport.simulateReceive(fetchReply(first: 7, last: 9, count: 3))
    for seq: UInt32 in [7, 8, 9] {
      await transport.simulateReceive(record(seq: seq, flags: 0x01))
    }
    await transport.simulateReceive(fetchEnd(first: 7, last: 9, sent: 3))
    try await waitUntil("the gap should fill") { await session.rxDeliveryStats.contiguousSeq == 9 }
    stats = await session.rxDeliveryStats
    #expect(stats.lostAtRadio == 2)
    #expect(stats.recovered == 3)
    await session.stop()
  }

  @Test
  func `a backlog expected for a SUBSCRIBE that fails is dropped`() async throws {
    let (session, transport) = try await makeStartedRxSession()
    await session.beginRxSyncHold()
    await session.expectRxBacklog(CairnRxBacklog(epoch: Self.epoch, afterSeq: 2, throughSeq: 4, limit: 512))
    await session.releaseRxSyncHold()
    try await subscribe(session, transport, cursor: 7)
    #expect(await session.rxDeliveryStats.missing == 0)
    await session.stop()
  }
}

// MARK: - Helpers

/// Collects the session's rxLogData events from before the test feeds any frame.
private actor RxCollector {
  private(set) var records: [ParsedRxLogData] = []
  private var task: Task<Void, Never>?

  init(session: MeshCoreSession) async throws {
    let before = await session.subscriberCountForTest
    let events = await session.events(filter: .rxLogData, buffering: .bufferingNewest(4096), label: "test")
    try await waitUntil("the collector should subscribe") { await session.subscriberCountForTest > before }
    task = Task { [weak self] in
      for await event in events {
        if case let .rxLogData(data) = event { await self?.append(data) }
      }
    }
  }

  private func append(_ data: ParsedRxLogData) {
    records.append(data)
  }
}

/// Opts the link in, with the radio answering live from `cursor`.
private func subscribe(_ session: MeshCoreSession, _ transport: MockTransport, cursor: UInt32) async throws {
  let sentBefore = await transport.sentData.count
  let task = Task {
    try await session.setCairnRxSync(on: true, resumeEpoch: 0, resumeSeq: 0, resumeMax: 512)
  }
  try await waitUntil("SUBSCRIBE should be sent") { await transport.sentData.count == sentBefore + 1 }
  #expect(await transport.sentData[sentBefore]
    == PacketBuilder.cairnRxSyncSubscribe(on: true, resumeEpoch: 0, resumeSeq: 0, resumeMax: 512))
  await transport.simulateReceive(subscribeReply(resumed: false, first: 1, last: cursor &- 1, cursor: cursor))
  let result = try await task.value
  #expect(result.isOn)
}

/// A first frame of a whole record: a flood advert whose one payload byte is the low byte of `seq`.
private func record(seq: UInt32, flags: UInt8 = 0) -> Data {
  Data([0xC8, flags]) + le32(seq) + le32(250) + Data([0x14, 0xA6, 0x11, 0x00, UInt8(seq & 0xFF)])
}

/// A stock 0x88 frame of a flood advert with one payload byte.
private func stockFrame(payloadByte: UInt8) -> Data {
  Data([0x88, 0x14, 0xA6, 0x11, 0x00, payloadByte])
}

private func subscribeReply(resumed: Bool, first: UInt32, last: UInt32, cursor: UInt32) -> Data {
  Data([0xC0, 0x07, 0x00, 0x01, 0x01, resumed ? 1 : 0]) + le32(0xDEAD_BEEF) + le32(first) + le32(last) + le32(cursor)
}

private func fetchReply(first: UInt32, last: UInt32, count: UInt8) -> Data {
  Data([0xC0, 0x07, 0x00, 0x02]) + le32(first) + le32(last) + Data([count])
}

private func fetchEnd(first: UInt32, last: UInt32, sent: UInt8) -> Data {
  Data([0xC9, 0x00]) + le32(0xDEAD_BEEF) + le32(first) + le32(last) + Data([sent])
}

private func le32(_ value: UInt32) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func makeStartedRxSession() async throws -> (MeshCoreSession, MockTransport) {
  let transport = MockTransport()
  let session = MeshCoreSession(
    transport: transport,
    configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
  )
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeRxSelfInfoPacket())
  try await startTask.value
  return (session, transport)
}

private func makeRxSelfInfoPacket() -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1) // adv type
  payload.append(UInt8(bitPattern: 22)) // tx power
  payload.append(UInt8(bitPattern: 22)) // max tx power
  payload.append(Data(repeating: 0x01, count: 32)) // pubkey
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
  payload.append(0) // multi acks
  payload.append(0) // adv loc policy
  payload.append(0) // telemetry mode
  payload.append(0) // manual add
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
  payload.append(11) // sf
  payload.append(5) // cr
  return payload
}
