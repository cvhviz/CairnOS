import Foundation
import SwiftData

// MARK: - Discovered nodes import

public extension PersistenceStore {
  /// What importing `nodes` into this radio's list would do. Writes nothing.
  func planDiscoveredNodesImport(
    _ nodes: [DiscoveredNodesFile.Node],
    radioID: UUID,
    selfPublicKey: Data?
  ) throws -> DiscoveredNodesImportPlan.Summary {
    try makeDiscoveredNodesImportPlan(nodes, radioID: radioID, selfPublicKey: selfPublicKey).plan.summary
  }

  /// Imports `nodes` into this radio's list, whatever radio the file came from. The plan is
  /// made again here, in the same isolation as the write, so adverts heard since the preview
  /// are taken into account.
  @discardableResult
  func importDiscoveredNodes(
    _ nodes: [DiscoveredNodesFile.Node],
    radioID: UUID,
    selfPublicKey: Data?
  ) throws -> DiscoveredNodesImportPlan.Summary {
    let (plan, rows) = try makeDiscoveredNodesImportPlan(nodes, radioID: radioID, selfPublicKey: selfPublicKey)
    guard plan.summary.changesAnything else { return plan.summary }

    do {
      for node in plan.updates {
        guard let row = rows[node.publicKey] else { continue }
        row.name = node.name
        row.typeRawValue = node.type.rawValue
        row.latitude = node.latitude ?? 0
        row.longitude = node.longitude ?? 0
        row.lastAdvertTimestamp = node.lastAdvertTimestamp
        // Route and hop count stay: they are what this radio learned, not what the file's did.
        row.lastHeard = max(row.lastHeard, node.lastHeard)
      }
      for node in plan.inserts {
        modelContext.insert(DiscoveredNode(
          radioID: radioID,
          publicKey: node.publicKey,
          name: node.name,
          typeRawValue: node.type.rawValue,
          lastHeard: node.lastHeard,
          lastAdvertTimestamp: node.lastAdvertTimestamp,
          latitude: node.latitude ?? 0,
          longitude: node.longitude ?? 0
        ))
      }
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    return plan.summary
  }

  private func makeDiscoveredNodesImportPlan(
    _ nodes: [DiscoveredNodesFile.Node],
    radioID: UUID,
    selfPublicKey: Data?
  ) throws -> (plan: DiscoveredNodesImportPlan, rows: [Data: DiscoveredNode]) {
    let targetRadioID = radioID
    let descriptor = FetchDescriptor<DiscoveredNode>(predicate: #Predicate { $0.radioID == targetRadioID })
    let rows = try Dictionary(
      modelContext.fetch(descriptor).map { ($0.publicKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let plan = try DiscoveredNodesImportPlan.make(
      nodes: nodes,
      existingAdvertTimestamps: rows.mapValues(\.lastAdvertTimestamp),
      contactKeys: fetchContactPublicKeys(radioID: radioID),
      selfPublicKey: selfPublicKey
    )
    return (plan, rows)
  }
}
