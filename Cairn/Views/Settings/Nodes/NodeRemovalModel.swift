import CairnServices
import SwiftUI

/// Settings → Nodes → Remove Nodes: the two removals (non-favorites, every node), their
/// confirmations, their progress and how each ended.
///
/// Owned by `AppState` (`nodeRemoval`), not by the screen. A removal is one radio command per
/// node, often queued behind the sync that follows a connection, so it can easily outlast the
/// sheet it started from: Done, a swipe down, a tab switch. It used to live in the screen's own
/// view model and was cancelled from `onDisappear`, which ended it silently, often before the
/// first node was removed. Nothing in the view's lifetime stops a removal now; it ends on its
/// own (done, or stopped by the radio or the link), and whatever it ends with stays here until
/// the screen shows it.
@Observable
@MainActor
final class NodeRemovalModel {
  enum Kind: Equatable {
    case unfavorited
    case all
  }

  /// The removal in flight, if any. Both share the radio, so only one runs at a time.
  private(set) var running: Kind?
  /// Running count of the removal in flight, for the button label.
  private(set) var progress: (removed: Int, total: Int)?
  /// The nodes the removal in flight is taking off the radio, by public key, from the moment it
  /// starts until it ends. The node list and the map leave them out meanwhile, so a removal of
  /// hundreds of nodes (one radio command each) shows at once; a node the radio fails to remove
  /// is still saved, so it reappears when the run ends.
  private(set) var removingKeys: Set<Data> = []
  /// The removal that just finished cleanly: its button shows "Removed" for a moment.
  private(set) var justRemoved: Kind?

  var showingRemoveUnfavoritedAlert = false
  var showingRemoveAllAlert = false
  private(set) var unfavoritedCount = 0
  private(set) var allNodesCount = 0

  /// An outcome to report: nothing to remove, or a run that stopped part way and why.
  var showRemoveResult = false
  private(set) var removeResult: String?
  /// A removal that could not start, or a count that could not be read.
  var errorMessage: String?

  var isRemovingUnfavorited: Bool { running == .unfavorited }
  var isRemovingAll: Bool { running == .all }
  var isRemovingNodes: Bool { running != nil }
  var showRemoveSuccess: Bool { justRemoved == .unfavorited }
  var showRemoveAllSuccess: Bool { justRemoved == .all }

  var progressText: String {
    guard let progress else { return L10n.Settings.DangerZone.removing }
    return L10n.Settings.DangerZone.removingProgress(progress.removed, progress.total)
  }

  private let remover: any NodeRemoving
  private let successDisplayDuration: Duration

  /// - Parameters:
  ///   - remover: The radio side; the connection manager in the app, a stand-in in tests.
  ///   - successDisplayDuration: How long the "Removed" label stays on the button.
  init(remover: any NodeRemoving, successDisplayDuration: Duration = .seconds(1.5)) {
    self.remover = remover
    self.successDisplayDuration = successDisplayDuration
  }

  // MARK: - Count, then confirm

  func fetchUnfavoritedCount() async {
    do {
      unfavoritedCount = try await remover.unfavoritedNodeCount()
      if unfavoritedCount == 0 {
        report(L10n.Settings.DangerZone.Alert.RemoveUnfavorited.noneFound)
      } else {
        showingRemoveUnfavoritedAlert = true
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  func fetchAllNodesCount() async {
    do {
      allNodesCount = try await remover.removableNodeCount()
      if allNodesCount == 0 {
        report(L10n.Settings.DangerZone.Alert.RemoveAll.noneFound)
      } else {
        showingRemoveAllAlert = true
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  // MARK: - Remove

  func removeUnfavoritedNodes() {
    start(.unfavorited)
  }

  func removeAllNodes() {
    start(.all)
  }

  private func start(_ kind: Kind) {
    guard running == nil else { return }
    running = kind
    progress = nil
    justRemoved = nil
    // Unstructured and never cancelled: see the type's comment.
    Task { await run(kind) }
  }

  private func run(_ kind: Kind) async {
    let result: RemoveUnfavoritedResult
    do {
      let onStart: (Set<Data>) -> Void = { [weak self] keys in
        self?.removingKeys = keys
      }
      let onProgress: (Int, Int) -> Void = { [weak self] removed, total in
        self?.progress = (removed, total)
      }
      result = switch kind {
      case .unfavorited: try await remover.removeUnfavoritedNodes(onStart: onStart, onProgress: onProgress)
      case .all: try await remover.removeAllNodes(onStart: onStart, onProgress: onProgress)
      }
    } catch {
      finish()
      errorMessage = error.userFacingMessage
      return
    }
    finish()

    if result.removedAll {
      withAnimation { justRemoved = kind }
      try? await Task.sleep(for: successDisplayDuration)
      if justRemoved == kind {
        withAnimation { justRemoved = nil }
      }
    } else if result.total == 0 {
      // The confirmation counted nodes that were gone by the time the run looked: say so
      // rather than "Removed".
      report(kind == .all
        ? L10n.Settings.DangerZone.Alert.RemoveAll.noneFound
        : L10n.Settings.DangerZone.Alert.RemoveUnfavorited.noneFound)
    } else if let failure = result.failure {
      report(L10n.Settings.DangerZone.Alert.Removal.stopped(
        result.removed,
        result.total - result.removed,
        failure.userFacingMessage
      ))
    } else {
      // Every node was tried; some local copies couldn't be deleted.
      report(kind == .all
        ? L10n.Settings.DangerZone.Alert.RemoveAll.partial(result.removed, result.total - result.removed)
        : L10n.Settings.DangerZone.Alert.RemoveUnfavorited.partial(result.removed, result.total))
    }
  }

  private func finish() {
    running = nil
    progress = nil
    removingKeys = []
  }

  private func report(_ message: String) {
    removeResult = message
    showRemoveResult = true
  }
}
