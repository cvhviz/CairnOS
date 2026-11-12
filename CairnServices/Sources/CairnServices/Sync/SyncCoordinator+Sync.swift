// SyncCoordinator+Sync.swift
import Foundation

// MARK: - Full Sync & Connection Lifecycle

extension SyncCoordinator {
  private struct ContactChannelSyncResult {
    let contacts: SyncPhaseStatus
    let channels: SyncPhaseStatus
    let channelRetryIndices: [UInt8]
  }

  /// Contact watermark value meaning no contact sync has ever succeeded.
  static let noContactWatermark: UInt32 = 0

  /// `since` value for a prune-free full contact fetch: the device reports every
  /// contact while local rows the device omits are kept.
  private static let pruneFreeFullFetchSince = Date(timeIntervalSince1970: 0)

  /// Seconds the incremental `since` filter is rewound from the stored watermark.
  /// The device reports a contact only when `lastmod > since`, so a contact modified
  /// in the same second as the watermark would never be reported. One second of
  /// overlap re-reports that second; the upsert behind it is idempotent.
  private static let incrementalSinceOverlap: TimeInterval = 1

  /// Max lead over the plausibility reference before a stored watermark is
  /// treated as unusable for incremental `since`. Multi-day residual lastmod
  /// from a radio RTC far ahead of the phone is broken; minute-scale lead is
  /// normal drift.
  static let contactWatermarkPlausibilitySkew: TimeInterval = 2 * 24 * 60 * 60

  /// Bound for waiting out an advert-owned contact-sync claim.
  /// Above `SessionConfiguration.contactStreamHardTimeout` (180s) so a large
  /// contact table can finish streaming, but a wedged wait cannot hang forever.
  static let advertContactSyncWaitTimeout: Duration = .seconds(200)

  /// Developer-facing reason when the advert claim wait hits its bound.
  static let advertContactSyncWaitTimedOutMessage =
    "Timed out waiting for background contact sync"

  /// How to use a stored contact-sync watermark for one fetch round.
  /// Does not rewrite storage — only decides the `since` filter for this round.
  enum ContactWatermarkUse: Equatable, Sendable {
    /// No successful contact sync stamp yet.
    case none
    /// Stamp is usable for incremental `since = watermark - 1`.
    case incremental(UInt32)
    /// Stamp is implausibly ahead of the reference. Fetch with `since == nil`
    /// this round; leave the stored value alone until write-back of the new max.
    case invalid(stored: UInt32)
  }

  /// The `since` filter for an incremental contact fetch from a stored watermark.
  private static func incrementalSince(watermark: UInt32) -> Date {
    Date(timeIntervalSince1970: Double(watermark) - incrementalSinceOverlap)
  }

  /// Decides whether a stored contact-sync watermark can drive incremental sync.
  ///
  /// Reference clock: **phone `Date`**. `syncDeviceTimeIfNeeded` holds the radio
  /// within `deviceClockDriftTolerance` (5 s) of the phone on connect and sync
  /// retry, so the phone is a local proxy for radio time without an extra
  /// `getTime` BLE round on every contact sync and advert delta.
  ///
  /// When the stamp leads the reference by more than
  /// `contactWatermarkPlausibilitySkew`, return `.invalid` so the caller fetches
  /// with `since == nil` once. Never rewrite the stored stamp downward here —
  /// phone-clock clamps pin below radio lastmods and loop full-table deltas.
  nonisolated static func contactWatermarkUse(
    fromLastContactSync raw: UInt32?,
    referenceNow: Date = Date()
  ) -> ContactWatermarkUse {
    guard let raw, raw != noContactWatermark else { return .none }
    let referenceSeconds = UInt32(referenceNow.timeIntervalSince1970)
    let maxSkew = UInt32(contactWatermarkPlausibilitySkew)
    let upperBound = referenceSeconds > UInt32.max - maxSkew
      ? UInt32.max
      : referenceSeconds + maxSkew
    if raw > upperBound {
      return .invalid(stored: raw)
    }
    return .incremental(raw)
  }

  // MARK: - Full Sync

  /// Performs full sync of contacts, channels, and messages from device.
  ///
  /// This is the core sync method that ensures all data is pulled from the device.
  /// It syncs in order: contacts → channels → messages. In the background the radio's message
  /// queue is drained (and auto-fetch started) before contacts, since the process may get only
  /// seconds and the queue is what can overflow.
  ///
  /// - Parameters:
  ///   - radioID: The connected device UUID
  ///   - dataStore: Persistence store for data operations
  ///   - contactService: Service for contact sync
  ///   - channelService: Service for channel sync
  ///   - messagePollingService: Service for message polling
  ///   - appStateProvider: Optional provider for foreground/background state. When nil,
  ///     defaults to foreground mode (channels sync). When provided and app is backgrounded,
  ///     channel sync is skipped to reduce BLE traffic.
  ///   - rxLogService: Optional service for updating contact public keys after sync.
  ///   - forceFullSync: When true, ignores lastContactSync watermark and fetches all contacts.
  @discardableResult
  func performFullSync(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    contactService: some ContactServiceProtocol,
    channelService: some ChannelServiceProtocol,
    messagePollingService: some MessagePollingServiceProtocol,
    appStateProvider: AppStateProvider? = nil,
    rxLogService: RxLogService? = nil,
    notificationService: NotificationService? = nil,
    forceFullSync: Bool = false,
    channelSyncConfig: ChannelSyncConfig = .none,
    platformName: String = "unknown"
  ) async throws -> FullSyncResult {
    try await waitForAdvertContactSync()

    // Prevent concurrent syncs — actor-local flag avoids the TOCTOU window
    // that existed when guarding via `await state.isSyncing`
    guard !isSyncInProgress else {
      logger.warning("performFullSync called while already syncing, ignoring duplicate")
      return .skipped
    }
    isSyncInProgress = true
    defer { isSyncInProgress = false }

    return try await runFullSync(
      radioID: radioID,
      dataStore: dataStore,
      contactService: contactService,
      channelService: channelService,
      messagePollingService: messagePollingService,
      appStateProvider: appStateProvider,
      rxLogService: rxLogService,
      notificationService: notificationService,
      forceFullSync: forceFullSync,
      channelSyncConfig: channelSyncConfig,
      platformName: platformName
    )
  }

