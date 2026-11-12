import Foundation

// MARK: - Cairn RX_SYNC (firmware's examples/companion_radio/ui-l2/net/RX_SYNC.md)

/// Session operations for a Cairn companion's receive journal (RX_SYNC): every packet the radio
/// hears, numbered, delivered in order and fetched again when a frame went missing.
public protocol CairnRxSyncSessionOps: Actor {
  /// Turns RX_SYNC delivery on (resuming after the app's last stored record) or off for this link.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without RX_SYNC; ``MeshCoreError/timeout`` if no reply arrives.
  func setCairnRxSync(
    on: Bool, resumeEpoch: UInt32, resumeSeq: UInt32, resumeMax: UInt16, timeout: TimeInterval?
  ) async throws -> CairnRxSubscribeResult

  /// Reads the radio's receive journal state.
  ///
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without RX_SYNC; ``MeshCoreError/timeout`` if no reply arrives.
  func cairnRxSyncState(timeout: TimeInterval?) async throws -> CairnRxSyncState

  /// Starts holding plain 0x88 frames until the next SUBSCRIBE is answered. Call it before the
  /// STATE probe: a resumed SUBSCRIBE sends the packets heard meanwhile again as records, so
  /// passing them on as well would deliver them twice.
  func beginRxSyncHold()

  /// Passes on the 0x88 frames held since ``beginRxSyncHold()`` when no SUBSCRIBE will follow
  /// (the probe failed).
  func releaseRxSyncHold() async

  /// Has the next SUBSCRIBE reply owe `backlog`: records the app never received that a live
  /// SUBSCRIBE skips past, fetched as backfill once delivery is on. Dropped when that SUBSCRIBE
  /// fails.
  func expectRxBacklog(_ backlog: CairnRxBacklog)

  /// Vouches that journal `epoch`'s records after `afterSeq` were heard on `channel`, so the ones
  /// the radio held from before this connection are stamped with it while it still reports that
  /// channel. Call it before the SUBSCRIBE whose backlog it covers.
  func trustRxBacklog(channel: ChannelKey, epoch: UInt32, afterSeq: UInt32)

  /// Asks the radio for records the app already had again, for a consumer that lost some.
  ///
  /// - Returns: `false` when RX_SYNC isn't on for this link (nothing will come).
  func requestRxReplay(from seq: UInt32, count: Int) -> Bool

  /// How this connection's received packets have been delivered so far.
  var rxDeliveryStats: RxDeliveryStats { get }
}

public extension CairnRxSyncSessionOps {
  /// Default for test doubles: nothing is vouched for.
  func trustRxBacklog(channel _: ChannelKey, epoch _: UInt32, afterSeq _: UInt32) {}
}

/// Records the app never received that a live SUBSCRIBE skips past
/// (``CairnRxSyncSessionOps/expectRxBacklog(_:)``).
///
/// A resumed SUBSCRIBE that got no reply can't simply be sent again: the 0x88 frames held for it
/// were passed on, and a resume would send those packets again as records. The retry asks live
/// instead, and the records heard before those frames, from the app's stored cursor to the newest
/// the STATE probe saw, are fetched as backfill.
public struct CairnRxBacklog: Sendable, Equatable {
  /// The journal the records belong to: nothing is owed when the radio answers with another.
  public let epoch: UInt32
  /// The last record the app has.
  public let afterSeq: UInt32
  /// The newest record the app never received.
  public let throughSeq: UInt32
  /// The most records to fetch; older ones count lost, as a resume the radio capped would.
  public let limit: UInt16

  public init(epoch: UInt32, afterSeq: UInt32, throughSeq: UInt32, limit: UInt16) {
    self.epoch = epoch
    self.afterSeq = afterSeq
    self.throughSeq = throughSeq
    self.limit = limit
  }
}

