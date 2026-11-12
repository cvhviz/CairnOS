// SyncCoordinator+MessageHandlers.swift
import CryptoKit
import Foundation

// MARK: - Message & Discovery Handler Wiring

extension SyncCoordinator {
  // MARK: - Message Handler Wiring

  func wireMessageHandlers(dependencies: SyncDependencies, radioID: UUID) async {
    logger.info("Wiring message handlers for device \(radioID)")

    // Populate blocked contacts cache
    await refreshBlockedContactsCache(radioID: radioID, dataStore: dependencies.dataStore)
    catchUpAppStateProvider = dependencies.appStateProvider

    // Sender names in notifications come from this connection's contacts; session names follow
    // contact changes. The radio's own node name is read per message (`currentSelfNodeName`), so
    // a rename while connected applies to self-mentions and reactions at once.
    contactNameDirectories.removeAll()
    contactNameStore = (dependencies.dataStore, radioID)

    await wireContactMessageHandler(dependencies: dependencies, radioID: radioID)
    await wireChannelMessageHandler(dependencies: dependencies, radioID: radioID)
    await wireSignedMessageHandler(dependencies: dependencies)
    await wireCLIMessageHandler(dependencies: dependencies)
    await wireRadioSentMessageHandler(dependencies: dependencies, radioID: radioID)
    await wireQueueLossHandler(dependencies: dependencies, radioID: radioID)
    await repairStoredNames(dependencies: dependencies, radioID: radioID)

    logger.info("Message handlers wired successfully")
  }

  // MARK: - Radio queue loss (Cairn firmware)

  /// A Cairn radio reports what its offline queue lost while the app was away (QUEUE_SYNC.md):
  /// those messages never reach the app, so the user is told how many. A loss no notification
  /// could report (notifications off or not yet allowed) is kept in `RadioQueueLossLedger`, which
  /// Settings → Notifications shows, before the radio's counters are cleared.
  private func wireQueueLossHandler(dependencies: SyncDependencies, radioID: UUID) async {
    let dataStore = dependencies.dataStore
    let notificationService = dependencies.notificationService
    let ledger = queueLossLedger
    await dependencies.messagePollingService.setQueueLossHandler { loss in
      await Self.surfaceQueueLoss(loss, ledger: ledger) {
        (try? await dataStore.fetchDevice(radioID: radioID))?.nodeName ?? "Radio"
      } post: { name, count in
        await notificationService.postRadioQueueLossNotification(deviceName: name, lostMessages: count)
      }
    }
  }

  /// Tells the user about a queue loss: a notification, or else the ledger. Returns whether either
  /// took it (true for a loss with no lost messages, e.g. only evicted delivery confirmations).
  static func surfaceQueueLoss(
    _ loss: CairnQueueLoss,
    ledger: RadioQueueLossLedger,
    deviceName: () async -> String,
    post: (String, Int) async -> Bool
  ) async -> Bool {
    guard loss.lostMessages > 0 else { return true }
    let name = await deviceName()
    if await post(name, loss.lostMessages) { return true }
    ledger.record(lostMessages: loss.lostMessages, deviceName: name)
    return true
  }

  // MARK: - Contact Message Handler

  private func wireContactMessageHandler(dependencies: SyncDependencies, radioID: UUID) async {
    await dependencies.messagePollingService.setContactMessageHandler { [weak self] message, contact, context in
      guard let self else { return }
      await handleIncomingMessage(
        kind: .direct(message, contact: contact),
        context: context,
        dependencies: dependencies,
        radioID: radioID
      )
    }
  }

  // MARK: - Channel Message Handler

  private func wireChannelMessageHandler(dependencies: SyncDependencies, radioID: UUID) async {
    await dependencies.messagePollingService.setChannelMessageHandler { [weak self] message, channel, context in
      guard let self else { return }
      await handleIncomingMessage(
        kind: .channel(message, channel: channel),
        context: context,
        dependencies: dependencies,
        radioID: radioID
      )
    }
  }

  // MARK: - Incoming Message Pipeline

  /// Discriminates the two text-message ingestion paths, carrying the wire
  /// message and the resolved conversation for each.
  private enum IncomingMessageKind {
    case direct(ContactMessage, contact: ContactDTO?)
    case channel(ChannelMessage, channel: ChannelDTO?)

