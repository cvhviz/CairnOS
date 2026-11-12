import Foundation
import MeshCore
import os

// MARK: - Message Polling Errors

public enum MessagePollingError: Error, Sendable {
  case notConnected
  case pollingFailed
  case sessionError(MeshCoreError)
}

extension MessagePollingError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected to device."
    case .pollingFailed: "Message polling failed."
    case let .sessionError(e): e.localizedDescription
    }
  }
}

// MARK: - Message Polling Service

/// Service for polling messages from the mesh device.
/// Handles automatic message fetching and contact message routing.
actor MessagePollingService {
  // MARK: - Properties

  private let session: any MeshCoreSessionProtocol
  private let dataStore: any PersistenceStoreProtocol
  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "MessagePolling")

  /// Handler for incoming contact messages.
  /// Installed by `SyncCoordinator.wireMessageHandlers`; cleared by `clearMessageHandlers`.
  private var contactMessageHandler: (@Sendable (ContactMessage, ContactDTO?, DeliveryContext) async -> Void)?

  /// Handler for incoming channel messages.
  /// Installed by `SyncCoordinator.wireMessageHandlers`; cleared by `clearMessageHandlers`.
  private var channelMessageHandler: (@Sendable (ChannelMessage, ChannelDTO?, DeliveryContext) async -> Void)?

  /// Handler for signed messages (from room servers).
  /// Installed by `SyncCoordinator.wireMessageHandlers`; cleared by `clearMessageHandlers`.
  private var signedMessageHandler: (@Sendable (ContactMessage, ContactDTO?) async -> Void)?

  /// Handler for CLI responses (textType = 0x01).
  /// Installed by `SyncCoordinator.wireMessageHandlers`; cleared by `clearMessageHandlers`.
  private var cliMessageHandler: (@Sendable (ContactMessage, ContactDTO?) async -> Void)?

  /// Handler for messages sent from the radio's own UI (Cairn sent-message echo).
  /// Installed by `SyncCoordinator.wireMessageHandlers`; cleared by `clearMessageHandlers`.
  private var radioSentMessageHandler: (@Sendable (RadioSentMessage, DeliveryContext) async -> Void)?

  /// The radio answered the sent-message opt-in as unsupported this session (a timeout is not sticky).
  private var radioSentSyncUnavailable = false
  /// The board answered history "unsupported": not asked again this session.
  private var radioHistoryUnavailable = false
  /// The radio's DEVICE_INFO carries no Cairn build: none of the Cairn extensions (sent-message
  /// sync, history, queue sync) is asked for, each probe being a round trip it answers unsupported.
  private var cairnExtensionsAbsent = false

  /// Event monitoring task
  private var eventMonitorTask: Task<Void, Never>?

  /// Whether auto-fetch is currently enabled
  private var isAutoFetchEnabled = false

  /// Device ID for contact lookups
  private var currentRadioID: UUID?

  /// Count of message handlers currently executing
  /// Used to wait for sync-time handlers to complete before resuming notifications
  private var pendingHandlerCount: Int = 0

  /// The sort anchor of the drain `pollAllMessages()` is running, nil outside one. A message the
  /// event monitor handles meanwhile is backlog too, so it shares the anchor.
  private var drainAnchor: Date?

  /// Keys of messages already handed to a handler, oldest first (see `claim(_:)`).
  private var claimedMessageKeys: Set<String> = []
  private var claimedMessageOrder: [String] = []
  private static let claimedMessageLimit = 256
  /// Claimed messages whose handler is still running, by claim key (a count: a key that fell out of
  /// the claims can be claimed again while its first handler runs). A drain whose fetch the event
  /// monitor claimed first waits on its key here, so it knows that very message is stored.
  private var handlingKeys: [String: Int] = [:]
  /// How long a drain waits for another handler to store the message it fetched.
  static let defaultClaimedHandlerWait: Duration = .seconds(30)
  private var claimedHandlerWait = MessagePollingService.defaultClaimedHandlerWait
  /// Queue sync: times in a row a fetched frame may come back unstored (its handler still running)
  /// before the drain gives up and leaves it on the radio for the next one.
  static let unstoredRedeliveryLimit = 3

  /// Retries of a timed-out fetch inside one `pollAllMessages()` before it gives up.
  static let pollTimeoutRetryLimit = 2

  /// The event subscription's label in the session's drop counts.
  static let eventSubscriptionLabel = "messages"

  // MARK: Queue sync (Cairn firmware, QUEUE_SYNC.md)

  /// Whether the radio reads its queue with queue sync's two-step NEXT: nil until the radio has
  /// answered the ARM probe on this connection (a probe that fails another way leaves it nil, so a
  /// later drain asks again), false only once the radio has said twice that it lacks queue sync.
  private var queueSyncSupport: Bool?
  /// After a probe that got no answer, automatic drains (MSG_WAITING pushes, a refused push's
  /// recovery, the periodic catch-up) read the stock way until `until` before asking again. It holds
  /// only while no explicit drain has been asked for since that probe began (`request` is the
  /// count of explicit requests the probe started under): an explicit drain (`pollAllMessages()`,
  /// `requestDrain()`: a sync, a resync, the return to the foreground) asks again even when it waits
  /// behind the probe whose timeout set it, so one lost reply, e.g. to the probe a background
  /// reconnect made while the app was suspended, never decides how it reads.
  private var queueSyncProbeHoldOff: (until: ContinuousClock.Instant, request: UInt64)?
  /// Explicit drains asked for on this connection, which void any hold-off from an earlier probe.
  private var explicitDrainRequests: UInt64 = 0
  /// How long a probe that got no answer holds off the next automatic one.
  static let queueSyncProbeBackoff: Duration = .seconds(60)
  /// The seq of the frame stored since the radio last answered a NEXT (0 = none). Sent with the next
  /// NEXT, which is what removes it from the radio; kept across a failed NEXT so it is sent again.
  private var queueSyncAckSeq: UInt32 = 0
  /// When the radio's loss counters were last read.
  private var lastQueueLossCheck: Date?
  /// Told what the radio's queue lost while this app was away (Cairn firmware).
  private var queueLossHandler: (@Sendable (CairnQueueLoss) async -> Bool)?
  /// How often a drain that stored nothing reads the loss counters again.
  static let queueLossCheckInterval: TimeInterval = 600
  /// BUSY answers (the radio's send queue full) a NEXT drain waits out before it fails.
  static let queueSyncBusyRetryLimit = 20

  /// One drain at a time: a second waits for the first, then drains what is left.
  private var drainInProgress = false
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  // MARK: - Initialization

  init(
    session: any MeshCoreSessionProtocol,
    dataStore: any PersistenceStoreProtocol
  ) {
    self.session = session
    self.dataStore = dataStore
  }

  deinit {
    eventMonitorTask?.cancel()
  }

  // MARK: - Event Handlers

  /// Set handler for incoming contact messages
  func setContactMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?, DeliveryContext) async -> Void) {
    contactMessageHandler = handler
  }

  /// Set handler for incoming channel messages
  func setChannelMessageHandler(_ handler: @escaping @Sendable (ChannelMessage, ChannelDTO?, DeliveryContext) async -> Void) {
    channelMessageHandler = handler
  }

  /// Set handler for signed messages (from room servers)
  func setSignedMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void) {
    signedMessageHandler = handler
  }

  /// Set handler for CLI responses (textType = 0x01)
  func setCLIMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void) {
    cliMessageHandler = handler
  }

  /// Set handler for messages sent from the radio's own UI
  func setRadioSentMessageHandler(_ handler: @escaping @Sendable (RadioSentMessage, DeliveryContext) async -> Void) {
    radioSentMessageHandler = handler
  }

  /// Called on connect with what DEVICE_INFO said: `false` (stock firmware) skips every Cairn
  /// extension's probe for this connection.
  func setCairnFirmware(_ isCairn: Bool) {
    cairnExtensionsAbsent = !isCairn
  }

  // MARK: - Sent-message sync (Cairn firmware)

  /// Opts this link in to the radio's echo of messages sent from its own UI
  /// (`CMD_CAIRN_FW` sub 0x04, SENT_SYNC.md). Call on every connect before draining messages:
  /// the radio forgets the opt-in when the link drops. Firmware without it answers
  /// unsupported, and the app then doesn't ask again this session; a timeout is retried on the
  /// next call.
  func enableRadioSentSync() async {
    guard !radioSentSyncUnavailable, !cairnExtensionsAbsent else { return }
    do {
      let state = try await session.setCairnSyncSent(on: true, timeout: 5)
      logger.info("Sent-message sync on=\(state.isOn) queued=\(state.queued)")
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      radioSentSyncUnavailable = true
      logger.debug("Sent-message sync not supported by this firmware")
    } catch MeshCoreError.timeout {
      // A slow or lost reply is not proof the feature is missing (old firmware answers
      // unsupported at once): leave the flag clear so the next sync or resync asks again.
      logger.warning("Sent-message sync opt-in got no reply; will ask again on the next sync")
    } catch {
      logger.warning("Sent-message sync opt-in failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Chat history (Cairn firmware)

  /// Pulls the board's own chat history past this app's watermark (`CMD_CAIRN_FW` sub 0x05,
  /// HIST_SYNC.md): its messages from before this app was paired, or while another app drained
  /// the queue. Each record goes through the same handlers as a drained message (so the same
  /// dedupe keys match a copy the drain already stored) with ``DeliveryContext/history(storedAt:)``:
  /// stored read, no notification. The watermark (the board's store id and last record) moves on
  /// only after a page is stored, so a cut link resumes where it stopped. Never throws.
  ///
  /// Room posts reach the board signed and the record does not carry their author, so they are
  /// left out (counted in the log).
  func importRadioHistory() async -> Int {
    guard !radioHistoryUnavailable, !cairnExtensionsAbsent, let radioID = currentRadioID else { return 0 }
    let mark = HistoryWatermark(radioID: radioID)
    let first: CairnHistoryPageReply
    do {
      first = try await session.queryCairnHistory()
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      radioHistoryUnavailable = true
      logger.debug("Chat history pull not supported by this firmware")
      return 0
    } catch {
      logger.warning("Chat history query failed: \(error.localizedDescription)")
      return 0
    }
    // another numbering (a new board, its history cleared, a failed lease): from the start
    var since: UInt32 = mark.storeID == first.storeID ? mark.lastSeq : 0
    if since == 0, mark.storeID != first.storeID { mark.save(storeID: first.storeID, lastSeq: 0) }
    var walked = 0, stored = 0, skipped = 0, busyTries = 0
    while walked < 5000 {
      let page: CairnHistoryPage
      do {
        page = try await session.fetchCairnHistoryPage(sinceSeq: since, max: 32, inactivity: 3)
      } catch {
        logger.warning("Chat history page failed at \(since): \(error.localizedDescription)")
        break
      }
      if page.reply.status == .busy {
        busyTries += 1
        if busyTries > 5 { break }
        try? await Task.sleep(for: .seconds(2))
        continue
      }
      if page.reply.storeID != first.storeID {   // renumbered between pages: the next connect starts over
        mark.save(storeID: page.reply.storeID, lastSeq: 0)
        break
      }
      if page.reply.page == 0 { break }          // nothing past the cursor
      for record in page.records {
        if await deliverHistoryRecord(record) { stored += 1 } else { skipped += 1 }
      }
      walked += Int(page.reply.page)
      let next = page.nextSince(after: since)
      if next == since { break }                 // no progress (a page cut before its first record)
      since = next
      mark.save(storeID: first.storeID, lastSeq: since)
      if let end = page.end, end.remaining == 0 { break }
      if page.end == nil { break }               // the link went quiet: resume on the next connect
    }
    if walked > 0 {
      logger.info("Chat history: walked \(walked), handled \(stored), left out \(skipped), cursor \(since)")
    }
    return walked
  }

  /// One history record as the drained message it once was; false = left out (a room post: no author).
  private func deliverHistoryRecord(_ r: CairnHistoryRecord) async -> Bool {
    let context = DeliveryContext.history(storedAt: Date(timeIntervalSince1970: TimeInterval(r.storedAt)))
    let text = r.string
    if r.flags.contains(.outgoing) {
      // the board keeps the exact wire timestamp of a send as its stored time
      let destination = r.channelIndex.map { Data([$0, 0, 0, 0, 0, 0]) } ?? r.key
      await radioSentMessageHandler?(RadioSentMessage(
        isLive: false,
        kind: r.channelIndex == nil ? .direct : .channel,
        destination: destination,
        timestamp: r.storedAt,
        ackCode: 0,
        isDelivered: r.flags.contains(.delivered),
        text: text
      ), context)
      return true
    }
    if r.flags.contains(.signed) { return false }
    let sent = r.flags.contains(.hasSentTimestamp) ? r.sentAt : r.storedAt
    let snr = Double(r.snrX4) / 4
    if let channelIndex = r.channelIndex {
      await handleChannelMessage(ChannelMessage(
        channelIndex: channelIndex,
        pathLength: r.pathLength,
        textType: MeshTextType.plain.rawValue,
        senderTimestamp: Date(timeIntervalSince1970: TimeInterval(sent)),
        text: text,
        snr: snr
      ), context: context)
    } else {
      await handleContactMessage(ContactMessage(
        senderPublicKeyPrefix: r.key,
        pathLength: r.pathLength,
        textType: MeshTextType.plain.rawValue,
        senderTimestamp: Date(timeIntervalSince1970: TimeInterval(sent)),
        signature: nil,
        text: text,
        snr: snr
      ), context: context)
    }
    return true
  }

  /// Clears all message handlers. The wired handlers capture the owning
  /// `ServiceContainer` strongly, so leaving them in place keeps the whole
  /// service graph alive after the container is torn down on disconnect.
  func clearMessageHandlers() {
    contactMessageHandler = nil
    channelMessageHandler = nil
    signedMessageHandler = nil
    cliMessageHandler = nil
    radioSentMessageHandler = nil
  }

  /// Whether any message handler is currently wired.
  var hasMessageHandlersWired: Bool {
    contactMessageHandler != nil || channelMessageHandler != nil
      || signedMessageHandler != nil || cliMessageHandler != nil
      || radioSentMessageHandler != nil
  }

  // MARK: - Event Monitoring

  /// Start event monitoring for message handlers without enabling auto-fetch.
  /// Call this before sync to ensure handlers are ready for polled messages.
  /// - Parameter radioID: The radio ID for contact lookups
  func startMessageEventMonitoring(radioID: UUID) {
    currentRadioID = radioID
    startEventMonitoring()
    logger.info("Message event monitoring started for radio \(radioID)")
  }

  /// Stop event monitoring (also stops auto-fetch if running)
  func stopMessageEventMonitoring() async {
    if isAutoFetchEnabled {
      await stopAutoFetch()
    } else {
      stopEventMonitoring()
      currentRadioID = nil
    }
  }

  // MARK: - Auto-Fetch Control

  /// Start automatic message fetching for a device.
  /// This enables the session's auto-fetch feature and monitors for incoming messages.
  /// - Parameter radioID: The radio ID for contact lookups
  func startAutoFetch(radioID: UUID) async {
    guard !isAutoFetchEnabled else { return }

    currentRadioID = radioID
    isAutoFetchEnabled = true

    // Start event monitoring if not already running
    if eventMonitorTask == nil {
      startEventMonitoring()
    }
    // Every automatic drain (MSG_WAITING push, requestDrain, the periodic catch-up) runs here,
    // storing each answer before the next fetch: see `drainQueue(context:)`.
    await session.setAutoMessageDrainHandler { [weak self] in
      guard let self else { return }
      _ = try await self.drainQueue(timeoutRetries: 0)
    }
    await session.startAutoMessageFetching()
    // The radio pushes MSG_WAITING only when a message arrives: whatever a failed catch-up
    // drain left behind would otherwise wait for the next one.
    await session.requestMessageDrain()

    logger.info("Auto-fetch started for radio \(radioID)")
  }

  /// Stop automatic message fetching
  func stopAutoFetch() async {
    guard isAutoFetchEnabled else { return }

    isAutoFetchEnabled = false

    // Stop session-level auto-fetch
    await session.stopAutoMessageFetching()
    await session.setAutoMessageDrainHandler(nil)

    // Stop event monitoring
    stopEventMonitoring()

    logger.info("Auto-fetch stopped")
  }

  /// Pause session-level auto-fetching without stopping event monitoring.
  /// Used during resync to prevent auto-fetch events from inflating handler counts.
  func pauseAutoFetch() async {
    guard isAutoFetchEnabled else { return }
    await session.stopAutoMessageFetching()
  }

  /// Resume session-level auto-fetching after a pause.
  func resumeAutoFetch() async {
    guard isAutoFetchEnabled else { return }
    await session.startAutoMessageFetching()
    // A push that came while paused was dropped with the paused subscription.
    await session.requestMessageDrain()
  }

  /// Drains the radio's message queue now (auto-fetch must be on), e.g. on returning to the
  /// foreground: a drain cut short while suspended leaves messages the radio won't push again.
  /// Asked for, not pushed: the drain probes queue sync again even inside a failed probe's hold-off.
  func requestDrain() async {
    guard isAutoFetchEnabled else { return }
    explicitDrainRequests &+= 1
    await session.requestMessageDrain()
  }

  /// Drains the radio's queue after it reported refusing a MSG_WAITING push (RX_SYNC loss). An
  /// automatic drain like the push it replaces: it keeps a failed probe's hold-off, so a burst of
  /// refused pushes doesn't send an ARM, and wait out its timeout, for each one.
  func requestPushRecoveryDrain() async {
    guard isAutoFetchEnabled else { return }
    await session.requestMessageDrain()
  }

  /// Check if auto-fetch is currently enabled
  var isAutoFetching: Bool {
    isAutoFetchEnabled
  }

  // MARK: - Manual Polling

  /// Manually poll for one message from the device.
  /// - Returns: The message result (contact message, channel message, or no more messages)
  func pollMessage() async throws -> MessageResult {
    do {
      return try await session.getMessage()
    } catch let error as MeshCoreError {
      throw MessagePollingError.sessionError(error)
    }
  }

  /// Poll all waiting messages from the device.
  ///
  /// A fetch that times out is asked again a couple of times before the drain fails: the
  /// radio's answer can be lost on a busy link, and a failed drain leaves the rest of the queue
  /// on the radio until it next pushes MSG_WAITING.
  /// - Returns: Count of messages retrieved
  func pollAllMessages() async throws -> Int {
    // One anchor for the whole drain so every backlog message shares a sort date
    // and forms a single contiguous block positioned at delivery time.
    let blockAnchor = Date()
    drainAnchor = blockAnchor
    defer { drainAnchor = nil }
    // An explicit drain: probe queue sync again even inside a failed probe's hold-off.
    explicitDrainRequests &+= 1
    let count = try await drainQueue(timeoutRetries: Self.pollTimeoutRetryLimit)
    // Answers the event monitor claimed first must be stored before the caller ends
    // notification suppression.
    _ = await waitForPendingHandlers(timeout: .seconds(10))
    return count
  }

  /// Drains the radio's queue to its end, storing each message before fetching the next.
  ///
  /// The radio removes a message from its queue when it answers the fetch, so an answer must
  /// reach storage before the next one is asked for: the session's own auto-drain used to fetch
  /// as fast as the link answered and leave storage to the event monitor, whose buffer dropped
  /// the oldest answers once a backlog outran the handlers. Here a slow store slows the fetching
  /// instead, and at most one dequeued message is ever unsaved. Used by `pollAllMessages()` and,
  /// through the session's drain handler, by every automatic drain.
  /// - Parameter timeoutRetries: Timed-out fetches asked again before the drain throws.
  /// - Returns: How many received (not radio-sent) messages it handled.
  func drainQueue(timeoutRetries: Int) async throws -> Int {
    await acquireDrain()
    defer { releaseDrain() }
    if await queueSyncAvailable() {
      do {
        return try await drainWithQueueSync(timeoutRetries: timeoutRetries)
      } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
        // Not proof the firmware lacks queue sync (a reflash reboots the radio and so reconnects):
        // read the stock way this once, and let the next drain's ARM, the real test, decide.
        queueSyncSupport = nil
      }
    }
    var count = 0
    var timeouts = 0
    while true {
      try Task.checkCancellation()
      let result: MessageResult
      do {
        result = try await pollMessage()
        timeouts = 0
      } catch MessagePollingError.sessionError(.timeout) where timeouts < timeoutRetries {
        timeouts += 1
        logger.warning("Message fetch timed out during drain; asking again (\(timeouts))")
        continue
      }
      if case .noMoreMessages = result {
        lastDrainCompletedAt = Date()
        return count
      }
      if await deliverFetched(result).counted { count += 1 }
    }
  }

  /// When a drain last reached the end of the radio's queue, nil before the first.
  private(set) var lastDrainCompletedAt: Date?

  private func acquireDrain() async {
    guard drainInProgress else {
      drainInProgress = true
      return
    }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  private func releaseDrain() {
    if drainWaiters.isEmpty {
      drainInProgress = false
    } else {
      drainWaiters.removeFirst().resume()
    }
  }

  // MARK: - Queue sync (Cairn firmware)

  /// Installs the handler told what the radio's queue lost while this app was away.
  /// The handler returns whether the loss reached the user or was recorded where the app shows it;
  /// only then are the radio's counters cleared.
  func setQueueLossHandler(_ handler: @escaping @Sendable (CairnQueueLoss) async -> Bool) {
    queueLossHandler = handler
  }

  /// Whether this radio has queue sync, asking it once per connection. The question is an ARM, which
  /// also has the radio keep delivery confirmations for this app while it is away.
  private func queueSyncAvailable() async -> Bool {
    if cairnExtensionsAbsent { return false }
    if let queueSyncSupport { return queueSyncSupport }
    if let holdOff = queueSyncProbeHoldOff, holdOff.request == explicitDrainRequests,
       ContinuousClock.now < holdOff.until {
      return false
    }
    let request = explicitDrainRequests
    var unsupportedAnswers = 0
    while true {
      do {
        let state = try await session.armCairnQueueSync(on: true, timeout: 5)
        queueSyncSupport = true
        queueSyncProbeHoldOff = nil
        logger.info("Queue sync on: depth=\(state.depth)/\(state.capacity)")
        await reportQueueLoss(state.loss)
        return true
      } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
        // An ERR(unsupported) can be a stray (a late reply to another command, or another link's
        // error, which the radio writes to every interface): only a second one in a row is the
        // firmware's answer. Stock firmware answers both at once.
        unsupportedAnswers += 1
        guard unsupportedAnswers >= 2 else { continue }
        queueSyncSupport = false
        logger.debug("Queue sync not supported by this firmware: stock message reads")
        return false
      } catch {
        // A cancelled drain (the background sync stopped) says nothing about the radio.
        if Task.isCancelled || error is CancellationError { return false }
        // Not proof the feature is missing: automatic drains read the stock way for a while, until an
        // explicit drain asked for after this probe began.
        logger.warning("Queue sync probe failed: \(error.localizedDescription)")
        queueSyncProbeHoldOff = (ContinuousClock.now.advanced(by: Self.queueSyncProbeBackoff), request)
        return false
      }
    }
  }

  /// The drain over queue sync's two-step read: a frame leaves the radio only when the NEXT after it
  /// names its seq, which this app sends only once the frame is stored. A NEXT that times out or a link
  /// that drops leaves the frame queued, and it comes again (the handlers drop the duplicate).
  private func drainWithQueueSync(timeoutRetries: Int) async throws -> Int {
    var count = 0
    var timeouts = 0
    var busy = 0
    var unstored = 0
    while true {
      try Task.checkCancellation()
      let frame: CairnQueuedFrame
      do {
        frame = try await session.nextCairnQueuedFrame(ackSeq: queueSyncAckSeq, timeout: nil)
        timeouts = 0
        busy = 0
      } catch MeshCoreError.timeout where timeouts < timeoutRetries {
        timeouts += 1
        logger.warning("Queue sync NEXT timed out; asking again (\(timeouts))")
        continue
      } catch let MeshCoreError.deviceError(code) where code == MeshCoreSession.queueSyncBusyCode
        && busy < Self.queueSyncBusyRetryLimit {
        busy += 1
        try await Task.sleep(for: .milliseconds(100 * busy))
        continue
      }
      // The radio answered, so it removed the frame the request named.
      queueSyncAckSeq = 0
      switch frame.content {
      case .noMoreMessages:
        lastDrainCompletedAt = Date()
        if count > 0 || lastQueueLossCheck.map({ Date().timeIntervalSince($0) >= Self.queueLossCheckInterval }) ?? true {
          await checkQueueLoss()
        }
        return count
      case let .message(result):
        let delivery = await deliverFetched(result)
        guard delivery.stored else {
          // Another handler holds this message and has not stored it yet: no ACK, so the next NEXT
          // gets the same frame again (the claim drops the duplicate) instead of removing it.
          unstored += 1
          logger.warning("Queued frame \(frame.seq) not stored yet; leaving it on the radio (\(unstored))")
          if unstored >= Self.unstoredRedeliveryLimit { throw MessagePollingError.pollingFailed }
          continue
        }
        unstored = 0
        if delivery.counted { count += 1 }
      case .confirmation:
        // MessageService takes the acknowledgement event the same frame dispatched.
        break
      case .unreadable:
        logger.warning("Skipped an unreadable queued frame (seq \(frame.seq))")
      }
      // Stored (or skipped): the next NEXT removes it from the radio.
      queueSyncAckSeq = frame.seq
    }
  }

  /// Reads the radio's loss counters and reports any loss.
  private func checkQueueLoss() async {
    lastQueueLossCheck = Date()
    do {
      let state = try await session.cairnQueueSyncState(timeout: 5)
      await reportQueueLoss(state.loss)
    } catch {
      logger.debug("Queue sync STATE failed: \(error.localizedDescription)")
    }
  }

  /// Hands a non-empty loss to the handler, then clears what was reported on the radio once the
  /// handler says it reached the user or the app recorded it. Without a handler, or when it could
  /// do neither, nothing is cleared, so the next check reports it again.
  private func reportQueueLoss(_ loss: CairnQueueLoss) async {
    lastQueueLossCheck = Date()
    guard !loss.isEmpty else { return }
    logger.warning(
      "Radio queue loss: channelEvicted=\(loss.channelEvicted) refused=\(loss.refused) " +
        "snapshotLost=\(loss.snapshotLost) confirmationsEvicted=\(loss.confirmationsEvicted)"
    )
    guard let queueLossHandler else { return }
    guard await queueLossHandler(loss) else {
      logger.warning("Radio queue loss not surfaced; leaving the radio's counters for the next check")
      return
    }
    _ = try? await session.clearCairnQueueLoss(loss, timeout: 5)
  }

  /// What `deliverFetched` did with one answer.
  private struct Delivery {
    /// A received message (counted by the drains).
    let counted: Bool
    /// Stored: by this drain, or by the handler that claimed it first, which has returned.
    let stored: Bool
  }

  /// Hands one fetched answer to its handler and returns once it is stored. The event monitor
  /// sees the same answer; whichever claims it first handles it, and a drain that lost the claim
  /// waits for that message's handler, so the next fetch (and queue sync's ACK) still waits on
  /// storage. `stored` is false only when that handler outran the wait (30 s).
  private func deliverFetched(_ result: MessageResult) async -> Delivery {
    let context: DeliveryContext = drainAnchor.map { .initialSync(anchor: $0) } ?? .live
    switch result {
    case let .contactMessage(msg):
      let stored = await handleOnce(Self.claimKey(msg)) {
        await self.handleContactMessage(msg, context: context)
      }
      return Delivery(counted: true, stored: stored)
    case let .channelMessage(msg):
      let stored = await handleOnce(Self.claimKey(msg)) {
        await self.handleChannelMessage(msg, context: context)
      }
      return Delivery(counted: true, stored: stored)
    case .channelDatagram:
      // Datagrams are not user-visible messages; drain queue without counting.
      // A follow-up plan will add a dedicated CairnServices listener for them.
      return Delivery(counted: false, stored: true)
    case let .radioSentMessage(msg):
      // The radio's own sends: stored as outgoing, never counted as received. Same drain
      // anchor as the received messages around it, so the backlog stays in queue order.
      let handler = radioSentMessageHandler
      let stored = await handleOnce(Self.claimKey(msg)) {
        await handler?(msg, msg.isLive ? .live : context)
      }
      return Delivery(counted: false, stored: stored)
    case .noMoreMessages:
      return Delivery(counted: false, stored: true)
    }
  }

  /// Runs `body` for the message `key` names if this caller claims it; otherwise waits for the
  /// handler that did. Returns whether the message is handled (stored) on return.
  private func handleOnce(_ key: String, _ body: () async -> Void) async -> Bool {
    guard claim(key) else {
      return await waitForHandler(of: key, timeout: claimedHandlerWait)
    }
    beginHandling(key)
    defer { endHandling(key) }
    await body()
    return true
  }

  /// Test hook: shortens the wait for another handler's store.
  func setClaimedHandlerWait(_ wait: Duration) {
    claimedHandlerWait = wait
  }

  /// Marks a claimed message's handler as running (counted by `waitForPendingHandlers` too).
  private func beginHandling(_ key: String) {
    pendingHandlerCount += 1
    handlingKeys[key, default: 0] += 1
  }

  private func endHandling(_ key: String) {
    pendingHandlerCount -= 1
    if let running = handlingKeys[key], running > 1 {
      handlingKeys[key] = running - 1
    } else {
      handlingKeys[key] = nil
    }
  }

  /// Waits until no handler for `key` is running. True once none is (it stored the message, or
  /// returned without it, as the handlers do for what they drop on purpose); false on timeout or
  /// cancellation, when the message may not be stored yet.
  private func waitForHandler(of key: String, timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while handlingKeys[key] != nil {
      if clock.now >= deadline || Task.isCancelled { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  /// Wait for all pending message handlers to complete.
  /// Call this after pollAllMessages() to ensure all messages are fully processed
  /// before performing actions that depend on completion (like resuming notifications).
  func waitForPendingHandlers(timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while pendingHandlerCount > 0 {
      if clock.now >= deadline || Task.isCancelled {
        return false
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    return true
  }

  // MARK: - Event Monitoring

  /// Start monitoring MeshCore events for messages
  private func startEventMonitoring() {
    eventMonitorTask?.cancel()

    eventMonitorTask = Task { [weak self] in
      guard let self else { return }
      // Unbounded: every answer here was already taken off the radio's queue, so a dropped
      // event is a lost message. The drains wait on storage, so the backlog stays small; the
      // label counts any drop in the session's diagnostics.
      let events = await session.events(
        filter: EventFilter.anyContactMessage.or(.anyChannelMessage).or(.radioSentMessage),
        buffering: .unbounded,
        label: Self.eventSubscriptionLabel
      )

      for await event in events {
        guard !Task.isCancelled else { break }
        await handleEvent(event)
      }
    }
  }

  /// Stop monitoring events
  private func stopEventMonitoring() {
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
  }

  /// Handle incoming MeshCore event
  ///
  /// Every fetched message reaches this monitor, whoever asked for it: `pollAllMessages()`, the
  /// session's auto-drain, or another caller of `getMessage`. A drain used to make the monitor
  /// drop every message event while it ran, which lost the answers to fetches it didn't make
  /// (they were already gone from the radio's queue). Claims now keep each message to one
  /// handler instead.
  private func handleEvent(_ event: MeshEvent) async {
    let context: DeliveryContext = drainAnchor.map { .initialSync(anchor: $0) } ?? .live
    switch event {
    case let .contactMessageReceived(message):
      let key = Self.claimKey(message)
      guard claim(key) else { return }
      beginHandling(key)
      defer { endHandling(key) }
      await handleContactMessage(message, context: context)

    case let .channelMessageReceived(message):
      let key = Self.claimKey(message)
      guard claim(key) else { return }
      beginHandling(key)
      defer { endHandling(key) }
      await handleChannelMessage(message, context: context)

    case let .radioSentMessage(message):
      let key = Self.claimKey(message)
      guard claim(key) else { return }
      beginHandling(key)
      defer { endHandling(key) }
      await radioSentMessageHandler?(message, message.isLive ? .live : context)

    default:
      break
    }
  }

  // MARK: - Claims

  /// Claims a fetched message for handling. The answer to a drain's fetch reaches both the drain
  /// and the event monitor, so the first to claim handles it and the other skips it. False when
  /// it was already claimed. Keeps the most recent `claimedMessageLimit` keys.
  private func claim(_ key: String) -> Bool {
    guard claimedMessageKeys.insert(key).inserted else { return false }
    claimedMessageOrder.append(key)
    if claimedMessageOrder.count > Self.claimedMessageLimit {
      claimedMessageKeys.remove(claimedMessageOrder.removeFirst())
    }
    return true
  }

  static func claimKey(_ message: ContactMessage) -> String {
    let stamp = Int(message.senderTimestamp.timeIntervalSince1970)
    return "dm|\(message.senderPublicKeyPrefix.base64EncodedString())|\(stamp)|\(message.textType)|\(message.text)"
  }

  static func claimKey(_ message: ChannelMessage) -> String {
    let stamp = Int(message.senderTimestamp.timeIntervalSince1970)
    return "ch|\(message.channelIndex)|\(stamp)|\(message.textType)|\(message.text)"
  }

  static func claimKey(_ message: RadioSentMessage) -> String {
    let status = message.deliveryStatus.map { String(describing: $0) } ?? "-"
    return "rs|\(message.isLive)|\(message.kind.rawValue)|\(message.destination.base64EncodedString())|"
      + "\(message.timestamp)|\(message.ackCode)|\(message.isDelivered)|\(status)|\(message.text)"
  }

  // MARK: - Private Message Handlers

  /// Handle incoming contact message
  private func handleContactMessage(_ message: ContactMessage, context: DeliveryContext) async {
    guard let radioID = currentRadioID else {
      logger.warning("Received message but no radio ID set")
      await contactMessageHandler?(message, nil, context)
      return
    }

    // Look up the sender contact
    let contact = try? await dataStore.fetchContact(
      radioID: radioID,
      publicKeyPrefix: message.senderPublicKeyPrefix
    )

    // Route based on text type
    switch message.textType {
    case MeshTextType.cliData.rawValue:
      // CLI responses from repeaters (textType = 0x01)
      await cliMessageHandler?(message, contact)
    case MeshTextType.signedPlain.rawValue:
      // Signed messages from room servers (textType = 0x02)
      await signedMessageHandler?(message, contact)
    case MeshTextType.cliCommand.rawValue:
      // Another companion asked to run a command here (textType = 0x03). The radio
      // queues it only when that contact's remote-commands flag is off, so it is
      // not run, and it is no chat message either.
      let sender = contact?.displayName ?? message.senderPublicKeyPrefix.hexString
      logger.info("\(sender) asked to run a command here; not allowed (remote commands off)")
    default:
      // Regular contact messages (textType = 0x00 or unknown)
      await contactMessageHandler?(message, contact, context)
    }
  }

  /// Handle incoming channel message
  private func handleChannelMessage(_ message: ChannelMessage, context: DeliveryContext) async {
    guard let radioID = currentRadioID else {
      logger.warning("Received channel message but no radio ID set")
      await channelMessageHandler?(message, nil, context)
      return
    }

    // Look up the channel
    let channel = try? await dataStore.fetchChannel(radioID: radioID, index: message.channelIndex)

    await channelMessageHandler?(message, channel, context)
  }
}

// MARK: - MessagePollingServiceProtocol Conformance

extension MessagePollingService: MessagePollingServiceProtocol {
  // Already implements pollAllMessages() -> Int
}

// MARK: - Message Text Type Constants

/// Text type identifiers for mesh messages
enum MeshTextType: UInt8 {
  case plain = 0x00
  case cliData = 0x01
  case signedPlain = 0x02
  /// Another companion's command for this radio's CLI (MeshCore 1.18 `TXT_TYPE_CLI_COMMAND`).
  case cliCommand = 0x03
}

// MARK: - History watermark

/// How far this app has pulled one radio's chat history: the board's store id and the last
/// record it walked. Per radio, in the app's defaults (no schema change).
struct HistoryWatermark {
  let radioID: UUID
  private var key: String { "cairn.history.watermark.\(radioID.uuidString)" }

  var storeID: UInt32 { UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: key + ".store")) }
  var lastSeq: UInt32 { UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: key + ".seq")) }

  func save(storeID: UInt32, lastSeq: UInt32) {
    UserDefaults.standard.set(Int(storeID), forKey: key + ".store")
    UserDefaults.standard.set(Int(lastSeq), forKey: key + ".seq")
  }

  /// Forget it: the next pull starts from the board's first record ("Import again").
  func reset() {
    UserDefaults.standard.removeObject(forKey: key + ".store")
    UserDefaults.standard.removeObject(forKey: key + ".seq")
  }
}
