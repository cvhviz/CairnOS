import CairnServices
import SwiftUI

/// What the app already knows about how a node was last heard and how it was doing, read from the
/// RX log and the stored status snapshots, so Contact Detail can show it without asking the node.
enum NodeHeardSignal {
  /// The newest packet in `entries` known to come from the node: an advert carrying its public
  /// key whose signature holds, or a direct message the node's key decrypted from it (a one-byte
  /// sender prefix alone is shared by too many nodes). `selfKey`, this radio's key, tells an echo
  /// of our own message to the node apart when the node's first key byte is ours too.
  static func latest(in entries: [RxLogEntryDTO], publicKey: Data, selfKey: Data? = nil) -> RxLogEntryDTO? {
    entries
      .filter { isFromNode($0, publicKey: publicKey, selfKey: selfKey) }
      .max { $0.receivedAt < $1.receivedAt }
  }

  static func isFromNode(_ entry: RxLogEntryDTO, publicKey: Data, selfKey: Data? = nil) -> Bool {
    switch entry.payloadType {
    case .advert:
      // Anyone can put a key in an advert; only its signature says the node sent it
      guard case let .verified(advert)? = ObservationExtractor.advertCheck(in: RxPacketFields(entry)) else { return false }
      return advert.publicKey == publicKey
    case .textMessage:
      // The sender as the RX Log list names it: the contact whose key decrypted the message and
      // whose prefix sent it (its MAC proves the key), never a guess from the prefix
      guard let sender = PacketNodeResolver.resolve(entry, in: PacketNodeIndex(selfKey: selfKey)).sender,
            sender.role == .sender(.decryptedPeer), !sender.isUncertain else { return false }
      return sender.key == publicKey
    default:
      return false
    }
  }

  /// Every relay a flood packet came through, first to last, by hash. Empty for a packet heard
  /// straight from the node; nil for a direct packet, whose path is the route still ahead.
  static func relayHashes(of entry: RxLogEntryDTO) -> [Data]? {
    if isZeroHopAdvert(entry) { return [] }
    guard entry.isFlood else { return nil }
    let size = max(1, entry.pathHashSize)
    let bytes = Array(entry.pathNodes.prefix(entry.hopCount * size))
    return stride(from: 0, to: bytes.count - size + 1, by: size).map { Data(bytes[$0 ..< $0 + size]) }
  }

  /// The path a flood packet took to this radio, its relays named as the RX Log list and the
  /// Traffic map name them: each hop resolved against what this radio observed on the channel
  /// the packet was received on (`index`, from `ObservationDirectory.index(for:)`), by hash when
  /// no node heard there has it. A saved contact sharing a hash never names it. `shorten` fits a
  /// name to the screen (CarPlay's glance names).
  static func heardPath(
    of entry: RxLogEntryDTO,
    maxShown: Int = 3,
    in index: PacketNodeIndex,
    shorten: (String) -> String = { $0 }
  ) -> String? {
    let hops = PacketNodeResolver.resolve(entry, in: index).hops
    return heardPath(of: entry, maxShown: maxShown) { position, _ in
      guard hops.indices.contains(position), hops[position].isNamed else { return nil }
      return hops[position].displayName.map(shorten)
    }
  }

  /// The path a flood packet took to this radio, its relays by name where `name` knows them and
  /// by hash otherwise: "Hilltop → 7F → Ridge", or Direct with no relay. A long path keeps its
  /// ends and counts the hops: "Hilltop → … → Ridge (5 hops)". Nil for a direct packet.
  static func heardPath(of entry: RxLogEntryDTO, maxShown: Int = 3, name: (Data) -> String?) -> String? {
    heardPath(of: entry, maxShown: maxShown) { _, hash in name(hash) }
  }

  /// `heardPath`, naming each relay by its place in the path (oldest first) and its hash.
  private static func heardPath(of entry: RxLogEntryDTO, maxShown: Int, name: (Int, Data) -> String?) -> String? {
    guard let hashes = relayHashes(of: entry) else { return nil }
    let labels = hashes.enumerated().map { name($0, $1) ?? $1.uppercaseHexString() }
    guard let first = labels.first, let last = labels.last else { return L10n.Contacts.Contacts.Route.direct }
    guard labels.count > maxShown else { return labels.joined(separator: " \u{2192} ") }
    return [first, "\u{2026}", last].joined(separator: " \u{2192} ") + " (\(NodeRouteFormat.hopCount(labels.count)))"
  }

  /// A flood packet with no hops, or a zero-hop advert, came straight from the node, with no
  /// relay between.
  static func wasHeardDirectly(_ entry: RxLogEntryDTO) -> Bool {
    (entry.isFlood || isZeroHopAdvert(entry)) && entry.hopCount == 0
  }

  /// A zero-hop advert goes out direct with an empty path (`sendZeroHop`). Only an advert: any
  /// other direct packet with an empty path has just finished a stored route, its relays unknown.
  static func isZeroHopAdvert(_ entry: RxLogEntryDTO) -> Bool {
    !entry.isFlood && entry.payloadType == .advert && entry.hopCount == 0 && entry.pathNodes.isEmpty
  }
}

/// Captions for readings stored earlier rather than read now. Main-actor, like the timestamp
/// formatter it uses.
@MainActor
enum StoredReadingFormat {
  /// "as of 3 hr. ago".
  static func asOf(_ date: Date, now: Date) -> String {
    L10n.Contacts.Contacts.Detail.asOf(RelativeTimestampText.format(date: date, relativeTo: now))
  }
}
