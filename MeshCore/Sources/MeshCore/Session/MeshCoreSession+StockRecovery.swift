import Foundation
import os

// Official MeshCore companion firmware (v1.7 to v1.18) writes every frame for the app through a
// small Bluetooth send queue (4 frames on ESP32, sent one per 60 ms; 12 on nRF52) and silently
// drops a frame when it is full (src/helpers/esp32/SerialBLEInterface.cpp writeFrame,
// src/helpers/nrf52/SerialBLEInterface.cpp writeFrame). Nothing tells the app. This file holds
// what the session does about it without any firmware change:
// - it paces optional commands so their answers find room (``waitForQuietLink(quiet:maxWait:)``),
// - it counts 0x88 frames for the stats barrier (``receivedRxLogFrames``),
// - it recovers a dropped delivery confirmation (0x82) from the 0x88 copy of the ACK packet.

// MARK: - Quiet Link

/// Pacing values for ``SessionEventStreaming/waitForQuietLink(quiet:maxWait:)``.
public enum QuietLink {
  /// The silence that shows the radio's send queue has emptied: an ESP32 companion sends one
  /// queued frame per 60 ms from 4 slots, and an nRF52 one stalls at most 250 ms when its
  /// Bluetooth buffer is full. In the round trip after it, one more LoRa packet (three frames at
  /// most) can arrive, which fits even the 4-slot queue.
  public static let quiet: Duration = .milliseconds(300)
  /// How long a wait lasts at most under continuous traffic, after any hold has ended.
  public static let maxWait: Duration = .seconds(5)
  /// The longest one ``SessionEventStreaming/holdBackgroundTraffic(for:owner:)`` call holds traffic.
  public static let holdLimit: Duration = .seconds(30)
  /// The longest a message fetch waits for quiet again once it holds the request serializer,
  /// where every other command waits behind it.
  public static let serializedFetchMaxWait: Duration = .seconds(1)
}

/// What ``MeshCoreSession/waitForQuietLink(quiet:maxWait:)`` reads: pushes seen since the radio's
/// last answer, when the last one arrived, and any hold (all times on the session's ``MeshCoreSession/uptime``).
struct LinkPacingState {
  /// Frames with a code of 0x80 or more received, which the radio pushes unasked.
  var pushFrameSeq: UInt64 = 0
  /// ``pushFrameSeq`` when the radio last answered a command (a code below 0x80).
  var pushSeqAtLastReply: UInt64 = 0
  /// When the last push arrived.
  var lastPushAt: Duration?
  /// When each owner's hold ends.
  var holds: [String: Duration] = [:]
  /// Waits sleeping through a hold, woken when a hold ends early.
  var holdSleepers: [UInt64: Task<Void, Never>] = [:]
  var nextHoldSleeper: UInt64 = 0
  /// The quiet wait before each message fetch.
  var fetchQuiet = QuietLink.quiet
  var fetchMaxWait = QuietLink.maxWait

  /// When the last hold ends.
  var holdUntil: Duration? {
    holds.values.max()
  }
}

extension MeshCoreSession {
  /// A function giving the time since now on `clock`, for timestamps the session compares.
  static func makeUptime<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }

  /// Notes one received frame for the quiet-link wait.
  func noteLinkFrame(code: UInt8) {
    if code >= 0x80 {
      linkPacing.pushFrameSeq &+= 1
      linkPacing.lastPushAt = uptime()
    } else {
      // The send queue is first in, first out: every push queued before this answer has gone.
      linkPacing.pushSeqAtLastReply = linkPacing.pushFrameSeq
    }
  }
}

public extension MeshCoreSession {
  /// `PUSH_CODE_LOG_RX_DATA` (0x88) frames this session has received, counted before parsing,
  /// so unreadable frames and frames held for RX_SYNC count too. Only grows.
  ///
  /// The radio counts each packet it hears and queues its 0x88 frame in the same pass, so
  /// comparing this with ``PacketStats/received`` across two ``getStatsPackets()`` replies gives
  /// the packets the radio heard that never reached the session. Each reply carries the count
  /// at its arrival in ``PacketStats/appRxLogFrames``.
  var receivedRxLogFrames: UInt64 {
    rxLogFrameCount
  }