  /// Full-sync body without the `isSyncInProgress` claim. Callers must hold
  /// the claim already: `performFullSync` takes it per call, while
  /// `onConnectionEstablished` claims it before its handler-wiring awaits so
  /// racing connection setups cannot double-wire.
  private func runFullSync(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    contactService: some ContactServiceProtocol,
    channelService: some ChannelServiceProtocol,
    messagePollingService: some MessagePollingServiceProtocol,
    appStateProvider: AppStateProvider? = nil,
    rxLogService: RxLogService? = nil,
    notificationService: NotificationService? = nil,
    forceFullSync: Bool = false,
    channelSyncConfig: ChannelSyncConfig = .none,
    platformName: String = "unknown"
  ) async throws -> FullSyncResult {
    logger.info("Starting full sync for device \(radioID)")
    let syncStart = ContinuousClock.now

    do {
      // Set phase before triggering pill visibility
      logger.info("[Sync] State → .syncing(.contacts)")
      await setState(.syncing(progress: SyncProgress(phase: .contacts, current: 0, total: 0)))
      hasEndedSyncActivity = false
      logger.info("[Sync] Calling onSyncActivityStarted")
      await onSyncActivityStarted?()

      // In the background the radio's message queue is what is at risk, and the process may get
      // only seconds: drain it before the long contact exchange, then keep draining (auto-fetch)
      // while contacts sync, so a contact read that fails or is cut short by suspension never
      // leaves MSG_WAITING pushes unanswered. A DM from a sender not yet in contacts is stored
      // with its key prefix and linked when contacts arrive.
      let inForeground = await appStateProvider?.isInForeground ?? true
      if !inForeground {
        await drainMessagesBeforeContacts(
          radioID: radioID,
          messagePollingService: messagePollingService,
          notificationService: notificationService
        )
      }

      // Perform contacts and channels sync (activity should show pill).
      // Contacts remain connection-critical. Channel errors are degraded
      // state: keep existing local channels and let the caller schedule a
      // channel-only retry instead of replaying contacts.
      let contactChannelResult = try await syncContactsAndChannels(
        radioID: radioID,
        dataStore: dataStore,
        contactService: contactService,
        channelService: channelService,
        appStateProvider: appStateProvider,
        rxLogService: rxLogService,
        forceFullSync: forceFullSync,
        channelSyncSkipWindow: channelSyncConfig.channelSyncSkipWindow,
        cleanChannelSyncSkipWindow: channelSyncConfig.cleanChannelSyncSkipWindow,
        lastCleanChannelSync: channelSyncConfig.lastCleanChannelSync,
        lastAttemptedChannelSync: channelSyncConfig.lastAttemptedChannelSync,
        storedChannelTableVerified: channelSyncConfig.storedChannelTableVerified,
        startedInBackground: !inForeground,
        usePipelinedRead: channelSyncConfig.usePipelinedChannelRead
      )

      // DMs the pre-contact drain (or any earlier delivery) stored before their sender's contact
      // existed: link them now, and in the background post the banners they never got.
      await adoptPendingOrphanDirectMessages(
        radioID: radioID,
        dataStore: dataStore,
        notificationService: notificationService,
        postBanners: !inForeground
      )

      // End sync activity before messages phase (pill should hide).
      // During resync, the outer bracket (beginResyncActivity) holds syncActivityCount >= 1,
      // so this inner succeeded=true decrement cannot reach zero and prematurely trigger
      // the "Ready" toast. During initial sync there is no outer bracket, and reaching
      // zero here is the correct "sync complete" signal.
      await endSyncActivityOnce(succeeded: true)

      // Phase 3: Messages (no pill for this phase)
      logger.info("[Sync] State → .syncing(.messages)")
      await setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
      let messageStart = ContinuousClock.now
      let messageCount: Int
      let messageStatus: SyncPhaseStatus
      // Cairn firmware: opt this link in to the echo of messages sent from the radio's own
      // UI before draining, so queued echoes arrive in order with received messages.
      await messagePollingService.enableRadioSentSync()
      do {
        messageCount = try await messagePollingService.pollAllMessages()
        messageStatus = .clean
      } catch let error as CancellationError {
        throw error
      } catch {
        messageCount = 0
        messageStatus = .failed(error.localizedDescription)
        logger.warning("[Sync] Message polling failed after contacts/channels: \(error.localizedDescription)")
      }
      let messageElapsed = ContinuousClock.now - messageStart
      logger.info("[Sync] Phase end: messages - \(messageCount) polled in \(messageElapsed)")

      // Clear notification suppression immediately after catch-up poll completes.
      // All catch-up messages have been processed with suppression active;
      // any subsequent event-monitor messages are genuinely new and should notify.
      if let notificationService {
        cancelSuppressionWatchdog()
        await MainActor.run {
          notificationService.isSuppressingNotifications = false
        }
        // What the suppression swallowed, summed per conversation, when the app is away.
        await flushCatchUpNotifications(notificationService: notificationService)
      }
      markCatchUpDelivered()

      await notifyConversationsChanged()

      // Complete
      logger.info("[Sync] State → .synced")
      await setState(.synced)

      // Cairn firmware: the board's own chat history past what this app has (HIST_SYNC.md). After
      // the drain, so genuinely new messages were notified first; stored read and silent.
      if await messagePollingService.importRadioHistory() > 0 {
        await notifyConversationsChanged()
      }
      await setLastSyncDate(Date())

      let elapsed = ContinuousClock.now - syncStart
      logger.info("[Sync] Complete: platform=\(platformName), messages=\(messageCount), duration=\(elapsed)")
      return FullSyncResult(
        contacts: contactChannelResult.contacts,
        channels: contactChannelResult.channels,
        messages: messageStatus,
        channelRetryIndices: contactChannelResult.channelRetryIndices
      )
    } catch let error as CancellationError {
      // Defensive: ensure activity count is decremented even if cancellation
      // occurs outside the contacts/channels error path.
      await endSyncActivityOnce()
      await setState(.idle)
      throw error
    } catch {
      // Defensive: ensure activity count is decremented even if an error is
      // thrown from a path that bypasses the inner contacts/channels catch.
      await endSyncActivityOnce()
      logger.warning("[Sync] State → .failed: \(error.localizedDescription)")
      await setState(.failed(.syncFailed(error.localizedDescription)))
      throw error
    }
  }

  /// The background connect's first step: opt in to the sent-message echo, drain the radio's
  /// queue, end catch-up suppression (so messages arriving during the contact phase notify one
  /// by one), and start auto-fetch. A failed drain is logged, not thrown: auto-fetch retries it,
  /// and the full sync's own message phase drains again after contacts.
  private func drainMessagesBeforeContacts(
    radioID: UUID,
    messagePollingService: some MessagePollingServiceProtocol,
    notificationService: NotificationService?
  ) async {
    logger.info("[Sync] Background connect: draining messages before contacts")
    await messagePollingService.enableRadioSentSync()
    do {
      let drained = try await messagePollingService.pollAllMessages()
      logger.info("[Sync] Background pre-contact drain: \(drained) message(s)")
    } catch is CancellationError {
      return
    } catch {
      logger.warning("[Sync] Background pre-contact drain failed: \(error.localizedDescription)")
    }
    if let notificationService {
      cancelSuppressionWatchdog()
      await MainActor.run {
        notificationService.isSuppressingNotifications = false
      }
      await flushCatchUpNotifications(notificationService: notificationService)
    }
    markCatchUpDelivered()
    await notifyConversationsChanged()
    await messagePollingService.startAutoFetch(radioID: radioID)
  }

  /// Remembers a sender whose DM was stored without a contact row.
  func notePendingOrphanSender(_ prefix: Data) {
    guard pendingOrphanSenderPrefixes.count < Self.pendingOrphanSenderLimit else { return }
    pendingOrphanSenderPrefixes.insert(prefix)
  }

  /// Links DMs stored before their sender's contact row existed to the contacts the contact phase
  /// just brought in, and with `postBanners` (the app is in the background) posts the banner each
  /// such conversation never got at receipt, with the usual block and mute rules.
  ///
  /// The background connect drains the radio's queue before the contact phase, so a DM from a
  /// contact the radio added while the app was away is stored with only its key prefix. Advert
  /// delta sync adopts such DMs when it sees the sender's advert; this covers the full contact
  /// phase, which otherwise left them unlinked and unannounced.
  func adoptPendingOrphanDirectMessages(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    notificationService: NotificationService?,
    postBanners: Bool
  ) async {
    guard !pendingOrphanSenderPrefixes.isEmpty else { return }
    let prefixes = pendingOrphanSenderPrefixes
    let contacts: [ContactDTO]
    do {
      contacts = try await dataStore.fetchContacts(radioID: radioID)
    } catch {
      logger.warning("[Sync] Orphan DM adoption: contact fetch failed: \(error.localizedDescription)")
      return
    }
    let candidates = contacts.filter { contact in
      prefixes.contains { contact.publicKey.starts(with: $0) }
    }
    guard !candidates.isEmpty else { return }
    // Senders now known are settled whatever adoption does (an ambiguous prefix stays orphaned).
    let settled = prefixes.filter { prefix in candidates.contains { $0.publicKey.starts(with: prefix) } }
    let adopted: [UUID: Int]
    do {
      adopted = try await dataStore.adoptOrphanedDirectMessages(
        radioID: radioID,
        contacts: candidates.map { ($0.id, $0.publicKey) }
      )
    } catch {
      logger.warning("[Sync] Orphan DM adoption failed: \(error.localizedDescription)")
      return
    }
    pendingOrphanSenderPrefixes.subtract(settled)
    guard !adopted.isEmpty else { return }
    logger.info("[Sync] Linked \(adopted.values.reduce(0, +)) orphaned DM(s) to \(adopted.count) contact(s) after the contact phase")
    await notifyConversationsChanged()
    guard let notificationService else { return }
    if postBanners {
      await postAdoptedDirectMessageNotifications(
        contactIDs: Array(adopted.keys),
        dataStore: dataStore,
        notificationService: notificationService
      )
    } else {
      await notificationService.updateBadgeCount()
    }
  }

