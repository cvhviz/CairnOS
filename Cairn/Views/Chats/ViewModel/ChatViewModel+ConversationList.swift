import CairnServices
import SwiftUI

extension ChatViewModel {
  // MARK: - Notification Level

  /// Sets notification level for a conversation with optimistic UI update. An app-only
  /// SwiftData write for every conversation kind, so it needs no radio.
  func setNotificationLevel(_ conversation: Conversation, level: NotificationLevel) async {
    let originalLevel = conversation.notificationLevel

    // Capture once so the write and the badge update target the same container.
    let dataStore = dataStore
    let notificationService = notificationService

    // Optimistic UI update
    updateConversationNotificationLevel(conversation, level: level)

    do {
      switch conversation {
      case let .direct(contact):
        // Contacts still use boolean muted
        try await dataStore?.setContactMuted(contact.id, isMuted: level == .muted)
      case let .channel(channel):
        try await dataStore?.setChannelNotificationLevel(channel.id, level: level)
      case let .room(session):
        try await dataStore?.setSessionNotificationLevel(session.id, level: level)
      }
      await notificationService?.updateBadgeCount()
    } catch {
      // Rollback on failure
      updateConversationNotificationLevel(conversation, level: originalLevel)
      logger.error("Failed to set notification level: \(error)")
      errorMessage = error.userFacingMessage
    }
  }

  /// Live row for `id` from the fetch buffers.
  /// Swipe chrome keeps the value from first reveal, so toggles must not use that snapshot.
  func liveConversation(id: UUID) -> Conversation? {
    if let contact = conversations.first(where: { $0.id == id }) {
      return .direct(contact)
    }
    if let channel = channels.first(where: { $0.id == id }) {
      return .channel(channel)
    }
    if let session = roomSessions.first(where: { $0.id == id }) {
      return .room(session)
    }
    return nil
  }

  func toggleMute(_ conversation: Conversation) async {
    guard let current = liveConversation(id: conversation.id) else { return }
    let newLevel: NotificationLevel = current.isMuted ? .all : .muted
    await setNotificationLevel(current, level: newLevel)
  }

  /// Updates the notification level in the local conversations array
  private func updateConversationNotificationLevel(_ conversation: Conversation, level: NotificationLevel) {
    updateConversation(
      conversation,
      direct: { $0.with(isMuted: level == .muted) },
      channel: { $0.with(notificationLevel: level) },
      room: { $0.with(notificationLevel: level) }
    )
  }

  // MARK: - Mark as Read

  /// Clears a conversation's unread state without opening it: the same
  /// bookkeeping a conversation open performs, minus loading messages. Works
  /// offline, since unread counts live in the local store.
  func markAsRead(_ conversation: Conversation) async {
    guard let current = liveConversation(id: conversation.id), current.unreadCount > 0 else { return }
    let dataStore = dataStore
    let notificationService = notificationService

    do {
      switch current {
      case let .direct(contact):
        try await dataStore?.clearUnreadCount(contactID: contact.id)
        try await dataStore?.clearUnreadMentionCount(contactID: contact.id)
        await notificationService?.removeDeliveredNotifications(forContactID: contact.id)
      case let .channel(channel):
        try await dataStore?.clearChannelUnreadCount(channelID: channel.id)
        try await dataStore?.clearChannelUnreadMentionCount(channelID: channel.id)
        await notificationService?.removeDeliveredNotifications(
          forChannelIndex: channel.index,
          radioID: channel.radioID
        )
      case let .room(session):
        try await dataStore?.resetRoomUnreadCount(session.id)
        await notificationService?.removeDeliveredNotifications(forRoomSessionID: session.id)
      }
    } catch {
      logger.error("Failed to mark conversation as read: \(error)")
      return
    }

    await notificationService?.updateBadgeCount()
    await requestConversationReload()?.value
  }

