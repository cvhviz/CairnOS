import Foundation

/// What importing a discovered-nodes file would do to one radio's list, worked out before
/// anything is written so the user can be shown it first.
public struct DiscoveredNodesImportPlan: Sendable, Equatable {
  /// The counts shown before and after an import.
  public struct Summary: Sendable, Equatable {
    /// Valid nodes in the file, one per public key.
    public var fileNodeCount = 0
    /// Nodes that are not in the list yet and fit in it.
    public var newCount = 0
    /// Nodes in the list whose record in the file has a newer advert.
    public var updatedCount = 0
    /// Nodes in the list whose own record is as new as the file's or newer.
    public var unchangedCount = 0
    /// Nodes that are on the radio's contact list, or are the radio itself.
    public var alreadyKnownCount = 0
    /// New nodes left out because the list is full.
    public var overCapacityCount = 0

    public init() {}

    public var changesAnything: Bool {
      newCount > 0 || updatedCount > 0
    }
  }

  /// New rows, newest heard first.
  public let inserts: [DiscoveredNodesFile.Node]
  public let updates: [DiscoveredNodesFile.Node]
  public let summary: Summary

  /// - Parameters:
  ///   - nodes: Valid nodes from the file, one per public key.
  ///   - existingAdvertTimestamps: Advert timestamp of every node already in the list, by key.
  ///   - contactKeys: Public keys on the radio's contact list.
  ///   - selfPublicKey: The radio's own key, which it never lists as a node.
  ///   - capacity: The most rows the list may hold.
  public static func make(
    nodes: [DiscoveredNodesFile.Node],
    existingAdvertTimestamps: [Data: UInt32],
    contactKeys: Set<Data>,
    selfPublicKey: Data?,
    capacity: Int = PersistenceStore.maxDiscoveredNodes
  ) -> DiscoveredNodesImportPlan {
    var summary = Summary()
    summary.fileNodeCount = nodes.count
    var updates: [DiscoveredNodesFile.Node] = []
    var candidates: [DiscoveredNodesFile.Node] = []

    for node in nodes {
      if contactKeys.contains(node.publicKey) || node.publicKey == selfPublicKey {
        summary.alreadyKnownCount += 1
      } else if let existing = existingAdvertTimestamps[node.publicKey] {
        if node.lastAdvertTimestamp > existing {
          updates.append(node)
        } else {
          summary.unchangedCount += 1
        }
      } else {
        candidates.append(node)
      }
    }

    // Rows already in the list keep their place; the file only fills what room is left.
    let room = max(0, capacity - existingAdvertTimestamps.count)
    let newestFirst = candidates.sorted { lhs, rhs in
      if lhs.lastHeard != rhs.lastHeard {
        return lhs.lastHeard > rhs.lastHeard
      }
      return lhs.publicKey.lexicographicallyPrecedes(rhs.publicKey)
    }
    let inserts = Array(newestFirst.prefix(room))

    summary.newCount = inserts.count
    summary.updatedCount = updates.count
    summary.overCapacityCount = candidates.count - inserts.count
    return DiscoveredNodesImportPlan(inserts: inserts, updates: updates, summary: summary)
  }
}
