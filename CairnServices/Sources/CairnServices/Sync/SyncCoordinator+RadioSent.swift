// SyncCoordinator+RadioSent.swift
import Foundation

// MARK: - Messages Sent From the Radio's Own UI

/// Cairn firmware echoes each message its user composes on the radio itself, so the
/// conversation here shows it too (examples/companion_radio/ui-l2/net/SENT_SYNC.md in the
/// firmware repo). Echo rows are outgoing, `sentFromRadio`, read, and owned by the radio:
/// they never enter `pendingAcks`, the ACK expiry sweep, the send queue or a resend.
extension SyncCoordinator {
  /// Earliest wire timestamp treated as a set clock (2024-01-01T00:00:00Z).
  nonisolated static let radioSentEarliestValidTimestamp: UInt32 = 1_704_067_200
  /// How far ahead of the phone a radio clock may run before its timestamp is distrusted.
  nonisolated static let radioSentFutureTolerance: TimeInterval = 86_400

  func wireRadioSentMessageHandler(dependencies: SyncDependencies, radioID: UUID) async {
    await dependencies.messagePollingService.setRadioSentMessageHandler { [weak self] message, context in
      guard let self else { return }
      await handleRadioSentMessage(
        message,
        context: context,
        dependencies: dependencies,
        radioID: radioID
      )
    }
  }