  /// Attempts to resync data after a previous sync failure.
  /// Unlike onConnectionEstablished, does not rewire handlers or restart event monitoring.
  /// - Parameters:
  ///   - radioID: The connected device UUID
  ///   - dependencies: The sync dependency surface
  ///   - forceFullSync: When true, forces a full contact sync instead of incremental.
  ///   - channelSyncConfig: Channel sync skip configuration.
  ///   - platformName: Platform name for instrumentation logging.
  /// - Returns: `true` if sync succeeded, `false` if it failed
  func performResync(
    radioID: UUID,
    dependencies: SyncDependencies,
    forceFullSync: Bool = false,
    channelSyncConfig: ChannelSyncConfig = .none,
    platformName: String = "unknown"
  ) async -> Bool {
    #if DEBUG
      if let override = performResyncOverride {
        return await override(radioID, dependencies)
      }
    #endif
    logger.info("Attempting resync for device \(radioID)")

    await MainActor.run {
      logger.info("Suppressing message notifications during resync")
      dependencies.notificationService.isSuppressingNotifications = true
    }
    startSuppressionWatchdog(notificationService: dependencies.notificationService)
    // Auto-fetch is not paused for a resync: a paused fetch left every MSG_WAITING push of the
    // contact phase unanswered, and the drains' claims already keep each message to one handler.

    do {
      let result = try await performFullSync(
        radioID: radioID,
        dataStore: dependencies.dataStore,
        contactService: dependencies.contactService,
        channelService: dependencies.channelService,
        messagePollingService: dependencies.messagePollingService,
        appStateProvider: dependencies.appStateProvider,
        rxLogService: dependencies.rxLogService,
        notificationService: dependencies.notificationService,
        forceFullSync: forceFullSync,
        channelSyncConfig: channelSyncConfig,
        platformName: platformName
      )

      startDiscoveryEventMonitoring(dependencies: dependencies, radioID: radioID)

      await drainHandlersAndResumeNotifications(
        notificationService: dependencies.notificationService,
        messagePollingService: dependencies.messagePollingService,
        context: "resync complete"
      )
      // A failed initial sync may never have reached startAutoFetch. No-op when already on.
      await dependencies.messagePollingService.startAutoFetch(radioID: radioID)
      await dependencies.messagePollingService.requestDrain()

      if result.isConnectionUsable {
        logger.info("Resync succeeded")
        return true
      }

      logger.warning("Resync completed without usable contacts")
      return false
    } catch {
      await drainHandlersAndResumeNotifications(
        notificationService: dependencies.notificationService,
        messagePollingService: dependencies.messagePollingService,
        context: "resync failed"
      )
      // A failed contact phase must never leave the radio's queue undrained: keep auto-fetch on
      // (starting it when the initial sync never got that far) and drain what is waiting now.
      await dependencies.messagePollingService.startAutoFetch(radioID: radioID)
      await dependencies.messagePollingService.requestDrain()

      logger.warning("Resync failed: \(error.localizedDescription)")
      await setState(.failed(.syncFailed(error.localizedDescription)))
      return false
    }
  }

  // MARK: - Connection Lifecycle

  /// Called by ConnectionManager when connection is established.
  /// Wires handlers, starts event monitoring, and performs initial sync.
  ///
  /// This is the critical method that fixes the handler wiring gap:
  /// 1. Wire message handlers first (before events can arrive)
  /// 2. Start event monitoring (handlers are now ready)
  /// 3. Perform full sync (contacts, channels, messages)
  /// 4. Start discovery event monitoring (for ongoing contact discovery)
  ///
  /// - Parameters:
  ///   - radioID: The connected device UUID
  ///   - dependencies: The sync dependency surface
  ///   - forceFullSync: When true, forces a full contact sync instead of incremental.
  ///   - channelSyncConfig: Channel sync skip configuration.
  ///   - platformName: Platform name for instrumentation logging.
  ///   - transportType: The transport carrying this connection. The private key
  ///     export is skipped over WiFi, which is unencrypted TCP.
  @discardableResult
  func onConnectionEstablished(
    radioID: UUID,
    dependencies: SyncDependencies,
    forceFullSync: Bool = false,
    channelSyncConfig: ChannelSyncConfig = .none,
    platformName: String = "unknown",
    transportType: TransportType = .bluetooth
  ) async throws -> FullSyncResult {
    logger.info("Connection established for device \(radioID)")

    try await waitForAdvertContactSync()

    // Claim synchronously before the wiring awaits below. A read-only guard
    // let two racing calls (rapid auto-reconnect cycles) both pass and
    // double-wire handlers; the claim makes the loser skip immediately.
    guard !isSyncInProgress else {
      logger.warning("onConnectionEstablished called while already syncing, ignoring duplicate")
      return .skipped
    }
    isSyncInProgress = true
    defer { isSyncInProgress = false }

    // Suppress message notifications during sync to avoid flooding user on reconnect
    // Unread counts and badges still update - only system notifications are suppressed
    await MainActor.run {
      logger.info("Suppressing message notifications during sync")
      dependencies.notificationService.isSuppressingNotifications = true
    }
    startSuppressionWatchdog(notificationService: dependencies.notificationService)

    do {
      // Defer advert-driven contact sync during full sync to avoid BLE contention
      await dependencies.advertisementService.setSyncingContacts(true)

      // 1. Wire message handlers and advert delta-sync first (before events can arrive).
      // Delta-sync wiring must not wait until after runFullSync: if the initial sync
      // throws, performResync never rewires handlers and the handler would stay dead.
      await wireMessageHandlers(dependencies: dependencies, radioID: radioID)
      let dataStore = dependencies.dataStore
      // Stock firmware: no Cairn extension probes (each a wasted round trip). A device read that
      // fails leaves them on, as before.
      if let device = try? await dataStore.fetchDevice(radioID: radioID) {
        await dependencies.messagePollingService.setCairnFirmware(device.isCairnFirmware)
      }
      let contactService = dependencies.contactService
      await dependencies.advertisementService.setDeltaSyncHandler { [weak self] fullRefetch in
        // A released coordinator means the connection is gone; retrying cannot help.
        guard let self else { return .failed }
        return await self.performAdvertContactSync(
          fullRefetch: fullRefetch,
          radioID: radioID,
          dataStore: dataStore,
          contactService: contactService
        )
      }

      // Return to the foreground: drain what a suspended exchange left on the radio and read
      // channels a background connect skipped. Captures no AdvertisementService (it holds this).
      let channelService = dependencies.channelService
      let messagePollingService = dependencies.messagePollingService
      let rxLogService = dependencies.rxLogService
      await dependencies.advertisementService.setForegroundCatchUpHandler { [weak self] in
        await self?.runForegroundCatchUp(
          radioID: radioID,
          dataStore: dataStore,
          channelService: channelService,
          messagePollingService: messagePollingService,
          rxLogService: rxLogService
        )
      }

      // 2. Now start event monitoring (handlers are ready), but delay auto-fetch and advert monitoring until after sync
      logger.info("[Sync] Starting event monitoring for device \(radioID.uuidString.prefix(8))")
      await dependencies.startEventMonitoring(radioID, false)

      // 3. Export device private key for direct message decryption.
      // The WiFi link is plain TCP, so exporting there would send the radio's
      // identity key across the LAN in cleartext on every connect.
      if transportType == .wifi {
        logger.info("Skipping private key export over WiFi: DM decryption in the RX log is unavailable")
      } else {
        do {
          let privateKey = try await dependencies.exportPrivateKey()
          await dependencies.rxLogService.updatePrivateKey(privateKey)
          logger.debug("Device private key exported for direct message decryption")
        } catch {
          logger.warning("Failed to export private key: \(error.localizedDescription)")
        }
      }

      // 4. Perform full sync (claim is already held; the guarded entry
      // point would see its own claim and skip)
      let syncResult = try await runFullSync(
        radioID: radioID,
        dataStore: dependencies.dataStore,
        contactService: dependencies.contactService,
        channelService: dependencies.channelService,
        messagePollingService: dependencies.messagePollingService,
        appStateProvider: dependencies.appStateProvider,
        rxLogService: dependencies.rxLogService,
        notificationService: dependencies.notificationService,
        forceFullSync: forceFullSync,
        channelSyncConfig: channelSyncConfig,
        platformName: platformName
      )

      // 5. Start discovery event monitoring (for ongoing contact discovery).
      // Intentionally after the full sync so adverts arriving during sync
      // do not spam notifications.
      startDiscoveryEventMonitoring(dependencies: dependencies, radioID: radioID)

      // 6. Flush deferred advert-driven contact fetches now that discovery monitoring is live
      await dependencies.advertisementService.setSyncingContacts(false)

      // 7. Drain pending message handlers and resume notifications
      await drainHandlersAndResumeNotifications(
        notificationService: dependencies.notificationService,
        messagePollingService: dependencies.messagePollingService,
        context: "sync complete"
      )

      // 8. Start auto-fetch after suppression is cleared to avoid notification spam
      logger.info("[Sync] Starting auto-fetch for device \(radioID.uuidString.prefix(8))")
      await dependencies.messagePollingService.startAutoFetch(radioID: radioID)

      logger.info("Connection setup complete for device \(radioID)")
      return syncResult
    } catch {
      // Drain pending message handlers and resume notifications
      await drainHandlersAndResumeNotifications(
        notificationService: dependencies.notificationService,
        messagePollingService: dependencies.messagePollingService,
        context: "sync failed"
      )
      await dependencies.advertisementService.setSyncingContacts(false)
      // Contacts failing must not stop message delivery: start auto-fetch anyway, so every
      // MSG_WAITING push is answered and the queue drained while the resync loop retries.
      if !(error is CancellationError) {
        logger.info("[Sync] Starting auto-fetch after a failed sync for device \(radioID.uuidString.prefix(8))")
        await dependencies.messagePollingService.startAutoFetch(radioID: radioID)
      }
      throw error
    }
  }

