import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// The stats barrier on official companion firmware: the radio's received-packet counter
/// (`CMD_GET_STATS` packets) against the 0x88 frames that reached the session, over a real
/// session and a radio that answers as upstream firmware does.
@Suite("Stock delivery monitor")
struct StockDeliveryMonitorTests {
  // MARK: - Measurement

  @Test
  func `packets the radio heard without a frame reaching the app are counted as missed`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .packets28)
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    #expect(await monitor.totals == nil, "one reading measures nothing yet")

    await radio.hear(43, delivered: 40)
    await monitor.sample()
    try await waitUntil("the second reading is counted") { await monitor.totals != nil }

    #expect(await monitor.totals == StockRadioLoss(heard: 43, missed: 3))
    #expect(await session.receivedRxLogFrames == 40)
    await monitor.stop()
    await session.stop()
  }

  @Test
  func `v1.11 counters without receive errors measure the same way`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .packets24, packetsHeard: 7)
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    await radio.hear(12, delivered: 12)
    await monitor.sample()
    try await waitUntil("the second reading is counted") { await monitor.totals != nil }

    #expect(await monitor.totals == StockRadioLoss(heard: 12, missed: 0))
    await session.stop()
  }

  @Test
  func `a radio without the stats command is asked once and never again`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .unsupported)
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for") { await radio.statsRequests == 1 }
    try await waitUntil("the session keeps the unsupported answer") { await session.statsSupport == false }

    await radio.hear(5, delivered: 5)
    #expect(await monitor.sample() == nil)
    #expect(await monitor.mark() == nil)
    await monitor.setWatching(true)
    await monitor.start(measuring: true)
    try await Task.sleep(for: .milliseconds(100))

    #expect(await monitor.totals == nil)
    #expect(await radio.statsRequests == 1, "no further CMD_GET_STATS is written")
    await session.stop()
  }

  @Test
  func `a radio whose counter went back is measured again from there`() async throws {
    let radio = StockCompanionRadio(packetsHeard: 100)
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    await radio.hear(10, delivered: 10)
    await monitor.sample()
    try await waitUntil("the second reading is counted") { await monitor.totals != nil }
    #expect(await monitor.totals == StockRadioLoss(heard: 10, missed: 0))

    // The counter wraps or restarts: 4 packets heard, 3 frames, but the counter now reads 9.
    await radio.setPacketsHeard(5)
    await radio.hear(4, delivered: 3)
    await monitor.sample()
    try await waitUntil("the reset reading is read") { await radio.statsRequests == 3 }
    await radio.hear(5, delivered: 4)
    await monitor.sample()
    try await waitUntil("the next reading is counted from the reset") { await monitor.totals?.heard == 15 }

    #expect(await monitor.totals == StockRadioLoss(heard: 15, missed: 1))
    await session.stop()
  }

  @Test
  func `a reading another screen asked for is counted`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    await radio.hear(8, delivered: 6)

    // Device readings ask for the same counters (SettingsService.getStatsPackets).
    let stats = try await session.getStatsPackets()
    #expect(stats.appRxLogFrames == 6)
    try await waitUntil("the other requester's reply is counted") { await monitor.totals != nil }

    #expect(await monitor.totals == StockRadioLoss(heard: 8, missed: 2))
    #expect(await radio.statsRequests == 2)
    await session.stop()
  }

  /// A Cairn radio that opted a stock link in behind a lost SUBSCRIBE reply sends RX_SYNC records,
  /// paced by its journal, in place of 0x88 frames: its counter no longer pairs with what arrives,
  /// so the connection stops being measured instead of reporting packets the app did receive.
  @Test
  func `live RX_SYNC records on a stock link stop the measurement`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    await radio.hear(4, delivered: 4)
    await monitor.sample()
    try await waitUntil("the second reading is counted") { await monitor.totals != nil }
    #expect(await monitor.totals == StockRadioLoss(heard: 4, missed: 0))

    await radio.hear(3, delivered: 0)
    for seq: UInt32 in 1...3 {
      await radio.push(Self.liveRecord(seq: seq))
    }
    await monitor.sample()
    try await waitUntil("the reading is read") { await radio.statsRequests == 3 }
    try await waitUntil("the measurement stops") { await monitor.totals == nil }

    await radio.hear(2, delivered: 2)
    #expect(await monitor.sample() == nil, "nothing more is asked on this connection")
    #expect(await monitor.mark() == nil)
    #expect(await radio.statsRequests == 3)
    await session.stop()
  }

  // MARK: - Watching

  @Test
  func `a watched monitor reads at once and then every 30 seconds`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let sleeper = ManualSleeper()
    let monitor = StockDeliveryMonitor(
      session: session,
      quiet: .zero,
      sleep: { try await sleeper.sleep(for: $0) }
    )

    await monitor.setWatching(true)
    await monitor.start(measuring: true)
    try await waitUntil("a watched start reads at once") { await sleeper.requested.count == 1 }
    #expect(await radio.statsRequests == 1)
    #expect(await sleeper.requested == [.seconds(30)])

    await radio.hear(3, delivered: 2)
    await sleeper.wakeAll()
    try await waitUntil("the next reading follows the wait") { await sleeper.requested.count == 2 }
    #expect(await radio.statsRequests == 2)
    try await waitUntil("the reading is counted") { await monitor.totals != nil }
    #expect(await monitor.totals == StockRadioLoss(heard: 3, missed: 1))

    await monitor.setWatching(false)
    await sleeper.wakeAll()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await radio.statsRequests == 2, "an unwatched monitor stops reading")
    #expect(await sleeper.requested.count == 2)
    await session.stop()
  }

  @Test
  func `closing one of two watching windows keeps the other measured`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let sleeper = ManualSleeper()
    let monitor = StockDeliveryMonitor(session: session, quiet: .zero, sleep: { try await sleeper.sleep(for: $0) })
    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }

    // Two RX Log windows on iPad or Mac, then one closes
    await monitor.setWatching(true)
    await monitor.setWatching(true)
    try await waitUntil("watching reads at once") { await sleeper.requested.count == 1 }
    await monitor.setWatching(false)
    await sleeper.wakeAll()
    try await waitUntil("the open window's readings go on") { await sleeper.requested.count == 2 }
    #expect(await radio.statsRequests == 3)

    // The last window closes
    await monitor.setWatching(false)
    await sleeper.wakeAll()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await radio.statsRequests == 3, "no window watches")
    #expect(await sleeper.requested.count == 2)
    // An extra close changes nothing; the next open watches again
    await monitor.setWatching(false)
    await monitor.setWatching(true)
    try await waitUntil("a new window reads at once") { await radio.statsRequests == 4 }
    await monitor.stop()
    await session.stop()
  }

  @Test
  func `watching an idle monitor reads nothing until it starts`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let sleeper = ManualSleeper()
    let monitor = StockDeliveryMonitor(session: session, quiet: .zero, sleep: { try await sleeper.sleep(for: $0) })

    await monitor.setWatching(true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await radio.statsRequests == 0)

    await monitor.start(measuring: true)
    try await waitUntil("the watch starts with the measurement") { await radio.statsRequests == 1 }
    await monitor.stop()
    await session.stop()
  }

  // MARK: - Windows

  @Test
  func `a mark measures the packets missed over a window`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)
    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }
    await radio.hear(6, delivered: 6)

    let mark = try #require(await monitor.mark())
    // A scan's replies: 20 packets heard, 17 frames reached the app.
    await radio.hear(20, delivered: 17)
    #expect(await monitor.missed(since: mark) == 3)

    await radio.hear(4, delivered: 4)
    #expect(await monitor.missed(since: mark) == 3, "a mark keeps measuring from where it was taken")
    await session.stop()
  }

  @Test
  func `a mark from an earlier connection doesn't compare`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)
    await monitor.start(measuring: true)
    let mark = try #require(await monitor.mark())

    await monitor.start(measuring: true)
    await radio.hear(2, delivered: 1)
    #expect(await monitor.missed(since: mark) == nil)
    await session.stop()
  }

  @Test
  func `an unanswered reading leaves the window unmeasured`() async throws {
    let radio = StockCompanionRadio()
    let session = try await radio.startedSession(defaultTimeout: 0.2)
    let monitor = Self.monitor(session)
    await monitor.start(measuring: true)
    let mark = try #require(await monitor.mark())

    await radio.setStatsAnswer(.silent)
    await radio.hear(5, delivered: 2)
    #expect(await monitor.missed(since: mark) == nil)
    await session.stop()
  }

  @Test
  func `firmware without the stats command is never asked`() async throws {
    let radio = StockCompanionRadio(statsAnswer: .unsupported)
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)

    await monitor.start(measuring: false)
    await monitor.setWatching(true)
    #expect(await monitor.mark() == nil)
    #expect(await monitor.sample() == nil)
    try await Task.sleep(for: .milliseconds(50))

    #expect(await radio.statsRequests == 0)
    #expect(await monitor.totals == nil)
    await session.stop()
  }

  // MARK: - Link Drops

  @Test
  func `frames the app's transport refused are counted once, inside missed`() async throws {
    let radio = StockCompanionRadio()
    await radio.setDroppedFrameCount(7) // an earlier connection's drops
    let session = try await radio.startedSession()
    let monitor = Self.monitor(session)
    await monitor.start(measuring: true)
    try await waitUntil("the baseline reading is asked for at once") { await radio.statsRequests == 1 }

    // 10 packets heard: 8 frames arrive, the app's full receive buffer refused the other 2.
    await radio.hear(10, delivered: 8, linkDropped: 2)
    await monitor.sample()
    try await waitUntil("the reading is counted") { await monitor.totals != nil }

    #expect(await monitor.linkDrops == 2, "only this connection's drops")
    #expect(await monitor.totals == StockRadioLoss(heard: 10, missed: 2))
    await session.stop()
  }

  // MARK: - Readings

  @Test
  func `readings compare only when the later one is newer and consistent`() {
    let base = StockBarrierSample(received: 100, appFrames: 50)
    #expect(base.step(to: StockBarrierSample(received: 110, appFrames: 57)) == .counted(heard: 10, missed: 3))
    #expect(base.step(to: base) == .counted(heard: 0, missed: 0))
    #expect(base.step(to: StockBarrierSample(received: 95, appFrames: 48)) == .stale)
    #expect(base.step(to: StockBarrierSample(received: 100, appFrames: 49)) == .stale)
    #expect(base.step(to: StockBarrierSample(received: 3, appFrames: 52)) == .reset)
    #expect(base.step(to: StockBarrierSample(received: 102, appFrames: 55)) == .reset, "more frames than packets")
    #expect(base.step(to: StockBarrierSample(received: 120, appFrames: 10)) == .reset, "the session's count restarted")
    #expect(base.step(to: StockBarrierSample(received: 110, appFrames: 50, liveRecords: 10)) == .unmeasurable, "RX_SYNC records")
    let withRecords = StockBarrierSample(received: 100, appFrames: 50, liveRecords: 7)
    #expect(withRecords.step(to: StockBarrierSample(received: 104, appFrames: 53, liveRecords: 7)) == .counted(heard: 4, missed: 1))
    #expect(withRecords.step(to: StockBarrierSample(received: 104, appFrames: 53, liveRecords: 2)) == .reset)
  }

  @Test
  func `a stale reading is ignored and a reset keeps the totals so far`() {
    var ledger = StockLossLedger()
    #expect(ledger.ingest(StockBarrierSample(received: 10, appFrames: 0)) == nil)
    #expect(ledger.totals == nil)
    ledger.ingest(StockBarrierSample(received: 20, appFrames: 8))
    ledger.ingest(StockBarrierSample(received: 15, appFrames: 5))
    #expect(ledger.totals == StockRadioLoss(heard: 10, missed: 2))
    ledger.ingest(StockBarrierSample(received: 2, appFrames: 9))
    ledger.ingest(StockBarrierSample(received: 6, appFrames: 13))
    #expect(ledger.totals == StockRadioLoss(heard: 14, missed: 2))
  }

  // MARK: - Helpers

  /// A monitor that doesn't wait for a quiet link (the radio model's frames arrive at once).
  private static func monitor(_ session: MeshCoreSession) -> StockDeliveryMonitor {
    StockDeliveryMonitor(session: session, quiet: .zero)
  }

  /// A whole live RX_SYNC record (0xC8) of a short packet.
  private static func liveRecord(seq: UInt32) -> Data {
    var frame = Data([0xC8, 0x00])
    withUnsafeBytes(of: seq.littleEndian) { frame.append(contentsOf: $0) }
    return frame + Data([0xFA, 0x00, 0x00, 0x00, 0x14, 0xA6, 0x11, 0x00, UInt8(seq & 0xFF)])
  }
}

// MARK: - Test Doubles

/// A sleep each test wakes by hand, recording what was asked for.
actor ManualSleeper {
  private(set) var requested: [Duration] = []
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

  func sleep(for duration: Duration) async throws {
    requested.append(duration)
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func wakeAll() {
    let woken = waiters
    waiters.removeAll()
    for continuation in woken.values {
      continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
