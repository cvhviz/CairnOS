import CairnServices
import UserNotifications

/// App-lifetime `UNUserNotificationCenter` delegate. `NotificationService` is
/// created per connection, so with it as the delegate none was installed on a
/// cold launch or while the radio was out of range, and a notification tap
/// went nowhere. The relay is installed once from `CairnApp.init()`, before
/// launch finishes, which is the only point at which the system hands over
/// the response that launched the app. It forwards to the connected
/// `NotificationService` when there is one, and otherwise resolves taps
/// against the process-lifetime store.
///
/// Mirrors `IntentBridge` and `PendingExternalURL`: a reference type stored as
/// a `let` on `CairnApp`, so it outlives the before-first-unlock `AppState` swap
/// and keeps the notification center's weak delegate reference alive.
@MainActor
final class NotificationResponseRelay: NSObject {
  private(set) var appState: AppState?

  /// Stand-in for the per-connection service while no radio is connected.
  /// Carries the navigation tap handlers, plus quick reply and mark-as-read
  /// handlers that work without a connection's services: mark-as-read applies
  /// to the store directly, and a reply waits for the radio, then queues or
  /// keeps the text as the conversation's draft. See the Offline actions mark.
  let offlineNotificationService = NotificationService()

  /// Holds a navigation tap delivered before launch has settled, for the same
  /// reason `PendingExternalURL` holds a URL: a failed auto-reconnect during
  /// `AppState.initialize()` clears the selection the tap would set.
  private var launchHold = LaunchHold<UNNotificationResponse>()

  override init() {
    super.init()
    // A reply that can't be sent says so with the same localized notification
    // the connected service posts.
    offlineNotificationService.setStringProvider(NotificationStringProviderImpl())
    installOfflineActionHandlers()
  }

  /// Makes the relay the notification center's delegate.
  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  /// Points the relay at the live `AppState` and aims the offline tap handlers
  /// at its navigation and store. The badge count reads the same store, so an
  /// offline mark-as-read updates the badge too.
  func adopt(_ appState: AppState) {
    self.appState = appState
    appState.navigation.configureNotificationHandlers(
      notificationService: offlineNotificationService,
      dataStore: appState.connectionManager.persistenceStore,
      connectedDevice: { [weak appState] in appState?.connectedDevice }
    )
    let store = appState.connectionManager.persistenceStore
    offlineNotificationService.getBadgeCount = { [weak appState] in
      let radioID = await MainActor.run { appState?.currentRadioID }
      guard let radioID else { return (contacts: 0, channels: 0, rooms: 0) }
      return (try? await store.getTotalUnreadCounts(radioID: radioID)) ?? (contacts: 0, channels: 0, rooms: 0)
    }
  }

  /// The service that decides how a notification is presented: the connected
  /// one, which knows the conversation on screen, when there is one.
  var presentingNotificationService: NotificationService {
    appState?.services?.notificationService ?? offlineNotificationService
  }

  /// The service that answers a response. The connected service takes over
  /// only once its handlers are installed, which happens late in wiring, so a
  /// tap that lands while a reconnect is still wiring up is not dropped.
  var respondingNotificationService: NotificationService {
    if let connected = appState?.services?.notificationService,
       connected.onNotificationTapped != nil {
      return connected
    }
    return offlineNotificationService
  }

  /// The service that answers a quick reply. The connected service sends only
  /// over a ready link and otherwise keeps the text in memory, which a force
  /// quit loses, so while the link is still coming up (connecting, or syncing
  /// after a reconnect) the offline handler takes the reply instead: it waits
  /// for the radio and keeps an unsent reply as a saved draft.
  var replyingNotificationService: NotificationService {
    let responder = respondingNotificationService
    return Self.repliesOffline(
      connectedResponds: responder !== offlineNotificationService,
      isLinkReady: appState?.connectionState == .ready
    ) ? offlineNotificationService : responder
  }

  /// Whether a quick reply goes to the offline handler rather than the
  /// connected one.
  static func repliesOffline(connectedResponds: Bool, isLinkReady: Bool) -> Bool {
    !connectedResponds || !isLinkReady
  }

