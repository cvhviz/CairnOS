import Foundation

/// Result of removing a set of nodes from the device and the app.
public struct RemoveUnfavoritedResult: Sendable {
  public let removed: Int
  public let total: Int
  /// Why the run stopped before the end, when it did: the radio refused or didn't answer, the
  /// link dropped, or the app couldn't delete its copy. Nil when every node was tried.
  public let failure: (any Error)?

  public init(removed: Int, total: Int, failure: (any Error)? = nil) {
    self.removed = removed
    self.total = total
    self.failure = failure
  }

  /// Every node it set out to remove is gone, and there was at least one.
  public var removedAll: Bool {
    total > 0 && removed == total && failure == nil
  }
}
