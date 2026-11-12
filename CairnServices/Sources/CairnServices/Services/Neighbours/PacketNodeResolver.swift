import CoreLocation
import Foundation
import MeshCore

// MARK: - Match

/// Which node one hash, key or name in a received packet names.
public enum PacketNodeMatch: Sendable, Equatable {
  /// Exactly one node: the one observed node with this hash, or the key the packet itself proves.
  case resolved(NeighbourKeyEntry)
  /// More than one observed node could be it. `best` is the likeliest, `candidates` the likeliest
  /// few (at most ``PacketNodeResolver/maximumListedCandidates``, `best` first), `total` how many
  /// there are.
  case ambiguous(best: NeighbourKeyEntry, candidates: [NeighbourKeyEntry], total: Int)
  /// No node observed on this channel has this hash, or the packet was received on no recorded
  /// channel. Shown as the hash itself.
  case unknown(Data)
  /// This radio.
  case radio

  /// The resolved node, or the likeliest of an ambiguous match.
  public var entry: NeighbourKeyEntry? {
    switch self {
    case let .resolved(entry): entry
    case let .ambiguous(best, _, _): best
    case .unknown, .radio: nil
    }
  }

  /// A guess among several nodes rather than the one node the hash can be.
  public var isUncertain: Bool {
    if case .ambiguous = self { true } else { false }
  }
}

/// What in a packet names its sender.
public enum PacketSenderSource: Sendable, Equatable {
  /// The sender's whole key: an advert or an anonymous request.
  case fullKey
  /// An 8-byte key prefix: a node discovery's prefix-only answer.
  case keyPrefix
  /// The contact whose key decrypted a direct message.
  case decryptedPeer
  /// The one-byte source hash a peer packet opens with.
  case peerHash
  /// The name before ": " in a decrypted channel message. Anyone can type any name, so it is
  /// never certain.
  case channelName
  /// What the app had the radio send lately: this radio for an echo of its own packet, the node
  /// it asked for a reply, the node its direct message went to for the ack. The resolver never
  /// gives it; the app's own record of its sends does, for the list and the map alike.
  case sentLog
}

/// Why a node was resolved: how and when this radio observed it on the channel, for a detail
/// view ("only node heard on this channel with byte C1, heard via 3 hops 2 d ago").
public struct PacketNodeBasis: Sendable, Equatable {
  /// The strongest way the node was observed.
  public let strongestKind: ObservationKind?
  /// When this radio last received a frame the node itself transmitted.
  public let lastDirectAt: Date?
  /// The fewest relays any observation crossed.
  public let minHops: Int?
  /// When the node was last observed.
  public let lastObservedAt: Date?

  public init(strongestKind: ObservationKind?, lastDirectAt: Date?, minHops: Int?, lastObservedAt: Date?) {
    self.strongestKind = strongestKind
    self.lastDirectAt = lastDirectAt
    self.minHops = minHops
    self.lastObservedAt = lastObservedAt
  }

  init(_ entry: NeighbourKeyEntry) {
    self.init(
      strongestKind: entry.strongestKind,
      lastDirectAt: entry.lastDirectAt,
      minHops: entry.minHops,
      lastObservedAt: entry.lastHeard
    )
  }
}

// MARK: - Packet Node

/// One node a received packet names: its sender or one hop of its path, and which node that is.
public struct PacketNode: Sendable, Equatable {
  public enum Role: Sendable, Equatable {
    case sender(PacketSenderSource)
    /// `index` counts from the path's first (oldest) hop. A hop is reached when the packet has
    /// crossed it: every hop of a flood, the hops of a trace it has come through, none of the
    /// route still ahead of a direct packet.
    case hop(index: Int, isReached: Bool)
  }

  public let role: Role
  /// The bytes the packet names the node by: a path hash, the source byte, or the key; empty for
  /// a channel sender's name.
  public let hash: Data
  /// Nil for a trace target the packet hasn't reached and for a channel sender's name that no
  /// single observed node advertised.
  public let match: PacketNodeMatch?
  /// The sender's name from a channel message.
  public let channelName: String?
  /// An advert whose signature fails or that can't be read: its key is only a claim, so the
  /// sender is unknown, never placed.
  public let isUnverified: Bool
  /// The whole key an anonymous request claims, when no node observed on this channel holds it:
  /// the detail view may say "Claims to be Kona Hill (not heard on this channel)". Never named or
  /// drawn.
  public let claimedKey: Data?
  /// Set on the frame's transmitter only: its observed position is at least
  /// ``PacketNodeResolver/suspiciousLinkDistance`` from this radio. A flag for display; it never
  /// changes the match.
  public let isSuspicious: Bool
  /// For an unknown node, the likeliest node sharing its hash that is not a candidate (a contact
  /// never heard on this channel, a node not heard lately). A hint for a detail view only.
  public let unobservedHint: UnobservedSharer?
  /// A resolved match that is only likely, not proven: a reply named by our latest send to a node
  /// whose key starts with the reply's source byte. Shown with "?", like an ambiguous one.
  public let isProbable: Bool

