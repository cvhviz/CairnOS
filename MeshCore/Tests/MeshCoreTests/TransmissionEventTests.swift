import Foundation
@testable import MeshCore
import Testing

/// ``MeshCoreSession/transmissions()``: every command that makes the radio transmit, as it is
/// written, and the radio's own answer to it (stock `RESP_CODE_SENT` 0x06, `RESP_CODE_OK`,
/// `RESP_CODE_ERR`). Frames come from ``StockFirmwareFrames``; time is the session's test clock.
@Suite("Transmission events")
struct TransmissionEventTests {
  private static let ack: [UInt8] = [0x1A, 0x2B, 0x3C, 0x4D]
  private static let peer = Data((0..<32).map { UInt8(0xB0 &+ $0) })

  private struct Fixture {
    let session: MeshCoreSession
    let transport: StockTestTransport
    let clock: StockTestClock

    func waitForWrite(_ code: CommandCode, count: Int = 1) async throws {
      try await waitUntil("\(code) should be written") {
        await transport.sent(code: code.rawValue).count >= count
      }
    }
  }

  private func makeFixture(retransmit: TimeInterval? = 1.0) async throws -> Fixture {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(
        defaultTimeout: 5,
        clientIdentifier: "MeshCore-Tests",
        binaryRequestRetransmitInterval: retransmit
      ),
      clock: clock
    )
    let start = Task { try await session.start() }
    try await waitUntil("APP_START should be sent") {
      await !transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await transport.receive(StockFirmwareFrames.selfInfo)
    try await start.value
    await transport.clearSentData()
    return Fixture(session: session, transport: transport, clock: clock)
  }

  @Test
  func `two listeners both see the write and the radio's answer`() async throws {
    let fixture = try await makeFixture()
    let first = TransmissionCollector.collecting(await fixture.session.transmissions())
    let second = TransmissionCollector.collecting(await fixture.session.transmissions())

    let send = Task { try await fixture.session.sendChannelMessage(channel: 0, text: "hello", timestamp: Date(timeIntervalSince1970: 1_760_000_000)) }
    try await fixture.waitForWrite(.sendChannelMessage)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await send.value

    let written = await fixture.transport.sent(code: CommandCode.sendChannelMessage.rawValue).first
    for collector in [first, second] {
      try await waitUntil("both events should arrive") { await collector.events.count == 2 }
      let events = await collector.events
      guard case let .written(id, command, _) = events[0] else {
        Issue.record("Expected .written first, got \(events[0])")
        continue
      }
      #expect(command == written)
      #expect(events[1] == .answered(id: id, outcome: .ok))
    }
    await fixture.session.stop()
  }

  @Test
  func `a text send answered by RESP_CODE_SENT reports the route and expected ack`() async throws {
    let fixture = try await makeFixture()
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())
    let before = Date()

    let send = Task { try await fixture.session.sendMessage(to: Self.peer.prefix(6), text: "hi") }
    try await fixture.waitForWrite(.sendMessage)
    await fixture.transport.receive(StockFirmwareFrames.messageSent(ack: Self.ack, flood: true, timeoutMs: 7000))
    let info = try await send.value