  /// Called when disconnecting from device
  ///
  /// If disconnect occurs mid-sync (during contacts or channels phase), we must call
  /// onSyncActivityEnded to decrement the activity count, otherwise the pill stays stuck.
  func onDisconnected(notificationService: NotificationService) async {
    // Before the first suspension: the sync this drop cut off can release its claim while
    // `state` is read, and a deferred pending channel sync must not start on the dead link.
    deferredPendingChannelSync = nil
    linkGeneration &+= 1
    let currentState = await state
    logger.warning(
      "[Sync] onDisconnected called - syncState: \(String(describing: currentState)), hasEndedSyncActivity: \(hasEndedSyncActivity)"
    )

    // Safety net: clear sync guard flags on disconnect and wake any waiters so
    // pull-to-refresh / full-sync cannot stay suspended after the connection drops.
    if isSyncInProgress {
      logger.warning("isSyncInProgress still true at disconnect — clearing as safety net")
    }
    isSyncInProgress = false
    advertContactSyncActive = false
    manualContactSyncActive = false
    resumeAllAdvertSyncWaiters()

    // The next session must prove its own full contact fetch before delta sync runs.
    fullContactSyncCompletedRadioID = nil
    invalidWatermarkRecoveryRadioID = nil
    invalidWatermarkRecoveryExhaustedLoggedRadioID = nil

    // Note: pending reactions are not cleared on disconnect - they persist for the app session
    // This handles temporary BLE disconnects without losing queued reactions
    unresolvedChannelIndices.removeAll()
    lastUnresolvedChannelSummaryAt = nil

    // If we're mid-sync in contacts or channels phase, end the activity to hide the pill
    if case let .syncing(progress) = currentState,
       progress.phase == .contacts || progress.phase == .channels {
      await endSyncActivityOnce()
    }

    logger.info("[Sync] State → .idle (disconnected)")
    await setState(.idle)

    // Safety net: ensure suppression is cleared on disconnect
    // Handles edge cases like connection dropping mid-sync or force-quit
    cancelSuppressionWatchdog()
    await MainActor.run {
      notificationService.isSuppressingNotifications = false
    }
    // Messages stored before the link dropped mid-sync still get their notification.
    await flushCatchUpNotifications(notificationService: notificationService)

    logger.info("Disconnected, sync state reset to idle")
  }

  // MARK: - Sync Helpers