  public init(
    role: Role,
    hash: Data,
    match: PacketNodeMatch?,
    channelName: String? = nil,
    isUnverified: Bool = false,
    claimedKey: Data? = nil,
    isSuspicious: Bool = false,
    unobservedHint: UnobservedSharer? = nil,
    isProbable: Bool = false
  ) {
    self.role = role
    self.hash = hash
    self.match = match
    self.channelName = channelName
    self.isUnverified = isUnverified
    self.claimedKey = claimedKey
    self.isSuspicious = isSuspicious
    self.unobservedHint = unobservedHint
    self.isProbable = isProbable
  }

  public var entry: NeighbourKeyEntry? { match?.entry }
  public var key: Data? { entry?.publicKey }
  public var latitude: Double? { entry?.latitude }
  public var longitude: Double? { entry?.longitude }
  public var coordinate: CLLocationCoordinate2D? { entry?.coordinate }
  public var hasPosition: Bool { coordinate != nil }
  public var isRadio: Bool { match == .radio }

  /// Whether the node is one this radio observed on the packet's channel (the packet's own
  /// verified advert counts). False for a key the packet proves that the ledger doesn't hold.
  public var isObserved: Bool {
    entry?.isObserved == true
  }

  /// How the node was observed, for a resolved or ambiguous observed node.
  public var basis: PacketNodeBasis? {
    guard let entry, entry.isObserved else { return nil }
    return PacketNodeBasis(entry)
  }

  /// 1 chat, 2 repeater, 3 room, 4 sensor, 0 not said. A channel sender is a chat node, as is
  /// this radio.
  public var nodeTypeRaw: UInt8 {
    if let entry { return entry.nodeTypeRaw }
    return isRadio || channelName != nil ? ContactType.chat.rawValue : 0
  }

  public var isSender: Bool {
    if case .sender = role { true } else { false }
  }

  public var isReached: Bool {
    switch role {
    case .sender: true
    case let .hop(_, isReached): isReached
    }
  }

  /// A guess: an ambiguous or probable match, or a sender known only by the name it typed.
  public var isUncertain: Bool {
    match?.isUncertain == true || isProbable || role == .sender(.channelName)
  }

  /// Whether the packet names a node here, by key or by name: false for an unknown hash, an
  /// unreached trace target and this radio.
  public var isNamed: Bool {
    switch match {
    case .resolved, .ambiguous: true
    case .unknown, .radio: false
    case nil: channelName != nil
    }
  }

  /// The node's name; its key's first 3 bytes in hex when it has none; "?" after a guess; the hash
  /// in hex when no observed node has it. Nil for this radio, which each screen names its own way.
  public var displayName: String? {
    switch match {
    case let .resolved(entry):
      return Self.name(of: entry) + (isProbable ? "?" : "")
    case let .ambiguous(best, _, _):
      return Self.name(of: best) + "?"
    case let .unknown(hash):
      return hash.uppercaseHexString()
    case .radio:
      return nil
    case nil:
      return channelName ?? (hash.isEmpty ? nil : hash.uppercaseHexString())
    }
  }

  private static func name(of entry: NeighbourKeyEntry) -> String {
    entry.name ?? Data(entry.publicKey.prefix(3)).uppercaseHexString()
  }
}

/// Every node a received packet names: the RX Log list shows these and the Traffic map draws them.
public struct PacketNodes: Sendable, Equatable {
  public var sender: PacketNode?
  /// The path's hops, oldest first; for a trace, its targets.
  public var hops: [PacketNode]
  /// Who a peer packet is addressed to, from its destination byte.
  public var recipient: PacketNodeMatch?
  /// A direct packet's path is the route still ahead of it, not the hops it came through.
  public var isRouteAhead: Bool
  /// The node that transmitted the frame this radio received, which is the one observed link:
  /// a flood's newest hop, a trace's last reached hop, the sender of a 0-hop flood, a 0-hop
  /// direct advert or a discover reply. Nil when the packet doesn't say (a direct packet's route
  /// ahead, a direct packet with no path).
  public var transmitter: PacketNode.Role?
  /// Whether the frame was stamped with the channel it was received on. An unstamped frame (one
  /// stored before channels were recorded) names only what it proves itself; every hash is
  /// unknown.
  public var isChannelRecorded: Bool
  /// The channel the frame was received on.
  public var channelKey: ChannelKey?
  /// The hops whose claimed leg from the previous placed node of the packet (the sender, or an
  /// earlier hop) is at least ``PacketNodeResolver/suspiciousLinkDistance`` long. A flag for
  /// display; it never changes a match.
  public var suspiciousLegs: Set<Int>