  /// Flags a read conversation unread (count 1) without a new message, so it surfaces under the
  /// Unread filter and keeps its badge until opened. A local store write; the increment from
  /// zero is what sets the count to one. No-op while the conversation already counts unread.
  func markAsUnread(_ conversation: Conversation) async {
    guard let current = liveConversation(id: conversation.id), current.unreadCount == 0 else { return }
    let dataStore = dataStore
    let notificationService = notificationService

    do {
      switch current {
      case let .direct(contact):
        try await dataStore?.incrementUnreadCount(contactID: contact.id)
      case let .channel(channel):
        try await dataStore?.incrementChannelUnreadCount(channelID: channel.id)
      case let .room(session):
        try await dataStore?.incrementRoomUnreadCount(session.id)
      }
    } catch {
      logger.error("Failed to mark conversation as unread: \(error)")
      errorMessage = error.userFacingMessage
      return
    }

    await notificationService?.updateBadgeCount()
    await requestConversationReload()?.value
  }

  /// The listed conversations still counting unread messages, whatever the filter shows.
  var unreadConversations: [Conversation] {
    allConversations.filter { $0.unreadCount > 0 }
  }

  /// Clears every listed conversation's unread state: `markAsRead` for each, with one badge
  /// recompute and one list reload at the end rather than one per conversation.
  func markAllAsRead() async {
    let unread = unreadConversations
    guard !unread.isEmpty else { return }
    let dataStore = dataStore
    let notificationService = notificationService

    do {
      for conversation in unread {
        switch conversation {
        case let .direct(contact):
          try await dataStore?.clearUnreadCount(contactID: contact.id)
          try await dataStore?.clearUnreadMentionCount(contactID: contact.id)
          await notificationService?.removeDeliveredNotifications(forContactID: contact.id)
        case let .channel(channel):
          try await dataStore?.clearChannelUnreadCount(channelID: channel.id)
          try await dataStore?.clearChannelUnreadMentionCount(channelID: channel.id)
          await notificationService?.removeDeliveredNotifications(
            forChannelIndex: channel.index,
            radioID: channel.radioID
          )
        case let .room(session):
          try await dataStore?.resetRoomUnreadCount(session.id)
          await notificationService?.removeDeliveredNotifications(forRoomSessionID: session.id)
        }
      }
    } catch {
      logger.error("Failed to mark all conversations as read: \(error)")
      errorMessage = error.userFacingMessage
    }

    await notificationService?.updateBadgeCount()
    await requestConversationReload()?.value
  }

  // MARK: - Favorite

  /// Sets favorite state for a conversation with optimistic UI update
  func setFavorite(_ conversation: Conversation, isFavorite: Bool) async {
    guard let current = liveConversation(id: conversation.id) else { return }
    guard current.isFavorite != isFavorite else { return }

    // Reuse existing toggle logic
    await toggleFavorite(current)
  }