  /// Records that launch has settled and routes the tap held from launch.
  /// Called at the tail of `CairnApp`'s launch sequence.
  func markReady() async {
    guard let response = launchHold.markReady() else { return }
    await respondingNotificationService.userNotificationCenter(.current(), didReceive: response)
  }
}

// MARK: - Offline actions

extension NotificationResponseRelay {
  /// Installs the quick reply and mark-as-read handlers on the offline service.
  /// They read `appState` when they run, so one installed before the
  /// before-first-unlock swap acts on the real store once it is adopted.
  private func installOfflineActionHandlers() {
    let service = offlineNotificationService
    service.onQuickReply = { [weak self] contactID, text in
      await self?.handleOfflineQuickReply(contactID: contactID, text: text)
    }
    service.onChannelQuickReply = { [weak self] radioID, channelIndex, text in
      await self?.handleOfflineChannelQuickReply(radioID: radioID, channelIndex: channelIndex, text: text)
    }
    service.onMarkAsRead = { [weak self] contactID, messageID in
      await self?.markReadOffline(.direct(contactID: contactID), messageID: messageID)
    }
    service.onChannelMarkAsRead = { [weak self] radioID, channelIndex, messageID in
      await self?.markReadOffline(.channel(radioID: radioID, index: channelIndex), messageID: messageID)
    }
    service.onRoomMarkAsRead = { [weak self] sessionID, messageID in
      await self?.markReadOffline(.room(sessionID: sessionID), messageID: messageID)
    }
  }

  /// The conversation a notification action names.
  enum ActionTarget: Equatable {
    case direct(contactID: UUID)
    case channel(radioID: UUID, index: UInt8)
    case room(sessionID: UUID)
  }

  /// A reply typed while no connection is wired or its link isn't ready yet,
  /// whether the radio is reconnecting or the action launched the app in the
  /// background. It waits
  /// a few seconds for the radio the way a Siri send does (which also starts
  /// the launch sequence a scene-less launch never runs), then queues through
  /// the same durable path. If the radio still can't take it, the text is kept
  /// as the conversation's draft and the user is told it wasn't sent, so a
  /// reply is never silently dropped.
  ///
  /// The conversation is read from the store only after the wait: on a
  /// before-first-unlock launch the real store is adopted by the launch the
  /// wait starts, so reading it first would find nothing.
  func handleOfflineQuickReply(contactID: UUID, text: String) async {
    if await sendWhenReady(text, toConversation: contactID) {
      await finishSentReply(.direct(contactID: contactID))
      return
    }
    let contact = try? await appState?.connectionManager.persistenceStore.fetchContact(id: contactID)
    if let contact {
      keepUnsentReply(text, for: .dm(radioID: contact.radioID, contactID: contactID))
    }
    await offlineNotificationService.checkAuthorizationStatus()
    await offlineNotificationService.postQuickReplyFailedNotification(
      contactName: contact?.displayName ?? "",
      contactID: contactID
    )
  }

  /// The channel counterpart of `handleOfflineQuickReply`.
  func handleOfflineChannelQuickReply(radioID: UUID, channelIndex: UInt8, text: String) async {
    // Waits before reading the channel, for the reason given above.
    let isReady = await SiriMessageDirectory.readyToSend() != nil
    let channel = try? await appState?.connectionManager.persistenceStore.fetchChannel(radioID: radioID, index: channelIndex)
    if isReady, let channel,
       await SiriMessageDirectory.send(text: text, toConversation: channel.id) == .queued {
      await finishSentReply(.channel(radioID: radioID, index: channelIndex))
      return
    }
    keepUnsentReply(text, for: .channel(radioID: radioID, channelIndex: channelIndex))
    await offlineNotificationService.checkAuthorizationStatus()
    await offlineNotificationService.postChannelQuickReplyFailedNotification(
      channelName: channel?.displayName
        ?? NotificationStringProviderImpl().defaultChannelName(index: Int(channelIndex)),
      radioID: radioID,
      channelIndex: channelIndex
    )
  }

