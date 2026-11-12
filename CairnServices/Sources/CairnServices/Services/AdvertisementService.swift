import Foundation
import MeshCore
import os

// MARK: - Advertisement Errors

public enum AdvertisementError: Error, Sendable {
  case notConnected
  case sendFailed
  case invalidResponse
  case sessionError(MeshCoreError)
}

extension AdvertisementError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected to device."
    case .sendFailed: "Failed to send advertisement."
    case .invalidResponse: "Invalid response from device."
    case let .sessionError(e): e.localizedDescription
    }
  }
}

// MARK: - Advert Contact Sync Outcome

/// Result of one advert-driven contact delta exchange.
///
/// `busy` is not `failed`: a collision with another sync never reaches the
/// radio, so it must not spend the failure budget that drops drained keys.
/// `notReady` is permanent until a full contact fetch succeeds: neither requeue
/// nor spend the failure budget.
public enum AdvertContactSyncOutcome: Sendable {
  case synced
  case busy
  case failed
  case notReady
}

// MARK: - Advertisement Service

/// Service for managing device advertisements and discovery.
/// Handles sending self-advertisements and processing incoming adverts via MeshCore events.
public actor AdvertisementService {
  // MARK: - Properties

  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "Advertisement")

  /// End-to-end Discover trace (Logger category `discover-trace`).
  let discoverTrace = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "discover-trace")

  let session: any AdvertisingSessionOps & SessionEventStreaming
  let dataStore: any PersistenceStoreProtocol

  /// Shared with ``ContactService``: the path-discovery write reads the radio's record and
  /// writes it back, so it must not interleave with a flag change for the same contact.
  let recordWriteLock: ContactRecordWriteLock

  private var eventMonitorTask: Task<Void, Never>?
  /// In-flight `flushPendingDeletedKeys`. Callers wait through
  /// `.contactDeletedCleanup`, not only `deleteContacts`.
  private var deletionFlushTask: Task<Void, Never>?
  /// The wait before a foreground 0x8F burst is flushed as one batch (`scheduleDeletionFlush`).
  private var deletionBatchTask: Task<Void, Never>?
  var currentRadioID: UUID?

  /// When true, advert delta sync is deferred (full or manual contact sync).
  /// Manual pull-to-refresh also sets this; it is invisible to `SyncCoordinator.isSyncInProgress`.
  var isSyncingContacts = false

  /// 0x80 keys heard since the last delta sync.
  var pendingAdvertKeys: Set<Data> = []

  /// Phone receive times for pending 0x80 keys, keyed by public key.
  /// Stamped onto `lastHeardTimestamp` after a delta insert (or materialize)
  /// so a stale radio RTC cannot prune a contact just heard on air.
  private var pendingAdvertReceiveTimes: [Data: Date] = [:]

  /// 0x81 path-update keys waiting for the next delta sync. Tracked apart from
  /// `pendingAdvertKeys` because a path key must not create a Discover row.
  /// Keys (not a bool) so a successful incremental round can verify delivery
  /// when radio `lastmod` falls at or below the stored watermark.
  var pendingPathKeys: Set<Data> = []

  /// True when any 0x81 path key is waiting for delta sync.
  var pathSyncPending: Bool {
    !pendingPathKeys.isEmpty
  }

  /// Keys the radio deleted (0x8F) since this round drained its keys. Rolled back so
  /// a batch cannot re-save a dropped row, and skipped while reconciling. Cleared
  /// when the next round drains, so a between-round delete never undoes a later
  /// re-created contact.
  var contactsDeletedDuringSync: Set<Data> = []

  /// Drain-surviving 0x8F queue. Not `contactsDeletedDuringSync` (that is still
  /// round-scoped and cleared at drain). Flushed on foreground or `stopEventMonitoring`.
  var pendingDeletedKeys: Set<Data> = []

  /// Keys revived while `flushPendingDeletedKeys` is off-actor in `deleteContacts`.
  /// Read per key so a same-key 0x80 during that hop cannot cascade-delete the row.
  private let revivedDuringDeleteFlush = OSAllocatedUnfairLock(initialState: Set<Data>())

  var deltaSyncTask: Task<Void, Never>?
  /// Monotonic identity for the scheduled delta-sync round. `finishRound` clears
  /// `deltaSyncTask` only while this still matches the running round.
  var deltaSyncGeneration: UInt64 = 0
  var lastDeltaSyncEnd: ContinuousClock.Instant?
  var deltaSyncHandler: (@Sendable (_ fullRefetch: Bool) async -> AdvertContactSyncOutcome)?
  /// The sync coordinator's return-to-foreground catch-up (message drain, skipped channel sync),
  /// started by `handleReturnToForeground`. Installed per connection; cleared on stop.
  var foregroundCatchUpHandler: (@Sendable () async -> Void)?
  /// One-shot: the next delta sync runs as a prune-free full fetch.
  var escalateToFullRefetch = false
  /// One-shot: the next delta sync runs even with no keys pending (`requestResync`).
  var resyncRequested = false

  /// Unknown 0x80 keys whose radio record is being read so the node lands at once.
  private var newContactReadsInFlight: Set<Data> = []
  /// Keys already announced as new when their row was saved ahead of the delta round
  /// (`saveContactFromRadio`). The round skips them so a node is announced once.
  var newContactsAnnouncedEarly: Set<Data> = []

  /// Delta syncs that failed back to back without an intervening success.
  var consecutiveDeltaSyncFailures = 0

  /// Failed delta syncs tolerated before a round drops its drained keys. Without a
  /// cap, a handler that never succeeds repeats a full contact exchange forever.
  static let maxConsecutiveDeltaSyncFailures = 5

  let advertSyncDebounce: Duration
  let advertSyncMinInterval: Duration
  /// Backoff before re-arming after a `.busy` outcome. Shorter than
  /// `advertSyncMinInterval` so claim collisions poll cheaply without spinning.
  let advertSyncBusyBackoff: Duration
  /// How long a foreground 0x8F waits for others before its batch is flushed: the radio's own
  /// Select → Remove (and an overwrite run) sends one per contact, quickly, and a batch is one store
  /// write and one list refresh instead of one per contact.
  let deleteBatchWindow: Duration
  let appStateProvider: AppStateProvider?

  /// Last overwrite-oldest deletion, used to correlate the replacement advert (0x8F then new contact).
  private var lastOverwriteDeletion: (name: String, pubKeyHex: String, time: Date)?

  /// Adverts of stored contacts heard in the RX log (0x88) that wait for their 0x80 push.
  private var advertRecovery = AdvertPushRecovery()
  /// Each pending check's grace timer, keyed by public key.
  private(set) var advertRecoveryTasks: [Data: Task<Void, Never>] = [:]
  /// Waits out a check's grace; tests inject one they release by hand.
  private let advertRecoverySleep: @Sendable (Duration) async throws -> Void
  /// 0x80 pushes recovered from an advert's RX log copy on this connection, for diagnostics.
  private(set) var recoveredAdvertPushes = 0

  /// Multicast broadcaster for advertisement and discovery events.
  /// Producers yield synchronously; consumers subscribe via `events()`.
  nonisolated let eventBroadcaster = EventBroadcaster<AdvertisementEvent>()

  // MARK: - Initialization

  public init(
    session: any AdvertisingSessionOps & SessionEventStreaming,
    dataStore: any PersistenceStoreProtocol,
    advertSyncDebounce: Duration = .seconds(5),
    advertSyncMinInterval: Duration = .seconds(30),
    advertSyncBusyBackoff: Duration = .seconds(5),
    deleteBatchWindow: Duration = .milliseconds(250),
    appStateProvider: AppStateProvider? = nil,
    recordWriteLock: ContactRecordWriteLock = ContactRecordWriteLock(),
    advertRecoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.session = session
    self.dataStore = dataStore
    self.recordWriteLock = recordWriteLock
    self.advertSyncDebounce = advertSyncDebounce
    self.deleteBatchWindow = deleteBatchWindow
    self.advertSyncMinInterval = advertSyncMinInterval
    self.advertSyncBusyBackoff = advertSyncBusyBackoff
    self.appStateProvider = appStateProvider
    self.advertRecoverySleep = advertRecoverySleep
  }

  func isInForeground() async -> Bool {
    guard let appStateProvider else { return true }
    return await appStateProvider.isInForeground
  }

  func isRadioDeleted(_ key: Data) -> Bool {
    contactsDeletedDuringSync.contains(key) || pendingDeletedKeys.contains(key)
  }

  /// Cancels outstanding tasks only. Full teardown is ``stopEventMonitoring``
  /// (`ServiceContainer.tearDown`); deinit cannot safely clear the handler.
  deinit {
    eventMonitorTask?.cancel()
    deltaSyncTask?.cancel()
    for task in advertRecoveryTasks.values {
      task.cancel()
    }
  }

  // MARK: - Events

  /// Returns a fresh stream of advertisement and discovery events.
  /// Registration is synchronous, so events yielded after this call are
  /// never dropped. Consumers must re-subscribe per connection because the
  /// owning `ServiceContainer` is rebuilt on every connection.
  public nonisolated func events() -> AsyncStream<AdvertisementEvent> {
    eventBroadcaster.subscribe()
  }

  /// Ends every `events()` subscriber's for-await loop. Called by
  /// `ServiceContainer.tearDown()` so consumer tasks release the service
  /// references they hold.
  nonisolated func finishEvents() {
    eventBroadcaster.finish()
  }

  // MARK: - Event Monitoring

  /// Start monitoring MeshCore events for advertisement-related notifications
  public func startEventMonitoring(radioID: UUID) {
    eventMonitorTask?.cancel()
    resetAdvertRecovery()
    currentRadioID = radioID

    eventMonitorTask = Task { [weak self] in
      guard let self else { return }
      let filter = EventFilter { event in
        switch event {
        case .advertisement, .newContact, .pathUpdate, .pathResponse,
             .traceData, .contactDeleted, .contactsFull:
          true
        case let .rxLogData(log) where log.payloadType == .trace || log.payloadType == .advert:
          true
        default:
          false
        }
      }
      let events = await session.events(filter: filter)

      for await event in events {
        await handleEvent(event, radioID: radioID)
        if Task.isCancelled { break }
      }
    }
  }

  /// Stops event monitoring and clears advert delta-sync state.
  public func stopEventMonitoring() async {
    let monitor = eventMonitorTask
    eventMonitorTask = nil
    monitor?.cancel()
    // Drop the handler and bump deltaSyncGeneration before any await so the
    // in-flight round cannot reconcile or re-arm.
    deltaSyncHandler = nil
    foregroundCatchUpHandler = nil
    deltaSyncTask?.cancel()
    deltaSyncGeneration &+= 1
    deletionBatchTask?.cancel()   // the flush below takes what it was waiting for
    deletionBatchTask = nil
    resetAdvertRecovery()
    // Await `flushPendingDeletedKeys` before clearing `currentRadioID` so a queued
    // 0x8F cannot outlive `stopEventMonitoring`.
    await monitor?.value
    await flushPendingDeletedKeys()
    let receiveTimes = pendingAdvertReceiveTimes
    await stampAdvertReceiveTimes(receiveTimes, radioID: currentRadioID)
    currentRadioID = nil
    deltaSyncTask = nil
    pendingAdvertKeys.removeAll()
    pendingPathKeys.removeAll()
    pendingAdvertReceiveTimes.removeAll()
    newContactsAnnouncedEarly.removeAll()
    escalateToFullRefetch = false
    resyncRequested = false
    consecutiveDeltaSyncFailures = 0
    isSyncingContacts = false
    // Keep `contactsDeletedDuringSync` across teardown so a commit still in flight
    // can roll back rows the radio deleted; the next round clears it when it drains.
  }

  /// Flushes queued 0x8F deletes, then re-arms when `hasPendingDeltaSyncWork`.
  /// Does not re-read `isInForeground`; `AppState.handleReturnToForeground` already ran.
  public func handleReturnToForeground() async {
    // Unawaited: a channel sync takes seconds and must not hold up the rest of the
    // foreground path. It claims the coordinator's sync slot, so it never overlaps a resync.
    if let foregroundCatchUpHandler {
      Task { await foregroundCatchUpHandler() }
    }
    await flushPendingDeletedKeys()
    if hasPendingDeltaSyncWork {
      scheduleDeltaSync()
    }
  }

  /// Installs the sync coordinator's return-to-foreground catch-up (see `handleReturnToForeground`).
  func setForegroundCatchUpHandler(_ handler: (@Sendable () async -> Void)?) {
    foregroundCatchUpHandler = handler
  }

  func flushPendingDeletedKeys() async {
    if let deletionFlushTask {
      await deletionFlushTask.value
      return
    }
    guard !pendingDeletedKeys.isEmpty, let radioID = currentRadioID else { return }

    // Await this Task through `.contactDeletedCleanup` and the catch requeue, which
    // run after `deleteContacts`. A store error ends this flush.
    let task = Task {
      defer {
        revivedDuringDeleteFlush.withLock { $0.removeAll() }
        deletionFlushTask = nil
      }
      while !pendingDeletedKeys.isEmpty {
        let keys = pendingDeletedKeys
        pendingDeletedKeys.removeAll()
        do {
          let deletedIDs = try await dataStore.deleteContacts(
            radioID: radioID,
            publicKeys: keys,
            skippingPublicKeys: { revivedDuringDeleteFlush.withLock { $0 } }
          )
          guard !deletedIDs.isEmpty else { continue }
          logger.notice("Overwrite oldest: applying \(deletedIDs.count) deferred deletion(s)")
          eventBroadcaster.yield(.contactDeletedCleanup(contactIDs: deletedIDs))
          eventBroadcaster.yield(.nodeStorageFullChanged(isFull: false))
          eventBroadcaster.yield(.contactUpdated)
        } catch {
          pendingDeletedKeys.formUnion(keys)
          pendingDeletedKeys.subtract(pendingAdvertKeys)
          logger.error(
            "Overwrite oldest: deferred delete flush failed: \(error.localizedDescription)"
          )
          return
        }
      }
    }
    deletionFlushTask = task
    await task.value
  }

  /// Records a 0x80 key for the next delta sync.
  ///
  /// A re-advert for a key in `contactsDeletedDuringSync` or `pendingDeletedKeys`
  /// means the radio re-added it after 0x8F. Clear both so later paths treat it as live.
  ///
  /// `receivedAt` is the phone clock at the 0x80. It is applied to
  /// `lastHeardTimestamp` once a Contact row exists so prune recency is not
  /// hostage to a stale radio RTC. A re-record keeps the newest time it has seen,
  /// and nil (a requeued key with no recorded time) adds none: only an air time
  /// may move a heard time forward.
  func recordPendingAdvertKey(_ key: Data, receivedAt: Date? = Date()) {
    pendingAdvertKeys.insert(key)
    contactsDeletedDuringSync.remove(key)
    pendingDeletedKeys.remove(key)
    revivedDuringDeleteFlush.withLock { $0.formUnion([key]) }
    if let receivedAt {
      pendingAdvertReceiveTimes[key] = max(pendingAdvertReceiveTimes[key] ?? receivedAt, receivedAt)
    }
  }

  /// Captures and removes phone receive times for keys about to drain.
  func takeAdvertReceiveTimes(for keys: Set<Data>) -> [Data: Date] {
    var times: [Data: Date] = [:]
    times.reserveCapacity(keys.count)
    for key in keys {
      if let receivedAt = pendingAdvertReceiveTimes.removeValue(forKey: key) {
        times[key] = receivedAt
      }
    }
    return times
  }

  /// Stamps `lastHeardTimestamp` for drained 0x80 keys that now have a Contact
  /// row, using each key's recorded phone receive time. Uses
  /// `touchContactHeard` so clamping matches the live 0x80 path; it also creates
  /// or refreshes each key's Discover row from the synced radio fields while
  /// keeping that row's heard time the air time.
  func stampAdvertReceiveTimes(_ receiveTimes: [Data: Date], radioID: UUID?) async {
    guard let radioID, !receiveTimes.isEmpty else { return }
    for (publicKey, receivedAt) in receiveTimes {
      guard !isRadioDeleted(publicKey) else { continue }
      do {
        _ = try await dataStore.touchContactHeard(
          radioID: radioID, publicKey: publicKey, at: receivedAt
        )
      } catch {
        let pubKeyHex = publicKey.uppercaseHexString()
        logger.error(
          "Post-delta lastHeard stamp failed for \(pubKeyHex): \(error.localizedDescription)"
        )
      }
    }
  }

  /// True when a delta sync still has work: pending 0x80 keys, a path update,
  /// an owed prune-free full refetch or a requested resync. Re-arm sites and the
  /// empty-round guard share this definition so a future flag cannot desynchronise them.
  var hasPendingDeltaSyncWork: Bool {
    !pendingAdvertKeys.isEmpty || pathSyncPending || escalateToFullRefetch || resyncRequested
  }

  /// Runs one delta round although no advert key is pending, for when adverts may
  /// have been lost before reaching the app (the radio reported refused 0x80/0x8A
  /// pushes). The incremental contact fetch returns every contact the radio changed
  /// since the watermark, so the lost keys need not be known. Coalesces with a round
  /// already scheduled; a backgrounded app runs it on return to the foreground.
  public func requestResync() {
    resyncRequested = true
    scheduleDeltaSync()
  }

  /// Creates a local `Contact` from a pending 0x80 key so a DM that arrives
  /// inside the advert delta-sync debounce window can notify and list normally.
  ///
  /// Matches `prefix` against `pendingAdvertKeys` only (keys the radio already
  /// auto-added). Exactly one match is required; ambiguous prefixes return nil.
  /// The key stays pending so the debounced delta round still adopts orphan DMs
  /// and refreshes the row; the node is announced here when this inserts it.
  ///
  /// - Returns: The persisted contact, or nil when no unique pending key matches
  ///   or the radio fetch / save fails.
  public func materializeContactForPendingAdvert(
    matchingPrefix prefix: Data,
    radioID: UUID
  ) async -> ContactDTO? {
    guard !prefix.isEmpty else { return nil }

    let matches = pendingAdvertKeys.filter { $0.starts(with: prefix) }
    guard matches.count == 1, let publicKey = matches.first else { return nil }

    let pubKeyHex = publicKey.uppercaseHexString()
    do {
      guard let meshContact = try await session.getContact(publicKey: publicKey) else {
        logger.info("materialize pending advert: getContact nil key=\(pubKeyHex)")
        return nil
      }
      let receivedAt = pendingAdvertReceiveTimes[publicKey] ?? Date()
      guard let contactID = try await saveContactFromRadio(
        meshContact, radioID: radioID, receivedAt: receivedAt
      ) else { return nil }
      return try await dataStore.fetchContact(id: contactID)
    } catch {
      logger.error(
        "materialize pending advert failed key=\(pubKeyHex): \(error.localizedDescription)"
      )
      return nil
    }
  }

  /// Saves a record read from the radio, so a node the radio auto-added is listed
  /// without waiting for the delta round. Stamps the air time, which also creates the
  /// Discover row with that heard time, then yields `.contactUpdated`, and
  /// `.newContactDiscovered` when this inserted the row.
  ///
  /// - Returns: The contact id, or nil when the radio deleted the contact (0x8F)
  ///   during the save; the row is removed again.
  private func saveContactFromRadio(
    _ meshContact: MeshContact,
    radioID: UUID,
    receivedAt: Date
  ) async throws -> UUID? {
    let frame = meshContact.toContactFrame()
    let publicKey = frame.publicKey
    let pubKeyHex = publicKey.uppercaseHexString()
    let saveResult = try await dataStore.saveContact(radioID: radioID, from: frame)
    // A 0x8F handled during the save found no row to delete; undo the save.
    if isRadioDeleted(publicKey) {
      if saveResult.isNew {
        try await dataStore.deleteContactIfUnreferenced(id: saveResult.id)
      }
      return nil
    }
    // Stamp phone recency before the row is read so an insert ahead of the round
    // is not prune-eligible under a stale radio lastModified.
    do {
      _ = try await dataStore.touchContactHeard(
        radioID: radioID, publicKey: publicKey, at: receivedAt
      )
    } catch {
      logger.error(
        "Contact insert from radio lastHeard stamp failed key=\(pubKeyHex): \(error.localizedDescription)"
      )
    }
    eventBroadcaster.yield(.contactUpdated)
    if saveResult.isNew {
      // The round's pre-round snapshot may predate this insert; it skips this key.
      newContactsAnnouncedEarly.insert(publicKey)
      eventBroadcaster.yield(.newContactDiscovered(
        name: frame.name,
        contactID: saveResult.id,
        contactType: frame.type
      ))
      logOverwriteReplacementIfRecent(newContactName: frame.name, newContactType: frame.type)
    }
    return saveResult.id
  }

  /// Saves a node the radio auto-added (0x80 for a key with no local row) at once,
  /// instead of after the debounced delta round, so Home and the node lists show
  /// it as soon as it is heard. Runs off the event loop: the radio read must not
  /// hold up later events. Skipped until contact sync is wired for this connection
  /// and while a full contact sync runs, which brings the node itself. The key
  /// stays pending, so the round still runs as before.
  private func startEarlyContactInsert(publicKey: Data, radioID: UUID, receivedAt: Date) {
    guard deltaSyncHandler != nil, !isSyncingContacts else { return }
    guard newContactReadsInFlight.insert(publicKey).inserted else { return }
    Task { [weak self] in
      await self?.insertContactEarly(publicKey: publicKey, radioID: radioID, receivedAt: receivedAt)
    }
  }

  private func insertContactEarly(publicKey: Data, radioID: UUID, receivedAt: Date) async {
    defer { newContactReadsInFlight.remove(publicKey) }
    let pubKeyHex = publicKey.uppercaseHexString()
    // The connection may have moved on, or the radio deleted the key (0x8F), meanwhile.
    guard currentRadioID == radioID, !isRadioDeleted(publicKey) else { return }
    do {
      guard try await dataStore.fetchContact(radioID: radioID, publicKey: publicKey) == nil else { return }
      guard let meshContact = try await session.getContact(publicKey: publicKey) else {
        discoverTrace.debug("B2 0x80 early insert: radio has no contact key=\(pubKeyHex)")
        return
      }
      guard currentRadioID == radioID, !isRadioDeleted(publicKey) else { return }
      _ = try await saveContactFromRadio(meshContact, radioID: radioID, receivedAt: receivedAt)
      discoverTrace.debug("B2 0x80 early insert key=\(pubKeyHex)")
    } catch {
      logger.error("Early contact insert failed key=\(pubKeyHex): \(error.localizedDescription)")
    }
  }

  /// Installs the contact delta-sync handler used after debounced 0x80/0x81 events.
  /// A non-nil handler re-arms when work is already pending (adverts, path updates,
  /// or an owed full refetch that arrived before wiring).
  public func setDeltaSyncHandler(
    _ handler: (@Sendable (_ fullRefetch: Bool) async -> AdvertContactSyncOutcome)?
  ) {
    deltaSyncHandler = handler
    if handler != nil, hasPendingDeltaSyncWork {
      scheduleDeltaSync()
    }
  }

  /// Toggle deferred contact sync during a full or manual contact sync.
  /// When set to `false` with pending work, re-arms so a mid-sync debounce does
  /// not drop keys, path updates, or an owed full refetch.
  public func setSyncingContacts(_ isSyncing: Bool) async {
    isSyncingContacts = isSyncing
    if !isSyncing, hasPendingDeltaSyncWork, await isInForeground() {
      scheduleDeltaSync()
    }
  }

  /// Handle incoming MeshCore event
  private func handleEvent(_ event: MeshEvent, radioID: UUID) async {
    switch event {
    case let .advertisement(publicKey):
      await handleAdvertEvent(publicKey: publicKey, radioID: radioID)

    case let .newContact(contact):
      await handleNewAdvertEvent(contact: contact, radioID: radioID)

    case let .pathUpdate(publicKey):
      await handlePathUpdatedEvent(publicKey: publicKey, radioID: radioID)

    case let .pathResponse(result):
      await handlePathDiscoveryResponse(result: result, radioID: radioID)

    case let .traceData(traceInfo):
      await handleTraceData(traceInfo: traceInfo, radioID: radioID)

    case let .rxLogData(logData) where logData.payloadType == .trace:
      if logData.packetPayload.count >= 4, let snr = logData.snr {
        let tag = logData.packetPayload.readUInt32LE(at: 0)
        let remoteSnr: Double? = logData.pathNodes.last.map {
          Double(Int8(bitPattern: $0)) / 4.0
        }
        eventBroadcaster.yield(.traceSnrObserved(tag: tag, localSnr: snr, remoteSnr: remoteSnr, radioID: radioID))
      }
      // Each hop appends its SNR before passing a trace on, so a copy carrying k of them was
      // sent by the k-th hop: the trace got that far.
      if logData.packetPayload.count >= 4 {
        let tag = logData.packetPayload.readUInt32LE(at: 0)
        eventBroadcaster.yield(.traceProgress(tag: tag, hopsReached: logData.pathNodes.count, radioID: radioID))
      }

    case let .rxLogData(logData) where logData.payloadType == .advert:
      await handleRxLogAdvert(logData, radioID: radioID)

    case let .contactDeleted(publicKey):
      await handleContactDeletedEvent(publicKey: publicKey, radioID: radioID)

    case .contactsFull:
      await handleContactsFullEvent()

    default:
      break
    }
  }

  // MARK: - Send Advertisement

  /// Send self advertisement to the mesh network
  /// - Parameter flood: If true, sends flood advertisement (reaches all nodes).
  ///                   If false, sends zero-hop advertisement (direct only).
  public func sendSelfAdvertisement(flood: Bool) async throws {
    do {
      try await session.sendAdvertisement(flood: flood)
    } catch let error as MeshCoreError {
      throw AdvertisementError.sessionError(error)
    }
  }

  // MARK: - Update Node Name

  /// Set the node's advertised name
  /// - Parameter name: The name to advertise (max 31 characters)
  public func setAdvertName(_ name: String) async throws {
    do {
      try await session.setName(name)
    } catch let error as MeshCoreError {
      throw AdvertisementError.sessionError(error)
    }
  }

  // MARK: - Update Location

  /// Set the node's advertised GPS coordinates
  /// - Parameters:
  ///   - latitude: Latitude in degrees (-90 to 90)
  ///   - longitude: Longitude in degrees (-180 to 180)
  public func setAdvertLocation(latitude: Double, longitude: Double) async throws {
    do {
      try await session.setCoordinates(latitude: latitude, longitude: longitude)
    } catch let error as MeshCoreError {
      throw AdvertisementError.sessionError(error)
    }
  }

  // MARK: - Private Event Handlers

  /// 0x80 change notification: the radio already updated a contact row.
  private func handleAdvertEvent(publicKey: Data, radioID: UUID) async {
    let pubKeyHex = publicKey.uppercaseHexString()
    switch advertRecovery.notePush(key: publicKey, now: Date()) {
    case .answeredCheck:
      advertRecoveryTasks.removeValue(forKey: publicKey)?.cancel()
    case .duplicateOfRecovery:
      // Announced and stamped heard already from the advert's RX log copy, so not again. But a
      // user-set rx_delay_base delays the radio's own handling of a flood advert (and so this
      // push) by up to 32 s, and a round run since the recovery may have read the contact
      // before the radio updated it: read the radio's record once more. No heard time: the
      // copy's arrival was the air time.
      logger.info("Late 0x80 for \(pubKeyHex) after its advert was recovered from the RX log; reading the radio's record again")
      recordPendingAdvertKey(publicKey, receivedAt: nil)
      if await isInForeground() {
        scheduleDeltaSync()
      }
      return
    case .unrelated:
      break
    }
    logger.debug("Advert event for \(pubKeyHex)")
    discoverTrace.debug("B1 0x80 ADVERT received key=\(pubKeyHex)")
    // One phone clock for touch and pending receive-time so the post-delta
    // stamp matches the air-hear moment (not a later debounce fire).
    await applyAdvertPush(publicKey: publicKey, radioID: radioID, receivedAt: Date())
  }

  /// What a 0x80 does, for a real push or one recovered from the advert's RX log copy:
  /// announces the advert, stamps the contact heard at `receivedAt` and records the key for
  /// the delta round, which reads the radio's updated record.
  private func applyAdvertPush(publicKey: Data, radioID: UUID, receivedAt: Date) async {
    let pubKeyHex = publicKey.uppercaseHexString()
    eventBroadcaster.yield(.advertReceived(publicKey: publicKey))

    // Visible to an in-flight `deleteContacts` on PersistenceStore. Do not
    // `pendingDeletedKeys.remove` here: a failed touch must not drop a queued 0x8F.
    revivedDuringDeleteFlush.withLock { $0.formUnion([publicKey]) }
    let inForeground = await isInForeground()

    if !inForeground {
      recordPendingAdvertKey(publicKey, receivedAt: receivedAt)
      return
    }

    // Retry touch once: a transient store error must not permanently drop the
    // advert under the empty-round guard. Recording without a successful touch
    // is also wrong (it can announce a long-known contact as new).
    var known: Bool?
    do {
      known = try await dataStore.touchContactHeard(
        radioID: radioID, publicKey: publicKey, at: receivedAt
      )
    } catch {
      logger.error("Error handling advert event (retrying once): \(error.localizedDescription)")
      do {
        known = try await dataStore.touchContactHeard(
          radioID: radioID, publicKey: publicKey, at: receivedAt
        )
      } catch {
        logger.error("Advert touch retry failed: \(error.localizedDescription)")
        known = nil
      }
    }

    if let known {
      if known {
        eventBroadcaster.yield(.contactUpdated)
      } else {
        discoverTrace.debug("B2 0x80 no local contact key=\(pubKeyHex) syncing=\(isSyncingContacts)")
        logger.debug("ADVERT received for unknown contact - saving it now and scheduling delta sync")
      }
      recordPendingAdvertKey(publicKey, receivedAt: receivedAt)
      if !known {
        startEarlyContactInsert(publicKey: publicKey, radioID: radioID, receivedAt: receivedAt)
      }
    }

    // Schedule so other pending keys or a path update still run; the empty-round
    // guard no-ops when this advert alone failed both touch attempts.
    scheduleDeltaSync()
  }

  /// Handle new advertisement event - New contact discovered (manual add mode)
  private func handleNewAdvertEvent(contact: MeshContact, radioID: UUID) async {
    let contactFrame = contact.toContactFrame()
    let pubKeyHex = contactFrame.publicKey.uppercaseHexString()
    discoverTrace.debug("B1 0x8A NEW_ADVERT received key=\(pubKeyHex)")
    // The radio answered the advert copy's check itself (it no longer holds the contact)
    if advertRecovery.answerCheck(key: contactFrame.publicKey) {
      advertRecoveryTasks.removeValue(forKey: contactFrame.publicKey)?.cancel()
    }
    eventBroadcaster.yield(.advertReceived(publicKey: contactFrame.publicKey))

    do {
      let (node, isNew) = try await dataStore.upsertDiscoveredNode(radioID: radioID, from: contactFrame)
      discoverTrace.debug("B2 0x8A upsert key=\(pubKeyHex) isNew=\(isNew)")

      eventBroadcaster.yield(.contactUpdated)

      // Notify only first-time discoveries, not repeat adverts for the same contact.
      if isNew {
        let contactName = node.name
        let contactType = node.nodeType
        eventBroadcaster.yield(.newContactDiscovered(name: contactName, contactID: node.id, contactType: contactType))
        logOverwriteReplacementIfRecent(newContactName: contactName, newContactType: contactType)
      }
    } catch {
      logger.error("Error handling new advert event: \(error.localizedDescription)")
      discoverTrace.error("B2 0x8A upsert FAILED key=\(pubKeyHex): \(error.localizedDescription)")
    }
  }

  // MARK: - Advert Push Recovery

  /// An advert's RX log copy (0x88): when it is one the radio answers with a 0x80, waits for that
  /// push and handles the advert from the copy if the push was lost (``AdvertPushRecovery``).
  /// Runs on every firmware; a copy the radio sent again later (RX_SYNC backfill) is not live, so
  /// its 0x80 was never due now.
  private func handleRxLogAdvert(_ packet: ParsedRxLogData, radioID: UUID) async {
    let receivedAt = Date()
    guard !packet.isBackfill,
          let advert = AdvertPushRecovery.SignedAdvert(payload: packet.packetPayload),
          advert.hasName,
          advertRecovery.needsCheck(key: advert.publicKey, timestamp: advert.timestamp, now: receivedAt) else { return }
    let storedTimestamp: UInt32
    do {
      // The radio pushes a 0x80 only for a node it holds as a contact
      guard let contact = try await dataStore.fetchContact(radioID: radioID, publicKey: advert.publicKey),
            advert.timestamp > contact.lastAdvertTimestamp else { return }
      storedTimestamp = contact.lastAdvertTimestamp
      // The radio drops its own advert unanswered
      guard try await dataStore.fetchDevice(radioID: radioID)?.publicKey != advert.publicKey else { return }
    } catch {
      return
    }
    guard advert.isSignatureValid, currentRadioID == radioID,
          advertRecovery.beginCheck(
            key: advert.publicKey, timestamp: advert.timestamp, storedTimestamp: storedTimestamp, now: receivedAt
          )
    else { return }

    let publicKey = advert.publicKey
    let sleep = advertRecoverySleep
    advertRecoveryTasks[publicKey] = Task { [weak self] in
      guard (try? await sleep(AdvertPushRecovery.grace)) != nil, !Task.isCancelled else { return }
      await self?.advertRecoveryGraceEnded(publicKey: publicKey, radioID: radioID, receivedAt: receivedAt)
    }
  }

  /// A check's grace ended without a 0x80: the radio updated the contact but its push was lost,
  /// so the advert is handled from its copy, at the time the copy arrived.
  private func advertRecoveryGraceEnded(publicKey: Data, radioID: UUID, receivedAt: Date) async {
    advertRecoveryTasks[publicKey] = nil
    guard currentRadioID == radioID, advertRecovery.graceEnded(key: publicKey, now: Date()) else { return }
    recoveredAdvertPushes += 1
    logger.notice(
      "0x80 for \(publicKey.uppercaseHexString()) never arrived; handling the advert from its RX log copy"
    )
    discoverTrace.debug("B1 0x80 ADVERT recovered from 0x88 key=\(publicKey.uppercaseHexString())")
    await applyAdvertPush(publicKey: publicKey, radioID: radioID, receivedAt: receivedAt)
  }

  /// Forgets every advert check, for a new or ended connection.
  private func resetAdvertRecovery() {
    for task in advertRecoveryTasks.values {
      task.cancel()
    }
    advertRecoveryTasks.removeAll()
    advertRecovery = AdvertPushRecovery()
    recoveredAdvertPushes = 0
  }

  /// Path changed on the radio: record the key and schedule contact delta sync.
  /// Path keys must not create Discover rows; path changes are not on-air heard evidence.
  /// Delivery is via watermark-filtered GET_CONTACTS; if radio `lastmod` is at or
  /// below the stored watermark the incremental round returns nothing and the
  /// post-round path check escalates once to a prune-free full refetch.
  private func handlePathUpdatedEvent(publicKey: Data, radioID: UUID) async {
    let pubKeyHex = publicKey.uppercaseHexString()
    logger.debug("Path updated event for \(pubKeyHex)")
    pendingPathKeys.insert(publicKey)
    // A path discovery in progress counts this as its answer: a reply to an earlier send
    // is stored by the radio itself and arrives only as this push.
    eventBroadcaster.yield(.contactPathUpdated(publicKey: publicKey))
    if await isInForeground() {
      scheduleDeltaSync()
    }
  }

  /// Path discovery response: write the out-path to the radio, mirror it locally and stamp
  /// phone-clock lastHeard. Leaves radio lastModified unchanged — it is a radio watermark,
  /// not phone time.
  private func handlePathDiscoveryResponse(result: PathInfo, radioID: UUID) async {
    // Chunk debug output using the hash size each direction declares on
    // the wire so mode-skew between firmware and the cached device record
    // can't smear hop boundaries in the log.
    let outHashSize = decodePathLen(result.outPathLength)?.hashSize ?? 1
    let inHashSize = decodePathLen(result.inPathLength)?.hashSize ?? 1
    let outHops = stride(from: 0, to: result.outPath.count, by: outHashSize).map { start in
      result.outPath[start..<min(start + outHashSize, result.outPath.count)].uppercaseHexString()
    }
    let inHops = stride(from: 0, to: result.inPath.count, by: inHashSize).map { start in
      result.inPath[start..<min(start + inHashSize, result.inPath.count)].uppercaseHexString()
    }
    let pubKeyHex = result.publicKeyPrefix.prefix(3).uppercaseHexString()
    let outDisplay = outHops.isEmpty ? "direct" : outHops.joined(separator: " → ")
    let inDisplay = inHops.isEmpty ? "direct" : inHops.joined(separator: " → ")
    logger.info("Path discovery for \(pubKeyHex)... - Out: \(outHops.count) hops (\(outDisplay)), In: \(inHops.count) hops (\(inDisplay))")

    do {
      if let contact = try await dataStore.fetchContact(radioID: radioID, publicKeyPrefix: result.publicKeyPrefix) {
        // The firmware hands a matched discovery reply to the app and stores nothing, so the
        // radio keeps its old route unless the app writes this one. Mirror locally only what
        // the radio took, so a later contact refetch agrees with what the app shows.
        let routeWritten = try await recordWriteLock.withLock(contact.publicKey) {
          guard let frame = await self.discoveredPathFrame(contact: contact, result: result, pubKeyHex: pubKeyHex),
                await self.writeDiscoveredPath(frame, pubKeyHex: pubKeyHex) else { return false }
          _ = try await self.dataStore.saveContact(radioID: radioID, from: frame)
          return true
        }

        // The route mirror and the stamp change the stored contact and its Discover row;
        // observers reload node lists and Home on `.contactUpdated`.
        var changed = routeWritten
        do {
          changed = try await dataStore.touchContactHeard(
            radioID: radioID,
            publicKey: contact.publicKey,
            at: Date()
          ) || changed
        } catch {
          logger.error(
            "Path response lastHeard stamp failed: \(error.localizedDescription)"
          )
        }
        if changed {
          eventBroadcaster.yield(.contactUpdated)
        }
      }

      eventBroadcaster.yield(.pathDiscoveryResponse(result))
    } catch {
      logger.error("Error handling path discovery response: \(error.localizedDescription)")
    }
  }

  /// The record to write for a discovery reply: the stored contact with the discovered
  /// out-path and the flags the radio holds now. The stored copy's flags never go: they can
  /// be stale, and a remote-commands bit (0x10) or telemetry permission revoked on the device
  /// would be granted again. When the radio's record can't be read, or the radio no longer has
  /// the contact (writing would add it back), nothing is written and this returns nil.
  private func discoveredPathFrame(contact: ContactDTO, result: PathInfo, pubKeyHex: String) async -> ContactFrame? {
    let onRadio: MeshContact?
    do {
      onRadio = try await session.getContact(publicKey: contact.publicKey)
    } catch {
      logger.warning("Path discovery for \(pubKeyHex)...: reading the contact from the radio failed, route not written: \(error.localizedDescription)")
      return nil
    }
    guard let onRadio else {
      logger.info("Path discovery for \(pubKeyHex)...: the radio no longer has this contact, route not written")
      return nil
    }
    // Prefer the response's self-describing length byte over the device's
    // cached hashSize — the wire encoding is authoritative for this path.
    return ContactFrame(
      publicKey: contact.publicKey,
      type: contact.type,
      typeRawValue: contact.typeRawValue,
      flags: onRadio.flags.rawValue,
      outPathLength: result.outPathLength,
      outPath: result.outPath,
      name: contact.name,
      lastAdvertTimestamp: contact.lastAdvertTimestamp,
      latitude: contact.latitude,
      longitude: contact.longitude,
      lastModified: contact.lastModified
    )
  }

  /// Writes a discovered out-path to the radio. A reserved or oversized length byte is
  /// refused here, as the firmware would read past the path it was given.
  private func writeDiscoveredPath(_ frame: ContactFrame, pubKeyHex: String) async -> Bool {
    guard let decoded = decodePathLen(frame.outPathLength),
          decoded.byteLength <= PathEncoding.maxPathBytes,
          frame.outPath.count >= decoded.byteLength else {
      logger.warning("Path discovery for \(pubKeyHex)...: invalid out-path length, not written to radio")
      return false
    }
    do {
      try await session.addContact(frame.toMeshContact())
      return true
    } catch {
      logger.error("Path discovery for \(pubKeyHex)...: writing the route to the radio failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Handle trace data response
  private func handleTraceData(traceInfo: TraceInfo, radioID: UUID) async {
    logger.info("Received trace data: tag=\(traceInfo.tag), hops=\(traceInfo.path.count)")
    eventBroadcaster.yield(.traceResponse(traceInfo: traceInfo, radioID: radioID))
  }

  /// Handle contact deleted event (0x8F) - device auto-deleted a contact via overwrite oldest
  private func handleContactDeletedEvent(publicKey: Data, radioID: UUID) async {
    let fullPubKeyHex = publicKey.uppercaseHexString()
    let pubKeyPrefix = publicKey.prefix(6).uppercaseHexString()

    // ZephCore CLI `set v.contact off` also pushes 0x8F for the V-key. That is
    // not overwrite-oldest (no slot freed). Keep the local V row and leave
    // storage-full bookkeeping unchanged.
    if let selfPublicKey = try? await dataStore.fetchDevice(radioID: radioID)?.publicKey,
       VContactIdentity.isVContact(publicKey: publicKey, selfPublicKey: selfPublicKey) {
      logger.info(
        "Contact deleted push for ZephCore V-contact (\(pubKeyPrefix)...); preserving local row, not clearing storage-full"
      )
      return
    }

    // Drop pending reconcile / path keys so a deleted contact is not re-notified
    // and a surviving path key cannot escalate to an epoch-0 full refetch.
    pendingAdvertKeys.remove(publicKey)
    pendingPathKeys.remove(publicKey)
    pendingAdvertReceiveTimes.removeValue(forKey: publicKey)
    newContactsAnnouncedEarly.remove(publicKey)
    // A running delta sync can re-save or reconcile this row after the radio dropped
    // it. A key recorded outside a round is discarded when the next round drains.
    contactsDeletedDuringSync.insert(publicKey)
    // Enqueue before `isInForeground` so a concurrent flush cannot miss this
    // key while the actor is suspended.
    revivedDuringDeleteFlush.withLock { _ = $0.remove(publicKey) }
    pendingDeletedKeys.insert(publicKey)

    if await !isInForeground() {
      return
    }

    // Foreground: logged now, deleted with the rest of its burst a moment later (scheduleDeletionFlush):
    // one store write and one list refresh per burst, not per contact.
    if let contact = try? await dataStore.fetchContact(radioID: radioID, publicKey: publicKey) {
      let contactName = contact.name.isEmpty ? "(unnamed)" : contact.name
      let contactTypeDesc = ContactType(rawValue: contact.typeRawValue).map { "\($0)" } ?? "unknown(\(contact.typeRawValue))"
      let lastModifiedDate = Date(timeIntervalSince1970: TimeInterval(contact.lastModified))
      let lastAdvertDate = Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp))
      logger.notice(
        """
        Overwrite oldest: deleting contact '\(LogRedaction.nodeName(contactName))' \
        [key=\(fullPubKeyHex), type=\(contactTypeDesc), favorite=\(contact.isFavorite), \
        pathLen=\(contact.outPathLength), lastModified=\(lastModifiedDate), lastAdvert=\(lastAdvertDate)]
        """
      )
      lastOverwriteDeletion = (name: contactName, pubKeyHex: pubKeyPrefix, time: Date())
    } else {
      logger.warning("Overwrite oldest: contact not found in local database for key \(pubKeyPrefix)... (may have been deleted already)")
    }
    scheduleDeletionFlush()
  }

  /// One flush per burst of foreground 0x8F: the first starts a `deleteBatchWindow` wait, the rest join
  /// `pendingDeletedKeys` meanwhile, and `flushPendingDeletedKeys` takes them all (and any that arrive
  /// while it runs) in batches.
  private func scheduleDeletionFlush() {
    guard deletionBatchTask == nil else { return }
    deletionBatchTask = Task {
      if deleteBatchWindow > .zero { try? await Task.sleep(for: deleteBatchWindow) }
      if Task.isCancelled { return }
      deletionBatchTask = nil
      await flushPendingDeletedKeys()
    }
  }

  /// Correlates an overwrite-oldest deletion with a replacement contact seen soon after.
  func logOverwriteReplacementIfRecent(newContactName: String, newContactType: ContactType) {
    guard let deletion = lastOverwriteDeletion,
          Date().timeIntervalSince(deletion.time) < 60 else { return }

    logger.notice("Overwrite oldest: '\(LogRedaction.nodeName(deletion.name))' (\(deletion.pubKeyHex)...) replaced by '\(LogRedaction.nodeName(newContactName))' (type=\(newContactType))")
    lastOverwriteDeletion = nil
  }

  /// Handle contacts full event (0x90) - device storage is full
  private func handleContactsFullEvent() async {
    logger.warning("Device node storage is full - if overwrite oldest is enabled, the next new node will trigger auto-deletion of the oldest non-favorite contact")
    eventBroadcaster.yield(.nodeStorageFullChanged(isFull: true))
  }
}