  /// Syncs contacts and channels from the device (phases 1 and 2 of full sync).
  private func syncContactsAndChannels( // swiftlint:disable:this function_body_length
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    contactService: some ContactServiceProtocol,
    channelService: some ChannelServiceProtocol,
    appStateProvider: AppStateProvider?,
    rxLogService: RxLogService?,
    forceFullSync: Bool,
    channelSyncSkipWindow: Duration = .zero,
    cleanChannelSyncSkipWindow: Duration? = nil,
    lastCleanChannelSync: Date? = nil,
    lastAttemptedChannelSync: Date? = nil,
    storedChannelTableVerified: Bool = false,
    startedInBackground: Bool = false,
    usePipelinedRead: Bool = false
  ) async throws -> ContactChannelSyncResult {
    // Fetch device once for both contacts (lastContactSync) and channels (maxChannels)
    let device = try await dataStore.fetchDevice(radioID: radioID)

    // Phase 1: Contacts (incremental unless forced full). A full table no longer
    // forces a full fetch on every connect (with auto-add that was most connects):
    // the incremental fetch's `contactsStart` total is compared with the local
    // count afterwards, and only a difference brings the full, pruning fetch.
    var ranInvalidWatermarkRecovery = false
    let lastContactSync: Date?
    if forceFullSync {
      lastContactSync = nil
      logger.notice(
        "[Sync] Phase start: contacts (FULL sync, reason=forceFullSync) — local contacts not on device will be pruned"
      )
    } else {
      switch Self.contactWatermarkUse(fromLastContactSync: device?.lastContactSync) {
      case .none:
        lastContactSync = nil
        logger.notice(
          "[Sync] Phase start: contacts (FULL sync, reason=no watermark) — local contacts not on device will be pruned"
        )
      case let .incremental(watermark):
        lastContactSync = Self.incrementalSince(watermark: watermark)
      case let .invalid(stored):
        // Connect full-sync may prune (`since == nil`). Advert recovery must not —
        // see performAdvertContactSync. Bound to one recovery per radio lifetime.
        if invalidWatermarkRecoveryRadioID == radioID {
          lastContactSync = Self.incrementalSince(watermark: stored)
          logInvalidWatermarkRecoveryExhaustedIfNeeded(radioID: radioID, stored: stored)
        } else {
          ranInvalidWatermarkRecovery = true
          lastContactSync = nil
          logger.notice(
            "[Sync] Phase start: contacts (FULL sync, reason=invalid watermark \(stored) exceeds phone reference + \(Int(Self.contactWatermarkPlausibilitySkew))s) — one-shot recovery, store not rewritten"
          )
        }
      }
    }

    await reportContactFetchMode(isFullFetch: lastContactSync == nil)

    let contactResult = try await syncContactsPhase(
      radioID: radioID,
      dataStore: dataStore,
      contactService: contactService,
      since: lastContactSync,
      forceFullSync: forceFullSync
    )

    // An incremental fetch cannot see contacts the radio dropped while the app was
    // away (overwrite-oldest eviction, a removal on the device itself), nor ones it
    // holds from before the watermark. Its `contactsStart` total covers the whole
    // table either way: when that differs from the local count, one full (pruning)
    // fetch reconciles them.
    if lastContactSync != nil,
       let deviceTotal = contactResult.reportedTotal,
       let localCount = await localContactCountDiffering(
         from: deviceTotal, radioID: radioID, dataStore: dataStore, selfPublicKey: device?.publicKey
       ) {
      logger.notice(
        "[Sync] Phase start: contacts (FULL sync, reason=device has \(deviceTotal), local has \(localCount)) — local contacts not on device will be pruned"
      )
      await reportContactFetchMode(isFullFetch: true)
      _ = try await syncContactsPhase(
        radioID: radioID,
        dataStore: dataStore,
        contactService: contactService,
        since: nil
      )
    }

    if ranInvalidWatermarkRecovery {
      invalidWatermarkRecoveryRadioID = radioID
    }

    // Update RxLogService with contact public keys for direct message decryption
    if let rxLogService {
      do {
        let publicKeys = try await dataStore.fetchContactPublicKeysByPrefix(radioID: radioID)
        await rxLogService.updateContactPublicKeys(publicKeys)
        logger.debug("Updated \(publicKeys.count) contact public keys for direct message decryption")
      } catch {
        logger.error("Failed to fetch contact public keys: \(error)")
      }
    }

    // Phase 2: Channels (foreground only)
    var channelStatus: SyncPhaseStatus = .skipped
    var channelRetryIndices: [UInt8] = []
    logger.debug("About to check foreground state, provider exists: \(appStateProvider != nil)")
    let shouldSyncChannels: Bool
    if let provider = appStateProvider {
      logger.debug("Calling isInForeground...")
      shouldSyncChannels = await provider.isInForeground
      logger.debug("isInForeground returned: \(shouldSyncChannels)")
    } else {
      logger.debug("No appStateProvider, defaulting to foreground mode")
      shouldSyncChannels = true
    }
    logger.debug("Proceeding with shouldSyncChannels=\(shouldSyncChannels)")
    let shouldSkipChannels: Bool = {
      guard !forceFullSync else { return false }
      let cleanWindow = cleanChannelSyncSkipWindow ?? channelSyncSkipWindow
      let now = Date()
      if cleanWindow > .zero, let lastSync = lastCleanChannelSync,
         now.timeIntervalSince(lastSync) < Double(cleanWindow.components.seconds) {
        return true
      }
      if channelSyncSkipWindow > .zero, let lastAttempt = lastAttemptedChannelSync,
         now.timeIntervalSince(lastAttempt) < Double(channelSyncSkipWindow.components.seconds) {
        return true
      }
      return false
    }()
    // A clean read of this radio earlier in this app session left a full copy of its channel
    // table, so a reconnect (a link dropped while the app was away, say) checks that copy
    // against the radio with a few reads and reads every slot only when something changed.
    // A process iOS started in the background (state restoration, the wake source's pending
    // connect, Background App Refresh) has no such record, but the persisted marker says an
    // earlier process left the same full copy: a connect that began or reaches its channel
    // phase in the background checks it too, so the user's open is not a full read. A
    // foreground connect of a new process (a visible launch) still reads every slot.
    let trustsStoredTable = storedChannelTableVerified && (startedInBackground || !shouldSyncChannels)
    let canVerifyChannels = !forceFullSync && (lastCleanChannelSync != nil || trustsStoredTable)
    if shouldSyncChannels {
      if shouldSkipChannels {
        channelStatus = .skipped
        logger.info("[Sync] Skipping channel sync (recent clean or attempted sync)")
      } else {
        logger.info("[Sync] State → .syncing(.channels)")
        await setState(.syncing(progress: SyncProgress(phase: .channels, current: 0, total: 0)))
        let maxChannels = device?.maxChannels ?? 0
        await onChannelSyncAttempted?(radioID)
        if channelSyncPendingRadioID == radioID {
          channelSyncPendingRadioID = nil
        }

        if canVerifyChannels,
           try await verifyChannelsUnchanged(radioID: radioID, maxChannels: maxChannels, channelService: channelService) {
          await markChannelTableClean(radioID: radioID)
          await logPostSyncChannelDiagnostics(radioID: radioID, dataStore: dataStore)
          if let rxLogService {
            await refreshRxLogChannels(radioID: radioID, dataStore: dataStore, rxLogService: rxLogService)
          }
          return ContactChannelSyncResult(contacts: .clean, channels: .clean, channelRetryIndices: [])
        }
        if !canVerifyChannels {
          logger.info(
            "[Sync] Channel check unavailable (\(forceFullSync ? "forced full sync" : "no clean read of this radio's channels to check against")); reading every channel"
          )
        }

        let channelStart = ContinuousClock.now
        let channelResult: ChannelSyncResult
        do {
          channelResult = try await channelService.syncChannels(
            radioID: radioID,
            maxChannels: maxChannels,
            usePipelinedRead: usePipelinedRead
          )
        } catch let error as CancellationError {
          throw error
        } catch {
          let channelElapsed = ContinuousClock.now - channelStart
          channelStatus = .partial
          logger.warning(
            "[Sync] Phase end: channels partial after thrown error in \(channelElapsed): \(error.localizedDescription)"
          )
          await logPostSyncChannelDiagnostics(radioID: radioID, dataStore: dataStore)
          if let rxLogService {
            await refreshRxLogChannels(radioID: radioID, dataStore: dataStore, rxLogService: rxLogService)
          }
          return ContactChannelSyncResult(
            contacts: .clean,
            channels: channelStatus,
            channelRetryIndices: channelRetryIndices
          )
        }
        let channelElapsed = ContinuousClock.now - channelStart
        logger.info("[Sync] Phase end: channels - \(channelResult.channelsSynced) synced (device capacity: \(maxChannels)) in \(channelElapsed)")

        var channelPhaseClean = channelResult.isComplete
        let hasNonRetryableErrors = Self.leavesSlotsUnread(channelResult)
        var leftSlotsUnread = hasNonRetryableErrors
        var remainingRetryableIndices = channelResult.retryableIndices
        // A pass with failed slots that still rewrote some rows leaves fresh and old rows mixed:
        // stop vouching for the stored copy now, not after the retry, so a kill in between
        // cannot leave it trusted. A clean retry vouches for it again.
        var changedStoredTable = channelResult.changedStoredTable
        if !channelResult.isComplete, changedStoredTable {
          await onChannelTableTrustWithdrawn?(radioID)
        }

        // Retry failed channels once if there are retryable errors
        if !channelResult.isComplete {
          let retryableIndices = channelResult.retryableIndices
          if !retryableIndices.isEmpty {
            logger.info("Retrying \(retryableIndices.count) failed channels")
            let retryResult: ChannelSyncResult
            do {
              retryResult = try await channelService.retryFailedChannels(
                radioID: radioID,
                indices: retryableIndices
              )
            } catch let error as CancellationError {
              throw error
            } catch {
              logger.warning("Channel retry failed: \(error.localizedDescription)")
              channelPhaseClean = false
              remainingRetryableIndices = retryableIndices
              retryResult = ChannelSyncResult(
                channelsSynced: 0,
                errors: retryableIndices.map {
                  ChannelSyncError(
                    index: $0,
                    errorType: .timeout,
                    description: error.localizedDescription
                  )
                }
              )
            }

            changedStoredTable = changedStoredTable || retryResult.changedStoredTable
            leftSlotsUnread = leftSlotsUnread || Self.leavesSlotsUnread(retryResult)
            if retryResult.isComplete, !hasNonRetryableErrors {
              logger.info("Retry recovered \(retryResult.channelsSynced) channels")
              channelPhaseClean = true
            } else {
              remainingRetryableIndices = retryResult.retryableIndices
              if hasNonRetryableErrors {
                logger.warning("Channels have non-retryable errors, phase not clean")
              }
              logger.warning("Channels still failing after retry: \(retryResult.errors.map(\.index))")
              channelPhaseClean = false
            }
          }
        }

        // The channel-only retry reads only the retryable slots, so it must know which table
        // still has slots nothing will read again (`retryChannels`).
        channelSlotsUnreadRadioID = leftSlotsUnread ? radioID : nil
        if channelPhaseClean {
          channelStatus = .clean
          await markChannelTableClean(radioID: radioID)
        } else {
          channelStatus = .partial
          channelRetryIndices = remainingRetryableIndices
          if changedStoredTable {
            await onChannelTableTrustWithdrawn?(radioID)
          }
        }
      }

      await logPostSyncChannelDiagnostics(radioID: radioID, dataStore: dataStore)
      if let rxLogService {
        await refreshRxLogChannels(radioID: radioID, dataStore: dataStore, rxLogService: rxLogService)
      }
    } else if shouldSkipChannels {
      // Read cleanly moments ago: a foreground connect would skip them too, so nothing is owed.
      channelStatus = .skipped
      logger.info("Skipping channel sync (app in background, recent clean or attempted sync)")
    } else {
      channelStatus = .skipped
      // Nothing reads channels again until the next connect; a radio first synced here would
      // have no channel rows, so its channel messages had no conversation to show in.
      channelSyncPendingRadioID = radioID
      channelSyncPendingVerifiable = canVerifyChannels
      channelSyncPendingPipelined = usePipelinedRead
      logger.info(
        "Skipping channel sync (app in background); pending until foreground (\(canVerifyChannels ? "check first" : "full read"))"
      )
    }

    return ContactChannelSyncResult(
      contacts: .clean,
      channels: channelStatus,
      channelRetryIndices: channelRetryIndices
    )
  }

