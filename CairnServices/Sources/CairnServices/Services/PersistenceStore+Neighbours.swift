import Foundation
import MeshCore
import SwiftData

extension PersistenceStore: NeighbourPersisting {}

public extension PersistenceStore {
  /// Every stored neighbour row of a radio on one channel, most recently heard first. Rows whose
  /// identity can't be read are skipped.
  func fetchNeighbourRecords(radioID: UUID, channelKey: ChannelKey) throws -> [NeighbourRecord] {
    try fetchNeighbourLinks(radioID: radioID, channelKey: channelKey).compactMap(\.record)
  }

  /// Writes one batch for one channel in a single save. A channel holds at most a few hundred
  /// rows, so they are fetched once and matched by identity in memory. A second row with the same
  /// identity (which only a crash mid-save could leave) is deleted.
  func saveNeighbourRecords(
    radioID: UUID,
    channelKey: ChannelKey,
    upserting records: [NeighbourRecord],
    removing identities: [NeighbourIdentity]
  ) throws {
    guard !records.isEmpty || !identities.isEmpty else { return }
    var linksByIdentity: [NeighbourIdentity: NeighbourLink] = [:]
    for link in try fetchNeighbourLinks(radioID: radioID, channelKey: channelKey) {
      guard let identity = link.identity, linksByIdentity[identity] == nil else {
        modelContext.delete(link)
        continue
      }
      linksByIdentity[identity] = link
    }
    for identity in identities {
      if let link = linksByIdentity.removeValue(forKey: identity) {
        modelContext.delete(link)
      }
    }
    for record in records {
      if let link = linksByIdentity[record.identity] {
        link.update(from: record)
      } else {
        let link = NeighbourLink(radioID: radioID, channelKey: channelKey, record: record)
        modelContext.insert(link)
        linksByIdentity[record.identity] = link
      }
    }
    try modelContext.save()
  }

  /// Deletes a radio's rows not heard since `date`, on `channelKey`, or on every channel when nil.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func pruneNeighbourRecords(radioID: UUID, channelKey: ChannelKey?, notHeardSince date: Date) throws -> Int {
    let targetRadioID = radioID
    let cutoff = date
    let predicate: Predicate<NeighbourLink>
    if let key = channelKey?.rawValue {
      predicate = #Predicate { $0.radioID == targetRadioID && $0.channelKey == key && $0.lastHeard < cutoff }
    } else {
      predicate = #Predicate { $0.radioID == targetRadioID && $0.lastHeard < cutoff }
    }
    return try deleteNeighbourLinks(FetchDescriptor(predicate: predicate))
  }

  /// Deletes a radio's rows written before channels were recorded.
  /// - Returns: How many rows were deleted.
  @discardableResult
  func deleteUnstampedNeighbourRecords(radioID: UUID) throws -> Int {
    let targetRadioID = radioID
    return try deleteNeighbourLinks(FetchDescriptor(predicate: #Predicate<NeighbourLink> {
      $0.radioID == targetRadioID && $0.channelKey == nil
    }))
  }

  /// Deletes every neighbour row of a radio, on every channel.
  func clearNeighbourRecords(radioID: UUID) throws {
    let targetRadioID = radioID
    try deleteNeighbourLinks(FetchDescriptor(predicate: #Predicate<NeighbourLink> { $0.radioID == targetRadioID }))
  }

  /// The newest `limit` RX log entries received on `channelKey` at or after `since`, oldest first,
  /// reduced to the fields neighbour evidence and observations need. Stored Ints are narrowed the
  /// way `RxLogEntryDTO` does, so a corrupt row falls back instead of trapping.
  func fetchNeighbourReplay(radioID: UUID, channelKey: ChannelKey, since: Date, limit: Int) throws -> [NeighbourReplayEntry] {
    let targetRadioID = radioID
    let key = channelKey.rawValue
    let cutoff = since
    var descriptor = FetchDescriptor<RxLogEntry>(
      predicate: #Predicate { $0.radioID == targetRadioID && $0.channelKey == key && $0.receivedAt >= cutoff },
      sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    descriptor.propertiesToFetch = [
      \.receivedAt, \.snr, \.rssi, \.routeType, \.payloadType,
      \.pathLength, \.pathNodes, \.packetPayload, \.packetHash, \.radioEpoch, \.radioSeq, \.channelKey
    ]
    return try modelContext.fetch(descriptor).reversed().map { entry in
      NeighbourReplayEntry(
        receivedAt: entry.receivedAt,
        fields: RxPacketFields(
          routeType: UInt8(exactly: entry.routeType).flatMap(RouteType.init(rawValue:)) ?? .flood,
          payloadType: UInt8(exactly: entry.payloadType).flatMap(PayloadType.init(rawValue:)) ?? .unknown,
          pathLength: UInt8(exactly: entry.pathLength) ?? 0,
          pathNodes: entry.pathNodes,
          packetPayload: entry.packetPayload,
          packetHash: entry.packetHash,
          snr: entry.snr,
          rssi: entry.rssi
        ),
        channelKey: entry.channelKey.map(ChannelKey.init(rawValue:)),
        radioEpoch: entry.radioEpoch.flatMap { UInt32(exactly: $0) },
        radioSeq: entry.radioSeq.flatMap { UInt32(exactly: $0) }
      )
    }
  }

  private func fetchNeighbourLinks(radioID: UUID, channelKey: ChannelKey) throws -> [NeighbourLink] {
    let targetRadioID = radioID
    let key = channelKey.rawValue
    let descriptor = FetchDescriptor<NeighbourLink>(
      predicate: #Predicate { $0.radioID == targetRadioID && $0.channelKey == key },
      sortBy: [SortDescriptor(\.lastHeard, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Deletes the rows `descriptor` finds, in one save.
  /// - Returns: How many rows were deleted.
  @discardableResult
  private func deleteNeighbourLinks(_ descriptor: FetchDescriptor<NeighbourLink>) throws -> Int {
    let links = try modelContext.fetch(descriptor)
    guard !links.isEmpty else { return 0 }
    for link in links {
      modelContext.delete(link)
    }
    try modelContext.save()
    return links.count
  }
}