  /// Toggles favorite state for a conversation.
  ///
  /// For direct messages (contacts), this pushes the change to the device and waits
  /// for confirmation before updating the UI. For channels and rooms (app-only),
  /// this uses optimistic updates.
  ///
  /// - Parameters:
  ///   - conversation: The conversation to toggle
  ///   - disableAnimation: When true, disables SwiftUI List animations to prevent
  ///     conflicts with swipe action dismissal animations
  func toggleFavorite(_ conversation: Conversation, disableAnimation: Bool = false) async {
    guard let current = liveConversation(id: conversation.id) else { return }
    let originalState = current.isFavorite
    let newState = !originalState

    switch current {
    case let .direct(contact):
      // A contact's favorite flag lives on the radio, so this one write needs the connection;
      // say so rather than returning silently.
      guard connectionStateProvider() == .ready, let contactService else {
        errorMessage = L10n.Chats.Chats.Error.notConnectedToFavorite
        return
      }
      // Contacts sync with device - wait for confirmation
      togglingFavoriteID = contact.id
      defer { togglingFavoriteID = nil }

      do {
        try await contactService.setContactFavorite(contact.id, isFavorite: newState)
        // Device confirmed - update local UI
        applyFavoriteUpdate(current, isFavorite: newState, disableAnimation: disableAnimation)
      } catch {
        logger.error("Failed to toggle contact favorite: \(error)")
        errorMessage = error.userFacingMessage
      }

    case let .channel(channel):
      // Channels are app-only - optimistic update
      applyFavoriteUpdate(current, isFavorite: newState, disableAnimation: disableAnimation)

      do {
        try await dataStore?.setChannelFavorite(channel.id, isFavorite: newState)
      } catch {
        // Rollback on failure
        applyFavoriteUpdate(current, isFavorite: originalState, disableAnimation: disableAnimation)
        logger.error("Failed to toggle channel favorite: \(error)")
        errorMessage = error.userFacingMessage
      }

    case let .room(session):
      // Rooms are app-only - optimistic update
      applyFavoriteUpdate(current, isFavorite: newState, disableAnimation: disableAnimation)

      do {
        try await dataStore?.setSessionFavorite(session.id, isFavorite: newState)
      } catch {
        // Rollback on failure
        applyFavoriteUpdate(current, isFavorite: originalState, disableAnimation: disableAnimation)
        logger.error("Failed to toggle room favorite: \(error)")
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func applyFavoriteUpdate(_ conversation: Conversation, isFavorite: Bool, disableAnimation: Bool) {
    if disableAnimation {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        updateConversationFavoriteState(conversation, isFavorite: isFavorite)
      }
    } else {
      updateConversationFavoriteState(conversation, isFavorite: isFavorite)
    }
  }

  /// Updates the favorite state in the local buffers. `recomputeSnapshot()` runs synchronously
  /// after the mutation so it stays inside any `disablesAnimations` transaction the caller opens.
  private func updateConversationFavoriteState(_ conversation: Conversation, isFavorite: Bool) {
    updateConversation(
      conversation,
      direct: { $0.with(isFavorite: isFavorite) },
      channel: { $0.with(isFavorite: isFavorite) },
      room: { $0.with(isFavorite: isFavorite) }
    )
  }

  /// Locates the element backing `conversation` in its list, replaces it with the mapped value,
  /// and republishes the snapshot. Collapses the per-list `firstIndex` lookup the optimistic
  /// mutators would otherwise each repeat; each caller supplies only the differing transform.
  private func updateConversation(
    _ conversation: Conversation,
    direct mapDirect: (ContactDTO) -> ContactDTO,
    channel mapChannel: (ChannelDTO) -> ChannelDTO,
    room mapRoom: (RemoteNodeSessionDTO) -> RemoteNodeSessionDTO
  ) {
    switch conversation {
    case let .direct(contact):
      if let index = conversations.firstIndex(where: { $0.id == contact.id }) {
        conversations[index] = mapDirect(conversations[index])
      }
    case let .channel(channel):
      if let index = channels.firstIndex(where: { $0.id == channel.id }) {
        channels[index] = mapChannel(channels[index])
      }
    case let .room(session):
      if let index = roomSessions.firstIndex(where: { $0.id == session.id }) {
        roomSessions[index] = mapRoom(roomSessions[index])
      }
    }
    recomputeSnapshot()
  }

  // MARK: - Conversation List

  /// Clears all conversation data from the view model.
  /// Called when the device is forgotten or removed so the list doesn't show stale entries.
  func clearConversations() {
    conversations = []
    channels = []
    roomSessions = []
    pendingRemovalIDs = []
    deletingIDs = []
    allContacts = []
    nicknamesByLoweredName = [:]
    channelSenders = []
    channelSenderNames = []
    channelSenderOrder = [:]
    contactNameSet = []
    lastMessageCache = [:]
    lastRoomPostCache = [:]
    listSenderNames = .empty
    // Invalidates in-flight indicator refreshes; the list event task is not `reloadTask`.
    failedSendRefreshGeneration &+= 1
    failedSendConversationIDs = []
    recomputeSnapshot()
  }

  /// True while an optimistic hide or a confirmation-gated radio delete is in flight for
  /// `id`. Gates the delete action so a rapid re-tap can't double-fire the same removal.
  func isDeletePending(_ id: UUID) -> Bool {
    pendingRemovalIDs.contains(id) || deletingIDs.contains(id)
  }

  /// Hides a conversation, recording the id in `pendingRemovalIDs` so a racing reload can't
  /// resurrect it; `reconcilePendingRemovals()` drops the id once the fetch confirms it's gone.
  func removeConversation(_ conversation: Conversation) {
    pendingRemovalIDs.insert(conversation.id)
    withAnimation(.snappy) {
      switch conversation {
      case let .direct(contact):
        conversations = conversations.filter { $0.id != contact.id }
      case let .channel(channel):
        channels = channels.filter { $0.id != channel.id }
      case let .room(session):
        roomSessions = roomSessions.filter { $0.id != session.id }
      }
      recomputeSnapshot()
    }
  }

  /// Re-admits a row after its delete failed: drops the mask and re-inserts the caller-held DTO.
  /// Reusing the held DTO rather than re-fetching keeps the rollback independent of reload timing.
  func restoreConversation(_ conversation: Conversation) {
    pendingRemovalIDs.remove(conversation.id)
    withAnimation(.snappy) {
      switch conversation {
      case let .direct(contact):
        if !conversations.contains(where: { $0.id == contact.id }) {
          conversations.append(contact)
        }
      case let .channel(channel):
        if !channels.contains(where: { $0.id == channel.id }) {
          channels.append(channel)
        }
      case let .room(session):
        if !roomSessions.contains(where: { $0.id == session.id }) {
          roomSessions.append(session)
        }
      }
      recomputeSnapshot()
    }
  }

  /// Confirms a direct conversation's local clear: drops the mask and purges the fetch buffer
  /// together. Purging matters because a stale reload could have re-added the contact while it
  /// was masked, and a later recompute would then republish it; a re-created row still returns
  /// via the next reload's fetch.
  func confirmDirectRemoval(_ contact: ContactDTO) {
    pendingRemovalIDs.remove(contact.id)
    conversations.removeAll { $0.id == contact.id }
    recomputeSnapshot()
  }

  /// Load conversations for a device
  func loadConversations(radioID: UUID) async {
    guard let dataStore else {
      // No store until a radio has been paired: nothing to load, so show the empty list.
      hasLoadedOnce = true
      return
    }

    isLoading = true
    errorBannerMessage = nil

    do {
      conversations = try await dataStore.fetchConversations(radioID: radioID)
      recomputeSnapshot()
    } catch {
      errorBannerMessage = L10n.Chats.Chats.Error.loadConversationsFailed
      logger.error("loadConversations failed: \(error.localizedDescription)")
    }

    hasLoadedOnce = true
    isLoading = false
  }

  /// Single entry point for every list reload. Coalesces: one pass in flight, and a request
  /// that arrives meanwhile marks it to run once more when it finishes, so the latest request
  /// is always reflected and passes never interleave a mismatched commit.
  ///
  /// It used to cancel and replace the pass in flight. Every arriving message, advert and
  /// connection change requests a reload, and the fetches queue behind sync writes on the one
  /// store actor, so on a busy mesh each pass was cancelled before it committed: the list kept
  /// its spinner (nothing loaded yet) or stopped showing new messages.
  ///
  /// Returns the task that will reflect this request so a caller that needs ordering (initial
  /// load) can await `.value`.
  @discardableResult
  func requestConversationReload() -> Task<Void, Never>? {
    if let reloadTask {
      // Its next pass re-reads the radio, so a forget or a switch lands there too.
      reloadPending = true
      return reloadTask
    }
    guard currentRadioIDProvider() != nil else {
      clearConversationsForNoRadio()
      return nil
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      repeat {
        reloadPending = false
        guard let radioID = currentRadioIDProvider() else {
          clearConversationsForNoRadio()
          break
        }
        await performConversationReload(radioID: radioID)
      } while reloadPending && !Task.isCancelled
      reloadTask = nil
      reloadPending = false
    }
    reloadTask = task
    return task
  }

  /// No radio to read (never paired, or forgotten): an empty list, not a spinner that never ends.
  private func clearConversationsForNoRadio() {
    clearConversations()
    hasLoadedOnce = true
  }

  /// Fetches contacts, channels, and rooms into locals, then commits one consistent snapshot.
  /// No `await` may sit between the last `isCancelled` check and the assignment, so no other
  /// reload can interleave a mismatched commit on the main actor.
  private func performConversationReload(radioID: UUID) async {
    guard let dataStore else {
      // No store until a radio has been paired: show the empty list rather than spin.
      hasLoadedOnce = true
      return
    }
    isLoading = true
    defer { isLoading = false }

    // Only fetchConversations sets the error banner; channel/room failures stay silent.
    var banner: String?
    let fetchedConversations: [ContactDTO]?
    do {
      fetchedConversations = try await dataStore.fetchConversations(radioID: radioID)
    } catch {
      fetchedConversations = nil
      banner = L10n.Chats.Chats.Error.loadConversationsFailed
      logger.error("performConversationReload fetchConversations failed: \(error.localizedDescription)")
    }
    if Task.isCancelled { return }
    #if DEBUG
      await reloadInterleaveHook?()
      if Task.isCancelled { return }
    #endif

    let fetchedChannels = try? await dataStore.fetchChannels(radioID: radioID)
    if Task.isCancelled { return }
    let fetchedRooms = await (try? dataStore.fetchRemoteNodeSessions(radioID: radioID))?
      .filter(\.isRoom)
    if Task.isCancelled { return }

    if let fetchedConversations { conversations = fetchedConversations }
    if let fetchedChannels { channels = fetchedChannels }
    if let fetchedRooms { roomSessions = fetchedRooms }
    errorBannerMessage = banner
    reconcilePendingRemovals()
    recomputeSnapshot()
    hasLoadedOnce = true

    // Skip the trailing preview load if this reload was superseded.
    if Task.isCancelled { return }
    await loadLastMessagePreviews()
    if Task.isCancelled { return }
    await refreshFailedSendIndicators()
  }

  // MARK: - Message Previews

  /// Get the cached last-message preview text for a conversation (contact, channel or room),
  /// keyed by its id: one line, mentions and replies read as the bubble shows them.
  func lastMessagePreview(id: UUID) -> String? {
    if let message = lastMessageCache[id] { return MessagePreviewFormatter.preview(message.text) }
    if let post = lastRoomPostCache[id] { return MessagePreviewFormatter.preview(post.text) }
    return nil
  }

  /// Who sent the last message, for a list row's preview: You for one of ours; a channel sender by
  /// the contact's nickname when one contact has that name, else the name on air; a room post's
  /// author as the room shows them; nil for the other person's in a DM, whom the row names.
  func lastMessageSender(id: UUID) -> String? {
    if let message = lastMessageCache[id] {
      if message.direction == .outgoing { return L10n.Chats.Chats.Path.Receiver.you }
      guard message.channelIndex != nil else { return nil }
      return listSenderNames.channelSenders.shortName(for: message.senderNodeName)
    }
    if let post = lastRoomPostCache[id] {
      let room = roomSessions.first { $0.id == id }
      return listSenderNames.roomAuthors.resolve(
        post,
        roomPublicKey: room?.publicKey,
        roomName: room?.name,
        selfName: L10n.Chats.Chats.Path.Receiver.you
      ).displayName
    }
    return nil
  }

  /// Load last message previews for all conversations.
  /// Uses batch fetch methods to minimize actor hops (2 hops instead of N).
  func loadLastMessagePreviews() async {
    guard let dataStore else { return }

    // Sender names come from the listed radio's contacts (one read per reload).
    if let radioID = currentRadioIDProvider(),
       let contacts = try? await dataStore.fetchContacts(radioID: radioID) {
      let names = ContactNameDirectory(contacts: contacts)
      if names != listSenderNames { listSenderNames = names }
    }

    // Batch fetch contact message previews (single actor hop)
    if !conversations.isEmpty {
      do {
        let contactMessages = try await dataStore.fetchLastMessages(contactIDs: conversations.map(\.id), limit: 10)
        for contact in conversations {
          // Find the last non-reaction message (skip outgoing reactions unless failed)
          let lastMessage = contactMessages[contact.id]?.last { message in
            guard message.direction == .outgoing,
                  ReactionParser.parseDM(message.text) != nil else {
              return true
            }
            return message.status == .failed
          }

          // Evict the cached preview only when no messages remain, so a cleared DM
          // (still listed via lastMessageDate) shows "No messages"; a contact whose
          // recent messages are all filtered-out reactions keeps its prior preview.
          if let lastMessage {
            lastMessageCache[contact.id] = lastMessage
          } else if contactMessages[contact.id]?.isEmpty ?? true {
            lastMessageCache.removeValue(forKey: contact.id)
          }
        }
      } catch {
        logger.warning("Failed to load contact message previews: \(error)")
      }
    }

    // Batch fetch channel message previews (single actor hop)
    if !channels.isEmpty {
      do {
        let channelParams = channels.map { (radioID: $0.radioID, channelIndex: $0.index, id: $0.id) }
        let channelMessages = try await dataStore.fetchLastChannelMessages(channels: channelParams, limit: 20)
        for channel in channels {
          guard let messages = channelMessages[channel.id] else { continue }

          // Filter out outgoing reactions (keep failed ones visible)
          let lastMessage = messages.last { message in
            if message.direction == .outgoing,
               ReactionParser.parse(message.text) != nil,
               message.status != .failed {
              return false
            }
            return true
          }

          if let lastMessage {
            lastMessageCache[channel.id] = lastMessage
          } else {
            lastMessageCache.removeValue(forKey: channel.id)
          }
        }
      } catch {
        logger.warning("Failed to load channel message previews: \(error)")
      }
    }

    // Each room's latest post. Rooms are few and there is no batch read, so one read each.
    var roomPosts: [UUID: RoomMessageDTO] = [:]
    for room in roomSessions {
      guard !Task.isCancelled else { return }
      if let post = try? await dataStore.fetchLatestRoomMessages(sessionID: room.id, limit: 1).last {
        roomPosts[room.id] = post
      }
    }
    if roomPosts != lastRoomPostCache { lastRoomPostCache = roomPosts }
  }

  // MARK: - Failed-send indicators

  /// True when the conversation row for `id` should show the failed-send badge.
  func conversationHasFailedSend(_ id: UUID) -> Bool {
    failedSendConversationIDs.contains(id)
  }

  /// Replaces `failedSendConversationIDs` with the union of the store's list ids.
  func applyFailedSendKeys(_ keys: FailedSendConversationKeys) {
    failedSendConversationIDs = keys.contactIDs
      .union(keys.channelIDs)
      .union(keys.roomSessionIDs)
  }

  /// Re-runs the failed-send query and applies the keys. Does not reload
  /// contacts, channels, or rooms.
  func refreshFailedSendIndicators() async {
    failedSendRefreshGeneration &+= 1
    let generation = failedSendRefreshGeneration
    guard let dataStore, let radioID = currentRadioIDProvider() else {
      failedSendConversationIDs = []
      return
    }
    do {
      #if DEBUG
        try failedSendRefreshFaultInjection?()
      #endif
      let keys = try await dataStore.fetchFailedSendConversationKeys(radioID: radioID)
      #if DEBUG
        await failedSendRefreshInterleaveHook?()
      #endif
      guard generation == failedSendRefreshGeneration, !Task.isCancelled else { return }
      applyFailedSendKeys(keys)
    } catch is CancellationError {
      return
    } catch {
      guard generation == failedSendRefreshGeneration, !Task.isCancelled else { return }
      logger.warning("Failed to load failed-send indicators: \(error)")
    }
  }

  /// Whether a list `MessageEvent` should trigger `refreshFailedSendIndicators()`.
  /// Status-resolved ACKs (DM and room) only requery when a badge is already
  /// showing, so a retry success can drop it without hitting the store on every ACK.
  func shouldRefreshFailedSendIndicators(for event: MessageEvent) -> Bool {
    switch event {
    case .messageFailed, .messageResent, .roomMessageFailed:
      true
    case .messageStatusResolved, .roomMessageStatusUpdated:
      !failedSendConversationIDs.isEmpty
    case .directMessageReceived, .channelMessageReceived, .roomMessageReceived,
         .messageRetrying, .heardRepeatRecorded, .reactionReceived,
         .messagesRegionUpdated, .routingChanged:
      false
    }
  }
}
