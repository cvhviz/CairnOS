import Foundation
import MeshCore
import Testing
@testable import CairnServices

/// The demo room (`SimulatorConnectionMode.seedDemoRoom`, `MockDataProvider+Rooms`) on the demo
/// radio (`SimulatorMockTransport`): it stays logged in while open, because the radio takes its
/// keep-alives as firmware does, and it reads as today's on every connect, like the other demo
/// conversations.
@MainActor
@Suite("Demo room seed and keep-alive")
struct DemoRoomSeedTests {
  private let sessionID = MockDataProvider.dianasRoomSessionID
  private let roomKey = MockDataProvider.dianasRoomSession().publicKey

  private func store() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  // MARK: - Refresh on connect

  @Test
  func `a later connect moves the posts and last activity to now without adding rows`() async throws {
    let store = try store()
    let mode = SimulatorConnectionMode()
    let firstDay = Date(timeIntervalSince1970: 1_790_000_000)
    let nextDay = firstDay.addingTimeInterval(86400)

    try await mode.seedDemoRoom(store, now: firstDay)
    try await mode.seedDemoRoom(store, now: nextDay)

    let posts = try await store.fetchRoomMessages(sessionID: sessionID)
    let expected = MockDataProvider.dianasRoomPosts(now: nextDay)
    #expect(posts.count == expected.count, "re-seeding must replace each post, not stack a copy")
    #expect(Set(posts.map(\.id)) == Set(expected.map(\.id)))
    for post in expected {
      let saved = try #require(posts.first { $0.id == post.id })
      #expect(saved.timestamp == post.timestamp, "\(post.text)")
      #expect(saved.createdAt == post.createdAt, "\(post.text)")
    }
    let session = try #require(try await store.fetchRemoteNodeSession(id: sessionID))
    #expect(session.lastMessageDate == MockDataProvider.dianasRoomSession(now: nextDay).lastMessageDate)
  }

  @Test
  func `a reconnect logs the room back in and keeps what the user changed`() async throws {
    let store = try store()
    let mode = SimulatorConnectionMode()
    try await mode.seedDemoRoom(store)
    try await store.markSessionDisconnected(sessionID)
    try await store.resetRoomUnreadCount(sessionID)
    try await store.setSessionFavorite(sessionID, isFavorite: true)

    try await mode.seedDemoRoom(store)

    let session = try #require(try await store.fetchRemoteNodeSession(id: sessionID))
    #expect(session.isConnected)
    #expect(session.permissionLevel == .readWrite)
    #expect(session.unreadCount == 0, "the user read the room; a reconnect must not bring the badge back")
    #expect(session.isFavorite)
  }

  @Test
  func `a room joined by hand under another id is left alone`() async throws {
    let store = try store()
    let joined = RemoteNodeSessionDTO(
      radioID: MockDataProvider.simulatorDeviceID,
      publicKey: roomKey,
      name: "Diana's Room",
      role: .roomServer
    )
    try await store.saveRemoteNodeSessionDTO(joined)

    try await SimulatorConnectionMode().seedDemoRoom(store)

    #expect(try await store.fetchRoomMessages(sessionID: sessionID).isEmpty)
    #expect(try await store.fetchRoomMessages(sessionID: joined.id).isEmpty)
    let session = try #require(try await store.fetchRemoteNodeSession(publicKey: roomKey))
    #expect(session.id == joined.id)
    #expect(!session.isConnected)
  }

  // MARK: - Keep-alive on the demo radio

  private func startedSession(contacts: [ContactDTO] = MockDataProvider.contacts) async throws -> MeshCoreSession {
    let session = MeshCoreSession(transport: SimulatorMockTransport(contacts: contacts))
    try await session.start()
    return session
  }

  @Test
  func `the demo radio takes a keep-alive to the room as sent, direct`() async throws {
    let session = try await startedSession()
    let sent = try await session.sendKeepAlive(to: roomKey, syncSince: 0)
    #expect(sent.route == 0, "Diana's Room has a known path")
    #expect(sent.expectedAck.count == 4)
    #expect(sent.suggestedTimeoutMs > 0)
  }

  @Test
  func `a keep-alive to a contact the radio doesn't hold is refused as not found`() async throws {
    let session = try await startedSession(contacts: [])
    do {
      _ = try await session.sendKeepAlive(to: roomKey, syncSince: 0)
      Issue.record("a keep-alive to an unknown contact must be refused")
    } catch let MeshCoreError.deviceError(code) {
      #expect(code == ErrorCode.notFound.rawValue)
    }
  }

  @Test
  func `the room service's keep-alive succeeds, so the open demo room stays logged in`() async throws {
    let store = try store()
    try await SimulatorConnectionMode().seedDataStore(store)
    let service = try await RemoteNodeService(
      session: startedSession(),
      dataStore: store,
      keychainService: KeychainService()
    )

    try await service.sendKeepAlive(sessionID: sessionID)

    let room = try #require(try await store.fetchRemoteNodeSession(id: sessionID))
    #expect(room.isConnected)
  }
}
