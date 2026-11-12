import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// Settings → Nodes → Remove Nodes (`NodeRemovalModel`): both removals, from the count through
/// the confirmation to how each run ends, against a stand-in radio.
@Suite("Node removal model")
@MainActor
struct NodeRemovalModelTests {
  private struct RadioFailure: Error {}

  /// Stands in for the radio: counts and removes without a connection.
  @MainActor
  private final class FakeNodeRemover: NodeRemoving {
    var count = 0
    var countError: (any Error)?
    var result = RemoveUnfavoritedResult(removed: 0, total: 0)
    var removeError: (any Error)?
    var progressSteps: [Int] = []
    /// The nodes the run reports it will remove (`onStart`).
    var targets: Set<Data> = []
    /// Holds the removal open after its progress steps until the test releases it.
    var holdsRemoval = false
    private(set) var countCalls = 0
    private(set) var removeAllCalls = 0
    private(set) var removeUnfavoritedCalls = 0
    private var release: CheckedContinuation<Void, Never>?
    private var isHeld = false

    func removableNodeCount() async throws -> Int {
      try countResult()
    }

    func unfavoritedNodeCount() async throws -> Int {
      try countResult()
    }

    func removeAllNodes(
      onStart: (_ targets: Set<Data>) -> Void,
      onProgress: (_ removed: Int, _ total: Int) -> Void
    ) async throws -> RemoveUnfavoritedResult {
      removeAllCalls += 1
      return try await remove(onStart: onStart, onProgress: onProgress)
    }

    func removeUnfavoritedNodes(
      onStart: (_ targets: Set<Data>) -> Void,
      onProgress: (_ removed: Int, _ total: Int) -> Void
    ) async throws -> RemoveUnfavoritedResult {
      removeUnfavoritedCalls += 1
      return try await remove(onStart: onStart, onProgress: onProgress)
    }

    private func countResult() throws -> Int {
      countCalls += 1
      if let countError { throw countError }
      return count
    }

    private func remove(
      onStart: (_ targets: Set<Data>) -> Void,
      onProgress: (_ removed: Int, _ total: Int) -> Void
    ) async throws -> RemoveUnfavoritedResult {
      if !targets.isEmpty {
        onStart(targets)
      }
      for step in progressSteps {
        onProgress(step, result.total)
      }
      if holdsRemoval {
        isHeld = true
        await withCheckedContinuation { release = $0 }
      }
      try Task.checkCancellation()
      if let removeError { throw removeError }
      return result
    }

    func waitUntilHeld() async {
      while !isHeld {
        await Task.yield()
      }
    }

    func releaseRemoval() {
      release?.resume()
      release = nil
    }
  }

  private static func makeModel(remover: FakeNodeRemover) -> NodeRemovalModel {
    NodeRemovalModel(remover: remover, successDisplayDuration: .seconds(60))
  }

  private static func waitForRemovalToEnd(_ model: NodeRemovalModel) async {
    while model.isRemovingNodes {
      await Task.yield()
    }
  }

  // MARK: - Count

  @Test
  func `asks for confirmation with the number of nodes`() async {
    let remover = FakeNodeRemover()
    remover.count = 42
    let model = Self.makeModel(remover: remover)

    await model.fetchAllNodesCount()
    await model.fetchUnfavoritedCount()

    #expect(model.allNodesCount == 42)
    #expect(model.showingRemoveAllAlert)
    #expect(model.unfavoritedCount == 42)
    #expect(model.showingRemoveUnfavoritedAlert)
    #expect(!model.showRemoveResult)
    #expect(remover.removeAllCalls == 0)
    #expect(remover.removeUnfavoritedCalls == 0)
  }

  @Test
  func `reports that there is nothing to remove`() async {
    let remover = FakeNodeRemover()
    let model = Self.makeModel(remover: remover)

    await model.fetchUnfavoritedCount()

    #expect(!model.showingRemoveUnfavoritedAlert)
    #expect(model.showRemoveResult)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.RemoveUnfavorited.noneFound)
  }

  @Test
  func `a count without a connection reports the error`() async {
    let remover = FakeNodeRemover()
    remover.countError = ConnectionError.notConnected
    let model = Self.makeModel(remover: remover)

    await model.fetchAllNodesCount()

    #expect(!model.showingRemoveAllAlert)
    #expect(!model.showRemoveResult)
    #expect(model.errorMessage == ConnectionError.notConnected.userFacingMessage)
  }

  // MARK: - Removal

  @Test
  func `removing every non-favorite shows the success label`() async {
    let remover = FakeNodeRemover()
    remover.result = RemoveUnfavoritedResult(removed: 3, total: 3)
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    #expect(model.isRemovingUnfavorited)
    await Self.waitForRemovalToEnd(model)
    await Task.yield()

    #expect(model.showRemoveSuccess)
    #expect(!model.showRemoveAllSuccess)
    #expect(!model.showRemoveResult)
    #expect(model.errorMessage == nil)
    #expect(remover.removeUnfavoritedCalls == 1)
  }

  @Test
  func `removing every node shows the success label`() async {
    let remover = FakeNodeRemover()
    remover.result = RemoveUnfavoritedResult(removed: 3, total: 3)
    let model = Self.makeModel(remover: remover)

    model.removeAllNodes()
    await Self.waitForRemovalToEnd(model)
    await Task.yield()

    #expect(model.showRemoveAllSuccess)
    #expect(!model.showRemoveResult)
    #expect(remover.removeAllCalls == 1)
  }

