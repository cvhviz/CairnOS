import Foundation
import MeshCore

/// Store operations for the observation ledgers: the nodes each radio has observed on each
/// channel (``ObservationLedger``). `NeighbourService` keeps the ledger in memory and writes only
/// what changed, in one batch with the neighbour table, so nothing here runs once per packet.
public protocol ObservationPersisting: Actor {
  /// Every stored node of one radio on one channel. Rows whose identity can't be read are skipped.
  func fetchObservedNodes(radioID: UUID, channelKey: ChannelKey) async throws -> [ObservedNode]

  /// Writes one batch in a single save: each node in `upserting` replaces the row with its
  /// identity (or adds one), and the rows named in `removing` are deleted.
  func saveObservedNodes(
    radioID: UUID,
    channelKey: ChannelKey,
    upserting nodes: [ObservedNode],
    removing identities: [ObservedIdentity]
  ) async throws

  /// Deletes a radio's rows, on every channel, not observed since `date`.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func pruneObservedNodes(radioID: UUID, notObservedSince date: Date) async throws -> Int

  /// Deletes every observed node of a radio, on every channel.
  func clearObservedNodes(radioID: UUID) async throws
}
