import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// A page's automatic reads run at background priority; a user's request to the same node must
/// not wait behind them.
@Suite("RemoteRequestPriority")
struct RemoteRequestPriorityTests {
  private static let publicKey = Data(repeating: 0xCC, count: 32)
  private static let prefix = Data(publicKey.prefix(6))

  private func makeService() async throws -> RemoteNodeService {
    let radioID = UUID()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    return RemoteNodeService(
      session: MockMeshCoreSession(),
      dataStore: dataStore,
      keychainService: KeychainService()
    )
  }

  @Test
  func `a background request waits while the user has one in flight`() async throws {
    let service = try await makeService()
    await service.beginUserAction(for: Self.prefix)

    let background = Task {
      await RemoteRequestPriority.$current.withValue(.background) {
        await service.yieldToUserActions(publicKey: Self.publicKey)
      }
      return Date()
    }

    try await Task.sleep(for: .milliseconds(600))
    let released = Date()
    await service.endUserAction(for: Self.prefix)
    let resumed = await background.value
    #expect(resumed >= released)
  }

  @Test
  func `a user request never waits on the gate`() async throws {
    let service = try await makeService()
    await service.beginUserAction(for: Self.prefix)

    // Default priority is .user: returns at once even with another user request in flight.
    await service.yieldToUserActions(publicKey: Self.publicKey)
    await service.endUserAction(for: Self.prefix)
  }

  @Test
  func `a background request to another node is not held up`() async throws {
    let service = try await makeService()
    await service.beginUserAction(for: Data(repeating: 0xAA, count: 6))

    await RemoteRequestPriority.$current.withValue(.background) {
      await service.yieldToUserActions(publicKey: Self.publicKey)
    }
  }

  @Test
  func `counts balance across overlapping user requests`() async throws {
    let service = try await makeService()
    await service.beginUserAction(for: Self.prefix)
    await service.beginUserAction(for: Self.prefix)
    await service.endUserAction(for: Self.prefix)
    #expect(await service.userActionCounts[Self.prefix] == 1)
    await service.endUserAction(for: Self.prefix)
    #expect(await service.userActionCounts[Self.prefix] == nil)
  }
}
