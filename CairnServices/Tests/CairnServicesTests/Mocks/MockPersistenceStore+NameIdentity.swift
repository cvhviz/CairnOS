import Foundation
@testable import CairnServices

// MARK: - NameIdentityPersisting

extension MockPersistenceStore {
  public func updateMessageSentAsNodeName(id: UUID, name: String) async throws {
    messages[id]?.sentAsNodeName = name
  }

  public func updateRemoteNodeSessionName(id _: UUID, name _: String) async throws {}

  public func markOwnReactions(radioID _: UUID, selfNames _: Set<String>) async throws -> Int { 0 }

  public func removeRoomPostsFiledAsDirectMessages(radioID _: UUID, roomContactIDs _: [UUID]) async throws -> [MessageDTO] { [] }
}
