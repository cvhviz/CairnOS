import Foundation
import MeshCore

private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "StockDeliveryMonitor")

/// The session operations ``StockDeliveryMonitor`` uses.
public protocol StockDeliverySessionOps: Actor {
  /// Reads the radio's packet counters (`CMD_GET_STATS`, packets), stamped with the 0x88 frames
  /// the session had received when the reply arrived (``PacketStats/appRxLogFrames``).
  func getStatsPackets() async throws -> PacketStats

  /// Whether the radio answers `CMD_GET_STATS` on this connection: nil until asked, `false` after
  /// it answered unsupported.
  var statsSupport: Bool? { get async }

  /// Waits until the link has been free of pushed frames for `quiet`, for at most `maxWait`.
  func waitForQuietLink(quiet: Duration, maxWait: Duration) async

  /// Frames the transport threw away before the session read them, on this connection.
  var droppedTransportFrames: Int { get async }

  /// Subscribes to the session's events passing `filter`.
  func events(filter: EventFilter) async -> AsyncStream<MeshEvent>
}

extension MeshCoreSession: StockDeliverySessionOps {}

/// Packets a radio on stock firmware heard over a connection, and how many of them never reached
/// the app (``StockDeliveryMonitor/totals``).
public struct StockRadioLoss: Sendable, Equatable {
  /// Packets the radio counted as received.
  public let heard: Int
  /// Of ``heard``, the packets whose 0x88 frame never reached the session: dropped from the
  /// radio's full send queue, refused by the app's full Bluetooth buffer
  /// (``StockDeliveryMonitor/linkDrops``), or too long for the radio to pass on
  /// (``DeviceDTO/maxForwardedRxPacketLength``).
  public let missed: Int

  public init(heard: Int, missed: Int) {
    self.heard = heard
    self.missed = missed
  }
}

/// One reading of the radio's received-packet counter, paired with the 0x88 frames the session
/// had received when that reading arrived.
public struct StockBarrierSample: Sendable, Equatable {
  /// The radio's received-packet counter (``PacketStats/received``).
  public let received: UInt32
  /// The session's 0x88 frame count when the reply arrived (``PacketStats/appRxLogFrames``).
  public let appFrames: UInt64
  /// The session's live RX_SYNC record count when the reply arrived
  /// (``PacketStats/appLiveRxRecords``).
  public let liveRecords: UInt64

  public init(received: UInt32, appFrames: UInt64, liveRecords: UInt64 = 0) {
    self.received = received
    self.appFrames = appFrames
    self.liveRecords = liveRecords
  }

  /// The pair a session-read reply carries, or nil for counters no session stamped.
  init?(_ stats: PacketStats) {
    guard let appFrames = stats.appRxLogFrames else { return nil }
    self.init(received: stats.received, appFrames: appFrames, liveRecords: stats.appLiveRxRecords ?? 0)
  }

  /// How two readings compare.
  enum Step: Equatable {
    /// The later reading counts `heard` more packets, `missed` of them without a frame.
    case counted(heard: Int, missed: Int)
    /// An older reading than the one it is compared with.
    case stale
    /// The counters can't be compared (the radio's counter went back or wrapped, the session's
    /// count restarted, or more frames than packets): measure again from the later reading.
    case reset
    /// Live RX_SYNC records arrived between the readings: the radio opted this stock link in
    /// (behind a lost SUBSCRIBE reply) and sends records in place of 0x88 frames, at its journal's
    /// pace rather than in the pass that counts their packets. No pair of readings on this link
    /// is exact any more.
    case unmeasurable
  }

  /// How `next` compares with `self` as the earlier reading.
  ///
  /// The radio counts a packet and queues its 0x88 frame in the same main-loop pass, and its stats
  /// reply leaves through the same first-in-first-out queue, so a clean pair of readings never
  /// shows more new frames than new packets.
  func step(to next: StockBarrierSample) -> Step {
    if next.received <= received, next.appFrames <= appFrames, next != self {
      return .stale
    }
    guard next.received >= received, next.appFrames >= appFrames, next.liveRecords >= liveRecords else { return .reset }
    guard next.liveRecords == liveRecords else { return .unmeasurable }
    let heard = UInt64(next.received - received)
    let delivered = next.appFrames - appFrames
    guard heard >= delivered else { return .reset }
    return .counted(heard: Int(heard), missed: Int(heard - delivered))
  }
}

/// Where a stock delivery measurement stood at one moment (``StockDeliveryMonitor/mark()``).
public struct StockDeliveryMark: Sendable, Equatable {
  /// The monitor run it was taken in: marks from another connection don't compare.
  let run: UInt64
  let sample: StockBarrierSample
}

/// The running totals of a connection's stock delivery readings.
struct StockLossLedger: Sendable, Equatable {
  /// The reading the next one is compared with.
  private(set) var last: StockBarrierSample?
  private(set) var heard = 0
  private(set) var missed = 0
  /// Readings counted after the first.
  private(set) var steps = 0

  /// The totals, once a reading has followed the first.
  var totals: StockRadioLoss? {
    steps > 0 ? StockRadioLoss(heard: heard, missed: missed) : nil
  }

