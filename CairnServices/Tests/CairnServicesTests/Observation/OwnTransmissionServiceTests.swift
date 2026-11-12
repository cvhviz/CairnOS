@testable import CairnServices
import Foundation
import MeshCore
import os
import Testing

@Suite("Own transmission service")
struct OwnTransmissionServiceTests {
  private typealias F = OwnTransmissionFixtures

  /// A clock tests move by hand.
  private final class Clock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: OwnTransmissionFixtures.base)
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
  }

  /// A started service, its mock session, and a reader of its snapshots past the current one.
  private struct Harness {
    let session: MockMeshCoreSession
    let service: OwnTransmissionService
    let clock: Clock
    var snapshots: AsyncStream<[OwnTransmission]>.Iterator

    /// Emits `event` and returns the snapshot it produced.
    mutating func emit(_ event: TransmissionEvent) async -> [OwnTransmission]? {
      await session.emitTransmission(event)
      return await snapshots.next()
    }
  }

  private func harness(radioID: UUID = UUID()) async -> Harness {
    let session = MockMeshCoreSession()
    let clock = Clock()
    let service = OwnTransmissionService(session: session, now: { clock.now })
    await service.start(radioID: radioID)
    var snapshots = service.transmissions().makeAsyncIterator()
    _ = await snapshots.next() // the current (empty) list
    return Harness(session: session, service: service, clock: clock, snapshots: snapshots)
  }

  private static func dmCommand(_ text: String = "hi") -> Data {
    PacketBuilder.sendMessage(to: F.peerKey, text: text, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
  }

  private static func channelCommand(_ text: String = "hello all") -> Data {
    PacketBuilder.sendChannelMessage(channel: 1, text: text, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test
  func `a write and the radio's sent answer record the route and the ack it expects`() async throws {
    var h = await harness()
    let written = try #require(await h.emit(.written(id: 1, command: Self.dmCommand(), at: F.base)))
    #expect(written.count == 1)
    #expect(written.first?.kind == .directMessage && written.first?.outcome == nil && written.first?.writtenAt == F.base)

    let info = MessageSentInfo(route: 1, expectedAck: Data([0xA1, 0xA2, 0xA3, 0xA4]), suggestedTimeoutMs: 4000)
    let answered = try #require(await h.emit(.answered(id: 1, outcome: .sent(info))))
    let send = try #require(answered.first)
    #expect(send.outcome == .sent(info))
    #expect(send.route == .flood)
    #expect(send.radioExpectedAck == Data([0xA1, 0xA2, 0xA3, 0xA4]))

    // Its ack, as the radio said to expect it, answers it.
    let ack = F.entry(.ack, payload: [0xA1, 0xA2, 0xA3, 0xA4])
    #expect(await h.service.match(ack, selfKey: F.radioKey) == EchoMatch(sendID: send.id, confidence: .exact, relation: .answer))
  }

  @Test
  func `a send left unanswered when the session stops is marked unconfirmed, never pending`() async throws {
    var h = await harness()
    _ = await h.emit(.written(id: 1, command: Self.dmCommand(), at: F.base))
    // The session stops before the radio answers: its stream ends with the write still owed
    await h.session.finishTransmissionStreams()
    let ended = try #require(await h.snapshots.next())
    #expect(ended.first?.outcome == .unconfirmed)
  }

  @Test
  func `a send left unanswered at stop or a new start is marked unconfirmed`() async throws {
    var h = await harness()
    _ = await h.emit(.written(id: 1, command: Self.dmCommand(), at: F.base))
    await h.service.stop()
    let stopped = try #require(await h.snapshots.next())
    #expect(stopped.first?.outcome == .unconfirmed)

    // An answered send keeps its answer across a restart
    let radioID = UUID()
    var again = await harness(radioID: radioID)
    _ = await again.emit(.written(id: 1, command: Self.channelCommand(), at: F.base))
    _ = await again.emit(.answered(id: 1, outcome: .ok))
    _ = await again.emit(.written(id: 2, command: Self.dmCommand(), at: F.base))
    await again.service.start(radioID: radioID)
    let restarted = try #require(await again.snapshots.next())
    #expect(restarted.map(\.outcome) == [.ok, .unconfirmed])
  }

  @Test
  func `a command the radio refused is marked rejected and never matches`() async throws {
    var h = await harness()
    _ = await h.emit(.written(id: 4, command: Self.channelCommand(), at: F.base))
    let refused = try #require(await h.emit(.answered(id: 4, outcome: .rejected(code: 2))))
    #expect(refused.first?.isRejected == true)
    #expect(await h.service.match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000), selfKey: F.radioKey) == nil)
  }

  @Test
  func `a command that sends nothing over the air is not recorded`() async {
    var h = await harness()
    await h.session.emitTransmission(.written(id: 1, command: PacketBuilder.sendLogout(to: F.peerKey), at: F.base))
    let next = await h.emit(.written(id: 2, command: Self.channelCommand(), at: F.base))
    #expect(next?.map(\.kind) == [.channelMessage])
  }

  @Test
  func `echoes are looked for only within 120 seconds of the send`() async {
    var h = await harness()
    _ = await h.emit(.written(id: 1, command: Self.channelCommand(), at: F.base))
    let inside = F.channelEcho(text: "hello all", timestamp: 1_700_000_000, at: F.base.addingTimeInterval(100))
    #expect(await h.service.match(inside, selfKey: F.radioKey)?.confidence == .exact)
    let outside = F.channelEcho(text: "hello all", timestamp: 1_700_000_000, variant: 1, at: F.base.addingTimeInterval(200))
    #expect(await h.service.match(outside, selfKey: F.radioKey) == nil)
  }

  @Test
  func `an exact echo is remembered by its hash, for copies and for hears-you`() async throws {
    var h = await harness()
    _ = await h.emit(.written(id: 1, command: Self.dmCommand("ping"), at: F.base))
    let echo = F.entry(
      .textMessage, path: [0xAA], payload: F.dmPayload(to: F.peerHash, from: F.radioHash),
      decryptStatus: .success, senderTimestamp: 1_800_000_000, decodedText: "ping", peerPublicKey: F.peerKey
    )
    h.clock.set(F.base.addingTimeInterval(5))
    #expect(await h.service.match(echo, selfKey: F.radioKey)?.confidence == .exact)
    let proven = try #require(await h.snapshots.next())
    #expect(proven.first?.provenPacketHashes == [echo.packetHash])
    #expect(await h.service.recentOwnPacketHashes() == [echo.packetHash])

    // A copy by another path, not decrypted, is known by the hash.
    let copy = F.entry(.textMessage, path: [0xCC], payload: F.dmPayload(to: F.peerHash, from: F.radioHash), decryptStatus: .dmNoMatchingKey)
    #expect(await h.service.match(copy, selfKey: F.radioKey)?.confidence == .exact)

    h.clock.set(F.base.addingTimeInterval(600))
    #expect(await h.service.recentOwnPacketHashes().isEmpty, "Sent ten minutes ago")
  }

  @Test
  func `the ring keeps the newest 256 sends`() async {
    var h = await harness()
    var last: [OwnTransmission]?
    for id in UInt64(1)...300 {
      last = await h.emit(.written(id: id, command: Self.channelCommand("m\(id)"), at: F.base))
    }
    #expect(last?.count == OwnTransmissionService.capacity)
    #expect(last?.first?.text == "m45")
    #expect(last?.last?.text == "m300")
    // An answer to a write that gave way changes nothing; one to a kept write applies.
    await h.session.emitTransmission(.answered(id: 1, outcome: .ok))
    let applied = await h.emit(.answered(id: 300, outcome: .ok))
    #expect(applied?.last?.outcome == .ok)
    #expect(applied?.filter { $0.outcome != nil }.count == 1)
  }

  @Test
  func `another radio starts an empty ring, the same radio keeps it`() async {
    let radio = UUID()
    var h = await harness(radioID: radio)
    _ = await h.emit(.written(id: 1, command: Self.channelCommand(), at: F.base))

    // A reconnect of the same radio: the session counts its writes from 1 again. The old write
    // was never answered, so it is unconfirmed now.
    await h.service.stop()
    #expect(await h.snapshots.next()?.map(\.outcome) == [.unconfirmed])
    await h.service.start(radioID: radio)
    #expect(await h.service.currentTransmissions.count == 1)
    let afterReconnect = await h.emit(.written(id: 1, command: Self.dmCommand(), at: F.base))
    #expect(afterReconnect?.map(\.kind) == [.channelMessage, .directMessage])
    let answered = await h.emit(.answered(id: 1, outcome: .ok))
    #expect(answered?.map(\.outcome) == [.unconfirmed, .ok], "The answer is the new write's, not the old one's")

    await h.service.start(radioID: UUID())
    #expect(await h.snapshots.next()?.isEmpty == true)
    #expect(await h.service.currentTransmissions.isEmpty)
  }

  @Test
  func `a message sent from the radio's own UI and a path discovery are recorded`() async throws {
    var h = await harness()
    let message = RadioSentMessage(
      isLive: true, kind: .channel, destination: Data([1, 0, 0, 0, 0, 0]),
      timestamp: 1_700_000_000, ackCode: 0, isDelivered: false, text: "hello all"
    )
    let send = try #require(await h.service.record(radioSent: message, at: F.base))
    #expect(await h.snapshots.next()?.map(\.id) == [send.id])
    #expect(await h.service.match(F.channelEcho(text: "hello all", timestamp: 1_700_000_000), selfKey: F.radioKey)?.sendID == send.id)

    var discoveries = h.service.pathDiscoveryEvents().makeAsyncIterator()
    let discovery = OwnPathDiscovery(contactPrefix: Data(F.peerKey.prefix(6)), outHops: [Data([0xAA])], inHops: [], at: F.base)
    await h.service.recordDiscovery(discovery)
    #expect(await discoveries.next() == discovery)
    #expect(await h.service.pathDiscoveries == [discovery])
  }

  @Test
  func `finishing the streams ends every subscriber`() async {
    let h = await harness()
    var stream = h.service.transmissions().makeAsyncIterator()
    _ = await stream.next()
    h.service.finishStreams()
    #expect(await stream.next() == nil)
  }
}
