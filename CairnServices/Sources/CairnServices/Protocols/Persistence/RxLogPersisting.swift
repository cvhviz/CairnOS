import Foundation
import MeshCore

/// Retention bounds for the RX log radio partition.
///
/// Shared by prune defaults and region reprocess so the fetch window stays
/// aligned with how many rows can exist before pruning.
public enum RxLogRetention {
  /// Rows kept after a prune pass.
  public static let keepCount = 1000

  /// Extra rows allowed before prune runs. Peak retained count between
  /// flush-time prune passes is `keepCount + pruneThreshold + batchSize - 1`.
  public static let pruneThreshold = 100

  /// Inserts between RxLog-initiated `modelContext.save()` calls.
  public static let batchSize = 20

  /// Debounce for a partial batch. Must not be awaited inside `saveRxLogEntry`.
  public static let flushInterval: Duration = .seconds(1)
}

/// Where a Cairn companion's RX_SYNC delivery last reached the store: the radio journal's epoch
/// and the newest record saved under it. The next connection resumes after it.
public struct RxStreamCursor: Sendable, Equatable {
  /// The radio journal's identity (random at each boot).
  public let epoch: UInt32
  /// The newest record saved under ``epoch``.
  public let seq: UInt32

  public init(epoch: UInt32, seq: UInt32) {
    self.epoch = epoch
    self.seq = seq
  }
}

/// Store operations for the per-radio RX_SYNC resume cursor.
public protocol RxStreamCursorPersisting: Actor {
  /// The cursor stored for a radio, or `nil` when none is.
  func fetchRxStreamCursor(radioID: UUID) async throws -> RxStreamCursor?

  /// Stores a radio's cursor; `nil` forgets it (a new journal epoch).
  func saveRxStreamCursor(_ cursor: RxStreamCursor?, radioID: UUID) async throws

  /// The channel the stored RX log entry at `cursor` was stamped with: where the radio was when
  /// the app last took its records. Nil when that entry isn't stored or had no channel.
  func fetchRxStreamCursorChannel(radioID: UUID, cursor: RxStreamCursor) async throws -> ChannelKey?
}

public extension RxStreamCursorPersisting {
  /// Default for test doubles: no entry is stored at the cursor.
  func fetchRxStreamCursorChannel(radioID _: UUID, cursor _: RxStreamCursor) async throws -> ChannelKey? {
    nil
  }
}

/// The writes `RxLogService`'s flush makes: a batch of entries, then the resume cursor.
public protocol RxLogBatchPersisting: RxStreamCursorPersisting {
  /// Inserts a batch of RX log entries and commits them in one save, running the retention
  /// prune once for the batch. Returns only after the commit.
  func saveRxLogEntries(_ dtos: [RxLogEntryDTO]) async throws
}

/// Store operations for RX log entries: persistence, lookup, and batch enrichment.
public protocol RxLogPersisting: RxLogBatchPersisting {
  // MARK: - RxLogEntry Lookup

  /// Find RxLogEntry matching an incoming message for path correlation.
  ///
  /// For channel messages: Correlates by channel index and sender timestamp.
  /// For direct messages: Correlates by sender timestamp and payload type.
  func findRxLogEntry(
    radioID: UUID,
    channelIndex: UInt8?,
    senderTimestamp: UInt32
  ) async throws -> RxLogEntryDTO?

  /// Same channel predicate as `findRxLogEntry`, no fetch limit, oldest `receivedAt` first
  /// so harvest is deterministic.
  func fetchRxLogEntries(
    radioID: UUID,
    channelIndex: UInt8,
    senderTimestamp: UInt32
  ) async throws -> [RxLogEntryDTO]

  /// Find a DM RxLogEntry by matching the sender prefix byte in the packet payload.
  /// Fallback for when the primary timestamp-based lookup fails.
  func findRxLogEntryBySenderPrefix(
    radioID: UUID,
    senderPrefixByte: UInt8,
    receivedSince: Date
  ) async throws -> RxLogEntryDTO?

  // MARK: - RX Log

  /// Save a new RX log entry
  func saveRxLogEntry(_ dto: RxLogEntryDTO) async throws