  /// Waits for the radio, then queues `text` through the Siri send path.
  /// True only once the message is in the durable queue.
  private func sendWhenReady(_ text: String, toConversation id: UUID) async -> Bool {
    guard await SiriMessageDirectory.readyToSend() != nil else { return false }
    return await SiriMessageDirectory.send(text: text, toConversation: id) == .queued
  }

  /// Saves an unsent reply as the conversation's draft, which the composer
  /// restores when the chat opens. Appended to any draft already there, so
  /// neither the reply nor what the user had typed is lost.
  private func keepUnsentReply(_ text: String, for id: ChatConversationID) {
    guard let draftStore = appState?.draftStore else { return }
    Self.keepUnsentReply(text, for: id, in: draftStore)
  }

  static func keepUnsentReply(_ text: String, for id: ChatConversationID, in draftStore: DraftStore) {
    draftStore.setDraft(ForwardedDraft.merged(existing: draftStore.draft(for: id), forwarded: text), for: id)
  }

  /// A queued reply means the user has seen the conversation: clear its
  /// unread state, as the connected handler does after a send.
  private func finishSentReply(_ target: ActionTarget) async {
    guard let appState else { return }
    let store = appState.connectionManager.persistenceStore
    switch target {
    case let .direct(contactID):
      try? await store.clearUnreadCount(contactID: contactID)
      await offlineNotificationService.removeDeliveredNotifications(forContactID: contactID)
    case let .channel(radioID, index):
      try? await store.clearChannelUnreadCount(radioID: radioID, index: index)
      await offlineNotificationService.removeDeliveredNotifications(forChannelIndex: index, radioID: radioID)
    case .room:
      break
    }
    await offlineNotificationService.updateBadgeCount()
    appState.refreshConversations()
  }

  /// Mark-as-read needs no radio: read state lives in the store, so it is
  /// applied there directly and never waits for a connection.
  func markReadOffline(_ target: ActionTarget, messageID: UUID) async {
    guard let appState else { return }
    let store = appState.connectionManager.persistenceStore
    switch target {
    case let .direct(contactID):
      try? await store.markMessageAsRead(id: messageID)
      try? await store.clearUnreadCount(contactID: contactID)
    case let .channel(radioID, index):
      try? await store.markMessageAsRead(id: messageID)
      try? await store.clearChannelUnreadCount(radioID: radioID, index: index)
    case let .room(sessionID):
      try? await store.resetRoomUnreadCount(sessionID)
    }
    offlineNotificationService.removeDeliveredNotification(messageID: messageID)
    await offlineNotificationService.updateBadgeCount()
    appState.refreshConversations()
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationResponseRelay: @preconcurrency UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await presentingNotificationService.userNotificationCenter(center, willPresent: notification)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    // Only a tap navigates, and only a tap is guaranteed a scene whose launch
    // will release the hold. Reply and mark-as-read can launch the app in the
    // background with no scene, so they are never held.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      let service = response is UNTextInputNotificationResponse
        ? replyingNotificationService
        : respondingNotificationService
      await service.userNotificationCenter(center, didReceive: response)
      return
    }
    guard let response = launchHold.submit(response) else { return }
    await respondingNotificationService.userNotificationCenter(center, didReceive: response)
  }
}

/// Gate for a value that must not be acted on until launch has settled.
/// Generic so the hold can be tested without a `UNNotificationResponse`,
/// which has no public initializer.
struct LaunchHold<Value> {
  private(set) var isReady = false
  private(set) var held: Value?

  /// Hands `value` back when it can be acted on now; otherwise holds it,
  /// replacing any earlier one, and returns `nil`.
  mutating func submit(_ value: Value) -> Value? {
    guard isReady else {
      held = value
      return nil
    }
    return value
  }

  /// Records that launch has settled and hands back the held value, once.
  mutating func markReady() -> Value? {
    isReady = true
    defer { held = nil }
    return held
  }
}
