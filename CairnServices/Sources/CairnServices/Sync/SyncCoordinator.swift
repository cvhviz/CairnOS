// SyncCoordinator.swift
import Foundation

// MARK: - Sync Types

/// Current state of the sync coordinator
enum SyncState: Equatable {
  case idle
  case syncing(progress: SyncProgress)
  case synced
  case failed(SyncCoordinatorError)

  /// Whether currently syncing
  var isSyncing: Bool {
    if case .syncing = self { return true }
    return false
  }

  static func == (lhs: SyncState, rhs: SyncState) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle): true
    case (.synced, .synced): true
    case let (.syncing(a), .syncing(b)): a == b
    case (.failed, .failed): true // Simplified equality
    default: false
    }
  }
}

/// Progress information during sync
struct SyncProgress: Equatable {
  let phase: SyncPhase
  let current: Int
  let total: Int
}

/// Phases of the sync process
public enum SyncPhase: Sendable, Equatable {
  case contacts
  case channels
  case messages
}

/// Phase-level sync outcome.
enum SyncPhaseStatus: Equatable {
  case clean
  case partial
  case skipped
  case failed(String)

  var isClean: Bool {
    self == .clean
  }
}

/// Structured result for an initial or full sync.
struct FullSyncResult: Equatable {
  let contacts: SyncPhaseStatus
  let channels: SyncPhaseStatus
  let messages: SyncPhaseStatus
  let channelRetryIndices: [UInt8]

  var isConnectionUsable: Bool {
    contacts == .clean
  }

  init(
    contacts: SyncPhaseStatus,
    channels: SyncPhaseStatus,
    messages: SyncPhaseStatus,
    channelRetryIndices: [UInt8] = []
  ) {
    self.contacts = contacts
    self.channels = channels
    self.messages = messages
    self.channelRetryIndices = channelRetryIndices
  }

  static let skipped = FullSyncResult(
    contacts: .skipped,
    channels: .skipped,
    messages: .skipped
  )
}

/// Errors from SyncCoordinator operations
public enum SyncCoordinatorError: Error, Sendable {
  case notConnected
  case syncFailed(String)
  case alreadySyncing
}

extension SyncCoordinatorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected to device."
    case let .syncFailed(msg): "Sync failed: \(msg)"
    case .alreadySyncing: "A sync is already in progress."
    }
  }
}

// MARK: - SyncCoordinator Actor