    /// Log noun distinguishing the two paths in shared diagnostics.
    var logLabel: String {
      switch self {
      case .direct: "direct"
      case .channel: "channel"
      }
    }
  }

  /// When a DM arrives with no local contact, try to create the row from a
  /// pending 0x80 key before save/notify. Adoption still links pure orphans
  /// without posting a second alert.
  private func resolveDirectContactIfNeeded(
    _ kind: IncomingMessageKind,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async -> IncomingMessageKind {
    guard case let .direct(message, contact) = kind, contact == nil else {
      return kind
    }
    let prefix = message.senderPublicKeyPrefix
    guard !prefix.isEmpty else { return kind }

    guard let materialized = await dependencies.advertisementService
      .materializeContactForPendingAdvert(matchingPrefix: prefix, radioID: radioID)
    else {
      return kind
    }
    return .direct(message, contact: materialized)
  }

  /// Re-decrypts stamp-matched 0x88 rows and harvests extras, then refetches
  /// so the channel broadcast carries the extra count.
  private func harvestAndRefreshChannelMessage(
    messageDTO: MessageDTO,
    radioID: UUID,
    dependencies: SyncDependencies
  ) async throws -> MessageDTO {
    guard let channelIndex = messageDTO.channelIndex else { return messageDTO }
    let stamp = messageDTO.senderTimestamp ?? messageDTO.timestamp
    do {
      let raw = try await dependencies.dataStore.fetchRxLogEntries(
        radioID: radioID,
        channelIndex: channelIndex,
        senderTimestamp: stamp
      )
      let decoded = await dependencies.rxLogService.decodedEntries(raw)
      await dependencies.heardRepeatsService.harvestIncomingPaths(
        for: messageDTO,
        decodedCandidates: decoded
      )
    } catch {
      logger.error("Failed to harvest incoming channel paths: \(error)")
    }
    if let refreshed = try await dependencies.dataStore.fetchMessage(id: messageDTO.id) {
      return refreshed
    }
    return messageDTO
  }

  /// True when a row already owns this content key. A known distinct channel path
  /// is recorded as an extra; a nil path is unknown and is not written as one.
  private func recordArrivalAndSkipDuplicate(
    resolvedKind: IncomingMessageKind,
    deduplicationKey: String,
    radioID: UUID,
    rxResult: RxLogLookupResult,
    snr: Double?,
    receiveTime: Date,
    dependencies: SyncDependencies
  ) async -> Bool {
    do {
      guard let existing = try await dependencies.dataStore.fetchMessage(
        deduplicationKey: deduplicationKey,
        radioID: radioID
      ) else {
        return false
      }
      if case .channel = resolvedKind {
        guard let path = rxResult.pathNodes else {
          logger.debug("Skipping duplicate \(resolvedKind.logLabel) message")
          return true
        }
        await dependencies.heardRepeatsService.recordDistinctPathIfNeeded(
          message: existing,
          pathNodes: path,
          pathLength: rxResult.pathLength,
          snr: snr,
          rssi: nil,
          receivedAt: receiveTime,
          rxLogEntryID: nil
        )
      }
      logger.debug("Skipping duplicate \(resolvedKind.logLabel) message")
      return true
    } catch {
      logger.warning("Dedup check failed, proceeding with save: \(error)")
      return false
    }
  }

  /// Shared ingestion pipeline for incoming direct and channel messages:
  /// timestamp correction, RX-log path correlation, dedup, reaction
  /// short-circuit, persistence, unread/notification updates, and UI refresh.
  private func handleIncomingMessage(
    kind: IncomingMessageKind,
    context: DeliveryContext,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async {
    let selfNodeName = await currentSelfNodeName(radioID: radioID, dataStore: dependencies.dataStore)

    // A DM can land in the advert delta-sync debounce window before the local
    // Contact row exists. Materialize from a pending 0x80 key so unread,
    // notification, and Chats-list updates use the live path exactly once.
    let resolvedKind = await resolveDirectContactIfNeeded(
      kind, dependencies: dependencies, radioID: radioID
    )

    // Per-kind wire fields. Channel messages embed the sender as a
    // "NodeName: text" prefix; direct messages carry the sender key prefix.
    let text: String
    let senderNodeName: String?
    let senderTimestampDate: Date
    let textTypeRaw: UInt8
    let snr: Double?
    let reportedPathLength: UInt8
    let contactID: UUID?
    let channelIndex: UInt8?
    let senderKeyPrefix: Data?
    switch resolvedKind {
    case let .direct(message, contact):
      // The firmware cannot surface a self-DM here: decrypt runs against a
      // contact's ECDH shared secret and the local self_id is never in
      // contacts[], so an echo of the user's own DM never reaches this arm.
      text = message.text
      senderNodeName = nil
      senderTimestampDate = message.senderTimestamp
      textTypeRaw = message.textType
      snr = message.snr
      reportedPathLength = message.pathLength
      contactID = contact?.id
      channelIndex = nil
      senderKeyPrefix = message.senderPublicKeyPrefix
    case let .channel(message, _):
      // Parse "NodeName: text" format for sender name
      (senderNodeName, text) = Self.parseChannelMessage(message.text)
      senderTimestampDate = message.senderTimestamp
      textTypeRaw = message.textType
      snr = message.snr
      reportedPathLength = message.pathLength
      contactID = nil
      channelIndex = message.channelIndex
      senderKeyPrefix = nil
    }

    let timestamp = UInt32(senderTimestampDate.timeIntervalSince1970)

    // Correct invalid timestamps (sender clock wrong). History is judged against when the board
    // stored it, not now.
    let receiveTime = context.receiveTime()
    let (finalTimestamp, timestampCorrected) = Self.correctTimestampIfNeeded(timestamp, receiveTime: receiveTime)
    if timestampCorrected {
      logger.debug("Corrected invalid \(resolvedKind.logLabel) message timestamp from \(Date(timeIntervalSince1970: TimeInterval(timestamp))) to \(receiveTime)")
    }

    let sortDate = Self.sortDate(for: context, receiveTime: receiveTime)

    // Use content-based key for dedup (stable across retry attempts).
    // The RX log packetHash is per-encrypted-packet and differs between
    // retries with different attempt counters, so it must not drive dedup.
    let deduplicationKey = Self.fallbackDeduplicationKey(
      contactID: contactID, channelIndex: channelIndex,
      senderNodeName: senderNodeName, timestamp: timestamp, content: text
    )

    // Channel lookup joins decrypted 0x88 rows by DeduplicationKey; DMs still
    // match timestamp then sender-prefix.
    let rxResult = await lookupRxLogEntry(
      dependencies: dependencies,
      radioID: radioID,
      channelIndex: channelIndex,
      senderTimestamp: timestamp,
      senderPublicKeyPrefix: senderKeyPrefix,
      defaultPathLength: reportedPathLength,
      channelDeduplicationKey: channelIndex != nil ? deduplicationKey : nil
    )

    // Check for self-mention before creating DTO
    // For channel messages, filter out messages where the user mentions themselves
    let hasSelfMention: Bool = switch resolvedKind {
    case .direct:
      !selfNodeName.isEmpty &&
        MentionUtilities.containsSelfMention(in: text, selfName: selfNodeName)
    case .channel:
      !selfNodeName.isEmpty &&
        senderNodeName != selfNodeName &&
        MentionUtilities.containsSelfMention(in: text, selfName: selfNodeName)
    }

    // Clamp an unknown wire textType to .plain. MessageDTO decodes textType
    // non-optionally, so an out-of-range raw value would throw and fail the
    // whole envelope decode on backup round-trip; guaranteeing only the
    // known cases reach persistence keeps that round-trip safe.
    let resolvedTextType: TextType
    if let parsed = TextType(rawValue: textTypeRaw) {
      resolvedTextType = parsed
    } else {
      logger.warning("Unknown \(resolvedKind.logLabel) message textType raw=\(textTypeRaw); clamping to .plain")
      resolvedTextType = .plain
    }

    // regionScope is incoming-only by data-pipeline design — outgoing
    // messages do not flow through 0x88 / RxLogEntry correlation.
    let messageDTO = MessageDTO(
      id: UUID(),
      radioID: radioID,
      contactID: contactID,
      channelIndex: channelIndex,
      text: text,
      timestamp: finalTimestamp,
      createdAt: receiveTime,
      sortDate: sortDate,
      direction: .incoming,
      status: .delivered,
      textType: resolvedTextType,
      ackCode: nil,
      pathLength: rxResult.pathLength,
      snr: snr,
      pathNodes: rxResult.pathNodes,
      senderKeyPrefix: senderKeyPrefix,
      senderNodeName: senderNodeName,
      isRead: context.isHistory,   // seen on the board already
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      deduplicationKey: deduplicationKey,
      containsSelfMention: hasSelfMention,
      mentionSeen: false,
      timestampCorrected: timestampCorrected,
      senderTimestamp: timestampCorrected ? timestamp : nil,
      routeType: rxResult.routeType,
      regionScope: rxResult.regionScope,
      regionScopeMatches: rxResult.regionScopeMatches
    )

    if await recordArrivalAndSkipDuplicate(
      resolvedKind: resolvedKind,
      deduplicationKey: deduplicationKey,
      radioID: radioID,
      rxResult: rxResult,
      snr: snr,
      receiveTime: receiveTime,
      dependencies: dependencies
    ) {
      return
    }

    // Stamp before the reaction early return so bodies and reactions both count. Not for history:
    // it says nothing about the contact being heard now.
    if !context.isHistory, case let .direct(_, contact) = resolvedKind, let contact {
      do {
        _ = try await dependencies.dataStore.touchContactHeard(
          radioID: radioID,
          publicKey: contact.publicKey,
          at: Date()
        )
      } catch {
        logger.error(
          "lastHeard stamp failed for inbound DM: \(error.localizedDescription)"
        )
      }
    }

    switch resolvedKind {
    case let .direct(_, contact):
      // Check if this is a DM reaction
      if let contact,
         await handleDMReaction(
           text: text,
           contact: contact,
           radioID: radioID,
           dependencies: dependencies
         ) {
        return
      }
    case let .channel(message, _):
      // Discard messages from blocked senders or containing a blocked keyword
      if isBlockedChannelMessage(senderNodeName: senderNodeName, text: text) {
        return
      }

      // Check if this is a reaction
      if await handleChannelReaction(
        text: text,
        channelIndex: message.channelIndex,
        senderNodeName: senderNodeName,
        selfNodeName: selfNodeName,
        receiveTime: receiveTime,
        radioID: radioID,
        dependencies: dependencies
      ) {
        return
      }
    }

    do {
      try await dependencies.dataStore.saveMessage(messageDTO)
      // A DM whose sender has no contact row yet (the background drain runs before the contact
      // phase): the contact phase links it and posts its banner (adoptPendingOrphanDirectMessages).
      if !context.isHistory, case let .direct(_, contact) = resolvedKind, contact == nil,
         let senderKeyPrefix, !senderKeyPrefix.isEmpty {
        notePendingOrphanSender(senderKeyPrefix)
      }
      var savedDTO = messageDTO
      if case .channel = resolvedKind {
        savedDTO = try await harvestAndRefreshChannelMessage(
          messageDTO: messageDTO,
          radioID: radioID,
          dependencies: dependencies
        )
      }

      switch resolvedKind {
      case let .direct(_, contact):
        try await indexAndNotifyDirectMessage(
          messageDTO: savedDTO,
          contact: contact,
          messageText: text,
          timestamp: timestamp,
          hasSelfMention: hasSelfMention,
          history: context.isHistory,
          dependencies: dependencies,
          radioID: radioID
        )
      case let .channel(message, channel):
        try await indexAndNotifyChannelMessage(
          messageDTO: savedDTO,
          channel: channel,
          channelIndex: message.channelIndex,
          senderNodeName: senderNodeName,
          messageText: text,
          timestamp: timestamp,
          hasSelfMention: hasSelfMention,
          history: context.isHistory,
          dependencies: dependencies,
          radioID: radioID
        )
      }

      // History arrives a page at a time: the importer refreshes the lists once per page
      guard !context.isHistory else { return }

      // Notify conversation list of changes
      await notifyConversationsChanged()

      // Broadcast for real-time chat updates
      if case let .direct(_, contact) = resolvedKind, let contact {
        dataEventBroadcaster.yield(.directMessageReceived(message: savedDTO, contact: contact))
      }
    } catch {
      switch resolvedKind {
      case .direct:
        logger.error("Failed to save contact message: \(error)")
      case .channel:
        logger.error("Failed to save channel message: \(error)")
      }
    }
  }

  /// Post-save side effects for a direct message: reaction indexing, contact
  /// bookkeeping, and unread/notification updates.
  private func indexAndNotifyDirectMessage(
    messageDTO: MessageDTO,
    contact: ContactDTO?,
    messageText: String,
    timestamp: UInt32,
    hasSelfMention: Bool,
    history: Bool = false,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async throws {
    // Index DM message for reaction targeting
    if let contact {
      let pendingMatches = await dependencies.reactionService.indexDMMessage(
        id: messageDTO.id,
        contactID: contact.id,
        text: messageText,
        timestamp: timestamp
      )

      // Process pending reactions that now have their target
      for pending in pendingMatches {
        let reactionDTO = ReactionDTO(
          messageID: messageDTO.id,
          emoji: pending.parsed.emoji,
          senderName: pending.senderName,
          messageHash: pending.parsed.messageHash,
          rawText: pending.rawText,
          contactID: contact.id,
          radioID: radioID
        )
        if await persistReactionIfNew(reactionDTO, dependencies: dependencies) {
          logger.debug("Processed pending DM reaction \(pending.parsed.emoji)")
        }
      }
    }

    // Update contact's last message date (history: its own date, and only ever forward)
    if let contactID = contact?.id {
      if !history {
        try await dependencies.dataStore.updateContactLastMessage(contactID: contactID, date: Date())
      } else if contact?.lastMessageDate.map({ $0 < messageDTO.sortDate }) ?? true {
        try await dependencies.dataStore.updateContactLastMessage(contactID: contactID, date: messageDTO.sortDate)
      }
    }

    // Only increment unread count, post notification, and update badge for non-blocked contacts;
    // never for history (read on the board already)
    if !history, let contactID = contact?.id, contact?.isBlocked != true {
      try await updateDMUnreadsAndNotify(
        messageDTO: messageDTO,
        contactID: contactID,
        contact: contact,
        messageText: messageText,
        hasSelfMention: hasSelfMention,
        dependencies: dependencies
      )
    }
  }

  /// Post-save side effects for a channel message: reaction indexing, channel
  /// bookkeeping, and unread/notification updates.
  private func indexAndNotifyChannelMessage(
    messageDTO: MessageDTO,
    channel: ChannelDTO?,
    channelIndex: UInt8,
    senderNodeName: String?,
    messageText: String,
    timestamp: UInt32,
    hasSelfMention: Bool,
    history: Bool = false,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async throws {
    // Index message for reaction matching and process any pending reactions
    // Use original timestamp for indexing so pending reactions can match
    if let senderName = senderNodeName {
      let pendingMatches = await dependencies.reactionService.indexMessage(
        id: messageDTO.id,
        channelIndex: channelIndex,
        senderName: senderName,
        text: messageText,
        timestamp: timestamp
      )

      // Process any pending reactions that now have their target
      for pending in pendingMatches {
        let reactionDTO = ReactionDTO(
          messageID: messageDTO.id,
          emoji: pending.parsed.emoji,
          senderName: pending.senderNodeName,
          messageHash: pending.parsed.messageHash,
          rawText: pending.rawText,
          channelIndex: pending.channelIndex,
          radioID: pending.radioID
        )
        await persistReactionIfNew(reactionDTO, dependencies: dependencies)
      }
    }

    // Update channel's last message date (history: its own date, and only ever forward)
    if let channelID = channel?.id {
      if !history {
        try await dependencies.dataStore.updateChannelLastMessage(channelID: channelID, date: Date())
      } else if channel?.lastMessageDate.map({ $0 < messageDTO.sortDate }) ?? true {
        try await dependencies.dataStore.updateChannelLastMessage(channelID: channelID, date: messageDTO.sortDate)
      }
    }

    // Only update unread count, badges, and notify UI for non-blocked senders; never for history
    if !history, !isBlockedSender(senderNodeName) {
      try await updateChannelUnreadsAndNotify(
        messageDTO: messageDTO,
        channel: channel,
        channelIndex: channelIndex,
        senderNodeName: senderNodeName,
        messageText: messageText,
        timestamp: timestamp,
        hasSelfMention: hasSelfMention,
        radioID: radioID,
        dependencies: dependencies
      )
    }
  }

  // MARK: - Signed Message Handler

  private func wireSignedMessageHandler(dependencies: SyncDependencies) async {
    await dependencies.messagePollingService.setSignedMessageHandler { [weak self] message, _ in
      guard let self else { return }
      await handleIncomingSignedMessage(message, dependencies: dependencies)
    }
  }

  /// Persists a signed room message via `RoomServerService`, then posts the
  /// notification and refreshes the UI when the message was new.
  private func handleIncomingSignedMessage(_ message: ContactMessage, dependencies: SyncDependencies) async {
    // For signed room messages, the signature contains the 4-byte author key prefix
    guard let authorPrefix = message.signature?.prefix(4), authorPrefix.count == 4 else {
      logger.warning("Dropping signed message: missing or invalid author prefix")
      return
    }

    let timestamp = UInt32(message.senderTimestamp.timeIntervalSince1970)

    do {
      let savedMessage = try await dependencies.roomServerService.handleIncomingMessage(
        senderPublicKeyPrefix: message.senderPublicKeyPrefix,
        timestamp: timestamp,
        authorPrefix: Data(authorPrefix),
        text: message.text
      )

      // If message was saved (not a duplicate), notify UI and post notification
      if let savedMessage {
        // Fetch session for room name and mute status
        let session = try? await dependencies.dataStore.fetchRemoteNodeSession(id: savedMessage.sessionID)
        let senderName = await roomAuthorLabel(savedMessage, session: session, dependencies: dependencies)

        // Post notification for room message
        await dependencies.notificationService.postRoomMessageNotification(
          roomName: session?.name ?? "Room",
          sessionID: savedMessage.sessionID,
          senderName: senderName,
          messageText: savedMessage.text,
          messageID: savedMessage.id,
          notificationLevel: session?.notificationLevel ?? .all
        )
        await dependencies.notificationService.updateBadgeCount()

        await notifyConversationsChanged()
        dataEventBroadcaster.yield(.roomMessageReceived(savedMessage))
      }
    } catch {
      logger.error("Failed to handle room message: \(error)")
    }
  }

  // MARK: - CLI Message Handler

  private func wireCLIMessageHandler(dependencies: SyncDependencies) async {
    await dependencies.messagePollingService.setCLIMessageHandler { [weak self] message, contact in
      guard let self else { return }
      await handleIncomingCLIMessage(message, contact: contact, dependencies: dependencies)
    }
  }

  /// Routes a CLI response to the room or repeater admin service for the sending contact;
  /// another companion's reply is only audit-logged.
  /// A wire prefix echoed by the firmware is stripped first so downstream
  /// parsers see the same reply text regardless of firmware echo support.
  private func handleIncomingCLIMessage(
    _ message: ContactMessage,
    contact: ContactDTO?,
    dependencies: SyncDependencies
  ) async {
    if let contact {
      let routed: ContactMessage = if let echoed = CLIResponse.splitEchoedPrefix(message.text) {
        ContactMessage(
          senderPublicKeyPrefix: message.senderPublicKeyPrefix,
          pathLength: message.pathLength,
          textType: message.textType,
          senderTimestamp: message.senderTimestamp,
          signature: message.signature,
          text: echoed.body,
          snr: message.snr
        )
      } else {
        message
      }

      if contact.type == .room {
        await dependencies.roomAdminService.invokeCLIHandler(routed, fromContact: contact)
      } else if contact.type == .chat {
        // Another companion's reply: `RemoteNodeService` already matched it to its
        // command by tag, so a repeater page never sees it.
        await dependencies.repeaterAdminService.auditCLIResponse(routed, fromContact: contact)
      } else {
        await dependencies.repeaterAdminService.invokeCLIHandler(routed, fromContact: contact)
      }
    } else {
      logger.warning("Dropping CLI response: no contact found for sender")
    }
  }

  // MARK: - Discovery Event Monitoring

  /// Consumes the advertisement event stream to post new-contact
  /// notifications and refresh contact lists. The subscription is
  /// registered synchronously before this method returns; events yielded
  /// earlier (during the initial sync) are deliberately not seen.
  func startDiscoveryEventMonitoring(dependencies: SyncDependencies, radioID: UUID) {
    logger.info("Starting discovery event monitoring for device \(radioID)")
    discoveryEventsTask?.cancel()
    let events = dependencies.advertisementService.events()
    discoveryEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case let .newContactDiscovered(name, contactID, contactType):
          // Manual-add mode: a new contact was discovered via advertisement
          PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "discover-trace")
            .debug("B4 relay newContactDiscovered \(contactID) -> notifyContactsChanged")
          await dependencies.notificationService.postNewContactNotification(
            contactName: name,
            contactID: contactID,
            contactType: contactType
          )
          await notifyContactsChanged()
        case let .orphanDirectMessagesAdopted(contactIDs):
          await postAdoptedDirectMessageNotifications(
            contactIDs: contactIDs,
            dataStore: dependencies.dataStore,
            notificationService: dependencies.notificationService
          )
        case .contactUpdated:
          // A contact's name or nickname may have changed: sender labels and session names follow.
          await contactsDidChange()
        case .conversationsChanged, .nodeStorageFullChanged, .advertReceived,
             .contactDeletedCleanup, .pathDiscoveryResponse, .contactPathUpdated, .traceResponse,
             .traceSnrObserved, .traceProgress:
          break
        }
      }
    }
  }