  /// Adds one reading, in the order the session received them. Returns how it compared, or nil
  /// for the first.
  @discardableResult
  mutating func ingest(_ next: StockBarrierSample) -> StockBarrierSample.Step? {
    guard let last else {
      self.last = next
      return nil
    }
    let step = last.step(to: next)
    switch step {
    case let .counted(heard, missed):
      self.heard += heard
      self.missed += missed
      steps += 1
      self.last = next
    case .stale:
      break
    case .reset, .unmeasurable:
      self.last = next
    }
    return step
  }
}

/// Measures, on firmware without Cairn RX_SYNC, how many packets the radio heard never reached
/// the app.
///
/// Official companion firmware (v1.11 and later) counts each packet it hears and queues that
/// packet's 0x88 frame in the same main-loop pass (companion-v1.17.1
/// src/helpers/radiolib/RadioLibWrappers.cpp:125-139, src/Dispatcher.cpp:196-199), and answers
/// `CMD_GET_STATS` packets with that counter through the same first-in-first-out send queue
/// (v1.18.0 examples/companion_radio/MyMesh.cpp:1943-1960). So when a stats reply arrives, every
/// 0x88 frame for a packet it counts has already arrived or been dropped, and the session stamps
/// the reply with its frame count (``PacketStats/appRxLogFrames``). Between two replies, the growth
/// of the radio's counter minus the growth of the frame count is the exact number of heard packets
/// that never reached the session.
///
/// Every packet-counter reply the session reads is counted, whoever asked for it, in the order it
/// arrived. The monitor asks for one when it starts, at once and then every
/// ``watchInterval`` while watched (``setWatching(_:)``), and for each ``mark()`` and
/// ``missed(since:)``, each after a quiet link so the reply finds room in the radio's queue.
/// Firmware without the stats command (companion v1.7 to v1.10) is never asked, and a radio that
/// answers it unsupported isn't asked again on that connection.
public actor StockDeliveryMonitor {
  /// How often a watched monitor reads the radio's counters.
  public static let watchInterval: Duration = .seconds(30)

  private enum State: Equatable {
    case idle
    case measuring
    /// The radio has no stats command on this connection.
    case unsupported
    /// The radio sends this connection RX_SYNC records, which its counter can't be compared with
    /// (``StockBarrierSample/Step/unmeasurable``).
    case unmeasurable
  }

  private let session: any StockDeliverySessionOps
  private let watchInterval: Duration
  private let quiet: Duration
  private let quietMaxWait: Duration
  private let sleep: @Sendable (Duration) async throws -> Void

  private var state: State = .idle
  /// Counts starts and stops, so a reading from an earlier connection is never counted.
  private var run: UInt64 = 0
  private var ledger = StockLossLedger()
  /// Screens watching (``setWatching(_:)``): each RX Log window on iPad and Mac is one.
  private var watchers = 0
  private var watching: Bool {
    watchers > 0
  }
  private var listenTask: Task<Void, Never>?
  private var baselineTask: Task<Void, Never>?
  private var watchTask: Task<Void, Never>?

  /// - Parameters:
  ///   - session: The connection's session.
  ///   - watchInterval: How often a watched monitor reads the radio's counters.
  ///   - quiet: How long the link must be free of pushes before each reading.
  ///   - quietMaxWait: The longest a reading waits for that quiet.
  ///   - sleep: Waits between watched readings.
  public init(
    session: any StockDeliverySessionOps,
    watchInterval: Duration = StockDeliveryMonitor.watchInterval,
    quiet: Duration = QuietLink.quiet,
    quietMaxWait: Duration = .seconds(2),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.session = session
    self.watchInterval = watchInterval
    self.quiet = quiet
    self.quietMaxWait = quietMaxWait
    self.sleep = sleep
  }

  deinit {
    listenTask?.cancel()
    baselineTask?.cancel()
    watchTask?.cancel()
  }

  // MARK: - Lifecycle

  /// Starts measuring this connection from scratch. With `measuring` false (firmware without
  /// the stats command, ``DeviceDTO/supportsStats``) or a radio that already answered it
  /// unsupported, nothing is ever asked and ``totals`` stays nil.
  ///
  /// The first reading is taken at once, and becomes the baseline unless another requester's
  /// reply arrives first.
  public func start(measuring: Bool) async {
    stop()
    guard measuring else { return }
    let run = run
    guard await session.statsSupport != false else {
      if run == self.run { state = .unsupported }
      return
    }
    let replies = await session.events(filter: EventFilter { event in
      if case .statsPackets = event { return true }
      return false
    })
    guard run == self.run else { return }
    state = .measuring
    listenTask = Task { [weak self] in
      for await event in replies {
        guard !Task.isCancelled else { break }
        if case let .statsPackets(stats) = event {
          await self?.ingest(stats, run: run)
        }
      }
    }
    if watching {
      startWatchLoop()
    } else {
      baselineTask = Task { [weak self] in
        await self?.sample()
      }
    }
  }

  /// Stops measuring and forgets the totals. Whether the monitor is watched is kept.
  public func stop() {
    run &+= 1
    state = .idle
    ledger = StockLossLedger()
    listenTask?.cancel()
    listenTask = nil
    baselineTask?.cancel()
    baselineTask = nil
    watchTask?.cancel()
    watchTask = nil
  }

  /// Reads the radio's counters at once and then every ``watchInterval`` while any screen
  /// watches (an open RX Log or Traffic screen), so ``totals`` stays current. Each screen calls it
  /// with `true` when it opens and `false` when it closes, so closing one window leaves another
  /// still watching. Kept across connections.
  public func setWatching(_ watching: Bool) {
    let wasWatching = self.watching
    if watching {
      watchers += 1
    } else {
      watchers = max(0, watchers - 1)
    }
    guard self.watching != wasWatching else { return }
    if self.watching {
      if state == .measuring { startWatchLoop() }
    } else {
      watchTask?.cancel()
      watchTask = nil
    }
  }

  // MARK: - Readings

  /// Packets the radio heard on this connection and how many never reached the app, or nil
  /// until two readings have arrived, for firmware without the stats command, and once the radio
  /// sends this connection RX_SYNC records.
  public var totals: StockRadioLoss? {
    state == .measuring ? ledger.totals : nil
  }

  /// Frames the app's transport refused on this connection (a full Bluetooth receive buffer).
  /// Counted on every firmware. On stock firmware these packets are already inside
  /// ``StockRadioLoss/missed``, which is measured after them.
  public var linkDrops: Int {
    get async { await session.droppedTransportFrames }
  }

  /// Reads the radio's counters after a quiet link. The reply is counted in ``totals`` as the
  /// session receives it. Nil when not measuring, when the radio doesn't answer, or when it has
  /// no stats command (which stops the measurement for this connection).
  @discardableResult
  public func sample() async -> StockBarrierSample? {
    guard state == .measuring else { return nil }
    let run = run
    await session.waitForQuietLink(quiet: quiet, maxWait: quietMaxWait)
    guard run == self.run, state == .measuring, !Task.isCancelled else { return nil }
    do {
      let stats = try await session.getStatsPackets()
      guard run == self.run else { return nil }
      return StockBarrierSample(stats)
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      if run == self.run { markUnsupported() }
      return nil
    } catch {
      logger.debug("Packet counters not read: \(error.localizedDescription)")
      return nil
    }
  }

  /// A reading to measure a window from, such as a scan's listen time, or nil when the radio's
  /// counters can't be read.
  public func mark() async -> StockDeliveryMark? {
    let run = run
    guard let sample = await sample(), run == self.run else { return nil }
    return StockDeliveryMark(run: run, sample: sample)
  }

  /// Packets the radio heard since `mark` that never reached the app, from a new reading. Nil
  /// when the readings can't be compared (another connection, a counter that went back) or the
  /// counters can't be read.
  public func missed(since mark: StockDeliveryMark) async -> Int? {
    guard mark.run == run else { return nil }
    guard let sample = await sample(), mark.run == run else { return nil }
    if case let .counted(_, missed) = mark.sample.step(to: sample) {
      return missed
    }
    return nil
  }

  // MARK: - Private

  private func ingest(_ stats: PacketStats, run: UInt64) {
    guard run == self.run, state == .measuring, let sample = StockBarrierSample(stats) else { return }
    switch ledger.ingest(sample) {
    case let .counted(heard, missed) where missed > 0:
      logger.info("Radio heard \(heard) packets since the last reading; \(missed) didn't reach the app")
    case .reset:
      logger.info("Radio packet counter can't be compared with the last reading; measuring again from here")
    case .unmeasurable:
      markUnmeasurable()
    default:
      break
    }
  }

  private func startWatchLoop() {
    watchTask?.cancel()
    baselineTask?.cancel()
    baselineTask = nil
    let interval = watchInterval
    let sleep = sleep
    watchTask = Task { [weak self] in
      while !Task.isCancelled {
        guard await self?.watchedReading() == true else { return }
        do {
          try await sleep(interval)
        } catch {
          return
        }
      }
    }
  }

  /// One watched reading. Returns whether the watch goes on.
  private func watchedReading() async -> Bool {
    await sample()
    return state == .measuring && watching
  }

  /// Stops measuring this connection: the radio sends it RX_SYNC records, so its loss would be
  /// counted wrong. ``totals`` stays nil rather than reporting packets the app did receive.
  private func markUnmeasurable() {
    logger.warning("Radio sends RX_SYNC records to this stock connection; delivery isn't measured on it")
    state = .unmeasurable
    ledger = StockLossLedger()
    listenTask?.cancel()
    listenTask = nil
    baselineTask?.cancel()
    baselineTask = nil
    watchTask?.cancel()
    watchTask = nil
  }

  private func markUnsupported() {
    logger.info("Radio has no stats command; delivery isn't measured on this connection")
    state = .unsupported
    ledger = StockLossLedger()
    listenTask?.cancel()
    listenTask = nil
    watchTask?.cancel()
    watchTask = nil
  }
}
