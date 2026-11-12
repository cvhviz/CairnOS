import CairnServices
import MeshCore
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeAccessListVM")

/// Loads a repeater/room access control list over the binary protocol and edits it with the
/// firmware's `setperm` CLI command.
@Observable
@MainActor
final class NodeAccessListViewModel {
  struct Dependencies {
    let fetchACL: @MainActor (Data) async throws -> ACLResponse
    let sendCommand: @MainActor (_ sessionID: UUID, _ command: String) async throws -> String
    let loadCandidates: @MainActor () async -> [AccessListCandidate]
    let selfPublicKey: @MainActor () -> Data?
  }

  private(set) var items: [AccessListItem] = []
  private(set) var candidates: [AccessListCandidate] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  /// Inline load failure shown in place of the list.
  private(set) var loadError: String?
  /// Prefix of the entry whose change is in flight.
  private(set) var pendingPrefix: Data?
  private(set) var isAdding = false
  /// Action failure presented through `errorAlert`.
  var errorMessage: String?

  private var dependencies: Dependencies?
  private var session: RemoteNodeSessionDTO?

  static let commandTimeout: Duration = .seconds(10)

  func configure(session: RemoteNodeSessionDTO, dependencies: Dependencies) {
    self.session = session
    self.dependencies = dependencies
  }

  var isBusy: Bool { isLoading || pendingPrefix != nil || isAdding }

  /// Contacts that can be added: complete keys not already on the list.
  var addableCandidates: [AccessListCandidate] {
    let existing = items.map(\.keyPrefix)
    let selfKey = dependencies?.selfPublicKey()
    return candidates.filter { candidate in
      candidate.isChatContact
        && candidate.publicKey.count == AccessListCommand.fullKeyLength
        && candidate.publicKey != session?.publicKey
        && candidate.publicKey != selfKey
        && !existing.contains { candidate.publicKey.starts(with: $0) }
    }
  }

  func load() async {
    guard let dependencies, let session, !isLoading else { return }
    isLoading = true
    loadError = nil
    defer { isLoading = false }

    if candidates.isEmpty {
      candidates = await dependencies.loadCandidates()
    }
    do {
      let response = try await dependencies.fetchACL(session.publicKey)
      items = AccessListResolver.items(
        from: response.entries,
        candidates: candidates,
        selfPublicKey: dependencies.selfPublicKey()
      )
      hasLoaded = true
    } catch is CancellationError {
      return
    } catch {
      logger.info("ACL request failed: \(error.localizedDescription)")
      // The inline failure state only replaces the list before the first load; after that the
      // rows stay on screen, so a failed re-read has to be reported as an alert.
      if hasLoaded {
        errorMessage = Self.message(for: error)
      } else {
        loadError = Self.message(for: error)
      }
    }
  }

  func setRole(_ role: AccessListRole, for item: AccessListItem) async {
    guard let key = item.fullPublicKey,
          let command = AccessListCommand.setRole(role, publicKey: key) else { return }
    pendingPrefix = item.keyPrefix
    defer { pendingPrefix = nil }
    await run(command)
  }

  func remove(_ item: AccessListItem) async {
    guard item.canRemove, let command = AccessListCommand.remove(keyPrefix: item.keyPrefix) else { return }
    pendingPrefix = item.keyPrefix
    defer { pendingPrefix = nil }
    await run(command)
  }

  func add(_ candidate: AccessListCandidate, role: AccessListRole) async {
    guard let command = AccessListCommand.setRole(role, publicKey: candidate.publicKey) else { return }
    isAdding = true
    defer { isAdding = false }
    await run(command)
  }

  /// Sends a `setperm` command, then re-reads the list so it reflects the node's state.
  private func run(_ command: String) async {
    guard let dependencies, let session else { return }
    do {
      let reply = try await dependencies.sendCommand(session.id, command)
      guard AccessListCommand.isSuccess(reply) else {
        errorMessage = L10n.RemoteNodes.RemoteNodes.Acl.Error.rejected(
          reply.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return
      }
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
      // A lost reply doesn't mean the node ignored the command, so still re-read what it holds.
      guard Self.isTimeout(error) else { return }
    }
    await load()
  }

  private static func isTimeout(_ error: Error) -> Bool {
    switch error {
    case RemoteNodeError.timeout, BinaryProtocolError.sessionError(MeshCoreError.timeout): true
    default: false
    }
  }

  private static func message(for error: Error) -> String {
    isTimeout(error) ? L10n.RemoteNodes.RemoteNodes.Status.requestTimedOut : error.userFacingMessage
  }
}