  public init(
    sender: PacketNode? = nil,
    hops: [PacketNode] = [],
    recipient: PacketNodeMatch? = nil,
    isRouteAhead: Bool = false,
    transmitter: PacketNode.Role? = nil,
    isChannelRecorded: Bool = true,
    channelKey: ChannelKey? = nil,
    suspiciousLegs: Set<Int> = []
  ) {
    self.sender = sender
    self.hops = hops
    self.recipient = recipient
    self.isRouteAhead = isRouteAhead
    self.transmitter = transmitter
    self.isChannelRecorded = isChannelRecorded
    self.channelKey = channelKey
    self.suspiciousLegs = suspiciousLegs
  }

  /// The sender, then the hops, keeping those the packet names (not this radio): each one the
  /// list names, which the map must light or list as not on the map.
  public var named: [PacketNode] {
    ([sender].compactMap(\.self) + hops).filter(\.isNamed)
  }

  /// The named nodes with no position: the map can't place them, so it lists them by name.
  public var offMap: [PacketNode] {
    named.filter { !$0.hasPosition }
  }

  /// The node at ``transmitter``.
  public var transmitterNode: PacketNode? {
    switch transmitter {
    case .sender: sender
    case let .hop(index, _): hops.indices.contains(index) ? hops[index] : nil
    case nil: nil
    }
  }
}

// MARK: - Resolver

/// Decides which node each hash, key and name in a received packet names, for the RX Log list, the
/// Traffic map, Scan for Nodes and Home alike. Pure: a function of the entry and the index, run
/// again whenever the ledger changes, so a node observed later corrects what earlier packets
/// showed.
///
/// Reads only what every stock 0x88 RX log entry carries (path length, path, payload, the channel
/// the session stamped) and what the app decrypted, never Cairn's RX_SYNC fields, so it gives the
/// same answer on any firmware.
///
/// Identity comes from observation (``PacketNodeIndex``):
/// - R0. An entry is resolved against the ledger of the channel it was received on. The caller
///   passes that index; an entry stamped with another channel than the index's, or not stamped,
///   gets no ledger: every short hash is unknown and only what the packet proves is named.
/// - R1. What the packet names itself needs no candidates: a verified advert's key (signature
///   checked; a forged one is unknown and never placed), a discover reply's key, a decrypted
///   direct message's contact, this radio. An anonymous request's key is a claim: named only
///   when observed. A key prefix of 6 bytes or more names one node.
/// - R2. A short hash (1-3 byte path hops, a peer packet's source or destination byte) resolves
///   only against the nodes observed on the channel within the active window: none is unknown
///   (shown as the hash), one resolves at any hash size, several are ambiguous, ranked: heard
///   directly in the last 24 h (for the hop this radio heard), the type the role expects, fewer
///   hops, observed more lately, then key bytes. This radio ranks last. Role never removes a
///   candidate (a companion can repeat). No distance, anchor or path rule decides identity.
/// - R3. A channel message's typed sender name matches only one observed node's advertised name.
/// - R4. A recipient byte is resolved as R2 with the recipient's role.
/// - R7. The transmitter's link, and claimed legs between placed nodes, of at least
///   ``suspiciousLinkDistance`` are flagged; nothing is re-resolved or hidden because of it.
public enum PacketNodeResolver {
  /// Candidates an ambiguous match lists.
  public static let maximumListedCandidates = NeighbourResolver.maximumListedCandidates
  /// The shortest key prefix ``resolveKeyPrefix(_:nodeTypeRaw:at:in:)`` treats as a key: 48 bits
  /// names one node.
  public static let minimumKeyPrefix = ObservedIdentity.minimumPrefixSize
  /// A link at least this long between two observed positions is flagged as unusually long
  /// (R7). Display only: it never decides which node a hash is.
  public static let suspiciousLinkDistance: CLLocationDistance = 500_000
  /// How lately a node must have been heard directly to rank first for the hop this radio heard.
  public static let directRankWindow: TimeInterval = 24 * 60 * 60
  /// The longest channel sender name (MeshCore's 32-byte name field).
  static let maximumChannelNameLength = 32
  /// A node discovery's answer: the control type in the high nibble, the node type in the low.
  static let discoverResponse: UInt8 = 0x90