/// How a connection's received packets reached the app over RX_SYNC.
public struct RxDeliveryStats: Sendable, Equatable {
  /// The radio confirmed RX_SYNC delivery for this link (`false`: stock 0x88 frames, where loss at
  /// the radio can't be seen).
  public let isActive: Bool
  /// The radio journal's epoch, once the radio has named it.
  public let epoch: UInt32?
  /// The newest record number delivered.
  public let lastSeq: UInt32?
  /// Records delivered, each once.
  public let delivered: Int
  /// Of ``delivered``, the records that came by FETCH after a frame went missing.
  public let recovered: Int
  /// Records the radio overwrote before this link was sent them.
  public let lostAtRadio: Int
  /// Missing records FETCH couldn't bring after ``RxSequencer/maxFetchAttempts`` tries.
  public let unrecovered: Int
  /// Records still being fetched.
  public let missing: Int
  /// Repeats dropped.
  public let duplicates: Int
  /// The newest record with nothing still being fetched at or before it: where a resume cursor
  /// may safely stand. `nil` before the radio has named its journal.
  public let contiguousSeq: UInt32?

  public init(
    isActive: Bool, epoch: UInt32?, lastSeq: UInt32?, delivered: Int, recovered: Int,
    lostAtRadio: Int, unrecovered: Int, missing: Int, duplicates: Int, contiguousSeq: UInt32? = nil
  ) {
    self.isActive = isActive
    self.epoch = epoch
    self.lastSeq = lastSeq
    self.delivered = delivered
    self.recovered = recovered
    self.lostAtRadio = lostAtRadio
    self.unrecovered = unrecovered
    self.missing = missing
    self.duplicates = duplicates
    self.contiguousSeq = contiguousSeq
  }
}

/// One connection's RX_SYNC state, kept by ``MeshCoreSession`` and changed only on its actor.
struct RxSyncLinkState {
  /// Where an RX_SYNC SUBSCRIBE asked to resume, until its reply arrives.
  struct Resume {
    let epoch: UInt32
    let seq: UInt32
    let max: UInt16
  }

  var sequencer = RxSequencer()
  /// The radio confirmed delivery is on for this link.
  var isActive = false
  /// The app opted in: renewed after every `APP_START`, which opts the link out.
  var wanted = false
  /// Plain 0x88 frames are held while a SUBSCRIBE is answered: a resumed journal sends them
  /// again as records, otherwise they are passed on once the reply arrives.
  var holding = false
  var held: [MeshEvent] = []
  var pendingResume: Resume?
  /// Records the next SUBSCRIBE reply owes, from ``MeshCoreSession/expectRxBacklog(_:)``.
  var pendingBacklog: CairnRxBacklog?
  /// The last record of the backlog a resumed SUBSCRIBE sends: the radio pushes those old
  /// records as live ones, and they are delivered marked backfill.
  var backlogEnd: UInt32?
  /// `APP_START`s this session wrote whose `selfInfo` answer hasn't arrived. The radio opts out
  /// only the link an `APP_START` came from, but sends its `selfInfo` to every link.
  var ownAppStarts = 0
  /// FETCH_ENDs the radio still owes for fetches it accepted: one follows every OK FETCH reply,
  /// even for no records, and a renewal keeps a fetch going. A fetch that gave up waiting leaves
  /// its FETCH_END owed, and the next FETCH waits for it so it can't take that one for its own.
  var owedFetchEnds = 0
  /// First frames waiting for their continuation, by `seq`.
  var heads: [UInt32: CairnRxRecordFrame] = [:]
  /// Records a consumer asked to have again (``MeshCoreSession/requestRxReplay(from:count:)``).
  var replayQueue: [ClosedRange<UInt32>] = []
  /// Replayed records to pass on even though they were delivered before.
  var replayExpected: Set<UInt32> = []
  var fetchTask: Task<Void, Never>?
  var fetchTaskID: UUID?
  var renewTask: Task<Void, Never>?

  /// Stops the fetch loop at once; a new one may start before the old one has wound down.
  mutating func cancelFetch() {
    fetchTask?.cancel()
    fetchTask = nil
    fetchTaskID = nil
  }

  /// Stops the tasks this state started.
  mutating func cancelTasks() {
    cancelFetch()
    renewTask?.cancel()
    renewTask = nil
  }
}

/// How one FETCH went.
enum RxFetchOutcome {
  /// Its FETCH_END arrived.
  case ended
  /// The radio is still sending a previous fetch.
  case busy
  /// No reply, no FETCH_END in time, or a refusal.
  case failed
}

extension MeshCoreSession: CairnRxSyncSessionOps {}

