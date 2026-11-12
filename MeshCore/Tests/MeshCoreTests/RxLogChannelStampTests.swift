import Foundation
@testable import MeshCore
import Testing

/// Every received packet is stamped with the channel the radio reported in `SELF_INFO`, and only
/// when the session can vouch for it. Frames are stock companion frames (``StockFirmwareFrames``);
/// time is the session's test clock.
@Suite("RX log channel stamp")
struct RxLogChannelStampTests {
  /// ``StockFirmwareFrames/selfInfo``: 910.525 MHz, 62.5 kHz, SF7, CR5.
  private static let stockChannel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
  private static let newChannel = RadioChannelConfig(frequencyKHz: 869_618, bandwidthHz: 250_000, spreadingFactor: 11, codingRate: 5)
  private static let newSelfInfo = stockSelfInfoFrame(frequencyKHz: 869_618, bandwidthHz: 250_000, sf: 11, cr: 5)
  private static let advert = StockFirmwareFrames.packet(payloadType: 0x04, route: StockFirmwareFrames.routeFlood, path: [0x7F], payload: [0x01, 0x02])

  private struct Fixture {
    let session: MeshCoreSession
    let transport: StockTestTransport
    let clock: StockTestClock
    let recorder: EventRecorder
    let recording: Task<Void, Never>

    /// Feeds `frame` and returns the packet it was dispatched as.
    func hear(_ frame: Data) async throws -> ParsedRxLogData {
      let before = await packets.count
      await transport.receive(frame)
      try await waitUntil("the frame should be dispatched") { await packets.count > before }
      return try #require(await packets.last)
    }

    var packets: [ParsedRxLogData] {
      get async {
        await recorder.events.compactMap { event in
          if case let .rxLogData(packet) = event { return packet }
          return nil
        }
      }
    }

    func stop() async {
      await session.stop()
      recording.cancel()
    }
  }

  private func makeFixture() async throws -> Fixture {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = try await StockSessionHarness.startedSession(transport: transport, clock: clock)
    let (recorder, recording) = await EventRecorder.recording(session)
    return Fixture(session: session, transport: transport, clock: clock, recorder: recorder, recording: recording)
  }

  /// Starts a `setRadio` to ``newChannel`` and waits until it was written.
  private func startRetune(_ fixture: Fixture) async throws -> Task<Void, Error> {
    let task = Task {
      try await fixture.session.setRadio(frequency: 869.618, bandwidth: 250, spreadingFactor: 11, codingRate: 5)
    }
    try await waitUntil("CMD_SET_RADIO_PARAMS should be written") {
      await !fixture.transport.sent(code: CommandCode.setRadio.rawValue).isEmpty
    }
    return task
  }