  /// What a hash is expected to be.
  public enum Role: Sendable, Equatable {
    /// A hop in a path: something that re-sent the packet.
    case relay
    /// A peer packet's sender or recipient, for a packet of this type.
    case originator(PayloadType)
  }

  /// What one resolution is judged against.
  struct Context {
    let index: PacketNodeIndex
    /// When the packet was received: candidates are the nodes active then.
    let date: Date
    /// Whether the index's ledger is the channel the packet was received on (R0).
    let hasLedger: Bool
  }

  // MARK: Packets

  /// Every node `entry` names: its sender, its hops, who it is addressed to, and which of them
  /// transmitted the frame this radio received.
  public static func resolve(_ entry: RxLogEntryDTO, in index: PacketNodeIndex) -> PacketNodes {
    let context = Context(
      index: index,
      date: entry.receivedAt,
      hasLedger: entry.channelKey != nil && entry.channelKey == index.channelKey
    )
    let isTrace = entry.payloadType == .trace
    let hashes: [Data]
    let reachedCount: Int
    var isRouteAhead = false
    if isTrace {
      // The repeaters it is sent through are in its payload; its path holds the SNR each one
      // heard it at, so the path's length is how far it has come.
      hashes = entry.traceTargetHashes ?? []
      reachedCount = min(entry.pathNodes.count, hashes.count)
    } else {
      hashes = PathHops.split(pathNodes: entry.pathNodes, pathLength: entry.pathLength) ?? []
      isRouteAhead = !entry.isFlood && !hashes.isEmpty
      reachedCount = isRouteAhead ? 0 : hashes.count
    }
    // The hop this radio heard: a flood's or a trace's newest reached hop
    let heardHop: Int? = isRouteAhead || reachedCount == 0 ? nil : reachedCount - 1

    var hops = hashes.enumerated().map { offset, hash in
      let isReached = offset < reachedCount
      // A trace target it hasn't reached yet names nothing; a route ahead is resolved, unreached
      let match: PacketNodeMatch? = isTrace && !isReached
        ? nil
        : hopMatch(hash, isRadioNeighbour: offset == heardHop, context: context)
      return PacketNode(
        role: .hop(index: offset, isReached: isReached),
        hash: hash,
        match: match,
        unobservedHint: hint(for: hash, match: match, context: context)
      )
    }

    var sender = certainSender(of: entry, context: context)
      ?? uncertainSender(of: entry, hopCount: hashes.count, context: context)
    let recipient = recipient(of: entry, sender: sender, context: context)

    let transmitter = transmitter(of: entry, sender: sender, isTrace: isTrace, reachedCount: reachedCount, isRouteAhead: isRouteAhead)
    // R7: the observed link to this radio
    switch transmitter {
    case .sender:
      sender = sender.map { flaggingLink($0, index: index) }
    case let .hop(offset, _):
      hops[offset] = flaggingLink(hops[offset], index: index)
    case nil:
      break
    }

    return PacketNodes(
      sender: sender,
      hops: hops,
      recipient: recipient,
      isRouteAhead: isRouteAhead,
      transmitter: transmitter,
      isChannelRecorded: entry.channelKey != nil,
      channelKey: entry.channelKey,
      suspiciousLegs: suspiciousLegs(sender: isRouteAhead ? nil : sender, hops: hops)
    )
  }

  /// Each of a path's hop hashes resolved as a relay, for a packet received at `date` (nil: when
  /// the ledger was taken). `newestFirst` (a flood, a trace) marks the last hash as the one this
  /// radio heard, which ranks a candidate heard directly first; a route ahead (`false`) has none.
  public static func resolvePath(
    _ hashes: [Data],
    newestFirst: Bool,
    at date: Date? = nil,
    in index: PacketNodeIndex
  ) -> [PacketNodeMatch] {
    let context = Context(index: index, date: date ?? index.ledger.takenAt, hasLedger: !index.isCold)
    return hashes.enumerated().map { offset, hash in
      hopMatch(hash, isRadioNeighbour: newestFirst && offset == hashes.count - 1, context: context)
    }
  }

  // MARK: Hashes

  /// Which node a short hash names (R2), for a node expected to play `role`, in a packet received
  /// at `date` (nil: when the ledger was taken). `isRadioNeighbour` marks the hash this radio heard
  /// directly, where a candidate heard directly lately ranks first.
  public static func resolveHash(
    _ hash: Data,
    role: Role,
    isRadioNeighbour: Bool = false,
    at date: Date? = nil,
    in index: PacketNodeIndex
  ) -> PacketNodeMatch {
    let context = Context(index: index, date: date ?? index.ledger.takenAt, hasLedger: !index.isCold)
    return hashMatch(hash, role: role, isRadioNeighbour: isRadioNeighbour, context: context)
  }

