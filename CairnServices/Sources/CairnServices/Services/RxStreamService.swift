import Foundation
import MeshCore

private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "RxStreamService")

/// How a connection's received packets reach the app.
public enum RxStreamMode: Sendable, Equatable {
  /// Not started, or stopped.
  case idle
  /// Asking the radio whether it offers RX_SYNC.
  case probing
  /// Plain 0x88 frames: the radio may drop packets when its link is busy, and nothing fetches
  /// them again. From companion v1.11 the radio's packet counter measures that loss
  /// (``RxStreamDeliveryStats/radioLoss``).
  case stock
  /// Cairn RX_SYNC: every packet numbered, gaps fetched again, loss at the radio reported.
  case synced
}

/// Why a connection receives plain 0x88 frames (``RxStreamMode/stock``).
public enum RxStockReason: Sendable, Equatable {
  /// The radio runs firmware other than Cairn's, which is never asked for RX_SYNC.
  case otherFirmware
  /// A Cairn radio whose build has no RX_SYNC (it answered the probe unsupported).
  case recoveryUnsupported
  /// A Cairn radio whose RX_SYNC didn't start on this connection: no answer, a refusal such as
  /// BUSY, another error, or a SUBSCRIBE left off. The next connection asks again.
  case recoveryFailed
}

/// A connection's delivery of received packets, for the RX Log and Network Health screens.
public struct RxStreamDeliveryStats: Sendable, Equatable {
  public let mode: RxStreamMode
  /// The session's RX_SYNC counters (all zero in stock mode).
  public let radio: RxDeliveryStats
  /// LOSS reports the radio sent this connection.
  public let lossReports: Int
  /// Frames the radio reported refusing because the link's send queue was full.
  public let refusedFrames: Int
  /// Events the app's own receive subscriptions dropped while they lagged, by label. Counted on
  /// every firmware.
  public let appDrops: [String: Int]
  /// Why this connection is in stock mode, or nil in any other mode.
  public let stockReason: RxStockReason?
  /// Frames the app's Bluetooth transport refused on this connection because its receive buffer
  /// was full. Counted on every firmware. In stock mode these packets are already inside
  /// ``radioLoss``'s missed count.
  public let linkDrops: Int
  /// In stock mode, the packets the radio counted on this connection and how many never reached
  /// the app, measured with the radio's own packet counter (companion v1.11+). Nil in other
  /// modes, on older firmware, and until two readings have arrived.
  public let radioLoss: StockRadioLoss?
  /// In stock mode, the longest received packet, in raw bytes, the radio passes to the app
  /// (``DeviceDTO/maxForwardedRxPacketLength``); longer ones never arrive. Nil in other modes.
  public let forwardLimit: Int?

  public init(
    mode: RxStreamMode,
    radio: RxDeliveryStats,
    lossReports: Int,
    refusedFrames: Int,
    appDrops: [String: Int],
    stockReason: RxStockReason? = nil,
    linkDrops: Int = 0,
    radioLoss: StockRadioLoss? = nil,
    forwardLimit: Int? = nil
  ) {
    self.mode = mode
    self.radio = radio
    self.lossReports = lossReports
    self.refusedFrames = refusedFrames
    self.appDrops = appDrops
    self.stockReason = stockReason
    self.linkDrops = linkDrops
    self.radioLoss = radioLoss
    self.forwardLimit = forwardLimit
  }
}

/// Where a connection's delivery stood at one moment (``RxStreamService/deliveryMark()``), for
/// counting the packets the radio heard over a window, such as a scan's listen time, that never
/// reached the app (``RxStreamService/packetsMissed(since:)``).
public struct RxDeliveryMark: Sendable, Equatable {
  enum Basis: Sendable, Equatable {
    /// The radio's packet counter against the 0x88 frames that reached the session (stock).
    case stock(StockDeliveryMark)
    /// RX_SYNC records lost at the radio or never fetched again (Cairn).
    case synced(epoch: UInt32?, lost: Int)
  }

  /// The ``RxStreamService`` start it was taken in: marks from another connection don't compare.
  let connection: UInt64
  let basis: Basis
}