public extension MeshCoreSession {
  /// Turns RX_SYNC delivery on or off for this link and session.
  ///
  /// While on, the radio pushes every packet it hears as a numbered record instead of a 0x88 frame;
  /// the session orders them, fetches any that went missing, and dispatches exactly one
  /// ``MeshEvent/rxLogData(_:)`` per record with ``ParsedRxLogData/seq``, ``ParsedRxLogData/epoch``,
  /// ``ParsedRxLogData/radioAge`` and ``ParsedRxLogData/isBackfill`` set. The radio forgets it when
  /// the link drops or on `APP_START`; once on, the session renews it after each later `APP_START`,
  /// resuming after the last record delivered.
  ///
  /// - Parameters:
  ///   - on: `true` to opt in, `false` to go back to stock 0x88 frames.
  ///   - resumeEpoch: The epoch of the last record the app stored (0 for none).
  ///   - resumeSeq: The last record the app stored under `resumeEpoch` (0 for none).
  ///   - resumeMax: The most records the radio sends again on resume.
  ///   - timeout: Optional timeout override in seconds.
  /// - Returns: The radio's answer: whether delivery is on, resumed, and where it starts.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without RX_SYNC (the link stays on stock frames); ``MeshCoreError/commandFailed(_:reason:)``
  ///   when the radio refuses (BUSY: every link slot taken); ``MeshCoreError/timeout``.
  func setCairnRxSync(
    on: Bool, resumeEpoch: UInt32, resumeSeq: UInt32, resumeMax: UInt16, timeout: TimeInterval? = nil
  ) async throws -> CairnRxSubscribeResult {
    if on {
      rxSync.holding = true
      rxSync.pendingResume = RxSyncLinkState.Resume(epoch: resumeEpoch, seq: resumeSeq, max: resumeMax)
    }
    let reply: CairnRxSyncReply
    do {
      reply = try await sendAndMatch(
        PacketBuilder.cairnRxSyncSubscribe(on: on, resumeEpoch: resumeEpoch, resumeSeq: resumeSeq, resumeMax: resumeMax),
        timeout: timeout
      ) { event in
        guard let reply = CairnRxSyncReply(answering: event, to: .subscribe) else { return .ignore }
        return .success(reply)
      }
    } catch {
      await releaseHeldRxFrames()
      throw error
    }
    switch reply {
    case let .subscribe(result):
      // The receive path already applied it (before any record that follows it).
      rxSync.wanted = result.isOn
      return result
    case .unsupported:
      rxSync.wanted = false
      await releaseHeldRxFrames()
      throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
    case let .refused(_, status):
      await releaseHeldRxFrames()
      throw MeshCoreError.commandFailed(.cairnFirmware, reason: "RX_SYNC SUBSCRIBE refused, status \(status.rawValue)")
    case .state, .fetch:
      await releaseHeldRxFrames()
      throw MeshCoreError.invalidResponse(expected: "RX_SYNC SUBSCRIBE reply", got: String(describing: reply))
    }
  }

  /// Starts holding plain 0x88 frames until the next SUBSCRIBE is answered; see
  /// ``CairnRxSyncSessionOps/beginRxSyncHold()``. ``setCairnRxSync(on:resumeEpoch:resumeSeq:resumeMax:timeout:)``
  /// passes them on, or drops them when the radio sends them again as records.
  func beginRxSyncHold() {
    rxSync.holding = true
  }

  /// Passes on the 0x88 frames held since ``beginRxSyncHold()``, for a probe that won't subscribe.
  func releaseRxSyncHold() async {
    await releaseHeldRxFrames()
  }

  /// Has the next SUBSCRIBE reply owe `backlog`; see ``CairnRxSyncSessionOps/expectRxBacklog(_:)``.
  func expectRxBacklog(_ backlog: CairnRxBacklog) {
    rxSync.pendingBacklog = backlog
  }