  /// Which node a key prefix of ``minimumKeyPrefix`` bytes or more names, or a whole key (R1): the
  /// one active observed node it can be; several are ambiguous; with none, the key itself, typed
  /// `nodeTypeRaw` when the packet says, labelled only by ``PacketNodeIndex/label(forKey:)`` and
  /// never placed. A shorter prefix is a hash (R2).
  public static func resolveKeyPrefix(
    _ prefix: Data,
    nodeTypeRaw: UInt8 = 0,
    at date: Date? = nil,
    in index: PacketNodeIndex
  ) -> PacketNodeMatch {
    let context = Context(index: index, date: date ?? index.ledger.takenAt, hasLedger: !index.isCold)
    return keyMatch(prefix, nodeTypeRaw: nodeTypeRaw, context: context)
  }

  /// A path hop: a key prefix for 6 bytes or more (a trace's 8-byte hash), else a relay hash.
  private static func hopMatch(_ hash: Data, isRadioNeighbour: Bool, context: Context) -> PacketNodeMatch {
    hash.count >= minimumKeyPrefix
      ? keyMatch(hash, nodeTypeRaw: 0, context: context)
      : hashMatch(hash, role: .relay, isRadioNeighbour: isRadioNeighbour, context: context)
  }

  /// R2 over the context's ledger. The hash this radio heard (`isRadioNeighbour`) names the
  /// frame's transmitter, which is never this radio (a radio doesn't receive its own
  /// transmission), so this radio is a candidate only for the other hashes.
  static func hashMatch(_ hash: Data, role: Role, isRadioNeighbour: Bool, context: Context) -> PacketNodeMatch {
    guard !hash.isEmpty, context.hasLedger else { return .unknown(hash) }
    let found = context.index.candidates(matching: hash, at: context.date)
    let isOwn = !isRadioNeighbour && context.index.selfKey?.starts(with: hash) == true
    return choose(found, isOwn: isOwn, role: role, isRadioNeighbour: isRadioNeighbour, context: context)
      ?? .unknown(hash)
  }

  /// R1 for a key or a key prefix of at least ``minimumKeyPrefix`` bytes.
  static func keyMatch(_ key: Data, nodeTypeRaw: UInt8, context: Context) -> PacketNodeMatch {
    guard key.count >= minimumKeyPrefix else {
      return hashMatch(key, role: .relay, isRadioNeighbour: false, context: context)
    }
    if isOwn(key, in: context.index) {
      return .radio
    }
    if context.hasLedger {
      let found = context.index.candidates(overlapping: key, at: context.date)
      if found.count == 1 {
        var observed = found[0]
        // An observed prefix (a reply's 6 bytes) and the longer key the packet carries are one
        // node: keep the longer key, and the nickname that exactly that key has
        if key.count > observed.publicKey.count {
          observed.publicKey = key
          if let nickname = context.index.displayName(forKey: key) { observed.name = nickname }
        }
        if observed.nodeTypeRaw == 0 { observed.nodeTypeRaw = nodeTypeRaw }
        return .resolved(observed)
      }
      if found.count > 1 {
        let ordered = ranked(found, role: .relay, isRadioNeighbour: false, date: context.date)
        return .ambiguous(best: ordered[0], candidates: Array(ordered.prefix(maximumListedCandidates)), total: found.count)
      }
    }
    return .resolved(NeighbourKeyEntry(
      publicKey: key,
      nodeTypeRaw: nodeTypeRaw,
      name: context.index.label(forKey: key)
    ))
  }

  /// One candidate (or this radio alone) resolves; several are ambiguous, this radio last; none
  /// gives nil.
  private static func choose(
    _ found: [NeighbourKeyEntry],
    isOwn: Bool,
    role: Role,
    isRadioNeighbour: Bool,
    context: Context
  ) -> PacketNodeMatch? {
    let total = found.count + (isOwn ? 1 : 0)
    switch total {
    case 0:
      return nil
    case 1:
      return found.first.map(PacketNodeMatch.resolved) ?? .radio
    default:
      // This radio ranks last, so it is never the best of several
      let ordered = ranked(found, role: role, isRadioNeighbour: isRadioNeighbour, date: context.date)
      return .ambiguous(best: ordered[0], candidates: Array(ordered.prefix(maximumListedCandidates)), total: total)
    }
  }

