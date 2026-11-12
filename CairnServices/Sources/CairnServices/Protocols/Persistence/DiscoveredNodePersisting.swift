import Foundation

/// Store operations for discovered (not yet added) mesh nodes.
public protocol DiscoveredNodePersisting: Actor {
  /// Insert or update a discovered node from an advertisement frame.
  /// Updates lastHeard timestamp if node already exists.
  /// - Returns: Tuple of (DiscoveredNodeDTO, isNew) where isNew is true only if node was newly created
  func upsertDiscoveredNode(radioID: UUID, from frame: ContactFrame) async throws -> (node: DiscoveredNodeDTO, isNew: Bool)

  /// Stamp the inbound advert hop count onto an existing discovered node, keyed by public key.
  /// Tracks the latest advert: a newer advertTimestamp always replaces the stored count;
  /// equal timestamps keep the closest copy of that broadcast. No-op if no matching row exists;
  /// the next advert upsert creates it.
  func setInboundHopCount(radioID: UUID, publicKey: Data, hopCount: Int, advertTimestamp: UInt32?) async throws

  /// Fetch all discovered nodes for a device.
  func fetchDiscoveredNodes(radioID: UUID) async throws -> [DiscoveredNodeDTO]

  /// Delete a discovered node by ID.
  func deleteDiscoveredNode(id: UUID) async throws

  /// Clear all discovered nodes for a device.
  func clearDiscoveredNodes(radioID: UUID) async throws

  /// Delete the discovered (heard) records of the given nodes on one radio: deleting a node forgets
  /// it (`ContactService.removeContact`). A node heard again afterwards gets a new record.
  /// - Returns: How many records were deleted.
  @discardableResult
  func deleteDiscoveredNodes(radioID: UUID, publicKeys: Set<Data>) async throws -> Int

  /// Batch fetch all contact public keys for efficient "added" state lookup.
  /// Returns public keys of confirmed (non-discovered) contacts only.
  func fetchContactPublicKeys(radioID: UUID) async throws -> Set<Data>
}

extension DiscoveredNodePersisting {
  /// One record at a time through the single delete; `PersistenceStore` does it in one save.
  @discardableResult
  public func deleteDiscoveredNodes(radioID: UUID, publicKeys: Set<Data>) async throws -> Int {
    guard !publicKeys.isEmpty else { return 0 }
    let matches = try await fetchDiscoveredNodes(radioID: radioID).filter { publicKeys.contains($0.publicKey) }
    for node in matches {
      try await deleteDiscoveredNode(id: node.id)
    }
    return matches.count
  }
}