  @Test
  func `a 0x88 frame after SELF_INFO carries the radio's channel`() async throws {
    let fixture = try await makeFixture()
    #expect(await fixture.session.currentChannelConfig == Self.stockChannel)
    #expect(await fixture.session.channelConfigSince != nil)

    let packet = try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert))
    #expect(packet.channel == Self.stockChannel)
    #expect(packet.channel?.key.rawValue == "f910525-bw62500-sf7")
    await fixture.stop()
  }

  @Test
  func `nothing is stamped before any SELF_INFO`() async {
    let session = MeshCoreSession(transport: StockTestTransport(), clock: StockTestClock())
    #expect(await session.currentChannelConfig == nil)
    #expect(await session.channelConfigSince == nil)
    #expect(await session.channelStamp(radioAge: nil) == nil)
  }

  @Test
  func `after a setRadio write and before the next SELF_INFO, frames are unstamped`() async throws {
    let fixture = try await makeFixture()
    let retune = try await startRetune(fixture)

    #expect(await fixture.session.currentChannelConfig == nil)
    #expect(try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert)).channel == nil)

    // OK: the session asks for SELF_INFO; frames before its answer still have no channel.
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await waitUntil("APP_START should follow the OK") {
      await !fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    #expect(try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert)).channel == nil)

    await fixture.transport.receive(Self.newSelfInfo)
    try await retune.value
    await fixture.stop()
  }

  @Test
  func `setRadio OK refreshes SELF_INFO and stamping resumes with the new key`() async throws {
    let fixture = try await makeFixture()
    let retune = try await startRetune(fixture)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await waitUntil("APP_START should follow the OK") {
      await !fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await fixture.transport.receive(Self.newSelfInfo)
    try await retune.value

    #expect(await fixture.session.currentChannelConfig == Self.newChannel)
    #expect(await fixture.session.currentSelfInfo?.radioSpreadingFactor == 11)
    let packet = try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert))
    #expect(packet.channel == Self.newChannel)
    #expect(packet.channel?.key != Self.stockChannel.key)
    await fixture.stop()
  }

  @Test
  func `setRadio ERR restores the old channel`() async throws {
    let fixture = try await makeFixture()
    let since = await fixture.session.channelConfigSince
    let retune = try await startRetune(fixture)
    #expect(await fixture.session.currentChannelConfig == nil)

    await fixture.transport.receive(StockFirmwareFrames.err(ErrorCode.illegalArgument.rawValue))
    let error = await #expect(throws: MeshCoreError.self) { try await retune.value }
    #expect(isDeviceError(error, ErrorCode.illegalArgument.rawValue))

    #expect(await fixture.session.currentChannelConfig == Self.stockChannel)
    #expect(await fixture.session.channelConfigSince == since)
    // the radio refused the retune, so no APP_START was needed
    #expect(await fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty)
    #expect(try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert)).channel == Self.stockChannel)
    await fixture.stop()
  }

  @Test
  func `an unanswered setRadio asks for SELF_INFO and takes the radio's report`() async throws {
    let fixture = try await makeFixture()
    let retune = try await startRetune(fixture)
    try await waitUntil("the wait should start") { fixture.clock.sleeperCount > 0 }
    fixture.clock.advance(by: .seconds(6))
    try await waitUntil("APP_START should follow the timeout") {
      await !fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await fixture.transport.receive(Self.newSelfInfo)
    let error = await #expect(throws: MeshCoreError.self) { try await retune.value }
    #expect(isTimeout(error))
    #expect(await fixture.session.currentChannelConfig == Self.newChannel)
    await fixture.stop()
  }

  @Test
  func `a SELF_INFO for the same channel keeps its start, and a coding-rate change keeps the key`() async throws {
    let fixture = try await makeFixture()
    let since = await fixture.session.channelConfigSince
    fixture.clock.advance(by: .seconds(30))
    await fixture.transport.receive(stockSelfInfoFrame(frequencyKHz: 910_525, bandwidthHz: 62_500, sf: 7, cr: 8))
    try await waitUntil("the SELF_INFO should be taken") {
      await fixture.session.currentChannelConfig?.codingRate == 8
    }
    #expect(await fixture.session.channelConfigSince == since)
    // a record received 10 s after the session first confirmed the channel is still stamped
    let packet = try await fixture.hear(rxRecord(seq: 1, ageMs: 20_000))
    #expect(packet.channel?.key == Self.stockChannel.key)
    #expect(packet.channel?.codingRate == 8)
    await fixture.stop()
  }

  @Test
  func `an RX_SYNC record received before the channel was confirmed is unstamped; a younger one is stamped`() async throws {
    let fixture = try await makeFixture()
    // The channel was confirmed at clock 0; it is now 60 s later.
    fixture.clock.advance(by: .seconds(60))

    let younger = try await fixture.hear(rxRecord(seq: 1, ageMs: 30_000))
    #expect(younger.radioAge == .milliseconds(30_000))
    #expect(younger.channel == Self.stockChannel)

    let older = try await fixture.hear(rxRecord(seq: 2, ageMs: 90_000))
    #expect(older.radioAge == .milliseconds(90_000))
    #expect(older.channel == nil)

    // a live stock frame has no age: received now, so stamped
    #expect(try await fixture.hear(StockFirmwareFrames.logRx(raw: Self.advert)).channel == Self.stockChannel)
    await fixture.stop()
  }

  @Test
  func `a retune confirmed later leaves RX_SYNC backlog from before it unstamped`() async throws {
    let fixture = try await makeFixture()
    fixture.clock.advance(by: .seconds(100))
    let retune = try await startRetune(fixture)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await waitUntil("APP_START should follow the OK") {
      await !fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await fixture.transport.receive(Self.newSelfInfo)
    try await retune.value
    fixture.clock.advance(by: .seconds(10))

    // received 50 s ago, on the old channel: nothing vouches for it now
    #expect(try await fixture.hear(rxRecord(seq: 1, ageMs: 50_000)).channel == nil)
    // received 5 s ago, after the new channel was confirmed
    #expect(try await fixture.hear(rxRecord(seq: 2, ageMs: 5000)).channel == Self.newChannel)
    await fixture.stop()
  }

  // MARK: - Held records the app vouched for

  @Test
  func `held records of a vouched journal take its channel while the radio still reports it`() async throws {
    let fixture = try await makeFixture()
    let hourAgo = Duration.seconds(3600)
    // heard before this connection confirmed the channel: unstamped on the session's word alone
    #expect(await fixture.session.channelStamp(radioAge: hourAgo, epoch: 7, seq: 120) == nil)

    await fixture.session.trustRxBacklog(channel: Self.stockChannel.key, epoch: 7, afterSeq: 100)
    #expect(await fixture.session.channelStamp(radioAge: hourAgo, epoch: 7, seq: 120) == Self.stockChannel)
    // another journal (the radio rebooted), or a record the app already had, is not covered
    #expect(await fixture.session.channelStamp(radioAge: hourAgo, epoch: 8, seq: 120) == nil)
    #expect(await fixture.session.channelStamp(radioAge: hourAgo, epoch: 7, seq: 100) == nil)
    #expect(await fixture.session.channelStamp(radioAge: hourAgo) == nil)
    await fixture.stop()
  }

  @Test
  func `a vouch for another channel than the radio reports stamps nothing`() async throws {
    let fixture = try await makeFixture()
    await fixture.session.trustRxBacklog(channel: Self.newChannel.key, epoch: 7, afterSeq: 100)
    #expect(await fixture.session.channelStamp(radioAge: .seconds(3600), epoch: 7, seq: 120) == nil)
    await fixture.stop()
  }

  @Test
  func `a retune ends the vouch`() async throws {
    let fixture = try await makeFixture()
    await fixture.session.trustRxBacklog(channel: Self.stockChannel.key, epoch: 7, afterSeq: 100)
    let retune = try await startRetune(fixture)
    await fixture.transport.receive(Data([ResponseCode.ok.rawValue]))
    try await waitUntil("APP_START should follow the OK") {
      await !fixture.transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await fixture.transport.receive(Self.newSelfInfo)
    try await retune.value
    #expect(await fixture.session.trustedRxBacklog == nil)
    #expect(await fixture.session.channelStamp(radioAge: .seconds(3600), epoch: 7, seq: 120) == nil)
    await fixture.stop()
  }
}

/// A whole RX_SYNC record (`net/RX_SYNC.md`): `[0xC8][flags][seq u32][age_ms u32][snr_x4][rssi][raw]`,
/// carrying a one-hop flood advert.
private func rxRecord(seq: UInt32, ageMs: UInt32) -> Data {
  var frame = Data([0xC8, 0x00])
  frame.append(contentsOf: withUnsafeBytes(of: seq.littleEndian) { Array($0) })
  frame.append(contentsOf: withUnsafeBytes(of: ageMs.littleEndian) { Array($0) })
  frame.append(contentsOf: [0x14, 0xA6])
  frame.append(contentsOf: StockFirmwareFrames.packet(payloadType: 0x04, route: StockFirmwareFrames.routeFlood, path: [0x7F], payload: [UInt8(seq & 0xFF)]))
  return frame
}
