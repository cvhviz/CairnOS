import Foundation
import MeshCore
import SwiftData

public extension PersistenceStore {
  // MARK: - RX_SYNC Resume Cursor

  /// The RX_SYNC cursor stored on a radio's device row, or `nil` when none is (or no row exists).
  /// Exact `async throws` match for `RxStreamCursorPersisting` so this implementation is the
  /// protocol witness over the protocol's default.
  func fetchRxStreamCursor(radioID: UUID) async throws -> RxStreamCursor? {
    guard let device = try rxStreamCursorDevice(radioID: radioID),
          let epoch = device.rxStreamEpoch,
          let seq = device.rxStreamSeq else { return nil }
    return RxStreamCursor(epoch: epoch, seq: seq)
  }

  /// Stores a radio's RX_SYNC cursor on its device row and saves; `nil` forgets it. A radio
  /// without a device row keeps no cursor.
  func saveRxStreamCursor(_ cursor: RxStreamCursor?, radioID: UUID) async throws {
    guard let device = try rxStreamCursorDevice(radioID: radioID) else { return }
    guard device.rxStreamEpoch != cursor?.epoch || device.rxStreamSeq != cursor?.seq else { return }
    device.rxStreamEpoch = cursor?.epoch
    device.rxStreamSeq = cursor?.seq
    try modelContext.save()
  }

  /// The channel of the newest stored RX log entry of `cursor`'s journal at or before it that has
  /// one (the cursor's own, unless it came in a backlog nothing vouched for), or `nil`. Exact
  /// `async throws` match for `RxStreamCursorPersisting`.
  func fetchRxStreamCursorChannel(radioID: UUID, cursor: RxStreamCursor) async throws -> ChannelKey? {
    let targetRadioID = radioID
    let epoch = Int(cursor.epoch)
    let seq = Int(cursor.seq)
    var descriptor = FetchDescriptor<RxLogEntry>(
      predicate: #Predicate {
        $0.radioID == targetRadioID && $0.radioEpoch == epoch && $0.radioSeq != nil && $0.channelKey != nil
      },
      sortBy: [SortDescriptor(\.radioSeq, order: .reverse)]
    )
    descriptor.fetchLimit = 8
    return try modelContext.fetch(descriptor)
      .first { ($0.radioSeq ?? .max) <= seq }?
      .channelKey.map(ChannelKey.init(rawValue:))
  }

  private func rxStreamCursorDevice(radioID: UUID) throws -> Device? {
    let targetRadioID = radioID
    var descriptor = FetchDescriptor<Device>(
      predicate: #Predicate { $0.radioID == targetRadioID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
}