  /// Logs once when invalid-watermark recovery is spent and rounds fall back to
  /// the stored stamp (pathological residual far-future lastmod table).
  private func logInvalidWatermarkRecoveryExhaustedIfNeeded(radioID: UUID, stored: UInt32) {
    guard invalidWatermarkRecoveryExhaustedLoggedRadioID != radioID else { return }
    invalidWatermarkRecoveryExhaustedLoggedRadioID = radioID
    logger.notice(
      "[Sync] Invalid watermark recovery exhausted for radio \(radioID.uuidString): stored \(stored) still implausible — using stored stamp; manual contact refresh required"
    )
  }

  /// Runs contact sync and writes back the watermark when the result carries one.
  /// Shared by full connect sync and advert-driven delta sync.
  @discardableResult
  /// The local contact count when it differs from the device's `contactsStart`
  /// total, else `nil`. The local V-contact may or may not be on the device's
  /// count (firmware that streams it counts it), so either count matching is a
  /// match. A count-read failure is a match too: the incremental result stands.
  private func localContactCountDiffering(
    from deviceTotal: Int,
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    selfPublicKey: Data?
  ) async -> Int? {
    let keys: Set<Data>
    do {
      keys = try await dataStore.fetchContactPublicKeys(radioID: radioID)
    } catch {
      logger.error("Failed to read local contact count to compare with the device's: \(error)")
      return nil
    }
    if keys.count == deviceTotal { return nil }
    if let selfPublicKey,
       let vContactKey = VContactIdentity.publicKey(forSelfPublicKey: selfPublicKey),
       keys.contains(vContactKey),
       keys.count - 1 == deviceTotal {
      return nil
    }
    return keys.count
  }

  private func syncContactsPhase(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    contactService: some ContactServiceProtocol,
    since: Date?,
    forceFullSync: Bool = false
  ) async throws -> ContactSyncResult {
    // Caller already logged prune-full cases; epoch-0 prune-free fetch is silent here.
    if let watermark = since {
      logger.info("[Sync] Phase start: contacts (incremental, watermark=\(watermark.formatted(.iso8601)))")
    }

    let contactStart = ContinuousClock.now
    let contactResult = try await contactService.syncContacts(radioID: radioID, since: since)
    let contactElapsed = ContinuousClock.now - contactStart
    let syncType = contactResult.isIncremental ? "incremental" : "full"
    let forced = forceFullSync ? ", forced" : ""
    logger.info("[Sync] Phase end: contacts - \(contactResult.contactsReceived) (\(syncType)\(forced)) in \(contactElapsed)")
    await notifyContactsChanged()

    if contactResult.lastSyncTimestamp > 0 {
      try await dataStore.updateDeviceLastContactSync(
        radioID: radioID,
        timestamp: contactResult.lastSyncTimestamp
      )
    }
    if since == nil {
      fullContactSyncCompletedRadioID = radioID
    }
    return contactResult
  }

  /// Suspends while an advert-driven delta sync holds the claim.
  ///
  /// Background advert work must not turn a full sync, connection setup, or
  /// channel-only retry into a silent skip, and must not interleave its
  /// `ContactServiceEvent.syncProgress` events with a user-initiated refresh.
  ///
  /// Throws `CancellationError` when the calling task is cancelled, and
  /// `SyncCoordinatorError.syncFailed` when `timeout` elapses while the claim
  /// is still held. On timeout the caller must not proceed into the radio
  /// pipeline (that races progress events) and must not return a silent skip
  /// for user-initiated work (the wait exists to stop that). Surface an error
  /// so the spinner stops and the user can retry.
  func waitForAdvertContactSync(
    timeout: Duration? = nil
  ) async throws {
    let bound = timeout
      ?? advertContactSyncWaitTimeoutOverride
      ?? Self.advertContactSyncWaitTimeout
    let deadline = ContinuousClock.now + bound

    while isSyncInProgress, advertContactSyncActive {
      try Task.checkCancellation()

      let remaining = deadline - ContinuousClock.now
      if remaining <= .zero {
        logger.warning("Timed out waiting for advert contact sync to release claim")
        throw SyncCoordinatorError.syncFailed(Self.advertContactSyncWaitTimedOutMessage)
      }

      let waiterID = nextAdvertSyncWaiterID
      nextAdvertSyncWaiterID &+= 1
      try await waitForAdvertClaimRelease(id: waiterID, timeout: remaining)
    }
  }

  /// Waits out an advert claim, then marks a user-initiated contact refresh
  /// active in the same actor turn so no delta can interleave between observe
  /// and claim (separate wait and claim hops leave that window).
  func claimManualContactSync(
    timeout: Duration? = nil
  ) async throws {
    try await waitForAdvertContactSync(timeout: timeout)
    manualContactSyncActive = true
  }

  /// Marks a user-initiated contact refresh so advert delta sync returns `.busy`.
  func setManualContactSyncActive(_ active: Bool) {
    manualContactSyncActive = active
  }

  /// Test hook: shortens the advert claim wait bound used by default parameters.
  func setAdvertContactSyncWaitTimeoutOverride(_ timeout: Duration?) {
    advertContactSyncWaitTimeoutOverride = timeout
  }

