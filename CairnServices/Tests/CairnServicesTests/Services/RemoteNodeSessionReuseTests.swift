import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// Covers `createSession` reusing the stored row for a node that was logged into before.
@Suite("RemoteNodeService session reuse")
struct RemoteNodeSessionReuseTests {
  private static let publicKey = Data(repeating: 0xCC, count: 32)

  @Test
  func `logging in again keeps the favorite flag and other preserved fields`() async throws {
    let radioID = UUID()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let existing = RemoteNodeSessionDTO.testSession(
      radioID: radioID,
      publicKey: Self.publicKey,
      role: .repeater,
      unreadCount: 3,
      notificationLevel: .muted,
      isFavorite: true
    )
    try await dataStore.saveRemoteNodeSessionDTO(existing)
    let contact = ContactDTO.testContact(
      radioID: radioID,
      publicKey: Self.publicKey,
      typeRawValue: ContactType.repeater.rawValue
    )
    let service = RemoteNodeService(
      session: MockMeshCoreSession(),
      dataStore: dataStore,
      keychainService: KeychainService()
    )

    let saved = try await service.createSession(radioID: radioID, contact: contact)

    #expect(saved.id == existing.id)
    #expect(saved.isFavorite)
    #expect(saved.unreadCount == 3)
    #expect(saved.notificationLevel == .muted)
  }

  @Test
  func `a first login starts without the favorite flag`() async throws {
    let radioID = UUID()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let contact = ContactDTO.testContact(
      radioID: radioID,
      publicKey: Self.publicKey,
      typeRawValue: ContactType.repeater.rawValue
    )
    let service = RemoteNodeService(
      session: MockMeshCoreSession(),
      dataStore: dataStore,
      keychainService: KeychainService()
    )

    let saved = try await service.createSession(radioID: radioID, contact: contact)

    #expect(!saved.isFavorite)
  }
}