  /// Reads a Cairn companion's receive journal: its epoch, the records it holds, whether this
  /// link is opted in, and its loss counters. Also the RX_SYNC probe.
  ///
  /// - Parameter timeout: Optional timeout override in seconds.
  /// - Throws: ``MeshCoreError/deviceError(code:)`` with ``ErrorCode/unsupportedCommand`` on
  ///   firmware without RX_SYNC; ``MeshCoreError/timeout`` if no reply arrives.
  func cairnRxSyncState(timeout: TimeInterval? = nil) async throws -> CairnRxSyncState {
    let reply: CairnRxSyncReply = try await sendAndMatch(PacketBuilder.cairnRxSyncState(), timeout: timeout) { event in
      guard let reply = CairnRxSyncReply(answering: event, to: .state) else { return .ignore }
      return .success(reply)
    }
    switch reply {
    case let .state(state):
      return state
    case .unsupported:
      throw MeshCoreError.deviceError(code: ErrorCode.unsupportedCommand.rawValue)
    case let .refused(_, status):
      throw MeshCoreError.commandFailed(.cairnFirmware, reason: "RX_SYNC STATE refused, status \(status.rawValue)")
    case .subscribe, .fetch:
      throw MeshCoreError.invalidResponse(expected: "RX_SYNC STATE reply", got: String(describing: reply))
    }
  }

  /// Asks the radio for `count` records from `seq` again, for a consumer whose own stream dropped
  /// some (a lagging subscription). They are dispatched again as ``MeshEvent/rxLogData(_:)`` with
  /// ``ParsedRxLogData/isBackfill`` set, so every subscriber sees them: consumers dedupe by
  /// (``ParsedRxLogData/epoch``, ``ParsedRxLogData/seq``). Records the journal no longer holds
  /// don't come.
  ///
  /// - Parameters:
  ///   - seq: The first record wanted.
  ///   - count: Records wanted (at most 4096 per request).
  /// - Returns: `false` when RX_SYNC isn't on for this link (nothing will come).
  @discardableResult
  func requestRxReplay(from seq: UInt32, count: Int) -> Bool {
    guard rxSync.isActive, count > 0, seq > 0 else { return false }
    let span = UInt32(min(count, Self.rxReplayLimit))
    let upper = seq.addingReportingOverflow(span - 1)
    guard !upper.overflow else { return false }
    rxSync.replayQueue.append(seq...upper.partialValue)
    scheduleRxFetch()
    return true
  }

  /// How this connection's received packets have been delivered so far.
  var rxDeliveryStats: RxDeliveryStats {
    let sequencer = rxSync.sequencer
    return RxDeliveryStats(
      isActive: rxSync.isActive,
      epoch: sequencer.epoch,
      lastSeq: sequencer.nextSeq.flatMap { $0 > 0 ? $0 - 1 : nil },
      delivered: sequencer.delivered,
      recovered: sequencer.recovered,
      lostAtRadio: sequencer.lostAtRadio,
      unrecovered: sequencer.unrecovered,
      missing: sequencer.missingCount,
      duplicates: sequencer.duplicates,
      contiguousSeq: sequencer.epoch == nil ? nil : sequencer.contiguousSeq
    )
  }
}

// MARK: - Receive Path

extension MeshCoreSession {
  /// Wait after a gap before fetching it, so frames still in flight land first.
  static let rxFetchSettle: Duration = .milliseconds(300)
  /// Records per FETCH (the radio's limit).
  static let rxFetchLimit = 32
  /// How long a FETCH's records and FETCH_END may take after its reply.
  static let rxFetchEndTimeout: Duration = .seconds(10)
  /// How often a FETCH waiting for an earlier fetch's FETCH_END looks again.
  static let rxFetchEndPoll: Duration = .milliseconds(50)
  /// Pause after a BUSY answer before fetching again.
  static let rxFetchBusyBackoff: Duration = .seconds(1)
  /// The most records a renewal after `APP_START` asks the radio to send again.
  static let rxRenewResumeMax: UInt16 = 512
  /// The most 0x88 frames held while a SUBSCRIBE is answered; later ones pass straight on.
  static let rxHeldFrameLimit = 512
  /// The most first frames kept waiting for their continuation.
  static let rxPendingHeadLimit = 8
  /// The most records one replay request asks for.
  static let rxReplayLimit = 4096

