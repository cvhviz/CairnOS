import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("NotificationResponseRelay Tests")
@MainActor
struct NotificationResponseRelayTests {
  // MARK: - Routing target

  @Test
  func `Without a connection the relay answers through its offline service`() {
    let appState = AppState()
    let relay = NotificationResponseRelay()
    relay.adopt(appState)

    #expect(appState.services == nil)
    #expect(relay.respondingNotificationService === relay.offlineNotificationService)
    #expect(relay.presentingNotificationService === relay.offlineNotificationService)
  }

  @Test
  func `A wired connection's service answers, and the offline one takes over when it is lost`() async throws {
    let appState = AppState()
    let relay = NotificationResponseRelay()
    relay.adopt(appState)

    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: MockTransport())
    )
    appState.connectionManager.setTestState(connectionState: .ready, services: services)
    await appState.wireServicesIfConnected()

    #expect(relay.respondingNotificationService === services.notificationService)
    #expect(relay.presentingNotificationService === services.notificationService)

    // Radio out of range: the container is gone, and taps must still land.
    appState.connectionManager.setTestState(connectionState: .disconnected, services: .some(nil))
    await appState.wireServicesIfConnected()

    #expect(relay.respondingNotificationService === relay.offlineNotificationService)
    #expect(relay.presentingNotificationService === relay.offlineNotificationService)
  }

  @Test
  func `A connection still being wired does not take responses yet`() async throws {
    let appState = AppState()
    let relay = NotificationResponseRelay()
    relay.adopt(appState)

    // Services exist, but `wireServicesIfConnected` has not installed their
    // tap handlers: forwarding there would drop the tap.
    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: MockTransport())
    )
    appState.connectionManager.setTestState(connectionState: .connected, services: services)

    #expect(relay.respondingNotificationService === relay.offlineNotificationService)
    #expect(relay.presentingNotificationService === services.notificationService)
  }

  @Test
  func `Before an AppState is adopted the relay still has a service to answer with`() {
    let relay = NotificationResponseRelay()
    #expect(relay.respondingNotificationService === relay.offlineNotificationService)
    #expect(relay.presentingNotificationService === relay.offlineNotificationService)
  }

  // MARK: - Offline taps

  @Test
  func `A message tap with no radio connected opens the conversation`() async throws {
    let appState = AppState()
    let contact = Self.makeContact()
    try await appState.connectionManager.persistenceStore.saveContact(contact)
    let relay = NotificationResponseRelay()
    relay.adopt(appState)
    appState.navigation.selectedTab = AppTab.gps.rawValue

    let onTap = try #require(relay.offlineNotificationService.onNotificationTapped)
    await onTap(contact.id)

    #expect(appState.navigation.pendingChatContact?.id == contact.id)
    #expect(appState.navigation.selectedTab == AppTab.chats.rawValue)
  }

  @Test
  func `Adopting the real AppState re-aims the offline taps at it`() async throws {
    let throwaway = AppState()
    let real = AppState()
    let contact = Self.makeContact()
    try await real.connectionManager.persistenceStore.saveContact(contact)
    let relay = NotificationResponseRelay()
    relay.adopt(throwaway)

    relay.adopt(real)
    let onTap = try #require(relay.offlineNotificationService.onNotificationTapped)
    await onTap(contact.id)

    #expect(relay.appState === real)
    #expect(real.navigation.pendingChatContact?.id == contact.id)
    #expect(throwaway.navigation.pendingChatContact == nil)
  }

  // MARK: - Offline actions

  @Test
  func `Reply and mark-as-read are handled before any connection or AppState`() {
    let relay = NotificationResponseRelay()
    let service = relay.offlineNotificationService

    #expect(service.onQuickReply != nil)
    #expect(service.onChannelQuickReply != nil)
    #expect(service.onMarkAsRead != nil)
    #expect(service.onChannelMarkAsRead != nil)
    #expect(service.onRoomMarkAsRead != nil)
  }

  @Test
  func `Mark as read with no radio connected clears the conversation's unread count`() async throws {
    let appState = AppState()
    let store = appState.connectionManager.persistenceStore
    let contact = Self.makeContact(unreadCount: 3)
    try await store.saveContact(contact)
    let relay = NotificationResponseRelay()
    relay.adopt(appState)

    let onMarkAsRead = try #require(relay.offlineNotificationService.onMarkAsRead)
    await onMarkAsRead(contact.id, UUID())

    let updated = try #require(try await store.fetchContact(id: contact.id))
    #expect(updated.unreadCount == 0)
  }

  @Test
  func `An unsent reply becomes the conversation's draft`() throws {
    let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
    let drafts = DraftStore(defaults: defaults)
    let id = ChatConversationID.dm(radioID: UUID(), contactID: UUID())

    NotificationResponseRelay.keepUnsentReply("On my way", for: id, in: drafts)

    #expect(drafts.draft(for: id) == "On my way")
  }

  @Test
  func `An unsent reply keeps the draft the user had already typed`() throws {
    let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
    let drafts = DraftStore(defaults: defaults)
    let id = ChatConversationID.channel(radioID: UUID(), channelIndex: 2)
    drafts.setDraft("Half a thought", for: id)

    NotificationResponseRelay.keepUnsentReply("On my way", for: id, in: drafts)

    #expect(drafts.draft(for: id) == "Half a thought\nOn my way")
  }

  @Test
  func `Without a connection a quick reply goes to the offline service`() {
    let relay = NotificationResponseRelay()
    relay.adopt(AppState())

    #expect(relay.replyingNotificationService === relay.offlineNotificationService)
  }

  @Test
  func `A quick reply goes to the connected service only over a ready link`() {
    #expect(!NotificationResponseRelay.repliesOffline(connectedResponds: true, isLinkReady: true))
    #expect(NotificationResponseRelay.repliesOffline(connectedResponds: true, isLinkReady: false))
    #expect(NotificationResponseRelay.repliesOffline(connectedResponds: false, isLinkReady: false))
    #expect(NotificationResponseRelay.repliesOffline(connectedResponds: false, isLinkReady: true))
  }

  // MARK: - Launch hold

  @Test
  func `A tap delivered before launch settles is held until markReady`() {
    var hold = LaunchHold<String>()

    #expect(hold.submit("launch tap") == nil)
    #expect(hold.isReady == false)
    #expect(hold.held == "launch tap")

    #expect(hold.markReady() == "launch tap")
    #expect(hold.isReady)
    #expect(hold.held == nil)
  }

  @Test
  func `markReady hands a held tap back exactly once`() {
    var hold = LaunchHold<String>()
    _ = hold.submit("launch tap")

    #expect(hold.markReady() == "launch tap")
    #expect(hold.markReady() == nil)
  }

  @Test
  func `A tap delivered after launch settles is routed immediately`() {
    var hold = LaunchHold<String>()
    #expect(hold.markReady() == nil)

    #expect(hold.submit("warm tap") == "warm tap")
    #expect(hold.held == nil)
  }

  @Test
  func `A second tap before launch settles replaces the first`() {
    var hold = LaunchHold<String>()
    _ = hold.submit("first")
    _ = hold.submit("second")

    #expect(hold.markReady() == "second")
  }

  // MARK: - Helpers

  private static func makeContact(unreadCount: Int = 0) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
      name: "RelayContact",
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 2,
      outPath: Data([0x01, 0x02]),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: Date(),
      unreadCount: unreadCount
    )
  }
}