  /// `match`, or this radio: an ambiguous match counting this radio among its candidates (it ranks
  /// last, so it is never the best).
  private static func orThisRadio(_ match: PacketNodeMatch) -> PacketNodeMatch {
    switch match {
    case let .resolved(entry):
      .ambiguous(best: entry, candidates: [entry], total: 2)
    case let .ambiguous(best, candidates, total):
      .ambiguous(best: best, candidates: candidates, total: total + 1)
    case .unknown, .radio:
      match
    }
  }

  /// The hint for an unknown node: the likeliest sharer of its hash that is not a candidate.
  private static func hint(for hash: Data, match: PacketNodeMatch?, context: Context) -> UnobservedSharer? {
    guard context.hasLedger, case .unknown = match else { return nil }
    return context.index.unobservedSharers(of: hash, at: context.date).first
  }

  // MARK: Senders

  /// The sender a packet names itself (R1): an advert's verified key, an anonymous request's key,
  /// a node discovery answer's key, a decrypted direct message's contact or this radio. Nil for
  /// any other packet.
  private static func certainSender(of entry: RxLogEntryDTO, context: Context) -> PacketNode? {
    let payload = [UInt8](entry.packetPayload)
    let index = context.index

    switch entry.payloadType {
    case .advert:
      return advertSender(of: entry, context: context)
    case .anonRequest:
      // A one-byte recipient hash, then the sender's whole key (`createAnonDatagram`): a claim,
      // named only when the sender was observed here
      guard payload.count >= 33 else { return nil }
      let key = Data(payload[1..<33])
      if isOwn(key, in: index) {
        return PacketNode(role: .sender(.fullKey), hash: key, match: .radio)
      }
      let observed = context.hasLedger ? index.candidates(overlapping: key, at: context.date) : []
      if observed.count == 1 {
        return PacketNode(role: .sender(.fullKey), hash: key, match: .resolved(observed[0]))
      }
      return PacketNode(role: .sender(.fullKey), hash: key, match: .unknown(Data(key.prefix(3))), claimedKey: key)
    case .control:
      // A node discovery's answer: type, the SNR it heard the request at, the tag, then the
      // answering node's key (8 bytes, or all 32)
      guard payload.count >= 6 + 8, payload[0] & 0xF0 == discoverResponse else { return nil }
      let key = Data(payload[6..<min(payload.count, 6 + 32)])
      return PacketNode(
        role: .sender(key.count == 32 ? .fullKey : .keyPrefix),
        hash: key,
        match: keyMatch(key, nodeTypeRaw: payload[0] & 0x0F, context: context)
      )
    case .textMessage:
      guard payload.count >= 2, entry.decryptStatus == .success,
            let peer = entry.peerPublicKey, let first = peer.first else { return nil }
      // The contact whose key decrypted it sent it (its MAC proves the key), or received it from
      // this radio
      if first == payload[1] {
        let peerMatch = keyMatch(peer, nodeTypeRaw: 0, context: context)
        // The contact's first key byte is ours too: the bytes can't tell its message to us from
        // an echo of ours to it, so the contact is only one of two (the send log settles an echo)
        let match = index.selfKey?.first == first ? orThisRadio(peerMatch) : peerMatch
        return PacketNode(role: .sender(.decryptedPeer), hash: peer, match: match)
      }
      if index.selfKey?.first == payload[1] {
        return PacketNode(role: .sender(.decryptedPeer), hash: Data([payload[1]]), match: .radio)
      }
      return nil
    default:
      return nil
    }
  }

  /// An advert's sender: its key when the signature holds, named and placed by what it
  /// announces, the observed node filling the gaps; unknown when the signature fails.
  private static func advertSender(of entry: RxLogEntryDTO, context: Context) -> PacketNode? {
    let fields = RxPacketFields(entry)
    let advert: VerifiedAdvert
    switch ObservationExtractor.advertCheck(in: fields) {
    case let .verified(verified):
      advert = verified
    case let .unverified(key):
      return PacketNode(role: .sender(.fullKey), hash: key, match: .unknown(Data(key.prefix(3))), isUnverified: true)
    case nil:
      guard entry.packetPayload.count >= 32 else { return nil }
      let key = Data(entry.packetPayload.prefix(32))
      return PacketNode(role: .sender(.fullKey), hash: key, match: .unknown(Data(key.prefix(3))), isUnverified: true)
    }
    let key = advert.publicKey
    if isOwn(key, in: context.index) {
      return PacketNode(role: .sender(.fullKey), hash: key, match: .radio)
    }
    let hops = PathHops.split(pathNodes: entry.pathNodes, pathLength: entry.pathLength)
    let hopCount: Int? = entry.isFlood ? hops?.count : (hops?.isEmpty == true ? 0 : nil)
    let stated = NeighbourKeyEntry(
      publicKey: key,
      nodeTypeRaw: advert.nodeTypeRaw ?? 0,
      name: context.index.displayName(forKey: key) ?? advert.name,
      advertisedName: advert.name,
      latitude: advert.latitude,
      longitude: advert.longitude,
      lastHeard: entry.receivedAt,
      lastDirectAt: hopCount == 0 ? entry.receivedAt : nil,
      minHops: hopCount,
      strongestKind: hopCount == 0 ? .advertDirect : .advertRelayed,
      // The advert is itself an observation on the channel it was stamped with
      isObserved: context.hasLedger
    )
    let known = context.index.keys.entry(for: key).map { stated.filling(from: $0) } ?? stated
    return PacketNode(role: .sender(.fullKey), hash: key, match: .resolved(known))
  }

