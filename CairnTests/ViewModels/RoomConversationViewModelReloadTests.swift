import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// The reload that follows an incoming room message is not the user opening the room: it must
/// leave the error state alone, and must not mark the room read for messages that arrived
/// while the app was in the background.
@Suite("RoomConversationViewModel reload")
@MainActor
struct RoomConversationViewModelReloadTests {
  private static let standingError = "Send failed"

  private func message(sessionID: UUID, ts: UInt32, text: String) -> RoomMessageDTO {
    RoomMessageDTO(
      id: UUID(),
      sessionID: sessionID,
      authorKeyPrefix: Data([0xAB, 0xCD, 0xEF, 0x01]),
      authorName: "Author",
      text: text,
      timestamp: ts
    )
  }

  /// An open room whose view model shows an error from an earlier action.
  private func makeOpenRoom() async throws -> (RoomConversationViewModel, ServiceContainer, RemoteNodeSessionDTO) {
    let services = try ServiceContainer(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true)),
      radioID: UUID()
    )
    let session = RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Room",
      role: .roomServer,
      isConnected: true
    )
    try await services.dataStore.saveRemoteNodeSessionDTO(session)

    let viewModel = RoomConversationViewModel()
    viewModel.configure(
      roomServerService: { services.roomServerService },
      dataStore: { services.dataStore },
      syncCoordinator: { nil },
      notificationService: { nil }
    )
    await viewModel.loadMessages(for: session)
    viewModel.errorMessage = Self.standingError
    return (viewModel, services, session)
  }

  /// Stores two messages as the sync path would, delivers the event for the first, and waits
  /// for the reload to bring in the second, which only the reload can.
  private func receiveMessages(
    in viewModel: RoomConversationViewModel,
    services: ServiceContainer,
    session: RemoteNodeSessionDTO
  ) async throws {
    let announced = message(sessionID: session.id, ts: 100, text: "announced")
    try await services.dataStore.saveRoomMessage(announced)
    try await services.dataStore.saveRoomMessage(message(sessionID: session.id, ts: 101, text: "stored only"))
    try await services.dataStore.incrementRoomUnreadCount(session.id)

    await viewModel.handleEvent(.roomMessageReceived(message: announced, sessionID: session.id))
    try await waitUntil("the coalesced reload should run") { viewModel.messages.count == 2 }
  }

  private func unreadCount(_ services: ServiceContainer, _ session: RemoteNodeSessionDTO) async throws -> Int? {
    try await services.dataStore.fetchRemoteNodeSession(id: session.id)?.unreadCount
  }

  @Test
  func `a reload in the background leaves the room unread and the error standing`() async throws {
    let (viewModel, services, session) = try await makeOpenRoom()
    viewModel.isSceneActive = false

    try await receiveMessages(in: viewModel, services: services, session: session)

    #expect(try await unreadCount(services, session) == 1)
    #expect(viewModel.errorMessage == Self.standingError)
    #expect(!viewModel.isLoading)
  }

  @Test
  func `returning to the foreground marks the room read`() async throws {
    let (viewModel, services, session) = try await makeOpenRoom()
    viewModel.isSceneActive = false
    try await receiveMessages(in: viewModel, services: services, session: session)

    await viewModel.sceneDidBecomeActive()

    #expect(viewModel.isSceneActive)
    #expect(try await unreadCount(services, session) == 0)
  }

  @Test
  func `a reload in the foreground marks the room read but keeps the error`() async throws {
    let (viewModel, services, session) = try await makeOpenRoom()

    try await receiveMessages(in: viewModel, services: services, session: session)
    try await waitUntil("the arrival should be marked read") {
      (try? await services.dataStore.fetchRemoteNodeSession(id: session.id)?.unreadCount) == 0
    }

    #expect(viewModel.errorMessage == Self.standingError)
  }
}
