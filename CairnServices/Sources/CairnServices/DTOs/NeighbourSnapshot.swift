import Foundation
import MeshCore

/// One of our own discover requests, as `NeighbourService.noteProbe(tag:filter:at:)` recorded it.
public struct NeighbourProbe: Sendable, Equatable {
  public let tag: UInt32
  /// The node-type bit mask asked for (bit 2 repeater, bit 4 sensor).
  public let filter: UInt8
  public let sentAt: Date

  public init(tag: UInt32, filter: UInt8, sentAt: Date) {
    self.tag = tag
    self.filter = filter
    self.sentAt = sentAt
  }
}

/// The direct neighbours of one radio on its current channel at one moment, every row resolved
/// against the nodes observed on that channel then, and those observations themselves. Built
/// fresh by `NeighbourService` for each update; nothing in it is stored.
public struct NeighbourSnapshot: Sendable, Equatable {
  public let radioID: UUID
  /// When it was built; freshness and confirmation are measured against this.
  public let takenAt: Date
  /// Every neighbour row, the rows naming the same node merged, most recently heard first.
  public let neighbours: [ResolvedNeighbour]
  /// Our latest discover request, while its replies still count as answers to us.
  public let lastProbe: NeighbourProbe?
  /// The stored rows and the last 24 hours of the RX log have been read in. Until then the list
  /// only holds what arrived live.
  public let isWarm: Bool
  /// The nodes this radio observed on its current channel: what every hash in the app resolves
  /// against (``PacketNodeIndex``). Cold (no channel) until the radio reports its channel, and
  /// while a retune waits for it; the neighbours are then empty too.
  public let ledger: LedgerSnapshot

  public init(
    radioID: UUID,
    takenAt: Date,
    neighbours: [ResolvedNeighbour],
    lastProbe: NeighbourProbe? = nil,
    isWarm: Bool = true,
    ledger: LedgerSnapshot = .empty
  ) {
    self.radioID = radioID
    self.takenAt = takenAt
    self.neighbours = neighbours
    self.lastProbe = lastProbe
    self.isWarm = isWarm
    self.ledger = ledger
  }

  /// No neighbours yet.
  public static func empty(radioID: UUID, at date: Date, isWarm: Bool = false) -> NeighbourSnapshot {
    NeighbourSnapshot(radioID: radioID, takenAt: date, neighbours: [], isWarm: isWarm)
  }

  /// The channel the neighbours and the ledger belong to; nil while cold.
  public var channelKey: ChannelKey? {
    ledger.channelKey
  }

  /// Whether `neighbour` answered ``lastProbe``: a reply carrying its tag arrived after it went out.
  public func answeredLastProbe(_ neighbour: ResolvedNeighbour) -> Bool {
    guard let lastProbe, let replies = neighbour.record.sources[.replyToUs] else { return false }
    return replies.lastHeard >= lastProbe.sentAt
  }

  /// The rows that answered ``lastProbe``.
  public var answeredLastProbeCount: Int {
    neighbours.count { answeredLastProbe($0) }
  }

  /// Confirmed neighbours heard in the live band (the last 10 minutes): "Nearby now".
  public var nearbyNowCount: Int {
    neighbours.count { $0.record.isConfirmed && $0.record.freshness(now: takenAt) == .live }
  }
}