  /// Routes one received event through RX_SYNC: joins and orders record frames into
  /// ``MeshEvent/rxLogData(_:)``, holds 0x88 frames while a SUBSCRIBE is answered, and notes
  /// `APP_START`s. Runs on the receive path, in frame order.
  ///
  /// - Returns: The events to dispatch, in order (none for a frame still waiting, a repeat or a
  ///   held 0x88 frame).
  func routeRxSync(_ event: MeshEvent) -> [MeshEvent] {
    switch event {
    case let .cairnRxRecordFrame(frame):
      return takeRxRecordFrame(frame)
    case let .cairnRxFetchEnd(end):
      rxSync.owedFetchEnds = max(0, rxSync.owedFetchEnds - 1)
      if end.epoch == rxSync.sequencer.epoch {
        rxSync.sequencer.markLost(below: end.firstSeq)
      }
      return [event]
    case let .cairnRxSyncReply(.fetch(reply)):
      // the radio now has a fetch going out on this link: its FETCH_END follows, even for none
      rxSync.owedFetchEnds += 1
      rxSync.sequencer.markLost(below: reply.firstSeq)
      return [event]
    case let .cairnRxSyncReply(.subscribe(result)):
      return applyRxSubscribe(result) + [event]
    case .rxLogData, .logData:
      guard rxSync.holding, rxSync.held.count < Self.rxHeldFrameLimit else { return [event] }
      rxSync.held.append(event)
      return []
    case .selfInfo:
      // Another link's APP_START (a stock app on USB or Wi-Fi) is answered on every link too, but
      // opts only that link out: only this session's own APP_START needs a renewal.
      guard rxSync.ownAppStarts > 0 else { return [event] }
      rxSync.ownAppStarts -= 1
      renewRxSyncAfterAppStart()
      return [event]
    default:
      return [event]
    }
  }

  private func takeRxRecordFrame(_ frame: CairnRxRecordFrame) -> [MeshEvent] {
    var record = frame
    if frame.flags.contains(.continuation) {
      // A continuation whose first frame never came is dropped: the gap it leaves is fetched.
      guard let head = rxSync.heads.removeValue(forKey: frame.seq),
            let joined = head.appending(frame) else { return [] }
      record = joined
    }
    if record.flags.contains(.more) {
      if rxSync.heads.count >= Self.rxPendingHeadLimit { rxSync.heads.removeAll() }
      rxSync.heads[record.seq] = record
      return []
    }

    let outcome = rxSync.sequencer.accept(seq: record.seq, gap: record.flags.contains(.gap))
    let isReplay = record.flags.contains(.backfill) && rxSync.replayExpected.remove(record.seq) != nil
    if !rxSync.sequencer.missing.isEmpty { scheduleRxFetch() }
    guard outcome != .duplicate || isReplay else { return [] }

    // 0 until the radio has named its journal (a record before any SUBSCRIBE reply).
    let epoch = rxSync.sequencer.epoch ?? 0
    // A resumed SUBSCRIBE's backlog comes without the BACKFILL flag but was heard before it
    let isBacklog = rxSync.backlogEnd.map { record.seq <= $0 } ?? false
    if var parsed = record.rxLogData(epoch: epoch, isBackfill: record.flags.contains(.backfill) || isBacklog) {
      // Stamped only when the radio's current channel was already confirmed when it received the
      // packet (its age back from now), or the app vouched for the journal it is in: older
      // backlog stays unstamped rather than guessed.
      parsed.channel = channelStamp(radioAge: parsed.radioAge, epoch: epoch, seq: record.seq)
      return [.rxLogData(parsed)]
    }
    // Bytes that don't parse as a packet are passed on as a 0x88 frame's would be.
    return [.logData(LogDataInfo(snr: record.snr, rssi: Int(record.rssi), payload: record.raw))]
  }

