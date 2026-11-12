import Foundation
import MeshCore

/// Store operations for the heard-neighbour tables, one per radio and channel. `NeighbourService`
/// keeps the current channel's table in memory and writes only what changed, in one batch, so
/// nothing here runs once per packet.
public protocol NeighbourPersisting: Actor {
  /// Every stored neighbour row of a radio on one channel. Rows whose identity can't be read are
  /// skipped.
  func fetchNeighbourRecords(radioID: UUID, channelKey: ChannelKey) async throws -> [NeighbourRecord]

  /// Writes one batch for one channel in a single save: each record in `upserting` replaces the
  /// row with its identity (or adds one), and the rows named in `removing` are deleted.
  func saveNeighbourRecords(
    radioID: UUID,
    channelKey: ChannelKey,
    upserting records: [NeighbourRecord],
    removing identities: [NeighbourIdentity]
  ) async throws

  /// Deletes a radio's rows not heard since `date`, on `channelKey`, or on every channel when nil.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func pruneNeighbourRecords(radioID: UUID, channelKey: ChannelKey?, notHeardSince date: Date) async throws -> Int

  /// Deletes a radio's rows written before channels were recorded: nothing says which channel
  /// they were heard on, so they are never evidence.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func deleteUnstampedNeighbourRecords(radioID: UUID) async throws -> Int

  /// Deletes every neighbour row of a radio, on every channel.
  func clearNeighbourRecords(radioID: UUID) async throws

  /// What the neighbour table and the observation ledger need from a radio's RX log entries
  /// received on `channelKey` at or after `since`: the newest `limit`, oldest first. Entries
  /// stamped with another channel, or with none, are left out. Reads only those fields, so
  /// warming the table from a full log stays fast.
  func fetchNeighbourReplay(radioID: UUID, channelKey: ChannelKey, since: Date, limit: Int) async throws -> [NeighbourReplayEntry]
}

/// One stored RX log entry, reduced to what neighbour evidence and observations are read from.
/// Its fields carry the whole packet payload, so an advert's signature can be checked.
public struct NeighbourReplayEntry: Sendable, Equatable {
  public let receivedAt: Date
  public let fields: RxPacketFields
  /// The channel the entry was received on.
  public let channelKey: ChannelKey?
  /// The RX_SYNC position the packet was stored with; nil for a stock 0x88 frame.
  public let radioEpoch: UInt32?
  public let radioSeq: UInt32?

  public init(
    receivedAt: Date,
    fields: RxPacketFields,
    channelKey: ChannelKey? = nil,
    radioEpoch: UInt32? = nil,
    radioSeq: UInt32? = nil
  ) {
    self.receivedAt = receivedAt
    self.fields = fields
    self.channelKey = channelKey
    self.radioEpoch = radioEpoch
    self.radioSeq = radioSeq
  }
}