  /// The sender a packet names only by a guess: a peer packet's source byte (R2), or a channel
  /// message's typed name (R3). Nil for a packet that names no sender (trace, ack, multipart,
  /// channel data, raw).
  private static func uncertainSender(of entry: RxLogEntryDTO, hopCount: Int, context: Context) -> PacketNode? {
    let payload = [UInt8](entry.packetPayload)

    switch entry.payloadType {
    case .textMessage, .request, .response, .path:
      guard payload.count >= 2 else { return nil }
      let hash = Data([payload[1]])
      let match = hashMatch(
        hash,
        role: .originator(entry.payloadType),
        // Heard straight from its sender: a flood no repeater has passed on
        isRadioNeighbour: entry.isFlood && hopCount == 0,
        context: context
      )
      return PacketNode(role: .sender(.peerHash), hash: hash, match: match, unobservedHint: hint(for: hash, match: match, context: context))
    case .groupText:
      guard entry.decryptStatus == .success, let name = channelSenderName(entry.decodedText) else { return nil }
      if name == context.index.selfName {
        return PacketNode(role: .sender(.channelName), hash: Data(), match: .radio, channelName: name)
      }
      // A name two nodes share, or no observed node has, still names the sender: by name alone
      let named = context.hasLedger ? context.index.candidates(named: name, at: context.date) : []
      let match = named.count == 1 ? PacketNodeMatch.resolved(named[0]) : nil
      return PacketNode(role: .sender(.channelName), hash: Data(), match: match, channelName: name)
    default:
      return nil
    }
  }

  /// Who a peer packet is addressed to, from its one-byte destination hash (R4); for a decrypted
  /// direct message, the contact whose key decrypted it or this radio.
  private static func recipient(of entry: RxLogEntryDTO, sender: PacketNode?, context: Context) -> PacketNodeMatch? {
    let payload = [UInt8](entry.packetPayload)
    let counterpart: PayloadType
    switch entry.payloadType {
    case .textMessage: counterpart = .textMessage
    case .request, .anonRequest: counterpart = .response
    case .response, .path: counterpart = .request
    default: return nil
    }
    guard payload.count >= 2 else { return nil }
    let destination = payload[0]
    if entry.payloadType == .textMessage, entry.decryptStatus == .success,
       let peer = entry.peerPublicKey, let first = peer.first {
      let selfFirst = context.index.selfKey?.first
      if first == payload[1], first == destination, first == selfFirst {
        // Contact and radio share the byte: either one sent it to the other
        return orThisRadio(keyMatch(peer, nodeTypeRaw: 0, context: context))
      }
      if sender?.isRadio == true, first == destination {
        return keyMatch(peer, nodeTypeRaw: 0, context: context)
      }
      if first == payload[1], selfFirst == destination {
        return .radio
      }
    }
    // Answered by the kind of node that sends the reply: a request goes to a repeater, room or
    // sensor, its response back to whoever asked
    return hashMatch(Data([destination]), role: .originator(counterpart), isRadioNeighbour: false, context: context)
  }