/// Turns on a Cairn companion's RX_SYNC delivery for each connection
/// (`CMD_CAIRN_FW` sub 0x07, the firmware's ui-l2/net/RX_SYNC.md).
///
/// On start, a device whose firmware may offer it (``DeviceDTO/supportsRxSync``) is probed with
/// STATE. Firmware that answers unsupported stays on stock 0x88 frames for this connection; a
/// probe with no reply does too, and the next connection asks again. A supported radio is then
/// subscribed, resuming after the RX log's stored cursor (at most ``resumeMax`` records). A
/// SUBSCRIBE with no reply is sent again once the link is quiet (``subscribeRetries``), and one
/// that still gets none is turned off, so the radio never pushes records to a stock link. The
/// session renews the subscription after each `APP_START`. LOSS reports for refused advert or
/// message pushes go to the injected callbacks, so the data those pushes carried is fetched again.
///
/// A connection that settles on stock frames records why (``RxStockReason``), and its packets
/// that never reached the app are measured with the radio's own packet counter where the firmware
/// has one (companion v1.11+, ``StockDeliveryMonitor``).
public actor RxStreamService {
  /// The session operations this service uses.
  public typealias Session = CairnRxSyncSessionOps & SessionEventStreaming

  /// The most records a resume asks the radio to send again.
  static let resumeMax: UInt16 = 512

  /// Seconds to wait for the radio's answer to STATE or SUBSCRIBE.
  static let replyTimeout: TimeInterval = 5

  /// SUBSCRIBEs sent again after one got no reply. The radio opts the link in before it writes
  /// the reply, so a reply lost in a full send queue (or one later than the wait) leaves it
  /// pushing RX_SYNC records, and no 0x88 frames, to a link the app would otherwise treat as
  /// stock. The firmware takes a repeat as a renewal.
  static let subscribeRetries = 1

  /// The receive subscriptions whose drops ``deliveryStats()`` reports.
  public static let monitoredLabels = [RxLogService.eventLabel, "neighbours"]

  private let session: any Session
  private let cursorStore: any RxStreamCursorPersisting
  private let onAdvertLoss: @Sendable () async -> Void
  private let onMessageLoss: @Sendable () async -> Void
  private let deliveryMonitor: StockDeliveryMonitor?

  public private(set) var mode: RxStreamMode = .idle
  /// Why the current connection is in stock mode, or nil in any other mode.
  public private(set) var stockReason: RxStockReason?
  private var lossReports = 0
  private var refusedFrames = 0
  /// Counts starts, so a delivery mark from another connection is never compared.
  private var connection: UInt64 = 0
  /// The connected device's capabilities that stock delivery depends on.
  private var deviceSupportsStats = false
  private var deviceForwardLimit: Int?
  private var startTask: Task<Void, Never>?
  private var lossTask: Task<Void, Never>?

  /// - Parameters:
  ///   - session: The connection's session.
  ///   - cursorStore: Where the RX log keeps each radio's resume cursor.
  ///   - deliveryMonitor: Measures stock delivery with the radio's packet counter, or nil to leave
  ///     it unmeasured.
  ///   - onAdvertLoss: Called when the radio refused an advert push (0x80 or 0x8A): resync adverts.
  ///   - onMessageLoss: Called when the radio refused a messages-waiting push (0x83): fetch messages.
  public init(
    session: any Session,
    cursorStore: any RxStreamCursorPersisting,
    deliveryMonitor: StockDeliveryMonitor? = nil,
    onAdvertLoss: @escaping @Sendable () async -> Void = {},
    onMessageLoss: @escaping @Sendable () async -> Void = {}
  ) {
    self.session = session
    self.cursorStore = cursorStore
    self.deliveryMonitor = deliveryMonitor
    self.onAdvertLoss = onAdvertLoss
    self.onMessageLoss = onMessageLoss
  }

  deinit {
    startTask?.cancel()
    lossTask?.cancel()
  }

  // MARK: - Lifecycle

  /// Has the session hold plain 0x88 frames until this connection's SUBSCRIBE is answered, for a
  /// device that may offer RX_SYNC. Called before the RX log and the neighbour table subscribe:
  /// a resumed SUBSCRIBE sends every packet heard since the stored cursor again as a record, so
  /// the frames held are dropped then instead of reaching those consumers twice; otherwise
  /// (stock, a live start, a failed probe) they are passed on. ``start(radioID:device:)`` holds too.
  public func prepare(device: DeviceDTO?) async {
    guard device?.supportsRxSync == true else { return }
    await session.beginRxSyncHold()
  }

  /// Starts the probe for this connection and returns once the session holds 0x88 frames for it
  /// (see ``prepare(device:)``); ``waitForStart()`` waits for the probe. A device that isn't Cairn
  /// firmware is never asked: it stays in stock mode.
  public func start(radioID: UUID, device: DeviceDTO?) async {
    await stop()
    connection &+= 1
    deviceSupportsStats = device?.supportsStats ?? false
    deviceForwardLimit = device?.maxForwardedRxPacketLength
    guard device?.supportsRxSync == true else {
      mode = .stock
      stockReason = .otherFirmware
      await startStockMeasurement()
      return
    }
    mode = .probing
    await session.beginRxSyncHold()
    startTask = Task { [weak self] in
      await self?.probeAndSubscribe(radioID: radioID)
    }
  }

  /// Waits until the probe started by ``start(radioID:device:)`` has settled the mode.
  public func waitForStart() async {
    await startTask?.value
  }

  /// Stops listening for LOSS reports and measuring stock delivery. The radio forgets the
  /// subscription when the link drops.
  public func stop() async {
    startTask?.cancel()
    startTask = nil
    lossTask?.cancel()
    lossTask = nil
    mode = .idle
    stockReason = nil
    await deliveryMonitor?.stop()
  }

  /// This connection's delivery so far.
  public func deliveryStats() async -> RxStreamDeliveryStats {
    var appDrops: [String: Int] = [:]
    for label in Self.monitoredLabels {
      appDrops[label] = await session.eventDropCount(label: label)
    }
    let mode = mode
    let isStock = mode == .stock
    let stockReason = isStock ? stockReason : nil
    let radioLoss = isStock ? await deliveryMonitor?.totals : nil
    let linkDrops = await deliveryMonitor?.linkDrops ?? 0
    return await RxStreamDeliveryStats(
      mode: mode,
      radio: session.rxDeliveryStats,
      lossReports: lossReports,
      refusedFrames: refusedFrames,
      appDrops: appDrops,
      stockReason: stockReason,
      linkDrops: linkDrops,
      radioLoss: radioLoss,
      forwardLimit: isStock ? deviceForwardLimit : nil
    )
  }

  /// Keeps stock delivery measured while any screen watches (an open RX Log or Traffic screen):
  /// the radio's packet counter is read at once and then every 30 seconds. Each screen passes
  /// `true` when it opens and `false` when it closes; the measuring stops when the last one
  /// closes. Kept across connections.
  public func setDeliveryWatching(_ watching: Bool) async {
    await deliveryMonitor?.setWatching(watching)
  }

  /// Where this connection's delivery stands now, for ``packetsMissed(since:)``: a fresh reading
  /// of the radio's packet counter in stock mode, RX_SYNC's loss counters in synced mode. Nil
  /// when delivery can't be measured (firmware without the stats command, no reply, not started).
  public func deliveryMark() async -> RxDeliveryMark? {
    let connection = connection
    switch mode {
    case .stock:
      guard let mark = await deliveryMonitor?.mark(), connection == self.connection, mode == .stock else { return nil }
      return RxDeliveryMark(connection: connection, basis: .stock(mark))
    case .synced:
      let radio = await session.rxDeliveryStats
      return RxDeliveryMark(connection: connection, basis: .synced(epoch: radio.epoch, lost: radio.lostAtRadio + radio.unrecovered))
    case .idle, .probing:
      return nil
    }
  }

  /// The packets the radio heard since `mark` that never reached the app: from a new reading of
  /// the radio's packet counter in stock mode, records RX_SYNC lost at the radio or couldn't
  /// fetch again in synced mode. Nil when `mark` doesn't compare with now (another connection,
  /// another mode, a counter that went back) or the counters can't be read.
  public func packetsMissed(since mark: RxDeliveryMark) async -> Int? {
    guard mark.connection == connection else { return nil }
    switch (mark.basis, mode) {
    case let (.stock(stockMark), .stock):
      guard let missed = await deliveryMonitor?.missed(since: stockMark), mark.connection == connection else { return nil }
      return missed
    case let (.synced(epoch, lost), .synced):
      let radio = await session.rxDeliveryStats
      guard epoch == nil || radio.epoch == epoch else { return nil }
      let missed = radio.lostAtRadio + radio.unrecovered - lost
      return missed >= 0 ? missed : nil
    default:
      return nil
    }
  }

  /// Measures this stock connection's delivery, where the firmware has the stats command.
  private func startStockMeasurement() async {
    await deliveryMonitor?.start(measuring: deviceSupportsStats)
  }

  // MARK: - Probe and Subscribe

  private func probeAndSubscribe(radioID: UUID) async {
    // Listen before subscribing: a LOSS can follow the SUBSCRIBE reply at once.
    let losses = await session.events(filter: .cairnRxLoss)
    guard !Task.isCancelled else {
      await session.releaseRxSyncHold()
      return
    }
    lossTask = Task { [weak self] in
      for await event in losses {
        guard !Task.isCancelled else { break }
        if case let .cairnRxLoss(loss) = event {
          await self?.handle(loss)
        }
      }
    }

    let state: CairnRxSyncState
    do {
      state = try await session.cairnRxSyncState(timeout: Self.replyTimeout)
    } catch {
      // no SUBSCRIBE follows: the frames held since start go on to their consumers
      await session.releaseRxSyncHold()
      await settleStock(after: error, step: "STATE")
      return
    }
    guard !Task.isCancelled else {
      await session.releaseRxSyncHold()
      return
    }

    // A cursor from another epoch belongs to a journal the radio no longer has (it rebooted).
    let stored = try? await cursorStore.fetchRxStreamCursor(radioID: radioID)
    var resume = stored
    if let stored, stored.epoch != state.epoch {
      await resetCursor(radioID: radioID, staleEpoch: stored.epoch)
      resume = nil
    }

    // The records held since the stored cursor were heard on the channel the record at it was,
    // unless the radio has moved since: the session stamps them with it while the radio still
    // reports that channel (the same epoch means it hasn't rebooted).
    if let resume, let channel = try? await cursorStore.fetchRxStreamCursorChannel(radioID: radioID, cursor: resume) {
      await session.trustRxBacklog(channel: channel, epoch: resume.epoch, afterSeq: resume.seq)
    }

    let result: CairnRxSubscribeResult
    do {
      result = try await subscribe(resume: &resume, heardThrough: state.lastSeq)
    } catch {
      // the session passed on the held frames when the SUBSCRIBE failed
      if let meshError = error as? MeshCoreError, case .timeout = meshError, !Task.isCancelled {
        await optOutAfterLostReplies()
      }
      await settleStock(after: error, step: "SUBSCRIBE")
      return
    }
    guard !Task.isCancelled else { return }

    // The radio can reboot between STATE and SUBSCRIBE.
    if let resume, resume.epoch != result.epoch {
      await resetCursor(radioID: radioID, staleEpoch: resume.epoch)
    }
    mode = result.isOn ? .synced : .stock
    if result.isOn {
      logger.info("RX_SYNC on: resumed=\(result.resumed) cursor=\(result.cursor) last=\(result.lastSeq)")
    } else {
      logger.warning("RX_SYNC SUBSCRIBE left off; stock delivery until the next connection")
      stockReason = .recoveryFailed
      lossTask?.cancel()
      lossTask = nil
      await startStockMeasurement()
    }
  }

  /// SUBSCRIBE on, sent again up to ``subscribeRetries`` times while no reply comes. Each retry
  /// waits for a quiet link and holds 0x88 frames again, and asks live: the frames held for the
  /// first try were passed on when it failed, and a resume would send those packets again as
  /// records. The records a resume would have sent from before those frames, after the stored
  /// cursor through `lastSeq` (the newest the STATE probe saw), are still owed: the session
  /// fetches them as backfill (``CairnRxBacklog``), so the catch-up isn't skipped. `resume` is
  /// left as the SUBSCRIBE that was answered asked.
  private func subscribe(resume: inout RxStreamCursor?, heardThrough lastSeq: UInt32) async throws -> CairnRxSubscribeResult {
    let backlog = resume.map {
      CairnRxBacklog(epoch: $0.epoch, afterSeq: $0.seq, throughSeq: lastSeq, limit: Self.resumeMax)
    }
    var retries = 0
    while true {
      do {
        return try await session.setCairnRxSync(
          on: true,
          resumeEpoch: resume?.epoch ?? 0,
          resumeSeq: resume?.seq ?? 0,
          resumeMax: Self.resumeMax,
          timeout: Self.replyTimeout
        )
      } catch MeshCoreError.timeout where retries < Self.subscribeRetries && !Task.isCancelled {
        retries += 1
        logger.warning("RX_SYNC SUBSCRIBE got no reply; asking again once the link is quiet")
        await session.waitForQuietLink()
        guard !Task.isCancelled else { throw CancellationError() }
        await session.beginRxSyncHold()
        if let backlog { await session.expectRxBacklog(backlog) }
        resume = nil
      }
    }
  }

  /// Best effort after every SUBSCRIBE went unanswered: the radio may have opted the link in all
  /// the same, and would push records (no 0x88 frames) to a connection that settles on stock. A
  /// lost answer to this changes nothing worse.
  private func optOutAfterLostReplies() async {
    await session.waitForQuietLink()
    guard !Task.isCancelled else { return }
    do {
      _ = try await session.setCairnRxSync(on: false, resumeEpoch: 0, resumeSeq: 0, resumeMax: 0, timeout: Self.replyTimeout)
    } catch {
      logger.warning("RX_SYNC SUBSCRIBE off got no answer either: \(error.localizedDescription)")
    }
  }

  /// Stock mode for this connection after a failed STATE or SUBSCRIBE. Nothing is remembered, so
  /// the next connection asks again (an older Cairn build answers unsupported at once).
  private func settleStock(after error: Error, step: String) async {
    guard !Task.isCancelled else { return }
    mode = .stock
    lossTask?.cancel()
    lossTask = nil
    switch error {
    case let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue:
      logger.debug("RX_SYNC not supported by this firmware")
      stockReason = .recoveryUnsupported
    case MeshCoreError.timeout:
      logger.warning("RX_SYNC \(step) got no reply; stock delivery until the next connection")
      stockReason = .recoveryFailed
    default:
      logger.warning("RX_SYNC \(step) failed: \(error.localizedDescription)")
      stockReason = .recoveryFailed
    }
    await startStockMeasurement()
  }

  private func resetCursor(radioID: UUID, staleEpoch: UInt32) async {
    logger.info("RX_SYNC journal epoch changed from \(staleEpoch); resume cursor reset")
    do {
      try await cursorStore.saveRxStreamCursor(nil, radioID: radioID)
    } catch {
      logger.error("Failed to reset the RX_SYNC cursor: \(error.localizedDescription)")
    }
  }

  // MARK: - Loss

  /// Routes a LOSS report: refused advert pushes resync adverts, a refused messages-waiting push
  /// fetches messages. Overwritten journal records are counted by the session.
  private func handle(_ loss: CairnRxLoss) async {
    lossReports += 1
    refusedFrames += Int(loss.refusedCount)
    logger.warning(
      "RX_SYNC loss: overwritten=\(loss.overwritten) refused=\(loss.refusedCount) mask=0x\(String(loss.refusedMask, radix: 16))"
    )
    if loss.refused(.advertisement) || loss.refused(.newAdvertisement) {
      await onAdvertLoss()
    }
    if loss.refused(.messagesWaiting) {
      await onMessageLoss()
    }
  }
}
