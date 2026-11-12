import Foundation
import MeshCore

/// A read-only copy of one radio's ``ObservationLedger`` for one channel: the only nodes a path
/// hash may resolve to.
///
/// ``empty`` (no channel) is the cold snapshot published before the radio has reported its
/// channel, or while a retune waits for it.
public struct LedgerSnapshot: Sendable, Equatable {
  public let radioID: UUID?
  public let channelKey: ChannelKey?
  /// The channel as the radio reported it, when known.
  public let channel: RadioChannelConfig?
  /// This radio's own key, never one of ``nodes``.
  public let selfKey: Data?
  public let takenAt: Date
  public let version: Int
  /// Every node held, active or stale, most recently observed first.
  public let nodes: [ObservedNode]

  public init(
    radioID: UUID?,
    channelKey: ChannelKey?,
    channel: RadioChannelConfig?,
    selfKey: Data?,
    takenAt: Date,
    version: Int,
    nodes: [ObservedNode]
  ) {
    self.radioID = radioID
    self.channelKey = channelKey
    self.channel = channel
    self.selfKey = selfKey
    self.takenAt = takenAt
    self.version = version
    self.nodes = nodes.sorted { lhs, rhs in
      lhs.lastObservedAt != rhs.lastObservedAt
        ? lhs.lastObservedAt > rhs.lastObservedAt
        : lhs.identity.bytes.lexicographicallyPrecedes(rhs.identity.bytes)
    }
  }

  /// No channel and no nodes.
  public static let empty = LedgerSnapshot(
    radioID: nil,
    channelKey: nil,
    channel: nil,
    selfKey: nil,
    takenAt: .distantPast,
    version: 0,
    nodes: []
  )

  /// Whether no channel is known yet, so nothing can resolve.
  public var isCold: Bool {
    channelKey == nil
  }

  /// The nodes observed within ``ObservationLedger/activeWindow`` before `date`: the candidates for
  /// a packet received at `date`.
  public func activeNodes(at date: Date) -> [ObservedNode] {
    nodes.filter { ObservationLedger.isActive($0, at: date) }
  }

  /// The node held under exactly `identity`.
  public func node(for identity: ObservedIdentity) -> ObservedNode? {
    nodes.first { $0.identity == identity }
  }

  /// The nodes, active or stale, whose identity starts with `hash`.
  public func nodes(withPrefix hash: Data) -> [ObservedNode] {
    nodes.filter { $0.identity.hasPrefix(hash) }
  }
}