  /// Applies the radio's SUBSCRIBE answer as its frame is received, so records that follow it are
  /// ordered against the right cursor.
  ///
  /// - Returns: Held 0x88 frames to pass on before the reply (none when a resumed journal sends
  ///   them again as records).
  private func applyRxSubscribe(_ result: CairnRxSubscribeResult) -> [MeshEvent] {
    let resume = rxSync.pendingResume
    rxSync.pendingResume = nil
    let backlog = rxSync.pendingBacklog
    rxSync.pendingBacklog = nil
    let held = rxSync.held
    rxSync.held = []
    rxSync.holding = false
    rxSync.heads = [:]
    guard result.isOn else {
      rxSync.isActive = false
      rxSync.backlogEnd = nil
      rxSync.cancelFetch()
      // the radio dropped this link's slot with any fetch still going out
      rxSync.owedFetchEnds = 0
      return held
    }
    let resumeAfter = resume.flatMap { $0.epoch == result.epoch && $0.seq > 0 ? $0.seq : nil }
    // Records taken before any SUBSCRIBE was answered (the radio opted the link in behind a lost
    // reply and was already sending that SUBSCRIBE's backlog, in order) are kept with their gaps:
    // the backlog is owed only up to the first of them.
    rxSync.sequencer.begin(epoch: result.epoch, cursor: result.cursor, after: resumeAfter, newest: result.lastSeq)
    if let backlog, backlog.epoch == result.epoch {
      rxSync.sequencer.owe(after: backlog.afterSeq, through: backlog.throughSeq, limit: Int(backlog.limit))
    }
    // what is owed from before the journal's oldest record was overwritten: no FETCH brings it
    rxSync.sequencer.markLost(below: result.firstSeq)
    // records from the cursor to the radio's newest are its backlog, sent at once as live pushes
    rxSync.backlogEnd = result.resumed && result.cursor <= result.lastSeq ? result.lastSeq : nil
    rxSync.isActive = true
    scheduleRxFetch()
    let resent = result.resumed && held.count <= Int(resume?.max ?? 0)
    return resent ? [] : held
  }

  /// Passes on the 0x88 frames held for a SUBSCRIBE that failed.
  func releaseHeldRxFrames() async {
    rxSync.pendingBacklog = nil
    guard rxSync.holding else { return }
    let held = rxSync.held
    rxSync.held = []
    rxSync.holding = false
    rxSync.pendingResume = nil
    for event in held {
      await dispatcher.dispatch(event)
    }
  }

