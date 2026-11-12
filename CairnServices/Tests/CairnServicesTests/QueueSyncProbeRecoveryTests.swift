import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// A radio with queue sync is read with queue sync whenever it can answer, above all on the return
/// to the foreground.
///
/// The background reconnect's pre-contact drain makes the connection's first ARM probe while the app
/// may be suspended or the link busy. One unanswered probe used to send every drain for the next 60 s
/// the stock way, the foreground catch-up included, and one stray ERR(unsupported) (a late reply to
/// another command, or another link's error the radio writes to every interface) used to latch stock
/// reads for the whole connection.
@Suite("Queue sync probe recovery")
@MainActor
struct QueueSyncProbeRecoveryTests {
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
      configuration: SessionConfiguration(defaultTimeout: 2, clientIdentifier: "QueueSyncProbeRecoveryTests")
    )
    let start = Task { try await session.start() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count >= 1 }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await start.value
    await transport.clearSentData()
    return (session, transport)
  }

  /// A radio whose answers can be scripted: with `queueSync` a Cairn radio (QUEUE_SYNC.md), without
  /// it stock firmware, which answers every `CMD_CAIRN_FW` with ERR(unsupported). A stock read pops
  /// the queue's head on either.
  private actor Radio {
    let queueSync: Bool
    var frames: [(seq: UInt32, data: Data)] = []
    var nextSeq: UInt32 = 1000
    var stockFetches = 0
    var nexts = 0
    var arms = 0
    /// ARMs left unanswered (the app suspended, or the reply dropped on a full send queue).
    var silentArms = 0
    /// Stray ERR(unsupported) frames written ahead of the next ARM's reply.
    var strayErrorsBeforeArm = 0
    /// Stray ERR(unsupported) frames written ahead of the next NEXT's reply.
    var strayErrorsBeforeNext = 0

    init(queueSync: Bool = true) {
      self.queueSync = queueSync
    }

    func append(_ more: [Data]) {
      for data in more {
        frames.append((nextSeq, data))
        nextSeq += 1
      }
    }

    func setSilentArms(_ count: Int) { silentArms = count }
    func setStrayErrorsBeforeArm(_ count: Int) { strayErrorsBeforeArm = count }
    func setStrayErrorsBeforeNext(_ count: Int) { strayErrorsBeforeNext = count }

    private func stateReply(op: UInt8) -> Data {
      var reply = Data([0xC0, 0x08, 0x00, op, 1, 1])
      reply.append(contentsOf: [UInt8(frames.count & 0xFF), UInt8(frames.count >> 8), 0x00, 0x01])
      reply.appendLittleEndian(nextSeq)
      for _ in 0..<4 { reply.appendLittleEndian(UInt32(0)) }
      return reply
    }

    func answer(_ command: Data) -> [Data] {
      let unsupported = Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue])
      if command.first == CommandCode.getMessage.rawValue {
        stockFetches += 1
        guard !frames.isEmpty else { return [Data([ResponseCode.noMoreMessages.rawValue])] }
        return [frames.removeFirst().data]
      }
      guard command.first == CommandCode.cairnFirmware.rawValue else { return [] }
      if command.count >= 3, command[1] == 0x08, command[2] == 0x01 { arms += 1 }
      guard queueSync, command.count >= 3, command[1] == 0x08 else { return [unsupported] }
      switch command[2] {
      case 0x01:
        if silentArms > 0 {
          silentArms -= 1
          return []
        }
        let strays = Array(repeating: unsupported, count: strayErrorsBeforeArm)
        strayErrorsBeforeArm = 0
        return strays + [stateReply(op: 0x01)]
      case 0x00, 0x03:
        return [stateReply(op: command[2])]
      case 0x02:
        nexts += 1
        frames.removeAll { $0.seq == command.readUInt32LE(at: 3) }
        let strays = Array(repeating: unsupported, count: strayErrorsBeforeNext)
        strayErrorsBeforeNext = 0
        var reply = Data([0xC0, 0x08, 0x00, 0x02])
        guard let head = frames.first else {
          reply.appendLittleEndian(UInt32(0))
          reply.append(contentsOf: [0, 0])
          return strays + [reply, Data([ResponseCode.noMoreMessages.rawValue])]
        }
        reply.appendLittleEndian(head.seq)
        let remaining = frames.count - 1
        reply.append(contentsOf: [UInt8(remaining & 0xFF), UInt8(remaining >> 8)])
        return strays + [reply, head.data]
      default:
        return []
      }
    }
  }

  private func serve(_ radio: Radio, on transport: MockTransport) -> Task<Void, Never> {
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
        for frame in await radio.answer(command) {
          await transport.simulateReceive(frame)
        }
      }
    }
  }

  private actor Stored {
    var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
  }

  private func makePolling(_ session: MeshCoreSession, radioID: UUID = UUID()) async throws
    -> (MessagePollingService, Stored) {
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MessagePollingService(session: session, dataStore: store)
    let stored = Stored()
    await polling.setContactMessageHandler { message, _, _ in await stored.add(message.text) }
    await polling.startMessageEventMonitoring(radioID: radioID)
    return (polling, stored)
  }

  // MARK: - A probe that got no answer

  @Test(.timeLimit(.minutes(1)))
  func `the foreground drain after a background probe timeout reads with queue sync`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let (polling, stored) = try await makePolling(session, radioID: radioID)
    let radio = Radio()
    await radio.setSilentArms(1)
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    // Background reconnect: the pre-contact drain's ARM goes unanswered, then auto-fetch starts.
    _ = try await polling.pollAllMessages()
    #expect(await radio.arms == 1)
    await polling.startAutoFetch(radioID: radioID)
    // Auto-fetch's own first drain is automatic: it stays inside the backoff and doesn't ask again.
    try await waitUntil("auto-fetch's first drain should run") { await radio.stockFetches >= 2 }
    #expect(await radio.arms == 1)

    // Opening the app: messages queued meanwhile, and the foreground catch-up asks for a drain.
    await radio.append((0..<5).map(dmFrame))
    let stockBefore = await radio.stockFetches
    await polling.requestDrain()
    // The last NEXT acknowledges the fifth frame and finds the queue's end.
    try await waitUntil("the foreground drain should empty the radio's queue") {
      let storedCount = await stored.texts.count
      let queueEmpty = await radio.frames.isEmpty
      let nexts = await radio.nexts
      return storedCount == 5 && queueEmpty && nexts >= 6
    }

    #expect(await radio.arms == 2, "the foreground drain asks again")
    #expect(await radio.stockFetches == stockBefore, "and reads with queue sync, never the stock way")
    await polling.stopAutoFetch()
  }

  @Test(.timeLimit(.minutes(1)))
  func `one unanswered ARM probe does not send the next explicit drain the stock way`() async throws {
    let (session, transport) = try await startedSession()
    let (polling, stored) = try await makePolling(session)
    let radio = Radio()
    await radio.setSilentArms(1)
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    _ = try await polling.pollAllMessages()   // the ARM times out (5 s): stock this once
    await radio.append((0..<5).map(dmFrame))
    let stockBefore = await radio.stockFetches
    let count = try await polling.pollAllMessages()

    #expect(count == 5)
    #expect(await radio.arms == 2, "the second drain asks again")
    #expect(await radio.stockFetches == stockBefore, "and reads with queue sync")
    #expect(await stored.texts.count == 5)
    await polling.stopMessageEventMonitoring()
  }

  // MARK: - An explicit drain asked for while a probe is in flight

  @Test(.timeLimit(.minutes(1)))
  func `a sync asked for while an unanswered ARM is in flight reads with queue sync`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let (polling, _) = try await makePolling(session, radioID: radioID)
    let radio = Radio()
    await radio.setSilentArms(1)
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    // An automatic drain (auto-fetch's first) holds the drain and waits on an ARM that gets no answer.
    await polling.startAutoFetch(radioID: radioID)
    try await waitUntil("the automatic drain should send its ARM") { await radio.arms == 1 }
    // The sync's drain queues behind it; the ARM's timeout lands while it waits.
    _ = try await polling.pollAllMessages()

    #expect(await radio.arms == 2, "the waiting explicit drain asks again despite the timeout's hold-off")
    #expect(await radio.nexts >= 1, "and reads with queue sync")
    #expect(await radio.stockFetches == 1, "only the automatic drain read the stock way")
    await polling.stopAutoFetch()
  }

  @Test(.timeLimit(.minutes(1)))
  func `a drain requested while an unanswered ARM is in flight reads with queue sync`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let (polling, _) = try await makePolling(session, radioID: radioID)
    let radio = Radio()
    await radio.setSilentArms(1)
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    // A background wake's drain sends an ARM; the app returns to the foreground before it times out.
    await polling.startAutoFetch(radioID: radioID)
    try await waitUntil("the automatic drain should send its ARM") { await radio.arms == 1 }
    // The foreground catch-up's request coalesces into the session's running drain, which reruns.
    await polling.requestDrain()
    try await waitUntil(timeout: .seconds(20), "the rerun drain should read with queue sync") { await radio.nexts >= 1 }

    #expect(await radio.arms == 2, "the rerun asks again despite the timeout's hold-off")
    #expect(await radio.stockFetches == 1, "only the drain whose ARM timed out read the stock way")
    await polling.stopAutoFetch()
  }

  @Test(.timeLimit(.minutes(1)))
  func `a refused push's recovery drain keeps a failed probe's hold-off`() async throws {
    let (session, transport) = try await startedSession()
    let radioID = UUID()
    let (polling, stored) = try await makePolling(session, radioID: radioID)
    let radio = Radio()
    await radio.setSilentArms(1)
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    await polling.startAutoFetch(radioID: radioID)
    try await waitUntil(timeout: .seconds(20), "the automatic drain should time out and read stock") { await radio.stockFetches >= 1 }
    #expect(await radio.arms == 1)

    // RX_SYNC reports refused MSG_WAITING pushes: each recovery drain reads stock, no new ARM.
    await radio.append((0..<3).map(dmFrame))
    await polling.requestPushRecoveryDrain()
    try await waitUntil("the recovery drain should store the messages") { await stored.texts.count == 3 }
    await polling.requestPushRecoveryDrain()
    try await waitUntil("the second recovery drain should run") { await radio.stockFetches >= 6 }

    #expect(await radio.arms == 1, "no probe while the hold-off lasts")
    #expect(await radio.nexts == 0)
    await polling.stopAutoFetch()
  }

  // MARK: - Stray errors

  @Test(.timeLimit(.minutes(1)))
  func `a stray unsupported error during the ARM probe does not latch stock reads`() async throws {
    let (session, transport) = try await startedSession()
    let (polling, stored) = try await makePolling(session)
    let radio = Radio()
    await radio.setStrayErrorsBeforeArm(1)
    await radio.append((0..<3).map(dmFrame))
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    let count = try await polling.pollAllMessages()

    #expect(count == 3)
    #expect(await radio.arms == 2, "a second ARM confirms the first answer")
    #expect(await radio.stockFetches == 0, "queue sync from the first drain")
    #expect(await radio.nexts >= 4)
    #expect(await stored.texts.count == 3)
    await polling.stopMessageEventMonitoring()
  }

  @Test(.timeLimit(.minutes(1)))
  func `a stray unsupported error during a NEXT neither fails the drain nor latches stock reads`() async throws {
    let (session, transport) = try await startedSession()
    let (polling, stored) = try await makePolling(session)
    let radio = Radio()
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    _ = try await polling.pollAllMessages()   // ARM answered: queue sync on
    await radio.setStrayErrorsBeforeNext(1)
    await radio.append((0..<3).map(dmFrame))
    let first = try await polling.pollAllMessages()
    await radio.append((3..<6).map(dmFrame))
    let second = try await polling.pollAllMessages()

    #expect(first == 3 && second == 3)
    #expect(await radio.stockFetches == 0, "every drain read with queue sync")
    #expect(await radio.arms == 1, "asked once for the connection")
    #expect(await stored.texts.count == 6)
    await polling.stopMessageEventMonitoring()
  }

  // MARK: - Stock firmware and new connections

  @Test(.timeLimit(.minutes(1)))
  func `stock firmware keeps the stock drain and is asked only once per connection`() async throws {
    let (session, transport) = try await startedSession()
    let (polling, stored) = try await makePolling(session)
    let radio = Radio(queueSync: false)
    await radio.append((0..<3).map(dmFrame))
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    let first = try await polling.pollAllMessages()
    #expect(first == 3)
    #expect(await radio.arms == 2, "two unsupported answers in a row settle it")
    await radio.append((3..<5).map(dmFrame))
    let second = try await polling.pollAllMessages()

    #expect(second == 2)
    #expect(await radio.arms == 2, "not asked again on this connection")
    #expect(await radio.nexts == 0)
    #expect(await stored.texts.count == 5)
    await polling.stopMessageEventMonitoring()
  }

  @Test(.timeLimit(.minutes(1)))
  func `each connection asks again whatever the last one found`() async throws {
    // The first connection found stock reads (e.g. the radio ran stock firmware then).
    let (oldSession, oldTransport) = try await startedSession()
    let (oldPolling, _) = try await makePolling(oldSession)
    let stockRadio = Radio(queueSync: false)
    let oldServer = serve(stockRadio, on: oldTransport)
    _ = try await oldPolling.pollAllMessages()
    oldServer.cancel()
    await oldPolling.stopMessageEventMonitoring()
    #expect(await stockRadio.nexts == 0)

    // A reconnect builds a new session and polling service, which probes afresh.
    let (session, transport) = try await startedSession()
    let (polling, stored) = try await makePolling(session)
    let radio = Radio()
    await radio.append((0..<2).map(dmFrame))
    let server = serve(radio, on: transport)
    defer { server.cancel() }

    let count = try await polling.pollAllMessages()

    #expect(count == 2)
    #expect(await radio.arms == 1)
    #expect(await radio.stockFetches == 0)
    #expect(await stored.texts.count == 2)
    await polling.stopMessageEventMonitoring()
  }
}