  /// "Alex" from a decoded channel message "Alex: on my way"; nil for a name too long to be one.
  static func channelSenderName(_ text: String?) -> String? {
    guard let text, let colon = text.range(of: ": ") else { return nil }
    let name = text[..<colon.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name.count > maximumChannelNameLength ? nil : name
  }

  // MARK: Transmitter

  /// Which node of the packet transmitted the frame this radio received; see
  /// ``PacketNodes/transmitter``.
  private static func transmitter(
    of entry: RxLogEntryDTO,
    sender: PacketNode?,
    isTrace: Bool,
    reachedCount: Int,
    isRouteAhead: Bool
  ) -> PacketNode.Role? {
    if isTrace {
      return reachedCount > 0 ? .hop(index: reachedCount - 1, isReached: true) : nil
    }
    if isRouteAhead {
      return nil
    }
    if entry.isFlood {
      return reachedCount > 0 ? .hop(index: reachedCount - 1, isReached: true) : sender?.role
    }
    // A direct packet with no path reached its destination; only a zero-hop advert or discover
    // reply was sent by the node it names
    switch sender?.role {
    case .sender(.fullKey) where entry.payloadType == .advert,
         .sender(.fullKey) where entry.payloadType == .control,
         .sender(.keyPrefix):
      return sender?.role
    default:
      return nil
    }
  }

  // MARK: Suspicious links

  /// `node`, flagged when its observed position is at least ``suspiciousLinkDistance`` from this
  /// radio's anchor: it transmitted the frame this radio received.
  private static func flaggingLink(_ node: PacketNode, index: PacketNodeIndex) -> PacketNode {
    guard let anchor = index.anchor, let coordinate = node.coordinate,
          RFCalculator.distance(from: anchor, to: coordinate) >= suspiciousLinkDistance else { return node }
    return PacketNode(
      role: node.role,
      hash: node.hash,
      match: node.match,
      channelName: node.channelName,
      isUnverified: node.isUnverified,
      claimedKey: node.claimedKey,
      isSuspicious: true,
      unobservedHint: node.unobservedHint,
      isProbable: node.isProbable
    )
  }

  /// The hops whose claimed leg from the previous placed node of the packet is at least
  /// ``suspiciousLinkDistance`` long.
  private static func suspiciousLegs(sender: PacketNode?, hops: [PacketNode]) -> Set<Int> {
    var previous = sender.flatMap { $0.role == .sender(.channelName) ? nil : $0.coordinate }
    var flagged: Set<Int> = []
    for (offset, hop) in hops.enumerated() {
      guard let coordinate = hop.coordinate else { continue }
      if let previous, RFCalculator.distance(from: previous, to: coordinate) >= suspiciousLinkDistance {
        flagged.insert(offset)
      }
      previous = coordinate
    }
    return flagged
  }

  // MARK: Ranking

  /// Likeliest first (R2): heard directly within ``directRankWindow`` of `date` (the hop this
  /// radio heard only), the types the role expects, fewer hops, observed more lately, then key
  /// bytes, so the order is total.
  private static func ranked(
    _ entries: [NeighbourKeyEntry],
    role: Role,
    isRadioNeighbour: Bool,
    date: Date
  ) -> [NeighbourKeyEntry] {
    let directCutoff = date.addingTimeInterval(-directRankWindow)
    let scored = entries.map { entry -> (entry: NeighbourKeyEntry, score: [Double]) in
      let heardDirectly = isRadioNeighbour && (entry.lastDirectAt.map { $0 >= directCutoff } ?? false)
      let score: [Double] = [
        heardDirectly ? 0 : 1,
        typePreference(entry.nodeTypeRaw, role: role),
        Double(entry.minHops ?? Int(Int32.max)),
        -(entry.lastHeard?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude),
      ]
      return (entry, score)
    }
    return scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score.lexicographicallyPrecedes(rhs.score) }
      return lhs.entry.publicKey.lexicographicallyPrecedes(rhs.entry.publicKey)
    }.map(\.entry)
  }

  /// 0 for the types `role` expects, 1 for the rest: relay-capable types for a hop; a chat node
  /// or room for a message, request or login; a repeater, room or sensor for a response or path.
  private static func typePreference(_ nodeTypeRaw: UInt8, role: Role) -> Double {
    let expected: Bool
    switch role {
    case .relay:
      expected = NeighbourKeyEntry.isRelayCapable(nodeTypeRaw)
    case .originator(.textMessage), .originator(.request), .originator(.anonRequest):
      expected = nodeTypeRaw == ContactType.chat.rawValue || nodeTypeRaw == ContactType.room.rawValue
    case .originator(.response), .originator(.path):
      expected = nodeTypeRaw == ContactType.repeater.rawValue || nodeTypeRaw == ContactType.room.rawValue
        || nodeTypeRaw == NeighbourKeyEntry.sensorType
    case .originator:
      expected = true
    }
    return expected ? 0 : 1
  }

  private static func isOwn(_ key: Data, in index: PacketNodeIndex) -> Bool {
    guard let own = index.selfKey else { return false }
    return key.starts(with: own) || own.starts(with: key)
  }
}