  /// The radio opts a link out of RX_SYNC on its own `APP_START` (answered by `selfInfo`): ask
  /// again, resuming after the last record delivered, and hold the 0x88 frames sent meanwhile.
  private func renewRxSyncAfterAppStart() {
    // The radio dropped this link's slot with any fetch still going out: no FETCH_END is owed
    rxSync.owedFetchEnds = 0
    guard rxSync.wanted else { return }
    rxSync.isActive = false
    rxSync.cancelFetch()
    rxSync.heads = [:]
    rxSync.holding = true
    let epoch = rxSync.sequencer.epoch ?? 0
    let lastSeq = rxSync.sequencer.nextSeq.flatMap { $0 > 0 ? $0 - 1 : nil } ?? 0
    rxSync.renewTask?.cancel()
    rxSync.renewTask = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await setCairnRxSync(
          on: true, resumeEpoch: epoch, resumeSeq: lastSeq, resumeMax: Self.rxRenewResumeMax, timeout: 5
        )
      } catch {
        logger.warning("RX_SYNC renewal after appStart failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - FETCH

  /// Starts the fetch loop when records are missing or a replay is queued and none is running.
  func scheduleRxFetch() {
    guard rxSync.isActive, rxSync.fetchTask == nil,
          !rxSync.sequencer.missing.isEmpty || !rxSync.replayQueue.isEmpty else { return }
    let id = UUID()
    rxSync.fetchTaskID = id
    rxSync.fetchTask = Task { [weak self] in
      await self?.runRxFetchLoop(id: id)
    }
  }

  /// Fetches missing records, oldest first, one FETCH at a time, then queued replays.
  private func runRxFetchLoop(id: UUID) async {
    defer {
      if rxSync.fetchTaskID == id {
        rxSync.fetchTask = nil
        rxSync.fetchTaskID = nil
      }
    }
    while !Task.isCancelled, rxSync.isActive {
      try? await clock.sleep(for: Self.rxFetchSettle)
      guard !Task.isCancelled, rxSync.isActive else { break }

      if let range = rxSync.sequencer.nextFetch(limit: Self.rxFetchLimit) {
        let outcome = await fetchRxRecords(after: range.lowerBound &- 1, count: range.count)
        // a renewal or opt-out cancelled it: the radio dropped the fetch, not the records
        guard !Task.isCancelled else { break }
        rxSync.sequencer.fetchEnded(range)
        if outcome == .busy { try? await clock.sleep(for: Self.rxFetchBusyBackoff) }
      } else if let queued = rxSync.replayQueue.first {
        let span = min(queued.count, Self.rxFetchLimit)
        let chunk = queued.lowerBound...(queued.lowerBound + UInt32(span - 1))
        if chunk.upperBound < queued.upperBound {
          rxSync.replayQueue[0] = (chunk.upperBound + 1)...queued.upperBound
        } else {
          rxSync.replayQueue.removeFirst()
        }
        rxSync.replayExpected.formUnion(chunk)
        let outcome = await fetchRxRecords(after: chunk.lowerBound &- 1, count: chunk.count)
        rxSync.replayExpected.subtract(chunk)
        // asked again after a BUSY, or by the next loop after a renewal cancelled this one
        if outcome == .busy || Task.isCancelled {
          rxSync.replayQueue.insert(chunk, at: 0)
        }
        if outcome == .busy, !Task.isCancelled {
          try? await clock.sleep(for: Self.rxFetchBusyBackoff)
        }
      } else {
        break
      }
    }
  }

  /// Sends one FETCH and waits for its FETCH_END; the records themselves are taken by the receive
  /// path as they arrive, before the FETCH_END that follows them.
  ///
  /// The radio sends one FETCH_END for every FETCH it accepts, even one with no records, and keeps
  /// a fetch going across a renewal. A FETCH_END still owed for an earlier fetch (one cancelled by a
  /// renewal, or one that timed out) is waited for first, so this fetch can't take it for its own
  /// and the radio doesn't answer BUSY.
  private func fetchRxRecords(after sinceSeq: UInt32, count: Int) async -> RxFetchOutcome {
    guard await drainOwedFetchEnds() else { return .failed }
    let sessionDispatcher = dispatcher
    let sessionClock = clock
    let (subscriptionID, ends) = await dispatcher.subscribeTracked(filter: EventFilter.cairnRxFetchEnd.matches)
    let reply: CairnRxSyncReply
    do {
      reply = try await sendAndMatch(
        PacketBuilder.cairnRxSyncFetch(sinceSeq: sinceSeq, max: UInt8(min(count, Self.rxFetchLimit)))
      ) { event in
        guard let reply = CairnRxSyncReply(answering: event, to: .fetch) else { return .ignore }
        return .success(reply)
      }
    } catch {
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      logger.warning("RX_SYNC fetch failed: \(error.localizedDescription)")
      return .failed
    }

    switch reply {
    case .fetch:
      // `count` records (perhaps none) and then the FETCH_END
      break
    case .refused(_, .busy):
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      return .busy
    default:
      await sessionDispatcher.finishSubscription(id: subscriptionID)
      logger.warning("RX_SYNC fetch refused: \(String(describing: reply))")
      return .failed
    }

    let end: CairnRxFetchEnd? = await withTaskGroup(of: CairnRxFetchEnd?.self) { group in
      group.addTask {
        for await event in ends {
          if case let .cairnRxFetchEnd(end) = event { return end }
        }
        return nil
      }
      group.addTask {
        try? await sessionClock.sleep(for: Self.rxFetchEndTimeout)
        // ends the stream: the waiting task returns nil
        await sessionDispatcher.finishSubscription(id: subscriptionID)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    await sessionDispatcher.finishSubscription(id: subscriptionID)
    return end == nil ? .failed : .ended
  }

  /// Waits until no FETCH_END is owed for an earlier fetch, polling the count the receive path
  /// keeps. After ``rxFetchEndTimeout`` the owed ones are written off (the radio dropped them).
  ///
  /// - Returns: `false` when the task was cancelled meanwhile.
  private func drainOwedFetchEnds() async -> Bool {
    var waited = Duration.zero
    while rxSync.owedFetchEnds > 0 {
      guard !Task.isCancelled else { return false }
      guard waited < Self.rxFetchEndTimeout else {
        let owed = rxSync.owedFetchEnds
        logger.warning("RX_SYNC: \(owed) FETCH_END never came; fetching again")
        rxSync.owedFetchEnds = 0
        break
      }
      try? await clock.sleep(for: Self.rxFetchEndPoll)
      waited += Self.rxFetchEndPoll
    }
    return !Task.isCancelled
  }
}