  /// Suspends until the advert claim clears, the wait is cancelled, or `timeout` elapses.
  private func waitForAdvertClaimRelease(id: UInt64, timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.suspendUntilAdvertClaimReleased(id: id)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw SyncCoordinatorError.syncFailed(Self.advertContactSyncWaitTimedOutMessage)
      }
      // First finisher wins: claim release, cancel, or timeout.
      try await group.next()
      group.cancelAll()
    }
  }

  /// Parks one waiter until resume, cancel, or timeout-driven cancellation.
  private func suspendUntilAdvertClaimReleased(id: UInt64) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        // Claim may have cleared between the while check and registration.
        if !(isSyncInProgress && advertContactSyncActive) {
          continuation.resume()
          return
        }
        advertSyncWaiters.append(AdvertSyncWaiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.finishAdvertSyncWaiter(id: id, error: CancellationError()) }
    }
  }

  /// Resumes one waiter if it is still registered (cancel/timeout path).
  private func finishAdvertSyncWaiter(id: UInt64, error: Error) {
    guard let index = advertSyncWaiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = advertSyncWaiters.remove(at: index)
    waiter.continuation.resume(throwing: error)
  }

  /// Resumes every advert-claim waiter. Used when the claim clears or on disconnect.
  private func resumeAllAdvertSyncWaiters() {
    let waiters = advertSyncWaiters
    advertSyncWaiters = []
    for waiter in waiters {
      waiter.continuation.resume()
    }
  }

  /// Advert-driven contact delta sync. Claims `isSyncInProgress` as advert-owned
  /// so full sync waits rather than skips.
  ///
  /// Both modes need proof that a full contact fetch already succeeded for this
  /// radio. Without it, writing a watermark here would make later full syncs
  /// incremental and leave ghost contacts the device no longer has. An empty
  /// radio stamps no watermark, so a completed full fetch grants entry on its
  /// own and the round fetches from epoch zero until the first contact stamps one.
  ///
  /// - Parameter fullRefetch: When true, uses the epoch-0 prune-free full fetch.
  ///   When false, uses the stored watermark.
  func performAdvertContactSync(
    fullRefetch: Bool,
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    contactService: some ContactServiceProtocol
  ) async -> AdvertContactSyncOutcome {
    guard !manualContactSyncActive else {
      logger.info("Advert contact sync deferred because a manual contact refresh is active")
      return .busy
    }
    guard !isSyncInProgress else {
      logger.info("Advert contact sync deferred because sync is already active")
      return .busy
    }
    isSyncInProgress = true
    advertContactSyncActive = true
    defer {
      isSyncInProgress = false
      advertContactSyncActive = false
      resumeAllAdvertSyncWaiters()
    }

    do {
      let device = try await dataStore.fetchDevice(radioID: radioID)
      let watermarkUse = Self.contactWatermarkUse(fromLastContactSync: device?.lastContactSync)
      let hasCompletedFullSync = fullContactSyncCompletedRadioID == radioID
      // `.invalid` still proves a prior stamp exists, so recovery may run.
      let isReady = watermarkUse != .none || hasCompletedFullSync
      guard isReady else {
        logger.notice(
          "[Sync] Advert contact sync skipped: no contact watermark yet (connect sync contacts phase has not succeeded)"
        )
        return .notReady
      }

      var ranInvalidWatermarkRecovery = false
      let since: Date?
      if fullRefetch {
        logger.info("[Sync] Advert contact sync: prune-free full refetch")
        since = Self.pruneFreeFullFetchSince
      } else {
        switch watermarkUse {
        case .none:
          logger.info("[Sync] Advert contact sync: prune-free full fetch (full sync found no contacts to stamp)")
          since = Self.pruneFreeFullFetchSince
        case let .incremental(watermark):
          since = Self.incrementalSince(watermark: watermark)
        case let .invalid(stored):
          // Prune-free epoch-0 only. `since == nil` would delete local rows the
          // device omits; connect full-sync may prune, background advert must not.
          // One recovery full fetch per radio per coordinator lifetime; further
          // rounds use the stored stamp so residual far-future lastmods cannot
          // re-stream the whole table every debounce.
          if invalidWatermarkRecoveryRadioID == radioID {
            since = Self.incrementalSince(watermark: stored)
            logInvalidWatermarkRecoveryExhaustedIfNeeded(radioID: radioID, stored: stored)
          } else {
            ranInvalidWatermarkRecovery = true
            logger.notice(
              "[Sync] Advert contact sync: invalid watermark \(stored) exceeds phone reference + \(Int(Self.contactWatermarkPlausibilitySkew))s — one-shot prune-free full recovery, store not rewritten"
            )
            since = Self.pruneFreeFullFetchSince
          }
        }
      }

      _ = try await syncContactsPhase(
        radioID: radioID,
        dataStore: dataStore,
        contactService: contactService,
        since: since
      )
      if ranInvalidWatermarkRecovery {
        invalidWatermarkRecoveryRadioID = radioID
      }
      return .synced
    } catch {
      logger.warning("Advert contact sync failed: \(error.localizedDescription)")
      return .failed
    }
  }

  // MARK: - Foreground Catch-up

  /// What the app owes a connection on return to the foreground: drain the radio's message
  /// queue (a drain cut short while suspended leaves messages the radio won't push again) and
  /// run a channel sync a background connect skipped. Wired to
  /// `AdvertisementService.handleReturnToForeground` by `onConnectionEstablished`.
  func runForegroundCatchUp(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    channelService: any ChannelServiceProtocol,
    messagePollingService: any MessagePollingServiceProtocol,
    rxLogService: RxLogService?
  ) async {
    await messagePollingService.requestDrain()
    await runPendingChannelSyncIfNeeded(
      radioID: radioID,
      dataStore: dataStore,
      channelService: channelService,
      rxLogService: rxLogService
    )
  }

  /// Runs the channel sync a background connect skipped (`channelSyncPendingRadioID`).
  ///
  /// Background connects (state restoration, auto-reconnect while suspended) skip channels to
  /// keep BLE traffic down, and nothing caught up afterwards: a radio first synced in the
  /// background showed no channels, and its channel messages had no conversation to land in.
  /// Call it once the app is in the foreground. A sync already running is left to finish, and
  /// this runs again once that sync releases its claim (still in the foreground, still owed),
  /// unless that sync read channels itself.
  /// When the stored rows are a known full copy (a clean read by this session, or by an earlier
  /// process for a background-started one), `verifyChannels` runs first and a match ends it
  /// after a few reads. A full read uses the skipping connect's pipelined-read policy.
  /// - Returns: `true` when a pending sync ran and every channel is known current.
  @discardableResult
  func runPendingChannelSyncIfNeeded(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    channelService: some ChannelServiceProtocol,
    rxLogService: RxLogService?
  ) async -> Bool {
    guard channelSyncPendingRadioID == radioID else { return false }
    do {
      try await waitForAdvertContactSync()
    } catch {
      return false
    }
    guard !isSyncInProgress else {
      logger.info("[Sync] Pending channel sync deferred: another sync is running; runs when it ends")
      let generation = linkGeneration
      deferredPendingChannelSync = { [weak self] in
        guard let self else { return }
        // The link it was deferred on may have dropped (and another come up) meanwhile.
        guard await linkGeneration == generation else { return }
        // The app may have gone back to the background while the other sync ran.
        guard await catchUpAppStateProvider?.isInForeground ?? true else { return }
        await runPendingChannelSyncIfNeeded(
          radioID: radioID,
          dataStore: dataStore,
          channelService: channelService,
          rxLogService: rxLogService
        )
      }
      return false
    }
    // A foreground sync may have read channels (and cleared the flag) during the wait.
    guard channelSyncPendingRadioID == radioID else { return false }
    isSyncInProgress = true
    defer { isSyncInProgress = false }

    logger.info("[Sync] Running the channel sync skipped while in the background")
    let maxChannels = await (try? dataStore.fetchDevice(radioID: radioID))?.maxChannels ?? 0
    await setState(.syncing(progress: SyncProgress(phase: .channels, current: 0, total: Int(maxChannels))))
    await onSyncActivityStarted?()
    await onChannelSyncAttempted?(radioID)

    var clean = false
    do {
      if channelSyncPendingVerifiable,
         try await verifyChannelsUnchanged(radioID: radioID, maxChannels: maxChannels, channelService: channelService) {
        // The stored rows still match the radio: nothing to read or write.
        clean = true
        channelSyncPendingRadioID = nil
      } else {
        if !channelSyncPendingVerifiable {
          logger.info("[Sync] Channel check unavailable (no clean read of this radio's channels to check against); reading every channel")
        }
        // A read that throws persists nothing, so a retry on the next foreground may still check.
        let result = try await channelService.syncChannels(
          radioID: radioID,
          maxChannels: maxChannels,
          usePipelinedRead: channelSyncPendingPipelined
        )
        clean = result.isComplete
        channelSlotsUnreadRadioID = Self.leavesSlotsUnread(result) ? radioID : nil
        if !result.isComplete, result.changedStoredTable {
          await onChannelTableTrustWithdrawn?(radioID)
        }
        // Every slot that answered has its row now; stragglers wait for the next connect's sync.
        channelSyncPendingRadioID = nil
        logger.info("[Sync] Pending channel sync: \(result.channelsSynced) synced, \(result.errors.count) failed")
      }
      channelSyncPendingVerifiable = false
      channelSyncPendingPipelined = false
      if clean {
        await markChannelTableClean(radioID: radioID)
      }
    } catch {
      logger.warning("[Sync] Pending channel sync failed, will retry on next foreground: \(error.localizedDescription)")
    }

    if let rxLogService {
      await refreshRxLogChannels(radioID: radioID, dataStore: dataStore, rxLogService: rxLogService)
    }
    await onSyncActivityEnded?(clean)
    await setState(.synced)
    await notifyConversationsChanged()
    return clean
  }

  /// Runs `verifyChannels` for a reconnect to a radio whose channels were read cleanly before
  /// (this session, or an earlier process for a background-started connect).
  /// `false` (read every slot) on a change, or when a slot could not be read.
  func verifyChannelsUnchanged(
    radioID: UUID,
    maxChannels: UInt8,
    channelService: some ChannelServiceProtocol
  ) async throws -> Bool {
    let start = ContinuousClock.now
    do {
      switch try await channelService.verifyChannels(radioID: radioID, maxChannels: maxChannels) {
      case let .unchanged(slotsRead):
        logger.info(
          "[Sync] Phase end: channels unchanged (\(slotsRead) of \(maxChannels) slots read) in \(ContinuousClock.now - start)"
        )
        return true
      case let .changed(reason):
        logger.info("[Sync] Channel check found a change (\(reason)); reading every channel")
        return false
      }
    } catch let error as CancellationError {
      throw error
    } catch {
      logger.warning("[Sync] Channel check failed (\(error.localizedDescription)); reading every channel")
      return false
    }
  }

  /// Retries only unresolved channel indices without replaying contacts/messages.
  @discardableResult
  func retryChannels(
    radioID: UUID,
    channelService: some ChannelServiceProtocol,
    indices: [UInt8]
  ) async -> ChannelSyncResult {
    guard !indices.isEmpty else {
      return ChannelSyncResult(channelsSynced: 0, errors: [])
    }

    do {
      try await waitForAdvertContactSync()
    } catch is CancellationError {
      return ChannelSyncResult(
        channelsSynced: 0,
        errors: indices.map {
          ChannelSyncError(index: $0, errorType: .transportError, description: "Retry cancelled")
        }
      )
    } catch {
      logger.warning("Channel-only retry timed out waiting for advert contact sync")
      return ChannelSyncResult(
        channelsSynced: 0,
        errors: indices.map {
          ChannelSyncError(
            index: $0,
            errorType: .circuitBreaker,
            description: Self.advertContactSyncWaitTimedOutMessage
          )
        }
      )
    }

    guard !isSyncInProgress else {
      logger.info("Channel-only retry skipped because sync is already active")
      return ChannelSyncResult(
        channelsSynced: 0,
        errors: indices.map {
          ChannelSyncError(
            index: $0,
            errorType: .circuitBreaker,
            description: "Skipped because sync is already active"
          )
        }
      )
    }

    isSyncInProgress = true
    defer { isSyncInProgress = false }

    logger.info("[Sync] State → .syncing(.channels) (channel-only retry)")
    await setState(.syncing(progress: SyncProgress(phase: .channels, current: 0, total: indices.count)))
    await onSyncActivityStarted?()
    await onChannelSyncAttempted?(radioID)

    let result: ChannelSyncResult
    do {
      result = try await channelService.retryFailedChannels(radioID: radioID, indices: indices)
    } catch is CancellationError {
      await onSyncActivityEnded?(false)
      await setState(.idle)
      return ChannelSyncResult(
        channelsSynced: 0,
        errors: indices.map {
          ChannelSyncError(index: $0, errorType: .transportError, description: "Retry cancelled")
        }
      )
    } catch {
      logger.warning("Channel-only retry failed: \(error.localizedDescription)")
      await onSyncActivityEnded?(false)
      await setState(.synced)
      return ChannelSyncResult(
        channelsSynced: 0,
        errors: indices.map {
          ChannelSyncError(index: $0, errorType: .transportError, description: error.localizedDescription)
        }
      )
    }

    // Only the slots asked for were read: a table an earlier pass left with slots nothing
    // retries (`channelSlotsUnreadRadioID`) is still incomplete, however cleanly these read.
    // The same rule as the connect's channel phase: vouch only for a table with every slot
    // read cleanly, and withdraw the trust from one this pass changed without finishing.
    if Self.leavesSlotsUnread(result) {
      channelSlotsUnreadRadioID = radioID
    }
    if result.isComplete, channelSlotsUnreadRadioID != radioID {
      await markChannelTableClean(radioID: radioID)
    } else if result.changedStoredTable {
      await onChannelTableTrustWithdrawn?(radioID)
    }

    await onSyncActivityEnded?(result.isComplete)
    await setState(.synced)
    return result
  }

  /// Whether a channel pass left slots the channel-only retry never reads again: it retries only
  /// `retryableIndices`, so a circuit-broken or failed-for-good slot stays unread.
  private static func leavesSlotsUnread(_ result: ChannelSyncResult) -> Bool {
    result.errors.count > result.retryableIndices.count
  }

  /// Every slot of `radioID`'s channel table was read or checked cleanly: nothing is left
  /// unread, and the clean records may vouch for the stored copy.
  private func markChannelTableClean(radioID: UUID) async {
    channelSlotsUnreadRadioID = nil
    await onCleanChannelSync?(radioID)
  }

  /// Cancels the suppression watchdog, resumes notifications, then waits for pending
  /// message handlers to drain. Suppression is cleared first as defense-in-depth for
  /// error paths where `performFullSync` throws before reaching `pollAllMessages()`.
  /// Both operations are idempotent, so double-clearing from the happy path is harmless.
  private func drainHandlersAndResumeNotifications(
    notificationService: NotificationService,
    messagePollingService: any MessagePollingServiceProtocol,
    context: String
  ) async {
    cancelSuppressionWatchdog()
    await MainActor.run {
      logger.info("Resuming message notifications (\(context))")
      notificationService.isSuppressingNotifications = false
    }

    let pendingHandlerDrainTimeout: Duration = .seconds(30)
    let didDrainPendingHandlers = await messagePollingService.waitForPendingHandlers(timeout: pendingHandlerDrainTimeout)
    if !didDrainPendingHandlers {
      logger.warning("Timed out waiting for pending message handlers")
    }
    // Handlers that were still running under suppression (or a sync that failed after
    // receiving messages) are summed here; a no-op after a clean sync already flushed.
    await flushCatchUpNotifications(notificationService: notificationService)
    markCatchUpDelivered()
  }

  private func logPostSyncChannelDiagnostics(radioID: UUID, dataStore: any PersistenceStoreProtocol) async {
    do {
      let channels = try await dataStore.fetchChannels(radioID: radioID)
      let emptyNameWithSecretIndices = channels
        .filter { $0.name.isEmpty && $0.hasSecret }
        .map(\.index)
        .sorted()
      logger.info(
        "Post-sync channel diagnostics: total=\(channels.count), emptyNameWithSecret=\(emptyNameWithSecretIndices.count)"
      )
      if !emptyNameWithSecretIndices.isEmpty {
        logger.warning(
          "Post-sync channels with empty names and non-zero secrets: \(emptyNameWithSecretIndices)"
        )
      }
    } catch {
      logger.error("Failed to compute post-sync channel diagnostics: \(error)")
    }
  }

  private func refreshRxLogChannels(
    radioID: UUID,
    dataStore: any PersistenceStoreProtocol,
    rxLogService: RxLogService
  ) async {
    do {
      let channels = try await dataStore.fetchChannels(radioID: radioID)
      // A corrupt store can hold duplicate slot indices; keep the first match
      // rather than trapping on the duplicate key.
      let secrets = Dictionary(channels.map { ($0.index, $0.secret) }, uniquingKeysWith: { first, _ in first })
      let names = Dictionary(channels.map { ($0.index, $0.name) }, uniquingKeysWith: { first, _ in first })
      await rxLogService.updateChannels(secrets: secrets, names: names)
      logger.debug("Refreshed RxLogService channel cache with \(channels.count) channels")
    } catch {
      logger.error("Failed to refresh RxLogService channel cache: \(error)")
    }
  }
}