  /// Live RX_SYNC records (`0xC8`, ``isLiveRxRecordHead(_:)``) this session has received, each
  /// once. Only grows.
  ///
  /// The radio writes them at its journal's pace, after the pass that counted their packets, so
  /// they never pair with ``PacketStats/received`` the way 0x88 frames do. A stats reply carries
  /// the count at its arrival in ``PacketStats/appLiveRxRecords``: a stock measurement whose
  /// window saw it grow can't be exact.
  var receivedLiveRxRecords: UInt64 {
    liveRxRecordCount
  }

  /// Frames the transport threw away before the session could read them on this connection.
  /// Those packets are already inside a stats-barrier difference, which is measured after them.
  var droppedTransportFrames: Int {
    get async { max(0, await transport.droppedFrameCount - transportDropBaseline) }
  }

  /// Waits until the link has been free of pushed frames for `quiet`, for at most `maxWait`
  /// after any hold from ``holdBackgroundTraffic(for:owner:)`` ends.
  ///
  /// Returns at once on a link with active RX_SYNC (its radio keeps room for answers) and when
  /// no push has arrived since the radio last answered a command (everything queued before that
  /// answer has already gone out). Returns early if the calling task is cancelled.
  ///
  /// - Parameters:
  ///   - quiet: How long the link must have been free of pushes (``QuietLink/quiet``).
  ///   - maxWait: The longest the wait lasts once any hold has ended (``QuietLink/maxWait``).
  func waitForQuietLink(quiet: Duration, maxWait: Duration) async {
    await waitForQuietLink(quiet: quiet, maxWait: maxWait, throughHolds: true)
  }

  /// Holds back optional traffic (message fetches and every other
  /// ``waitForQuietLink(quiet:maxWait:)`` caller) for `duration`, at most ``QuietLink/holdLimit``,
  /// while a burst of replies is expected. Each owner has one hold, which a later call can only
  /// extend; traffic waits until every owner's hold has ended or been released.
  ///
  /// Discover replies arrive as two frames each (0x88, then 0x8E) inside the repeaters' random
  /// reply window, which is when a stock radio's send queue is most likely to overflow.
  func holdBackgroundTraffic(for duration: Duration, owner: String) async {
    let now = uptime()
    let end = now + min(max(duration, .zero), QuietLink.holdLimit)
    linkPacing.holds = linkPacing.holds.filter { $0.value > now }
    if let current = linkPacing.holds[owner], current >= end { return }
    linkPacing.holds[owner] = end
  }

  /// Ends `owner`'s hold now, for a burst that won't come (the request failed or was stopped).
  /// Waits held only by it go on at once.
  func releaseBackgroundTraffic(owner: String) async {
    let before = linkPacing.holdUntil
    guard linkPacing.holds.removeValue(forKey: owner) != nil, linkPacing.holdUntil != before else { return }
    for sleeper in linkPacing.holdSleepers.values {
      sleeper.cancel()
    }
  }
}

extension MeshCoreSession {
  /// Whether `frame` is the first frame of a live RX_SYNC record (0xC8): one packet the radio
  /// pushed in place of its 0x88 frame. A continuation belongs to a record already counted; a
  /// backfill record was sent again for a FETCH.
  static func isLiveRxRecordHead(_ frame: Data) -> Bool {
    guard frame.count >= 2, frame[frame.startIndex] == ResponseCode.rxRecord.rawValue else { return false }
    let flags = CairnRxRecordFrame.Flags(rawValue: frame[frame.startIndex + 1])
    return !flags.contains(.continuation) && !flags.contains(.backfill)
  }

  /// ``waitForQuietLink(quiet:maxWait:)``, optionally ignoring holds: a caller already holding the
  /// request serializer must never wait out a 30 s hold.
  func waitForQuietLink(quiet: Duration, maxWait: Duration, throughHolds: Bool) async {
    var deadline: Duration?
    while !rxSync.isActive {
      let now = uptime()
      if throughHolds, let holdUntil = linkPacing.holdUntil, now < holdUntil {
        // The wait's own limit counts from the end of the hold.
        deadline = nil
        guard await sleepThroughHold(holdUntil - now) else { return }
        continue
      }
      let limit = deadline ?? now + maxWait
      deadline = limit
      guard linkPacing.pushFrameSeq != linkPacing.pushSeqAtLastReply,
            let lastPushAt = linkPacing.lastPushAt else { return }
      let quietAt = lastPushAt + quiet
      if now >= quietAt { return }
      if now >= limit {
        logger.info("Link still busy after \(maxWait); sending anyway")
        return
      }
      guard (try? await clock.sleep(for: min(quietAt, limit) - now)) != nil else { return }
    }
  }