  /// The report: nodes stayed in the Saved list while the radio worked through them one at a
  /// time. The run's nodes leave the list and the maps as it starts, and come back (any the
  /// radio didn't remove) only when it ends.
  @Test
  func `the nodes being removed are held from the start of the run to its end`() async {
    let remover = FakeNodeRemover()
    let keys: Set<Data> = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
    remover.targets = keys
    remover.holdsRemoval = true
    remover.result = RemoveUnfavoritedResult(removed: 1, total: 2, failure: RadioFailure())
    let model = Self.makeModel(remover: remover)
    #expect(model.removingKeys.isEmpty)

    model.removeUnfavoritedNodes()
    await remover.waitUntilHeld()
    #expect(model.removingKeys == keys)

    remover.releaseRemoval()
    await Self.waitForRemovalToEnd(model)
    #expect(model.removingKeys.isEmpty)
  }

  /// The report: "it gives me warning that it will delete N nodes … it doesn't delete anything".
  /// A run that finds nothing to do (0 of 0) must not read as a success after a count of N.
  @Test
  func `a run that finds nothing to remove does not claim success`() async {
    let remover = FakeNodeRemover()
    remover.count = 5
    remover.result = RemoveUnfavoritedResult(removed: 0, total: 0)
    let model = Self.makeModel(remover: remover)

    await model.fetchUnfavoritedCount()
    model.removeUnfavoritedNodes()
    await Self.waitForRemovalToEnd(model)

    #expect(!model.showRemoveSuccess)
    #expect(model.showRemoveResult)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.RemoveUnfavorited.noneFound)
  }

  /// The report again: the radio refused or never answered the first command, so nothing was
  /// removed. The user must be told, with the reason.
  @Test
  func `a run the radio stops says how far it got and why`() async {
    let remover = FakeNodeRemover()
    let failure = ContactServiceError.sessionError(.timeout)
    remover.result = RemoveUnfavoritedResult(removed: 0, total: 40, failure: failure)
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    await Self.waitForRemovalToEnd(model)

    #expect(!model.showRemoveSuccess)
    #expect(model.showRemoveResult)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.Removal.stopped(0, 40, failure.userFacingMessage))
    #expect(model.errorMessage == nil)
  }

  @Test
  func `a partial removal of every node reports how many were removed and how many were not`() async {
    let remover = FakeNodeRemover()
    let failure = RadioFailure()
    remover.result = RemoveUnfavoritedResult(removed: 12, total: 40, failure: failure)
    let model = Self.makeModel(remover: remover)

    model.removeAllNodes()
    await Self.waitForRemovalToEnd(model)

    #expect(model.showRemoveResult)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.Removal.stopped(12, 28, failure.userFacingMessage))
    #expect(!model.showRemoveAllSuccess)
  }

  @Test
  func `local copies that could not be deleted are reported`() async {
    let remover = FakeNodeRemover()
    remover.result = RemoveUnfavoritedResult(removed: 2, total: 3)
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    await Self.waitForRemovalToEnd(model)

    #expect(!model.showRemoveSuccess)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.RemoveUnfavorited.partial(2, 3))
  }

  @Test
  func `a removal that cannot start reports the error`() async {
    let remover = FakeNodeRemover()
    remover.removeError = ConnectionError.notConnected
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    await Self.waitForRemovalToEnd(model)

    #expect(model.errorMessage == ConnectionError.notConnected.userFacingMessage)
    #expect(!model.showRemoveResult)
    #expect(!model.showRemoveSuccess)
  }

  @Test
  func `progress feeds the button label for either removal`() async {
    let remover = FakeNodeRemover()
    remover.result = RemoveUnfavoritedResult(removed: 5, total: 5)
    remover.progressSteps = [0, 2]
    remover.holdsRemoval = true
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    #expect(model.progressText == L10n.Settings.DangerZone.removing)
    await remover.waitUntilHeld()

    #expect(model.isRemovingUnfavorited)
    #expect(model.isRemovingNodes)
    #expect(model.progress?.removed == 2)
    #expect(model.progress?.total == 5)
    #expect(model.progressText == L10n.Settings.DangerZone.removingProgress(2, 5))

    remover.releaseRemoval()
    await Self.waitForRemovalToEnd(model)
    #expect(model.progress == nil)
  }

  @Test
  func `a second removal does not start while one is running`() async {
    let remover = FakeNodeRemover()
    remover.result = RemoveUnfavoritedResult(removed: 1, total: 1)
    remover.holdsRemoval = true
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    await remover.waitUntilHeld()
    model.removeAllNodes()
    model.removeUnfavoritedNodes()

    #expect(remover.removeUnfavoritedCalls == 1)
    #expect(remover.removeAllCalls == 0)

    remover.releaseRemoval()
    await Self.waitForRemovalToEnd(model)
  }

  /// The bug: the removal belonged to the screen and `onDisappear` cancelled it, silently. The
  /// model now outlives the screen and has no cancel: a removal started from a sheet that is then
  /// closed runs to the end, and its outcome waits for the screen.
  @Test
  func `a removal outlives the screen that started it and keeps its outcome`() async {
    let remover = FakeNodeRemover()
    let failure = ContactServiceError.sessionError(.timeout)
    remover.result = RemoveUnfavoritedResult(removed: 3, total: 10, failure: failure)
    remover.holdsRemoval = true
    let model = Self.makeModel(remover: remover)

    model.removeUnfavoritedNodes()
    await remover.waitUntilHeld()
    // The sheet closes here; nothing reaches the model. The radio then finishes.
    remover.releaseRemoval()
    await Self.waitForRemovalToEnd(model)

    #expect(remover.removeUnfavoritedCalls == 1)
    #expect(model.showRemoveResult)
    #expect(model.removeResult == L10n.Settings.DangerZone.Alert.Removal.stopped(3, 7, failure.userFacingMessage))
  }
}