    try await waitUntil("both events should arrive") { await collector.events.count == 2 }
    let events = await collector.events
    guard case let .written(id, command, at) = events[0] else {
      Issue.record("Expected .written first, got \(events[0])")
      await fixture.session.stop()
      return
    }
    #expect(command.first == CommandCode.sendMessage.rawValue)
    #expect(at >= before)
    #expect(events[1] == .answered(id: id, outcome: .sent(info)))
    guard case let .answered(_, .sent(sent)) = events[1] else {
      Issue.record("Expected .sent, got \(events[1])")
      await fixture.session.stop()
      return
    }
    #expect(sent.route == 1)
    #expect(sent.expectedAck == Data(Self.ack))
    #expect(sent.suggestedTimeoutMs == 7000)
    await fixture.session.stop()
  }

  @Test
  func `RESP_CODE_ERR reports the send rejected`() async throws {
    let fixture = try await makeFixture()
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())

    let send = Task { try await fixture.session.sendAdvertisement(flood: true) }
    try await fixture.waitForWrite(.sendAdvertisement)
    await fixture.transport.receive(StockFirmwareFrames.err(ErrorCode.tableFull.rawValue))
    await #expect(throws: MeshCoreError.self) { try await send.value }

    try await waitUntil("both events should arrive") { await collector.events.count == 2 }
    let events = await collector.events
    #expect(events[1] == .answered(id: events[0].id, outcome: .rejected(code: ErrorCode.tableFull.rawValue)))
    await fixture.session.stop()
  }

  @Test
  func `no answer reports the send unconfirmed`() async throws {
    let fixture = try await makeFixture()
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())

    let send = Task { try await fixture.session.sendMessage(to: Self.peer.prefix(6), text: "hi") }
    try await fixture.waitForWrite(.sendMessage)
    try await waitUntil("the wait should start") { fixture.clock.sleeperCount > 0 }
    fixture.clock.advance(by: .seconds(6))
    let error = await #expect(throws: MeshCoreError.self) { try await send.value }
    #expect(isTimeout(error))

    try await waitUntil("both events should arrive") { await collector.events.count == 2 }
    let events = await collector.events
    #expect(events[1] == .answered(id: events[0].id, outcome: .unconfirmed))
    await fixture.session.stop()
  }

  @Test
  func `a command the radio answers itself reports nothing`() async throws {
    let fixture = try await makeFixture()
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())

    let rename = Task { try await fixture.session.setName("Base") }
    try await fixture.waitForWrite(.setName)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await rename.value

    // A transmitting send after it is the first thing reported, with the first id.
    let advert = Task { try await fixture.session.sendAdvertisement(flood: false) }
    try await fixture.waitForWrite(.sendAdvertisement)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await advert.value

    try await waitUntil("the advert's events should arrive") { await collector.events.count == 2 }
    let events = await collector.events
    guard case let .written(id, command, _) = events[0] else {
      Issue.record("Expected .written first, got \(events[0])")
      await fixture.session.stop()
      return
    }
    #expect(id == 1)
    #expect(command.first == CommandCode.sendAdvertisement.rawValue)
    #expect(events[1] == .answered(id: 1, outcome: .ok))
    await fixture.session.stop()
  }

  @Test
  func `a binary request reports its write and RESP_CODE_SENT`() async throws {
    let fixture = try await makeFixture(retransmit: nil)
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())

    let request = Task { try await fixture.session.requestTelemetry(from: Self.peer) }
    try await fixture.waitForWrite(.getSelfTelemetry)
    await fixture.transport.receive(StockFirmwareFrames.messageSent(ack: Self.ack, flood: false))
    try await waitUntil("the answer should be paired") { await collector.events.count == 2 }
    // PUSH_CODE_TELEMETRY_RESPONSE: [0x8B][reserved][pub_key prefix 6][LPP]
    await fixture.transport.receive(Data([0x8B, 0x00]) + Self.peer.prefix(6))
    _ = try await request.value

    let events = await collector.events
    #expect(events.count == 2)
    guard case let .written(id, command, _) = events[0] else {
      Issue.record("Expected .written first, got \(events[0])")
      await fixture.session.stop()
      return
    }
    #expect(command.first == CommandCode.getSelfTelemetry.rawValue)
    #expect(events[1] == .answered(
      id: id,
      outcome: .sent(MessageSentInfo(route: 0, expectedAck: Data(Self.ack), suggestedTimeoutMs: 6000))
    ))
    await fixture.session.stop()
  }

  @Test
  func `a binary request that ends without an answer reports its write unconfirmed`() async throws {
    let fixture = try await makeFixture(retransmit: nil)
    let collector = TransmissionCollector.collecting(await fixture.session.transmissions())

    let request = Task { try await fixture.session.requestTelemetry(from: Self.peer) }
    try await fixture.waitForWrite(.getSelfTelemetry)
    try await waitUntil("the wait should start") { fixture.clock.sleeperCount > 0 }
    fixture.clock.advance(by: .seconds(41))
    await #expect(throws: MeshCoreError.self) { try await request.value }

    try await waitUntil("both events should arrive") { await collector.events.count == 2 }
    let events = await collector.events
    #expect(events[1] == .answered(id: events[0].id, outcome: .unconfirmed))
    await fixture.session.stop()
  }

  @Test
  func `the streams end when the session stops`() async throws {
    let fixture = try await makeFixture()
    let stream = await fixture.session.transmissions()
    let drained = Task {
      var count = 0
      for await _ in stream { count += 1 }
      return count
    }
    await fixture.session.stop()
    #expect(await drained.value == 0)
  }

  // MARK: - Pairing

  @Test
  func `retransmit answers pair with writes in order, even an answer that comes first`() {
    var pairing = TransmissionAnswerPairing()
    #expect(pairing.wrote(1) == nil)
    #expect(pairing.wrote(2) == nil)
    #expect(pairing.answered(.rejected(code: 3)) == 1)
    #expect(pairing.answered(.ok) == 2)
    // an answer before its write is held for it
    #expect(pairing.answered(.unconfirmed) == nil)
    #expect(pairing.wrote(3) == .unconfirmed)
    #expect(pairing.wrote(4) == nil)
    #expect(pairing.finish() == [4])
    #expect(pairing.finish().isEmpty)
  }

  @Test
  func `outcomes map from exchange results`() {
    let info = MessageSentInfo(route: 1, expectedAck: Data(Self.ack), suggestedTimeoutMs: 100)
    #expect(TransmissionOutcome.answering(info) == .sent(info))
    #expect(TransmissionOutcome.answering(true) == .ok)
    #expect(TransmissionOutcome.failing(MeshCoreError.deviceError(code: 2)) == .rejected(code: 2))
    #expect(TransmissionOutcome.failing(MeshCoreError.timeout) == .unconfirmed)
    #expect(TransmissionOutcome.failing(CancellationError()) == .unconfirmed)
  }
}

/// Collects one ``MeshCoreSession/transmissions()`` stream.
private actor TransmissionCollector {
  private(set) var events: [TransmissionEvent] = []

  /// Starts collecting `stream`.
  static func collecting(_ stream: AsyncStream<TransmissionEvent>) -> TransmissionCollector {
    let collector = TransmissionCollector()
    Task {
      for await event in stream {
        await collector.append(event)
      }
    }
    return collector
  }

  private func append(_ event: TransmissionEvent) {
    events.append(event)
  }
}