  /// DMs that arrived before their sender's contact existed got no banner or badge at receipt.
  /// Adoption bumped the unread counts; post the banner and refresh the badge now, once per
  /// contact. The final badge refresh also covers a muted contact, whose unread rose but whose
  /// suppressed banner never updates the badge itself.
  func postAdoptedDirectMessageNotifications(
    contactIDs: [UUID],
    dataStore: any PersistenceStoreProtocol,
    notificationService: NotificationService
  ) async {
    for contactID in contactIDs {
      do {
        guard let contact = try await dataStore.fetchContact(id: contactID),
              !contact.isBlocked,
              let message = try await dataStore.newestUnreadIncomingMessage(contactID: contactID)
        else { continue }
        await notificationService.postDirectMessageNotification(
          from: contact.displayName,
          contactID: contactID,
          messageText: message.text,
          messageID: message.id,
          isMuted: contact.isMuted
        )
      } catch {
        logger.error(
          "Adopted DM notification failed for \(contactID): \(error.localizedDescription)"
        )
      }
    }
    await notificationService.updateBadgeCount()
  }

  /// Cancels the discovery event task so it releases the service references
  /// it captures. Called by `ServiceContainer.tearDown()`.
  func cancelDiscoveryEventMonitoring() {
    discoveryEventsTask?.cancel()
    discoveryEventsTask = nil
  }

  // MARK: - Static Helpers

  nonisolated static func fallbackDeduplicationKey(
    contactID: UUID?,
    channelIndex: UInt8?,
    senderNodeName: String?,
    timestamp: UInt32,
    content: String
  ) -> String {
    DeduplicationKey.contentBased(
      contactID: contactID,
      channelIndex: channelIndex,
      senderNodeName: senderNodeName,
      timestamp: timestamp,
      content: content
    )
  }

  /// Splits decrypted channel text into its sender and body through the one shared parser, so
  /// the deduplication key saved here matches the key RX-log correlation rebuilds later.
  nonisolated static func parseChannelMessage(_ text: String) -> (senderNodeName: String?, messageText: String) {
    ChannelMessageFormat.split(text)
  }

  /// A received channel message only warrants a user notification when it resolves to a known
  /// local channel. The radio can report a message on a slot the app has no `Channel` for: the
  /// firmware decrypts zero-key group traffic on an unconfigured slot and attributes it to the
  /// first empty slot. Such messages have no openable chat, so they are logged as unresolved
  /// but never surfaced as a notification.
  nonisolated static func shouldPostChannelNotification(forResolvedChannel channel: ChannelDTO?) -> Bool {
    channel != nil
  }
}