  func handleRadioSentMessage(
    _ message: RadioSentMessage,
    context: DeliveryContext = .live,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async {
    switch message.kind {
    case .direct, .channel:
      if message.isLive {
        dataEventBroadcaster.yield(.radioSentMessage(message))
      }
      await storeRadioSentEcho(
        message,
        context: context,
        dependencies: dependencies,
        radioID: radioID
      )
    case .statusUpdate:
      await applyRadioSentStatusUpdate(message, dependencies: dependencies, radioID: radioID)
    }
  }

  // MARK: - Echo (kinds 0, 1)

  private func storeRadioSentEcho(
    _ message: RadioSentMessage,
    context: DeliveryContext,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async {
    let dataStore = dependencies.dataStore
    // The name the radio put on air for a channel echo: its node name now.
    let selfNodeName = await currentSelfNodeName(radioID: radioID, dataStore: dataStore)
    let channelIndex = message.channelIndex
    var contact: ContactDTO?
    var channel: ChannelDTO?
    if let channelIndex {
      // No Channel row for this slot is handled as for a received channel message: the row is
      // saved under the index and shows once a channel is configured there.
      channel = try? await dataStore.fetchChannel(radioID: radioID, index: channelIndex)
    } else {
      contact = await resolveRadioSentContact(message.destination, dependencies: dependencies, radioID: radioID)
      guard let resolved = contact else {
        logger.warning("Dropping radio-sent DM echo: no contact for prefix \(message.destination.uppercaseHexString())")
        return
      }
      // On the radio a room post is a DM to the room's contact. It is the user's post in that
      // room, never a direct conversation with the room server.
      if resolved.type == .room {
        await storeRadioSentRoomPost(message, context: context, dependencies: dependencies)
        return
      }
    }

    let deduplicationKey = DeduplicationKey.radioSent(
      destination: message.destination,
      channelIndex: channelIndex,
      timestamp: message.timestamp,
      content: message.text
    )

    // History: a message this app sent itself is already here under its own key (same wire
    // timestamp and text, the board keeps the exact timestamp that went out): nothing to add.
    if context.isHistory,
       await hasAppSentCopy(message, contactID: contact?.id, channelIndex: channelIndex, dataStore: dataStore, radioID: radioID) {
      return
    }

    // A second copy (live push also synced, snapshot replay) only merges: delivered upgrades.
    if let existing = try? await dataStore.fetchMessage(deduplicationKey: deduplicationKey, radioID: radioID) {
      if message.isDelivered {
        await publishRadioSentStatus(
          radioID: radioID,
          contactID: existing.contactID,
          channelIndex: existing.channelIndex,
          timestamp: existing.timestamp,
          ackCode: existing.ackCode,
          status: .delivered,
          roundTripTime: nil,
          dependencies: dependencies
        )
      }
      logger.debug("Radio-sent echo already stored; merged")
      return
    }

    let receiveTime = context.receiveTime()
    let clockUnset = Self.isRadioSentClockUnset(message.timestamp, receiveTime: receiveTime)
    // createdAt: when it was sent if the clock was set, else its arrival here. sortDate follows
    // the same rule as received messages (drain anchor for backlog, receive time when live), so
    // an echo sits in event order with the messages around it, not at the board's send time.
    let sentDate = clockUnset ? receiveTime : Date(timeIntervalSince1970: TimeInterval(message.timestamp))
    let sortDate = Self.sortDate(for: context, receiveTime: receiveTime)

    let isDirect = channelIndex == nil
    let messageDTO = MessageDTO(
      id: UUID(),
      radioID: radioID,
      contactID: contact?.id,
      channelIndex: channelIndex,
      text: message.text,
      // Raw wire timestamp even when the clock is unset: dedupe and ACK matching key off it.
      timestamp: message.timestamp,
      createdAt: sentDate,
      sortDate: sortDate,
      direction: .outgoing,
      status: message.isDelivered && isDirect ? .delivered : .sent,
      textType: .plain,
      ackCode: isDirect && message.ackCode != 0 ? message.ackCode : nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      deduplicationKey: deduplicationKey,
      timestampCorrected: clockUnset,
      senderTimestamp: clockUnset ? message.timestamp : nil,
      sentFromRadio: true,
      sentAsNodeName: isDirect || selfNodeName.isEmpty ? nil : selfNodeName
    )

    do {
      try await dataStore.saveMessage(messageDTO)
    } catch {
      logger.error("Failed to save radio-sent echo: \(error)")
      return
    }

    // Reactions others send to this message hash its text and wire timestamp.
    if let channelIndex {
      if !selfNodeName.isEmpty {
        _ = await dependencies.reactionService.indexMessage(
          id: messageDTO.id,
          channelIndex: channelIndex,
          senderName: selfNodeName,
          text: message.text,
          timestamp: message.timestamp
        )
      }
      if let channelID = channel?.id, !context.isHistory || (channel?.lastMessageDate.map { $0 < receiveTime } ?? true) {
        try? await dataStore.updateChannelLastMessage(channelID: channelID, date: receiveTime)
      }
    } else if let contact {
      _ = await dependencies.reactionService.indexDMMessage(
        id: messageDTO.id,
        contactID: contact.id,
        text: message.text,
        timestamp: message.timestamp
      )
      if !context.isHistory || (contact.lastMessageDate.map { $0 < receiveTime } ?? true) {
        try? await dataStore.updateContactLastMessage(contactID: contact.id, date: receiveTime)
      }
    }

    logger.info("Stored radio-sent \(isDirect ? "DM" : "channel") echo (live=\(message.isLive))")

    // Outgoing: no unread count, notification or badge change. Refresh lists and open chats
    // (history: once per page, by the importer).
    guard !context.isHistory else { return }
    await notifyConversationsChanged()
    if let channelIndex {
      dataEventBroadcaster.yield(.channelMessageReceived(message: messageDTO, channelIndex: channelIndex))
    } else if let contact {
      dataEventBroadcaster.yield(.directMessageReceived(message: messageDTO, contact: contact))
    }
  }

  /// The contact a DM echo names, refreshing contacts from the radio once per unknown prefix.
  private func resolveRadioSentContact(
    _ prefix: Data,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async -> ContactDTO? {
    let dataStore = dependencies.dataStore
    if let contact = try? await dataStore.fetchContact(radioID: radioID, publicKeyPrefix: prefix) {
      return contact
    }
    let key = prefix.uppercaseHexString()
    guard radioSentContactRefreshes.insert(key).inserted else { return nil }
    if let materialized = await dependencies.advertisementService
      .materializeContactForPendingAdvert(matchingPrefix: prefix, radioID: radioID) {
      return materialized
    }
    do {
      _ = try await dependencies.contactService.syncContacts(radioID: radioID, since: nil)
      await notifyContactsChanged()
    } catch {
      logger.warning("Contact refresh for a radio-sent DM failed: \(error.localizedDescription)")
    }
    return try? await dataStore.fetchContact(radioID: radioID, publicKeyPrefix: prefix)
  }

  /// A room post the user wrote on the radio (live echo or history record), filed as their own
  /// post in the room. With no room session on this radio it is left out, as incoming room posts
  /// with no session are: it is never filed as a DM to the room.
  private func storeRadioSentRoomPost(
    _ message: RadioSentMessage,
    context: DeliveryContext,
    dependencies: SyncDependencies
  ) async {
    let receiveTime = context.receiveTime()
    let clockUnset = Self.isRadioSentClockUnset(message.timestamp, receiveTime: receiveTime)
    do {
      guard let post = try await dependencies.roomServerService.storeOwnPost(
        roomPublicKeyPrefix: message.destination,
        timestamp: message.timestamp,
        text: message.text,
        isDelivered: message.isDelivered,
        createdAt: clockUnset ? receiveTime : Date(timeIntervalSince1970: TimeInterval(message.timestamp))
      ) else { return }
      logger.info("Stored radio-sent room post (live=\(message.isLive))")
      guard !context.isHistory else { return }
      await notifyConversationsChanged()
      dataEventBroadcaster.yield(.roomMessageReceived(post))
    } catch {
      logger.error("Failed to store radio-sent room post: \(error)")
    }
  }

  // MARK: - Status update (kind 2)

  private func applyRadioSentStatusUpdate(
    _ message: RadioSentMessage,
    dependencies: SyncDependencies,
    radioID: UUID
  ) async {
    let status: MessageStatus
    switch message.deliveryStatus {
    case .delivered: status = .delivered
    case .failed: status = .failed
    case .other, nil:
      logger.debug("Ignoring radio-sent status update with an unknown status")
      return
    }

    // The destination names the conversation: a DM by key prefix, a channel by slot. With no
    // stored row yet (its echo was lost), the update is ignored.
    var contactID: UUID?
    var channelIndex: UInt8?
    let isChannel = message.destination.dropFirst().allSatisfy { $0 == 0 }
      && message.ackCode == 0
    if isChannel {
      channelIndex = message.destination.first
    } else {
      let contact = try? await dependencies.dataStore
        .fetchContact(radioID: radioID, publicKeyPrefix: message.destination)
      if contact?.type == .room {
        // A room post the user wrote on the radio: its status belongs to the room post.
        if let postID = try? await dependencies.roomServerService.applyOwnPostStatus(
          roomPublicKeyPrefix: message.destination,
          timestamp: message.timestamp,
          status: status,
          roundTripTime: message.roundTripTime
        ) {
          logger.debug("Applied radio-sent status to room post \(postID)")
        }
        return
      }
      contactID = contact?.id
    }

    await publishRadioSentStatus(
      radioID: radioID,
      contactID: contactID,
      channelIndex: channelIndex,
      timestamp: message.timestamp,
      ackCode: message.ackCode,
      status: status,
      roundTripTime: message.roundTripTime,
      dependencies: dependencies
    )
  }

  /// Writes delivered / failed onto a radio-sent row and tells open chats and lists.
  private func publishRadioSentStatus(
    radioID: UUID,
    contactID: UUID?,
    channelIndex: UInt8?,
    timestamp: UInt32,
    ackCode: UInt32?,
    status: MessageStatus,
    roundTripTime: UInt32?,
    dependencies: SyncDependencies
  ) async {
    let changedID: UUID?
    do {
      changedID = try await dependencies.dataStore.applyRadioSentStatus(
        radioID: radioID,
        contactID: contactID,
        channelIndex: channelIndex,
        timestamp: timestamp,
        ackCode: ackCode,
        status: status,
        roundTripTime: roundTripTime
      )
    } catch {
      logger.error("Failed to apply radio-sent status: \(error)")
      return
    }
    guard let changedID else { return }
    if status == .failed {
      dependencies.publishMessageStatus(.failed(messageID: changedID))
    } else {
      dependencies.publishMessageStatus(
        .statusResolved(messageID: changedID, status: status, roundTripTime: roundTripTime)
      )
    }
    await notifyConversationsChanged()
  }

  /// The radio's clock wasn't set when it sent: before 2024 or more than a day ahead.
  nonisolated static func isRadioSentClockUnset(_ timestamp: UInt32, receiveTime: Date = Date()) -> Bool {
    timestamp < radioSentEarliestValidTimestamp
      || TimeInterval(timestamp) > receiveTime.timeIntervalSince1970 + radioSentFutureTolerance
  }
}

// MARK: - History (own sends)

extension SyncCoordinator {
  /// A board history record of a message this app sent: stored here already when an outgoing
  /// message of this conversation has the same wire timestamp and text.
  func hasAppSentCopy(
    _ message: RadioSentMessage,
    contactID: UUID?,
    channelIndex: UInt8?,
    dataStore: any PersistenceStoreProtocol,
    radioID: UUID
  ) async -> Bool {
    if let channelIndex {
      let found = try? await dataStore.findSentChannelMessage(
        radioID: radioID, channelIndex: channelIndex, timestamp: message.timestamp, text: message.text
      )
      return found != nil
    }
    guard let contactID else { return false }
    let candidates = (try? await dataStore.fetchDMMessageCandidates(
      radioID: radioID, contactID: contactID, timestampWindow: message.timestamp...message.timestamp, limit: 8
    )) ?? []
    return candidates.contains { $0.direction == .outgoing && $0.text == message.text }
  }
}