  /// Sleeps for `duration`, or until ``releaseBackgroundTraffic(owner:)`` ends a hold early.
  ///
  /// - Returns: `false` when the calling task was cancelled.
  private func sleepThroughHold(_ duration: Duration) async -> Bool {
    let id = linkPacing.nextHoldSleeper
    linkPacing.nextHoldSleeper &+= 1
    let sleeper = Task { [clock] in
      _ = try? await clock.sleep(for: duration)
    }
    linkPacing.holdSleepers[id] = sleeper
    await withTaskCancellationHandler {
      await sleeper.value
    } onCancel: {
      sleeper.cancel()
    }
    linkPacing.holdSleepers[id] = nil
    return !Task.isCancelled
  }
}

// MARK: - Delivery Confirmation Recovery

/// The delivery confirmations (expected ACK codes from `RESP_CODE_SENT`) this session waits for,
/// and the ones it recovered from an ACK packet's 0x88 copy. Times are session uptime.
///
/// Official firmware writes the 0x88 copy of every packet before it handles it, and then the
/// `PUSH_CODE_SEND_CONFIRMED` (0x82) for a matching ACK, through the same drop-when-full queue
/// (companion-v1.18.0 src/Dispatcher.cpp checkRecv, examples/companion_radio/MyMesh.cpp processAck).
/// It confirms only the first copy it hears, so later copies (a second multi-ack, an early
/// direct ACK, flood repeats) reach the app as 0x88 alone. Matching their ACK CRC against the
/// codes in flight does what the firmware's own 4-byte compare does.
struct ExpectedAckTracker: Sendable {
  /// How long a sent message's code is waited for.
  static let pendingLifetime: Duration = .seconds(600)
  /// The most codes waited for at once; the oldest is forgotten first.
  static let pendingLimit = 64
  /// How long a recovered code swallows the radio's own late confirmation.
  static let recoveredMemory: Duration = .seconds(60)

  private struct Pending {
    let code: Data
    let sentAt: Duration
    var recoveryScheduled = false
  }

  /// What to do with the radio's own confirmation.
  enum RadioConfirmation: Equatable {
    /// Dispatch it; `cancelsRecovery` when a recovery for it was waiting out its grace.
    case dispatch(cancelsRecovery: Bool)
    /// Already recovered from its ACK packet: don't dispatch it again.
    case swallow
  }

  private var pending: [Pending] = []
  private var recovered: [Data: Duration] = [:]

  /// Codes currently waited for.
  var pendingCount: Int {
    pending.count
  }

  /// A message went out expecting `code` back.
  mutating func noteSent(_ code: Data, at now: Duration) {
    // A zero code means the radio expects no ACK (MyMesh.cpp only tables a non-zero one).
    guard code.count == 4, code.contains(where: { $0 != 0 }) else { return }
    prune(now)
    pending.removeAll { $0.code == code }
    pending.append(Pending(code: code, sentAt: now))
    if pending.count > Self.pendingLimit {
      pending.removeFirst(pending.count - Self.pendingLimit)
    }
  }

  /// An ACK CRC read from a received packet. Returns true when a recovery should wait out its
  /// grace: the code is waited for and no recovery is already waiting.
  mutating func heard(_ code: Data, at now: Duration) -> Bool {
    prune(now)
    guard let index = pending.firstIndex(where: { $0.code == code }),
          !pending[index].recoveryScheduled else { return false }
    pending[index].recoveryScheduled = true
    return true
  }

  /// The grace after ``heard(_:at:)`` ended. Returns true when the radio's own confirmation never
  /// came and the code should be dispatched as recovered.
  mutating func graceEnded(_ code: Data, at now: Duration) -> Bool {
    guard let index = pending.firstIndex(where: { $0.code == code && $0.recoveryScheduled }) else {
      return false
    }
    pending.remove(at: index)
    recovered[code] = now
    prune(now)
    return true
  }

