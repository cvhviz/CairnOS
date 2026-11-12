import Foundation
import MeshCore
import SwiftData

extension PersistenceStore: ObservationPersisting {}

public extension PersistenceStore {
  /// Every stored node of one radio on one channel, most recently observed first. Rows whose
  /// identity can't be read are skipped.
  func fetchObservedNodes(radioID: UUID, channelKey: ChannelKey) throws -> [ObservedNode] {
    try fetchObservedNodeRecords(radioID: radioID, channelKey: channelKey).compactMap(\.node)
  }

  /// When this radio last observed anything on a channel other than `channelKey`: the latest it can
  /// have been elsewhere. Nil when it never was.
  func fetchLatestObservation(radioID: UUID, otherThan channelKey: ChannelKey) throws -> Date? {
    let targetRadioID = radioID
    let targetKey = channelKey.rawValue
    var descriptor = FetchDescriptor<ObservedNodeRecord>(
      predicate: #Predicate { $0.radioID == targetRadioID && $0.channelKey != targetKey },
      sortBy: [SortDescriptor(\.lastObservedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first?.lastObservedAt
  }

  /// Writes one batch in a single save. A channel holds at most ``ObservationLedger/capacity``
  /// rows, so they are fetched once and matched by identity in memory. A second row with the same
  /// identity (which only a crash mid-save could leave) is deleted.
  func saveObservedNodes(
    radioID: UUID,
    channelKey: ChannelKey,
    upserting nodes: [ObservedNode],
    removing identities: [ObservedIdentity]
  ) throws {
    guard !nodes.isEmpty || !identities.isEmpty else { return }
    var recordsByIdentity: [ObservedIdentity: ObservedNodeRecord] = [:]
    for record in try fetchObservedNodeRecords(radioID: radioID, channelKey: channelKey) {
      guard let identity = record.observedIdentity, recordsByIdentity[identity] == nil else {
        modelContext.delete(record)
        continue
      }
      recordsByIdentity[identity] = record
    }
    for identity in identities {
      if let record = recordsByIdentity.removeValue(forKey: identity) {
        modelContext.delete(record)
      }
    }
    for node in nodes {
      if let record = recordsByIdentity[node.identity] {
        record.update(from: node)
      } else {
        let record = ObservedNodeRecord(radioID: radioID, channelKey: channelKey, node: node)
        modelContext.insert(record)
        recordsByIdentity[node.identity] = record
      }
    }
    try modelContext.save()
  }

  /// Deletes a radio's rows, on every channel, not observed since `date`.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func pruneObservedNodes(radioID: UUID, notObservedSince date: Date) throws -> Int {
    let targetRadioID = radioID
    let cutoff = date
    let predicate = #Predicate<ObservedNodeRecord> { $0.radioID == targetRadioID && $0.lastObservedAt < cutoff }
    let stale = try modelContext.fetch(FetchDescriptor(predicate: predicate))
    guard !stale.isEmpty else { return 0 }
    for record in stale {
      modelContext.delete(record)
    }
    try modelContext.save()
    return stale.count
  }

  /// Deletes every observed node of a radio, on every channel.
  func clearObservedNodes(radioID: UUID) throws {
    let targetRadioID = radioID
    let records = try modelContext.fetch(FetchDescriptor(predicate: #Predicate<ObservedNodeRecord> {
      $0.radioID == targetRadioID
    }))
    guard !records.isEmpty else { return }
    for record in records {
      modelContext.delete(record)
    }
    try modelContext.save()
  }

  private func fetchObservedNodeRecords(radioID: UUID, channelKey: ChannelKey) throws -> [ObservedNodeRecord] {
    let targetRadioID = radioID
    let targetKey = channelKey.rawValue
    let descriptor = FetchDescriptor<ObservedNodeRecord>(
      predicate: #Predicate { $0.radioID == targetRadioID && $0.channelKey == targetKey },
      sortBy: [SortDescriptor(\.lastObservedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }
}