/// Coordinates data synchronization between MeshCore device and local database.
///
/// SyncCoordinator owns:
/// - Handler wiring (before event monitoring starts)
/// - Event monitoring lifecycle
/// - Full sync (contacts, channels, messages)
/// - UI refresh notifications
public actor SyncCoordinator {
  // MARK: - Logging

  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "SyncCoordinator")

  /// Where a radio queue loss no notification could report is kept for Settings to show.
  var queueLossLedger = RadioQueueLossLedger()

  /// Key prefixes of senders whose DMs were stored without a contact row this process, waiting for
  /// the contact phase to link them (`adoptPendingOrphanDirectMessages`). Bounded: a sender the
  /// radio never learns stays orphaned, as before.
  var pendingOrphanSenderPrefixes: Set<Data> = []
  static let pendingOrphanSenderLimit = 64

  /// Actor-local guard against concurrent sync execution.
  /// Checked and set synchronously (no `await`) to eliminate the TOCTOU window
  /// that existed when guarding via the `@MainActor`-isolated `state` property.
  /// Releasing it starts a pending channel sync a foreground return had to defer.
  var isSyncInProgress = false {
    didSet {
      guard oldValue, !isSyncInProgress, let deferred = deferredPendingChannelSync else { return }
      deferredPendingChannelSync = nil
      Task { await deferred() }
    }
  }

  /// True while `performAdvertContactSync` holds `isSyncInProgress`. Full sync,
  /// connection setup, and channel-only retry wait for this claim instead of skipping.
  var advertContactSyncActive = false

  /// True while a user-initiated contact refresh holds the radio pipeline.
  /// Advert delta sync returns `.busy` so it retries on the debounce rather
  /// than racing progress events with pull-to-refresh.
  var manualContactSyncActive = false

  /// Continuations held by `waitForAdvertContactSync` until the advert claim clears.
  var advertSyncWaiters: [AdvertSyncWaiter] = []

  /// Monotonic id for advert-sync waiters so cancel/timeout can resume one waiter.
  var nextAdvertSyncWaiterID: UInt64 = 0

  /// Optional override for the advert claim wait bound. Tests set a short value;
  /// production leaves this nil so `advertContactSyncWaitTimeout` applies.
  var advertContactSyncWaitTimeoutOverride: Duration?

  /// One suspended waiter for the advert contact-sync claim.
  struct AdvertSyncWaiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  /// Radio whose full contact fetch (`since == nil`) last completed. An empty
  /// contact table stamps no watermark, so the zero sentinel alone cannot separate
  /// "no full sync yet" from "nothing to stamp". Advert delta sync needs that
  /// difference to run at all.
  var fullContactSyncCompletedRadioID: UUID?

  /// Radio that already spent its one invalid-watermark recovery full fetch this
  /// coordinator lifetime. Bounds residual far-future lastmod tables so advert
  /// delta cannot re-stream the whole contact table every debounce forever.
  /// Manual pull-to-refresh and `forceFullSync` do not consult this latch.
  var invalidWatermarkRecoveryRadioID: UUID?

  /// Radio for which the exhausted-recovery notice was already logged once.
  var invalidWatermarkRecoveryExhaustedLoggedRadioID: UUID?

  /// Cached blocked names (contacts + channel senders) for O(1) lookup in message handlers
  private var blockedNames: Set<String> = []

  /// Per-radio contact name tables for naming senders in notifications. Built on first use and
  /// dropped whenever contacts change (`invalidateContactNames()`), so a drain of many messages
  /// fetches contacts once.
  var contactNameDirectories: [UUID: ContactNameDirectory] = [:]

  /// The wired connection's store and radio, so a contact change can bring the names of remote
  /// node sessions (rooms, repeaters) up to date. Set by `wireMessageHandlers`.
  var contactNameStore: (dataStore: any PersistenceStoreProtocol, radioID: UUID)?

  /// The pending session-name refresh after a burst of contact changes.
  var sessionNameRefreshTask: Task<Void, Never>?

  /// Tracks channel indices received for slots with no local channel (notifications suppressed)
  /// in this connection session.
  var unresolvedChannelIndices: Set<UInt8> = []
  var lastUnresolvedChannelSummaryAt: Date?

  /// Radio whose channel phase was skipped because the app was in the background. Nothing else
  /// re-reads channels until the next connect, so `runPendingChannelSyncIfNeeded` runs it on
  /// return to the foreground; a foreground channel sync of that radio clears it.
  var channelSyncPendingRadioID: UUID?

  /// Whether the pending channel sync may start with `verifyChannels`: this app session, or an
  /// earlier process (`ChannelSyncConfig.storedChannelTableVerified`), read the pending radio's
  /// channels cleanly, so its stored rows are a full copy.
  var channelSyncPendingVerifiable = false

  /// Whether the pending channel sync's full read may use the pipelined read: the transport
  /// policy (`ChannelSyncConfig.usePipelinedChannelRead`) of the connect that skipped channels.
  var channelSyncPendingPipelined = false

  /// Radio whose channel reads left slots unread with errors the channel-only retry skips (a
  /// circuit breaker, a device error): it retries only the retryable slots, so a clean
  /// `retryChannels` must not vouch for the table. Cleared by a full read or check that finishes
  /// cleanly.
  var channelSlotsUnreadRadioID: UUID?

  /// The pending channel sync a return to the foreground found blocked by a sync still running
  /// (a background-started connect in its message phase, say). Run once that sync releases
  /// `isSyncInProgress`, instead of waiting for the next return to the foreground.
  var deferredPendingChannelSync: (@Sendable () async -> Void)?

  /// Bumped by every `onDisconnected`, before its first suspension. A deferred pending channel
  /// sync captures it and stands down if the link it was deferred on has since dropped.
  var linkGeneration: UInt64 = 0

  /// Messages that arrived while notifications were suppressed for a catch-up sync, one entry
  /// per conversation in arrival order. Flushed as one notification each when the app is away.
  var catchUpTally: [CatchUpConversation: CatchUpEntry] = [:]
  var catchUpOrder: [CatchUpConversation] = []

  /// Foreground check for the catch-up notifications, from the wired connection.
  var catchUpAppStateProvider: AppStateProvider?

  /// When a catch-up drain last finished delivering: the radio's queue drained, its message
  /// handlers done, suppression lifted and the tally posted (`markCatchUpDelivered()`). A
  /// Background App Refresh run waits for this, not for the queue to empty: until then the
  /// drained messages are stored but their notifications are not posted yet.
  private(set) var lastCatchUpDeliveredAt: Date?

  /// Records that a catch-up drain finished delivering (``lastCatchUpDeliveredAt``). Called after
  /// the drain, its suppression lift and its flush, whether or not anything was posted.
  func markCatchUpDelivered() {
    lastCatchUpDeliveredAt = Date()
  }

  /// Contact key prefixes (hex) a radio-sent DM echo named but no local contact had; each
  /// triggers one contact refresh per coordinator lifetime.
  var radioSentContactRefreshes: Set<String> = []
  let unresolvedChannelSummaryIntervalSeconds: TimeInterval = 60

  /// Timestamp window size (in seconds) for matching reactions to messages.
  /// Allows for clock drift and delayed delivery within a 5-minute window.
  let reactionTimestampWindowSeconds: UInt32 = 300

  // MARK: - Observable State (@MainActor for SwiftUI)

  /// Current sync state
  @MainActor private(set) var state: SyncState = .idle

  /// Incremented when contacts data changes
  @MainActor private(set) var contactsVersion: Int = 0

  /// Incremented when conversations data changes
  @MainActor private(set) var conversationsVersion: Int = 0

  /// Last successful sync date
  @MainActor private(set) var lastSyncDate: Date?

  /// Called when channel sync completes with zero errors (including retries).
  /// Used by ConnectionManager to track clean channel completions for smart resync.
  /// Installed by `ConnectionManager.wireCleanChannelSyncCallback`.
  var onCleanChannelSync: (@Sendable (_ radioID: UUID) async -> Void)?

  /// Called when a channel sync attempt starts, clean or partial.
  /// Used by ConnectionManager to cool down immediate channel retry loops.
  /// Installed by `ConnectionManager.wireCleanChannelSyncCallback`.
  var onChannelSyncAttempted: (@Sendable (_ radioID: UUID) async -> Void)?

  /// Called when a channel read (a full read, or a retry of its failed slots) that did not finish
  /// cleanly changed the stored table (`ChannelSyncResult.changedStoredTable`): fresh and old
  /// rows are mixed, so a later check could pass while the radio differs. A read that threw, or
  /// changed nothing, persisted nothing new and leaves the stored copy as clean as it was.
  /// Used by ConnectionManager to drop its clean records until a read finishes cleanly.
  /// Installed by `ConnectionManager.wireCleanChannelSyncCallback`.
  var onChannelTableTrustWithdrawn: (@Sendable (_ radioID: UUID) async -> Void)?

  /// Sets the callback for clean channel sync completion.
  func setCleanChannelSyncCallback(_ callback: @escaping @Sendable (_ radioID: UUID) async -> Void) {
    onCleanChannelSync = callback
  }

  /// Sets the callback for a full channel read that changed the stored table without finishing cleanly.
  func setChannelTableTrustWithdrawnCallback(_ callback: @escaping @Sendable (_ radioID: UUID) async -> Void) {
    onChannelTableTrustWithdrawn = callback
  }

  /// Sets the callback for any channel sync attempt.
  func setChannelSyncAttemptedCallback(_ callback: @escaping @Sendable (_ radioID: UUID) async -> Void) {
    onChannelSyncAttempted = callback
  }

  /// Callback when non-message sync activity starts.
  /// Installed by `ConnectionUIState.wireCallbacks` via `setSyncActivityCallbacks`.
  var onSyncActivityStarted: (@Sendable () async -> Void)?

  /// Callback when non-message sync activity ends.
  /// Installed by `ConnectionUIState.wireCallbacks` via `setSyncActivityCallbacks`.
  var onSyncActivityEnded: (@Sendable (_ succeeded: Bool) async -> Void)?

  /// Tracks whether onSyncActivityEnded has been called for the current sync cycle.
  /// Prevents double-callback when disconnect occurs mid-sync (both onDisconnected
  /// and error path would otherwise call onSyncActivityEnded).
  var hasEndedSyncActivity = true

  /// Watchdog task that force-clears notification suppression after 120s.
  /// Prevents stuck suppression if sync completes abnormally without clearing it.
  private var suppressionWatchdogTask: Task<Void, Never>?

  /// Callback when sync phase changes (for SwiftUI observation).
  /// Installed by `ConnectionUIState.wireCallbacks` via `setSyncActivityCallbacks`.
  @MainActor private var onPhaseChanged: (@Sendable @MainActor (_ phase: SyncPhase?) -> Void)?
  /// Tells the UI whether the contacts phase downloads every contact or only changed ones, so
  /// progress can show "42/150" for a full fetch and a plain update count otherwise.
  @MainActor private var onContactFetchModeChanged: (@Sendable @MainActor (_ isFullFetch: Bool) -> Void)?

  /// Multicast broadcaster for data-change and incoming-message events.
  /// Producers yield synchronously from any isolation; consumers subscribe
  /// via `dataEvents()`.
  nonisolated let dataEventBroadcaster = EventBroadcaster<SyncDataEvent>()

  /// Task consuming `AdvertisementService.events()` for ongoing contact
  /// discovery. Started by `startDiscoveryEventMonitoring` only after the
  /// initial sync so adverts arriving during sync do not spam notifications;
  /// cancelled by `ServiceContainer.tearDown()`.
  var discoveryEventsTask: Task<Void, Never>?

  // MARK: - Test Seams

  #if DEBUG
    /// Test override for `performResync`. When set, bypasses the real sync path.
    var performResyncOverride: ((_ radioID: UUID, _ dependencies: SyncDependencies) async -> Bool)?

    /// Sets the test override for `performResync`.
    func setPerformResyncOverride(_ override: @escaping @Sendable (_ radioID: UUID, _ dependencies: SyncDependencies) async -> Bool) {
      performResyncOverride = override
    }
  #endif

  // MARK: - Initialization

  init() {}

  // MARK: - State Setters

  @MainActor
  func setState(_ newState: SyncState) {
    state = newState
    if case let .syncing(progress) = newState {
      onPhaseChanged?(progress.phase)
    } else {
      onPhaseChanged?(nil)
    }
  }

  @MainActor
  func setLastSyncDate(_ date: Date) {
    lastSyncDate = date
  }

  /// Sets callbacks for sync activity tracking (used by UI to show syncing pill)
  /// Only called for contacts and channels phases, NOT for messages.
  public func setSyncActivityCallbacks(
    onStarted: @escaping @Sendable () async -> Void,
    onEnded: @escaping @Sendable (_ succeeded: Bool) async -> Void,
    onPhaseChanged: @escaping @Sendable @MainActor (_ phase: SyncPhase?) -> Void
  ) async {
    onSyncActivityStarted = onStarted
    onSyncActivityEnded = onEnded
    await MainActor.run { self.onPhaseChanged = onPhaseChanged }
  }

  /// Sets the callback that reports whether each contacts phase is a full or incremental fetch.
  @MainActor
  public func setContactFetchModeCallback(_ callback: @escaping @Sendable @MainActor (_ isFullFetch: Bool) -> Void) {
    onContactFetchModeChanged = callback
  }

  @MainActor
  func reportContactFetchMode(isFullFetch: Bool) {
    onContactFetchModeChanged?(isFullFetch)
  }

  // MARK: - Data Events

  /// Returns a fresh stream of data-change and incoming-message events.
  /// Registration is synchronous, so events yielded after this call are
  /// never dropped. Consumers must re-subscribe per connection because the
  /// owning `ServiceContainer` is rebuilt on every connection.
  public nonisolated func dataEvents() -> AsyncStream<SyncDataEvent> {
    dataEventBroadcaster.subscribe()
  }

  /// Ends every `dataEvents()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release the service
  /// references they hold.
  nonisolated func finishDataEvents() {
    dataEventBroadcaster.finish()
  }

  // MARK: - Sync Activity Tracking

  /// Calls onSyncActivityEnded at most once per sync cycle.
  /// Guards against double-callback when disconnect occurs mid-sync.
  func endSyncActivityOnce(succeeded: Bool = false) async {
    guard !hasEndedSyncActivity else { return }
    hasEndedSyncActivity = true
    logger.info("[Sync] Calling onSyncActivityEnded (succeeded: \(succeeded))")
    await onSyncActivityEnded?(succeeded)
  }

  /// Called by ConnectionManager when a resync loop starts.
  /// Increments the activity count so "Syncing" pill stays visible across retries.
  func beginResyncActivity() async {
    await onSyncActivityStarted?()
  }

  /// Called by ConnectionManager when a resync loop ends (success or exhausted retries).
  /// Decrements the activity count. Only triggers "Ready" toast on success.
  func endResyncActivity(succeeded: Bool) async {
    await onSyncActivityEnded?(succeeded)
  }

  // MARK: - Notification Suppression Watchdog

  func startSuppressionWatchdog(notificationService: NotificationService) {
    suppressionWatchdogTask?.cancel()
    suppressionWatchdogTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(120))
      guard !Task.isCancelled, let self else { return }
      let isSuppressing = await notificationService.isSuppressingNotifications
      guard isSuppressing else { return }
      logger.warning("[Sync] Notification suppression watchdog fired after 120s - force clearing")
      await MainActor.run {
        notificationService.isSuppressingNotifications = false
      }
    }
  }

  func cancelSuppressionWatchdog() {
    suppressionWatchdogTask?.cancel()
    suppressionWatchdogTask = nil
  }

  // MARK: - Notifications

  /// Notify that contacts data changed (triggers UI refresh)
  @MainActor
  public func notifyContactsChanged() {
    logger.debug("notifyContactsChanged: version \(contactsVersion) → \(contactsVersion + 1)")
    contactsVersion += 1
    dataEventBroadcaster.yield(.contactsChanged)
    Task { await self.contactsDidChange() }
  }

  /// Notify that conversations data changed (triggers UI refresh)
  @MainActor
  public func notifyConversationsChanged() {
    conversationsVersion += 1
    dataEventBroadcaster.yield(.conversationsChanged)
  }

  // MARK: - Blocked Contacts Cache

  /// Refresh the blocked names cache from the data store (contacts + channel senders)
  public func refreshBlockedContactsCache(radioID: UUID, dataStore: any ContactPersisting) async {
    do {
      let blockedContacts = try await dataStore.fetchBlockedContacts(radioID: radioID)
      let blockedSenders = try await dataStore.fetchBlockedChannelSenders(radioID: radioID)
      blockedNames = Set(blockedContacts.map(\.name))
        .union(Set(blockedSenders.map(\.name)))
      logger.debug("Refreshed blocked names cache: \(blockedNames.count) entries")
    } catch {
      logger.error("Failed to refresh blocked names cache: \(error)")
      blockedNames = []
    }
  }

  /// Whether an incoming channel message should be dropped before it is stored,
  /// counted as unread, or notified: its sender is blocked, or its text contains
  /// one of the user's blocked keywords.
  func isBlockedChannelMessage(senderNodeName: String?, text: String) -> Bool {
    if isBlockedSender(senderNodeName) { return true }
    guard BlockedKeywords.matches(text, keywords: BlockedKeywords.load()) else { return false }
    logger.debug("Dropped channel message matching a blocked keyword")
    return true
  }

  /// Check if a sender name is blocked (O(1) lookup)
  func isBlockedSender(_ name: String?) -> Bool {
    guard let name else { return false }
    return blockedNames.contains(name)
  }

  /// Returns a snapshot of blocked sender names for synchronous filtering
  public func blockedSenderNames() -> Set<String> {
    blockedNames
  }

  // MARK: - Timestamp Correction

  /// Maximum acceptable time in the future for a sender timestamp (5 minutes)
  static let timestampToleranceFuture: TimeInterval = 5 * 60

  /// Maximum acceptable time in the past for a sender timestamp (6 months)
  private static let timestampTolerancePast: TimeInterval = 6 * 30 * 24 * 60 * 60

  /// Corrects invalid timestamps from senders with broken clocks.
  ///
  /// MeshCore protocol does not specify timestamp validation. This is a client-side
  /// policy to prevent timeline corruption when devices have severely incorrect clocks
  /// (a common issue per MeshCore FAQ 6.1, 6.2). Original timestamps are preserved
  /// for ACK deduplication (per payloads.md:65).
  ///
  /// Returns the corrected timestamp and whether correction was applied.
  /// Timestamps are considered invalid if:
  /// - More than 5 minutes in the future (relative to receive time)
  /// - More than 6 months in the past (relative to receive time)
  ///
  /// - Parameters:
  ///   - timestamp: The sender's claimed timestamp
  ///   - receiveTime: When the message was received (defaults to now)
  /// - Returns: Tuple of (corrected timestamp, was corrected flag)
  nonisolated static func correctTimestampIfNeeded(
    _ timestamp: UInt32,
    receiveTime: Date = Date()
  ) -> (correctedTimestamp: UInt32, wasCorrected: Bool) {
    let receiveSeconds = receiveTime.timeIntervalSince1970
    let timestampSeconds = TimeInterval(timestamp)

    let isTooFarInFuture = timestampSeconds > receiveSeconds + timestampToleranceFuture
    let isTooFarInPast = timestampSeconds < receiveSeconds - timestampTolerancePast

    if isTooFarInFuture || isTooFarInPast {
      return (UInt32(receiveSeconds), true)
    }
    return (timestamp, false)
  }

  /// Computes the persisted sort date for an incoming message based on its delivery context.
  ///
  /// Live messages sort by receive time so a just-arrived message stays at the bottom of the
  /// transcript. Backlog messages drained during sync sort by the drain `anchor`, so a whole
  /// batch lands as one contiguous block at delivery time — recent, never buried — ordered
  /// within the block by the secondary `timestamp` fetch key. The sort key no longer reads
  /// sender time, so a skewed sender clock cannot scatter backlog into deep scrollback;
  /// `correctTimestampIfNeeded` still governs the persisted `Message.timestamp` used for
  /// dedup, display, and within-block ordering.
  ///
  /// - Parameters:
  ///   - context: Whether the message arrived live or via a backlog drain (carrying the anchor).
  ///   - receiveTime: When a live message was received. Ignored for `initialSync`.
  /// - Returns: The date to persist as the message's sort key.
  nonisolated static func sortDate(
    for context: DeliveryContext,
    receiveTime: Date
  ) -> Date {
    switch context {
    case .live:
      receiveTime
    case let .initialSync(anchor):
      anchor
    case let .history(storedAt):
      storedAt
    }
  }
}