  /// The radio's own confirmation for `code` arrived.
  mutating func radioConfirmed(_ code: Data, at now: Duration) -> RadioConfirmation {
    prune(now)
    if recovered[code] != nil {
      return .swallow
    }
    guard let index = pending.firstIndex(where: { $0.code == code }) else {
      return .dispatch(cancelsRecovery: false)
    }
    let scheduled = pending[index].recoveryScheduled
    pending.remove(at: index)
    return .dispatch(cancelsRecovery: scheduled)
  }

  private mutating func prune(_ now: Duration) {
    pending.removeAll { now - $0.sentAt > Self.pendingLifetime }
    recovered = recovered.filter { now - $0.value <= Self.recoveredMemory }
  }

  /// The ACK CRC a received packet carries in the clear, read the way Mesh.cpp reads it
  /// (companion-v1.18.0 src/Mesh.cpp onRecvPacket): a plain ACK's first four payload bytes (the
  /// payload is 4 bytes before v1.16.0 and 6 from it, with an attempt and a random byte), or a
  /// multipart ACK's four bytes after its `(remaining << 4) | PAYLOAD_TYPE_ACK` byte. ACKs inside
  /// an encrypted PATH packet can't be read.
  static func ackCode(in packet: ParsedRxLogData) -> Data? {
    let payload = packet.packetPayload
    switch packet.payloadType {
    case .ack:
      guard payload.count >= 4 else { return nil }
      return Data(payload.prefix(4))
    case .multipart:
      guard payload.count >= 5,
            payload[payload.startIndex] & 0x0F == PayloadType.ack.rawValue else { return nil }
      return Data(payload.dropFirst().prefix(4))
    default:
      return nil
    }
  }
}

/// The session's confirmation recovery: the tracker and the recoveries waiting out their grace.
struct AckRecoveryState {
  /// How long a recovery waits for the radio's own confirmation, which normally follows its
  /// 0x88 within milliseconds and carries the round-trip time.
  static let grace: Duration = .milliseconds(1500)

  var tracker = ExpectedAckTracker()
  var graceTasks: [Data: Task<Void, Never>] = [:]

  mutating func cancelAll() {
    for task in graceTasks.values {
      task.cancel()
    }
    graceTasks = [:]
  }
}

extension MeshCoreSession {
  /// Feeds the confirmation recovery with one received event. Returns false for the radio's own
  /// confirmation of a code already recovered, which must not be dispatched a second time. A
  /// packet fed twice (a held 0x88 frame the radio sends again as an RX_SYNC record) starts one
  /// recovery.
  func admitForAckRecovery(_ event: MeshEvent) -> Bool {
    switch event {
    case let .messageSent(info):
      ackRecovery.tracker.noteSent(info.expectedAck, at: uptime())
    case let .acknowledgement(code, _):
      switch ackRecovery.tracker.radioConfirmed(code, at: uptime()) {
      case .swallow:
        let hex = code.hexString
        logger.info("Radio confirmed \(hex) after it was recovered from the ACK packet; not dispatched again")
        return false
      case .dispatch(cancelsRecovery: true):
        ackRecovery.graceTasks.removeValue(forKey: code)?.cancel()
      case .dispatch(cancelsRecovery: false):
        break
      }
    case let .rxLogData(packet):
      if let code = ExpectedAckTracker.ackCode(in: packet),
         ackRecovery.tracker.heard(code, at: uptime()) {
        scheduleAckRecovery(code)
      }
    default:
      break
    }
    return true
  }

  private func scheduleAckRecovery(_ code: Data) {
    ackRecovery.graceTasks[code] = Task { [weak self, clock] in
      guard (try? await clock.sleep(for: AckRecoveryState.grace)) != nil else { return }
      await self?.ackGraceEnded(code)
    }
  }

  private func ackGraceEnded(_ code: Data) async {
    ackRecovery.graceTasks[code] = nil
    guard ackRecovery.tracker.graceEnded(code, at: uptime()) else { return }
    let hex = code.hexString
    logger.info("Recovered delivery confirmation \(hex) from its ACK packet; the radio's push never arrived")
    await dispatcher.dispatch(.acknowledgement(code: code, tripTime: nil))
  }
}