  /// Commits pending RxLog inserts (if any) and prunes every radio in the
  /// count cache. No-op when there is nothing RxLog-dirty from this API.
  func flushPendingRxLogEntries() async throws

  /// Fetch RX log entries for a device, most recent first
  func fetchRxLogEntries(radioID: UUID, limit: Int) async throws -> [RxLogEntryDTO]

  /// Clear all RX log entries for a device
  func clearRxLogEntries(radioID: UUID) async throws

  /// Delete oldest entries once the log materially exceeds the retention cap
  func pruneRxLogEntries(radioID: UUID, keepCount: Int, pruneThreshold: Int) async throws

  /// Fetch transport-coded RX log entries for region reprocess.
  ///
  /// Bound by prune retention (`limit`, typically
  /// `RxLogRetention.keepCount + RxLogRetention.pruneThreshold`). Scans the
  /// radio partition (indexed `radioID` + `receivedAt`); `transportCode` itself
  /// is unindexed. Includes rows that already have a region label so unique,
  /// multi-match, and clear rewrites all work.
  func fetchEntriesWithTransportCode(radioID: UUID, limit: Int) async throws -> [RxLogEntryDTO]

  /// Fetch recent RX log entries with a given decrypt status
  func fetchRecentEntriesByDecryptStatus(radioID: UUID, status: DecryptStatus, since: Date) async throws -> [RxLogEntryDTO]

  /// Batch update dual region fields on RX log entries by id
  func batchUpdateRxLogRegion(
    updates: [(id: UUID, regionScope: String?, regionScopeMatches: [String])]
  ) async throws

  /// Batch update RX log entries after successful decryption.
  /// Note: decodedText is transient and not persisted.
  func batchUpdateRxLogDecryption(
    _ updates: [(id: UUID, channelIndex: UInt8?, channelName: String?, senderTimestamp: UInt32?)]
  ) async throws

  /// Batch update dual region fields on incoming channel `Message` rows
  /// correlated by `(channelIndex, senderTimestamp)`.
  /// - Returns: IDs of messages that were written (for open-chat invalidation).
  @discardableResult
  func batchUpdateChannelMessageRegion(
    radioID: UUID,
    updates: [(channelIndex: UInt8, senderTimestamp: UInt32, regionScope: String?, regionScopeMatches: [String])]
  ) async throws -> [UUID]

  /// Batch update dual region fields on incoming DM `Message` rows
  /// correlated by `(senderPrefixByte, senderTimestamp)`.
  /// - Returns: IDs of messages that were written (for open-chat invalidation).
  @discardableResult
  func batchUpdateDMMessageRegion(
    radioID: UUID,
    updates: [(senderPrefixByte: UInt8, senderTimestamp: UInt32, regionScope: String?, regionScopeMatches: [String])]
  ) async throws -> [UUID]
}

// MARK: - Default Parameter Values

extension RxLogPersisting {
  func flushPendingRxLogEntries() async throws {}

  /// Fetch RX log entries with the default limit of 500
  func fetchRxLogEntries(radioID: UUID) async throws -> [RxLogEntryDTO] {
    try await fetchRxLogEntries(radioID: radioID, limit: 500)
  }

  /// Prune RX log entries with the default retention cap plus threshold
  func pruneRxLogEntries(radioID: UUID) async throws {
    try await pruneRxLogEntries(
      radioID: radioID,
      keepCount: RxLogRetention.keepCount,
      pruneThreshold: RxLogRetention.pruneThreshold
    )
  }
}

// MARK: - Batch and Cursor Defaults

public extension RxLogPersisting {
  /// Default for test doubles: one save per entry, then a flush.
  func saveRxLogEntries(_ dtos: [RxLogEntryDTO]) async throws {
    for dto in dtos {
      try await saveRxLogEntry(dto)
    }
    try await flushPendingRxLogEntries()
  }

  /// Default for test doubles: no cursor is stored.
  func fetchRxStreamCursor(radioID _: UUID) async throws -> RxStreamCursor? {
    nil
  }

  /// Default for test doubles: the cursor is not kept.
  func saveRxStreamCursor(_: RxStreamCursor?, radioID _: UUID) async throws {}
}
