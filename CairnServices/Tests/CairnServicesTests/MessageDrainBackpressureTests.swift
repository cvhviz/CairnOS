import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// The automatic drain stores each answer before it fetches the next one.
///
/// The radio removes a queued message when it answers the fetch. The session's auto-drain used
/// to fetch as fast as the link answered and leave storage to the polling service's event
/// subscription, which kept the newest 100 events: a backlog drained faster than it was stored
/// lost its oldest answers for good. These tests drain a backlog far larger than that buffer
/// through a deliberately slow handler.
@Suite("Message drain backpressure")
@MainActor
struct MessageDrainBackpressureTests {
  private let senderKey = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66] + Array(repeating: 0x42, count: 26))
  private let stamp = UInt32(Date().timeIntervalSince1970) - 600

  private func dmFrame(_ index: Int) -> Data {
    var frame = Data([ResponseCode.contactMessageReceivedV3.rawValue, 0x14, 0, 0])
    frame.append(senderKey.prefix(6))
    frame.append(0x01) // path length
    frame.append(0x00) // plain text
    frame.append(contentsOf: withUnsafeBytes(of: (stamp + UInt32(index)).littleEndian) { Array($0) })
    frame.append(contentsOf: "message \(index)".utf8)
    return frame
  }

  private static let noMoreMessages = Data([ResponseCode.noMoreMessages.rawValue])

  private func makeSelfInfoPacket() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(1) // adv type
    payload.append(22) // tx power
    payload.append(22) // max tx power
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

  private func startedSession() async throws -> (MeshCoreSession, MockTransport) {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 2, clientIdentifier: "DrainBackpressureTests")
    )
    let start = Task { try await session.start() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count >= 1 }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await start.value
    await transport.clearSentData()
    return (session, transport)
  }

  /// The radio's offline queue: answers each `CMD_SYNC_NEXT_MESSAGE` with its head (or
  /// NO_MORE_MESSAGES when empty), as fast as the fetches come. Frames can be appended later.
  private actor RadioQueue {
    var frames: [Data] = []
    var answered = 0
    func append(_ more: [Data]) { frames.append(contentsOf: more) }
    func next() -> Data {
      answered += 1
      return frames.isEmpty ? Data([ResponseCode.noMoreMessages.rawValue]) : frames.removeFirst()
    }
  }

  /// Stock firmware: answers `CMD_SYNC_NEXT_MESSAGE` by popping the queue, and the queue sync probe
  /// as unsupported.
  private func serve(_ queue: RadioQueue, on transport: MockTransport) -> Task<Void, Never> {
    Task {
      var handled = 0
      while !Task.isCancelled {
        let sent = await transport.sentData
        guard sent.count > handled else {
          try? await Task.sleep(for: .milliseconds(1))
          continue
        }
        let command = sent[handled]
        handled += 1
        if command.first == CommandCode.getMessage.rawValue {
          await transport.simulateReceive(await queue.next())
        } else if command.first == CommandCode.cairnFirmware.rawValue {
          await transport.simulateReceive(Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue]))
        }
      }
    }
  }

  private actor Stored {
    var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
  }

  @Test(.timeLimit(.minutes(2)))
  func `a backlog far beyond the event buffer drains through a slow store without loss`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    // Slower than a fetch: without backpressure the answers pile up in the event buffer.
    await polling.setContactMessageHandler { message, _, _ in
      try? await Task.sleep(for: .milliseconds(8))
      await stored.add(message.text)
    }

    let backlog = 300
    let queue = RadioQueue()
    await queue.append((0..<backlog).map(dmFrame))
    let server = serve(queue, on: transport)
    defer { server.cancel() }

    // Starting auto-fetch drains what is queued (as after a reconnect).
    await polling.startAutoFetch(radioID: radioID)

    try await waitUntil(timeout: .seconds(60), "every queued message should be stored") {
      await stored.texts.count >= backlog
    }

    // More arrive while connected: the radio pushes MSG_WAITING.
    await queue.append((backlog..<(backlog + 50)).map(dmFrame))
    await transport.simulateReceive(Data([ResponseCode.messagesWaiting.rawValue]))

    try await waitUntil(timeout: .seconds(30), "the pushed messages should be stored") {
      await stored.texts.count >= backlog + 50
    }
    try await Task.sleep(for: .milliseconds(100))

    let texts = await stored.texts
    #expect(texts.count == backlog + 50, "each message is stored once")
    #expect(Set(texts) == Set((0..<(backlog + 50)).map { "message \($0)" }))
    #expect(await session.eventDropCount(label: MessagePollingService.eventSubscriptionLabel) == 0)

    await polling.stopAutoFetch()
  }

  @Test(.timeLimit(.minutes(1)))
  func `the initial drain stores a large backlog in queue order`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    await polling.setContactMessageHandler { message, _, _ in
      try? await Task.sleep(for: .milliseconds(2))
      await stored.add(message.text)
    }
    await polling.startMessageEventMonitoring(radioID: radioID)

    let queue = RadioQueue()
    await queue.append((0..<200).map(dmFrame))
    let server = serve(queue, on: transport)
    defer { server.cancel() }

    let count = try await polling.pollAllMessages()

    #expect(count == 200)
    #expect(await stored.texts == (0..<200).map { "message \($0)" })
    await polling.stopMessageEventMonitoring()
  }

  // MARK: - Queue sync (Cairn firmware)

  /// A Cairn radio's queue sync (firmware's QUEUE_SYNC.md): NEXT leaves a frame queued until a later
  /// NEXT names its seq. `dropFrameOnce` loses the frame after one NEXT head on the way (the link
  /// dropped), as stock firmware would have lost that message for good.
  private actor QueueSyncRadio {
    var frames: [(seq: UInt32, data: Data)] = []
    var nextSeq: UInt32 = 1000
    var loss = (channel: UInt32(3), refused: UInt32(1), snapshot: UInt32(0), confirm: UInt32(0))
    var dropFrameAtSeq: UInt32?
    var stockFetches = 0

    func append(_ more: [Data]) {
      for data in more {
        frames.append((nextSeq, data))
        nextSeq += 1
      }
    }

    func dropFrameOnce(at seq: UInt32) { dropFrameAtSeq = seq }

    private func stateReply(op: UInt8) -> Data {
      var d = Data([0xC0, 0x08, 0x00, op, 1, 1])
      d.append(contentsOf: [UInt8(frames.count & 0xFF), UInt8(frames.count >> 8), 0x00, 0x01])
      d.appendLittleEndian(nextSeq)
      d.appendLittleEndian(loss.channel)
      d.appendLittleEndian(loss.refused)
      d.appendLittleEndian(loss.snapshot)
      d.appendLittleEndian(loss.confirm)
      return d
    }

    /// The frames answering one command.
    func answer(_ command: Data) -> [Data] {
      if command.first == CommandCode.getMessage.rawValue {
        stockFetches += 1
        return [Data([ResponseCode.noMoreMessages.rawValue])]
      }
      guard command.count >= 3, command[0] == 0xC0, command[1] == 0x08 else { return [] }
      switch command[2] {
      case 0x00, 0x01:
        return [stateReply(op: command[2])]
      case 0x03:
        loss.channel -= min(loss.channel, command.readUInt32LE(at: 3))
        loss.refused -= min(loss.refused, command.readUInt32LE(at: 7))
        return [stateReply(op: 0x03)]
      case 0x02:
        let ack = command.readUInt32LE(at: 3)
        frames.removeAll { $0.seq == ack }
        guard let head = frames.first else {
          var reply = Data([0xC0, 0x08, 0x00, 0x02])
          reply.appendLittleEndian(UInt32(0))
          reply.append(contentsOf: [0, 0])
          return [reply, Data([ResponseCode.noMoreMessages.rawValue])]
        }
        var reply = Data([0xC0, 0x08, 0x00, 0x02])
        reply.appendLittleEndian(head.seq)
        let remaining = frames.count - 1
        reply.append(contentsOf: [UInt8(remaining & 0xFF), UInt8(remaining >> 8)])
        if dropFrameAtSeq == head.seq {
          dropFrameAtSeq = nil
          return [reply]   // the frame never arrives
        }
        return [reply, head.data]
      default:
        return []
      }
    }
  }

  /// `beforeAnswer` sees each command before the radio does (the ACK checks).
  private func serveQueueSync(
    _ radio: QueueSyncRadio,
    on transport: MockTransport,
    beforeAnswer: (@Sendable (Data) async -> Void)? = nil
  ) -> Task<Void, Never> {
    Task {
      var handled = 0
      while !Task.isCancelled {
        let sent = await transport.sentData
        guard sent.count > handled else {
          try? await Task.sleep(for: .milliseconds(1))
          continue
        }
        let command = sent[handled]
        handled += 1
        await beforeAnswer?(command)
        for frame in await radio.answer(command) {
          await transport.simulateReceive(frame)
        }
      }
    }
  }

  private actor LossRecorder {
    var losses: [CairnQueueLoss] = []
    func add(_ loss: CairnQueueLoss) { losses.append(loss) }
  }

  @Test(.timeLimit(.minutes(1)))
  func `queue sync drains every frame once, sends a lost answer again, and reports the radio's losses`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    await polling.setContactMessageHandler { message, _, _ in
      try? await Task.sleep(for: .milliseconds(2))
      await stored.add(message.text)
    }
    let losses = LossRecorder()
    await polling.setQueueLossHandler { loss in
      await losses.add(loss)
      return true
    }
    await polling.startMessageEventMonitoring(radioID: radioID)

    let radio = QueueSyncRadio()
    await radio.append((0..<40).map(dmFrame))
    await radio.dropFrameOnce(at: 1010)   // the eleventh answer is lost on the link
    let server = serveQueueSync(radio, on: transport)
    defer { server.cancel() }

    let count = try await polling.pollAllMessages()

    #expect(count == 40)
    #expect(await stored.texts == (0..<40).map { "message \($0)" }, "in order, each once, none lost")
    #expect(await radio.frames.isEmpty, "every frame left the radio only after it was stored")
    #expect(await radio.stockFetches == 0, "a queue sync radio is never read the stock way")
    let reported = await losses.losses
    #expect(reported.first == CairnQueueLoss(channelEvicted: 3, refused: 1, snapshotLost: 0, confirmationsEvicted: 0))
    let remainingLoss = await radio.loss
    #expect(remainingLoss.channel == 0 && remainingLoss.refused == 0, "reported losses are cleared on the radio")
    await polling.stopMessageEventMonitoring()
  }

  @Test(.timeLimit(.minutes(1)))
  func `a loss the handler could not surface stays on the radio for the next check`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let losses = LossRecorder()
    await polling.setQueueLossHandler { loss in
      await losses.add(loss)
      return false
    }

    let radio = QueueSyncRadio()
    let server = serveQueueSync(radio, on: transport)
    defer { server.cancel() }

    _ = try await polling.pollAllMessages()

    #expect(await losses.losses.count == 1, "the handler was told")
    let remaining = await radio.loss
    #expect(remaining.channel == 3 && remaining.refused == 1, "not surfaced, so not cleared on the radio")
  }

  /// The ACKs a NEXT carried, and any that named a frame not yet stored.
  private actor AckAudit {
    var acked: [UInt32] = []
    var early: [UInt32] = []
    func check(_ seq: UInt32, storedTexts: [String]) {
      acked.append(seq)
      if !storedTexts.contains("message \(Int(seq) - 1000)") { early.append(seq) }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func `queue sync never acknowledges a frame before it is stored, whoever handles it`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    // Slow storage, and the event monitor races every drain fetch for the claim.
    await polling.setContactMessageHandler { message, _, _ in
      try? await Task.sleep(for: .milliseconds(30))
      await stored.add(message.text)
    }
    await polling.startMessageEventMonitoring(radioID: radioID)

    let radio = QueueSyncRadio()
    await radio.append((0..<25).map(dmFrame))
    let audit = AckAudit()
    let server = serveQueueSync(radio, on: transport) { command in
      guard command.count >= 7, command[0] == 0xC0, command[1] == 0x08, command[2] == 0x02 else { return }
      let ack = command.readUInt32LE(at: 3)
      guard ack != 0 else { return }
      await audit.check(ack, storedTexts: await stored.texts)
    }
    defer { server.cancel() }

    _ = try await polling.pollAllMessages()

    #expect(await audit.early.isEmpty, "every ACK named a frame already stored")
    #expect(await audit.acked.count == 25)
    #expect(await radio.frames.isEmpty)
    #expect(Set(await stored.texts) == Set((0..<25).map { "message \($0)" }))
    #expect(await stored.texts.count == 25, "each stored once")
    await polling.stopMessageEventMonitoring()
  }

  @Test(.timeLimit(.minutes(1)))
  func `queue sync leaves a frame on the radio while another handler is still storing it`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    // Storage slower than the drain will wait for it: whenever the event monitor wins the claim,
    // the drain must not ACK, and the frame comes again.
    await polling.setClaimedHandlerWait(.milliseconds(5))
    await polling.setContactMessageHandler { message, _, _ in
      try? await Task.sleep(for: .milliseconds(60))
      await stored.add(message.text)
    }
    await polling.startMessageEventMonitoring(radioID: radioID)

    let radio = QueueSyncRadio()
    await radio.append((0..<10).map(dmFrame))
    let audit = AckAudit()
    let server = serveQueueSync(radio, on: transport) { command in
      guard command.count >= 7, command[0] == 0xC0, command[1] == 0x08, command[2] == 0x02 else { return }
      let ack = command.readUInt32LE(at: 3)
      guard ack != 0 else { return }
      await audit.check(ack, storedTexts: await stored.texts)
    }
    defer { server.cancel() }

    // A drain that keeps getting an unstored frame gives up (pollingFailed) and the next resumes.
    for _ in 0..<200 {
      _ = try? await polling.pollAllMessages()
      if await radio.frames.isEmpty { break }
    }

    #expect(await audit.early.isEmpty, "no ACK named a frame its handler had not stored yet")
    #expect(await radio.frames.isEmpty)
    #expect(Set(await stored.texts) == Set((0..<10).map { "message \($0)" }))
    #expect(await stored.texts.count == 10, "each stored once")
    await polling.stopMessageEventMonitoring()
  }
}
