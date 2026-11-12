@testable import CairnServices
import Foundation
import MeshCore
import Testing

@Suite("RegionDiscoveryService probe order")
struct RegionDiscoveryOrderTests {
  /// Stands in for the session: records the order of calls and lets the send deliver replies
  /// before it returns, as a fast repeater's answer can.
  private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var continuation: AsyncStream<MeshEvent>.Continuation?
    /// Replies the radio pushes while the send is still being acknowledged.
    var repliesDuringSend: [DiscoverResponse] = []
    /// Frames the radio pushes while the send is still being acknowledged, parsed as the session
    /// parses them.
    var framesDuringSend: [Data] = []
    /// What the send throws once it is recorded, if anything.
    var sendError: (any Error)?

    var calls: [String] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }

    private func record(_ call: String) {
      lock.lock()
      _calls.append(call)
      lock.unlock()
    }

    /// Records a call made outside the session (the neighbour table, the scan screens).
    func note(_ call: String) {
      record(call)
    }

    private func setContinuation(_ continuation: AsyncStream<MeshEvent>.Continuation) {
      lock.lock()
      self.continuation = continuation
      lock.unlock()
    }

    private func currentContinuation() -> AsyncStream<MeshEvent>.Continuation? {
      lock.lock()
      defer { lock.unlock() }
      return continuation
    }

    var probe: RegionDiscoveryService.DiscoverProbe {
      RegionDiscoveryService.DiscoverProbe(
        subscribe: { [self] in
          record("subscribe")
          let (stream, continuation) = AsyncStream.makeStream(of: MeshEvent.self)
          setContinuation(continuation)
          return stream
        },
        send: { [self] _ in
          record("send")
          if let sendError { throw sendError }
          let continuation = currentContinuation()
          for reply in repliesDuringSend {
            continuation?.yield(.discoverResponse(reply))
          }
          for frame in framesDuringSend {
            continuation?.yield(PacketParser.parse(frame))
          }
        },
        hold: { [self] _ in record("hold") },
        release: { [self] in record("release") }
      )
    }
  }

  private struct SendFailure: Error {}

  private static let tag: UInt32 = 0x1234_5678
  private static var tagData: Data {
    withUnsafeBytes(of: tag.littleEndian) { Data($0) }
  }

  private static func reply(key: UInt8, tag: Data = tagData) -> DiscoverResponse {
    DiscoverResponse(
      nodeType: 2,
      snrIn: 5,
      snr: 6,
      rssi: -90,
      pathLength: 0,
      tag: tag,
      publicKey: Data(repeating: key, count: 32)
    )
  }

  @Test
  func `subscribes before sending`() async {
    let recorder = ProbeRecorder()
    _ = await RegionDiscoveryService.respondingRepeaters(
      probe: recorder.probe,
      gate: DiscoverRequestGate(),
      listenFor: .milliseconds(20),
      tag: Self.tag
    )
    #expect(recorder.calls == ["subscribe", "hold", "send", "release"])
  }

  @Test
  func `a reply delivered during the send is captured`() async {
    let recorder = ProbeRecorder()
    recorder.repliesDuringSend = [Self.reply(key: 0xAA), Self.reply(key: 0xBB, tag: Data([9, 9, 9, 9]))]
    let result = await RegionDiscoveryService.respondingRepeaters(
      probe: recorder.probe,
      gate: DiscoverRequestGate(),
      listenFor: .milliseconds(50),
      tag: Self.tag
    )
    // Only the reply to our tag counts; the other scan's reply is not ours to query.
    #expect(result == .responders([Data(repeating: 0xAA, count: 32)]))
  }

  @Test
  func `the tag is noted before the send and the recording is announced after it`() async {
    let recorder = ProbeRecorder()
    let gate = DiscoverRequestGate()
    let base = recorder.probe
    var probe = base
    probe.noteProbe = { tag, _ in
      #expect(tag == Self.tag)
      recorder.note("note")
    }
    probe.recorded = {
      // the gate already counts it when the screens are told
      if case .coolingDown = await gate.status() { recorder.note("recorded") }
    }
    _ = await RegionDiscoveryService.respondingRepeaters(
      probe: probe,
      gate: gate,
      listenFor: .milliseconds(10),
      tag: Self.tag
    )
    // the session holds its optional traffic for the listen window before the send, and lets it
    // go when the window ends
    #expect(recorder.calls == ["subscribe", "note", "hold", "send", "recorded", "release"])
  }

  @Test
  func `a sent probe is recorded with the gate`() async {
    let recorder = ProbeRecorder()
    let gate = DiscoverRequestGate()
    _ = await RegionDiscoveryService.respondingRepeaters(
      probe: recorder.probe,
      gate: gate,
      listenFor: .milliseconds(10),
      tag: Self.tag
    )
    guard case .coolingDown(_, reason: .spacing) = await gate.status() else {
      Issue.record("the gate should be spacing after a probe")
      return
    }
  }

  @Test
  func `the cooldown path sends nothing`() async {
    let recorder = ProbeRecorder()
    let gate = DiscoverRequestGate()
    await gate.recordOwn()
    let result = await RegionDiscoveryService.respondingRepeaters(
      probe: recorder.probe,
      gate: gate,
      listenFor: .milliseconds(10),
      tag: Self.tag
    )
    guard case .coolingDown(_, reason: .spacing) = result else {
      Issue.record("expected a spacing cooldown, got \(result)")
      return
    }
    #expect(recorder.calls.isEmpty)
  }

  @Test
  func `a failed send is reported`() async {
    let gate = DiscoverRequestGate()
    let probe = RegionDiscoveryService.DiscoverProbe(
      subscribe: { AsyncStream { _ in } },
      send: { _ in throw SendFailure() }
    )
    let result = await RegionDiscoveryService.respondingRepeaters(
      probe: probe,
      gate: gate,
      listenFor: .milliseconds(10),
      tag: Self.tag
    )
    #expect(result == .sendFailed)
    // It may have gone on air before failing, so the gate still counts it.
    guard case .coolingDown(_, reason: .spacing) = await gate.status() else {
      Issue.record("a failed send should still count against the gate")
      return
    }
  }

  // MARK: - Stock firmware: both copies of a reply

  /// A zero-hop direct discover reply to `tag`, as official firmware forwards it in the RX log
  /// (0x88), built byte for byte by the stock fixtures.
  private static func replyCopy(key: [UInt8], tag: Data = tagData) -> Data {
    StockCompanionFrames.logRx(raw: StockCompanionFrames.discoverReplyPacket(tag: Array(tag), key: key))
  }

  private static let keyA = [UInt8](repeating: 0xAA, count: 32)

  private func probe(_ recorder: ProbeRecorder, gate: DiscoverRequestGate = DiscoverRequestGate()) async
    -> RegionDiscoveryService.ProbeResult {
    await RegionDiscoveryService.respondingRepeaters(
      probe: recorder.probe,
      gate: gate,
      listenFor: .milliseconds(50),
      tag: Self.tag
    )
  }

  @Test
  func `a reply whose 0x8E push was dropped still counts from its 0x88 copy`() async {
    let recorder = ProbeRecorder()
    recorder.framesDuringSend = [Self.replyCopy(key: Self.keyA)]
    #expect(await probe(recorder) == .responders([Data(Self.keyA)]))
  }

  @Test
  func `a 0x88 reply to another scan's tag is ignored`() async {
    let recorder = ProbeRecorder()
    recorder.framesDuringSend = [Self.replyCopy(key: Self.keyA, tag: Data([9, 9, 9, 9]))]
    #expect(await probe(recorder) == .responders([]))
  }

  @Test
  func `both copies of one reply give one key`() async {
    let recorder = ProbeRecorder()
    recorder.framesDuringSend = [
      Self.replyCopy(key: Self.keyA),
      StockCompanionFrames.controlData(tag: Array(Self.tagData), key: Self.keyA),
    ]
    #expect(await probe(recorder) == .responders([Data(Self.keyA)]))
  }

  @Test
  func `a prefix-only reply names no key to ask, in either copy`() async {
    let recorder = ProbeRecorder()
    let prefix = Array(Self.keyA.prefix(8))
    recorder.framesDuringSend = [
      Self.replyCopy(key: prefix),
      StockCompanionFrames.controlData(tag: Array(Self.tagData), key: prefix),
    ]
    #expect(await probe(recorder) == .responders([]))
  }

  @Test
  func `only zero-hop direct control packets reach the probe's subscription`() throws {
    guard case let .rxLogData(reply) = PacketParser.parse(Self.replyCopy(key: Self.keyA)),
          case let .rxLogData(groupText) = PacketParser.parse(
            StockCompanionFrames.logRx(raw: StockCompanionFrames.groupTextPacket(index: 1))
          ),
          case let .rxLogData(relayed) = PacketParser.parse(StockCompanionFrames.logRx(raw: StockCompanionFrames.packet(
            payloadType: 0x0B, route: StockCompanionFrames.routeDirect, path: [0x3A],
            payload: [0x92, 0x18] + Array(Self.tagData) + Self.keyA
          ))) else {
      Issue.record("the stock frames should parse as RX log data")
      return
    }
    #expect(RegionDiscoveryService.isZeroHopDirectControl(reply))
    #expect(!RegionDiscoveryService.isZeroHopDirectControl(groupText))
    #expect(!RegionDiscoveryService.isZeroHopDirectControl(relayed))
  }

  @Test
  func `the session holds its optional traffic for the listen window`() async {
    let recorder = ProbeRecorder()
    let held = HeldDurations()
    var probe = recorder.probe
    probe.hold = { duration in await held.note(duration) }
    _ = await RegionDiscoveryService.respondingRepeaters(
      probe: probe,
      gate: DiscoverRequestGate(),
      listenFor: .milliseconds(30),
      tag: Self.tag
    )
    #expect(await held.durations == [.milliseconds(30)])
  }

  @Test
  func `a send that fails releases the hold at once`() async {
    for error: any Error in [MeshCoreError.deviceError(code: 1), MeshCoreError.timeout, SendFailure()] {
      let recorder = ProbeRecorder()
      recorder.sendError = error
      // A long window: the hold must not outlive the failed send
      _ = await RegionDiscoveryService.respondingRepeaters(
        probe: recorder.probe,
        gate: DiscoverRequestGate(),
        listenFor: .seconds(30),
        tag: Self.tag
      )
      #expect(recorder.calls == ["subscribe", "hold", "send", "release"], "\(error)")
    }
  }

  @Test
  func `a cancelled listen releases the hold`() async throws {
    let recorder = ProbeRecorder()
    let probe = recorder.probe
    let listen = Task {
      await RegionDiscoveryService.respondingRepeaters(
        probe: probe,
        gate: DiscoverRequestGate(),
        listenFor: .seconds(30),
        tag: Self.tag
      )
    }
    try await waitUntil("the probe should be sent") { recorder.calls.contains("send") }
    listen.cancel()
    _ = await listen.value
    #expect(recorder.calls == ["subscribe", "hold", "send", "release"])
  }

  // MARK: - Stock firmware without the discover command

  @Test
  func `a radio that refuses the command gives the reservation back`() async {
    let recorder = ProbeRecorder()
    // companion v1.9.0 MyMesh.cpp final else: writeErrFrame(ERR_CODE_UNSUPPORTED_CMD)
    recorder.sendError = MeshCoreError.deviceError(code: 1)
    let gate = DiscoverRequestGate()
    let before = await gate.status()
    #expect(await probe(recorder, gate: gate) == .unsupported)
    // Nothing went on air, so no repeater spent a token and the gate is as it was
    #expect(await gate.status() == before)
  }

  @Test
  func `a firmware without the discover command sends nothing and leaves the gate alone`() async throws {
    let radio = StockCompanionRadio()
    try await radio.connect()
    let session = MeshCoreSession(
      transport: radio,
      configuration: SessionConfiguration(defaultTimeout: 1, clientIdentifier: "StockTst")
    )
    let store = PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
    let gate = DiscoverRequestGate()
    let device = StockCompanionFrames.device("companion-v1.9.0")
    #expect(!device.supportsNodeDiscover)

    let outcome = await RegionDiscoveryService.discover(
      session: session,
      contactService: ContactService(
        session: MockMeshCoreSession(), dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil
      ),
      dataStore: store,
      radioID: device.radioID,
      knownRegions: [],
      supportsAdHocRequest: device.supportsAdHocRepeaterRequest,
      supportsDiscoverRequest: device.supportsNodeDiscover,
      gate: gate
    )
    guard case .discoverUnsupported = outcome else {
      Issue.record("expected .discoverUnsupported, got \(outcome)")
      return
    }
    #expect(await radio.sent.isEmpty)
    // Not even reserved: a reservation would make the gate wait for spacing
    #expect(await gate.status() == .allowed)
  }
}

/// The durations a probe asked the session to hold its traffic for.
private actor HeldDurations {
  private(set) var durations: [Duration] = []

  func note(_ duration: Duration) {
    durations.append(duration)
  }
}
