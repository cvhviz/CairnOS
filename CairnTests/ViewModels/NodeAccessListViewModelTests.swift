import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("NodeAccessListViewModel")
@MainActor
struct NodeAccessListViewModelTests {
  private let nodeKey = Data(repeating: 0x42, count: 32)
  private let memberKey = Data(repeating: 0x07, count: 32)

  /// Scripted node: what the ACL request returns and how `setperm` answers.
  @MainActor
  private final class ScriptedNode {
    var entries: [ACLEntry] = []
    var fetchError: Error?
    var commandError: Error?
    /// Applied to `entries` when a command arrives, whether or not the reply makes it back.
    var entriesAfterCommand: [ACLEntry]?
    var fetchCount = 0
  }

  private func entry(_ role: AccessListRole) -> ACLEntry {
    ACLEntry(keyPrefix: memberKey.prefix(6), permissions: role.rawValue)
  }

  private func makeViewModel(_ node: ScriptedNode) -> NodeAccessListViewModel {
    let viewModel = NodeAccessListViewModel()
    let candidates = [AccessListCandidate(publicKey: memberKey, name: "Member", isChatContact: true)]
    viewModel.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(),
        publicKey: nodeKey,
        name: "Hill",
        role: .repeater,
        isConnected: true,
        permissionLevel: .admin
      ),
      dependencies: .init(
        fetchACL: { [nodeKey] _ in
          node.fetchCount += 1
          if let error = node.fetchError { throw error }
          return ACLResponse(publicKeyPrefix: nodeKey.prefix(6), tag: Data(), entries: node.entries)
        },
        sendCommand: { _, _ in
          if let entries = node.entriesAfterCommand { node.entries = entries }
          if let error = node.commandError { throw error }
          return "OK"
        },
        loadCandidates: { candidates },
        selfPublicKey: { nil }
      )
    )
    return viewModel
  }

  @Test
  func `a failed first load shows the inline error`() async {
    let node = ScriptedNode()
    node.fetchError = RemoteNodeError.timeout
    let viewModel = makeViewModel(node)

    await viewModel.load()

    #expect(!viewModel.hasLoaded)
    #expect(viewModel.loadError == L10n.RemoteNodes.RemoteNodes.Status.requestTimedOut)
    #expect(viewModel.errorMessage == nil)
  }

  @Test
  func `a failed reload keeps the rows and raises an alert`() async {
    let node = ScriptedNode()
    node.entries = [entry(.readOnly)]
    let viewModel = makeViewModel(node)
    await viewModel.load()
    #expect(viewModel.items.map(\.role) == [.readOnly])

    node.fetchError = RemoteNodeError.timeout
    await viewModel.load()

    #expect(viewModel.items.map(\.role) == [.readOnly])
    #expect(viewModel.loadError == nil)
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Status.requestTimedOut)
  }

  @Test
  func `a setperm timeout still re-reads what the node applied`() async throws {
    let node = ScriptedNode()
    node.entries = [entry(.readOnly)]
    let viewModel = makeViewModel(node)
    await viewModel.load()
    let item = try #require(viewModel.items.first)

    node.commandError = RemoteNodeError.timeout
    node.entriesAfterCommand = [entry(.admin)]
    await viewModel.setRole(.admin, for: item)

    #expect(node.fetchCount == 2)
    #expect(viewModel.items.map(\.role) == [.admin])
    #expect(viewModel.errorMessage == L10n.RemoteNodes.RemoteNodes.Status.requestTimedOut)
  }

  @Test
  func `a setperm that fails outright does not re-read`() async throws {
    let node = ScriptedNode()
    node.entries = [entry(.readOnly)]
    let viewModel = makeViewModel(node)
    await viewModel.load()
    let item = try #require(viewModel.items.first)

    node.commandError = RemoteNodeError.notConnected
    await viewModel.setRole(.admin, for: item)

    #expect(node.fetchCount == 1)
    #expect(viewModel.items.map(\.role) == [.readOnly])
    #expect(viewModel.errorMessage != nil)
  }
}
