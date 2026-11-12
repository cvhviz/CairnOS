import CoreLocation
import Foundation
import CairnServices

/// Picks and words the CarPlay Nodes tab as the app's Nodes tab has it: its groups collapsed with
/// their counts (Favorites, Contacts, Repeaters, Rooms, the nodes heard in the last hour and the
/// Heard list, then the user's own groups), Find's letter groups, and each list in the order
/// chosen in the app's settings. Pure over plain `Node` values; `nodes(contacts:discovered:)` and
/// `heardNodes(discovered:savedKeys:)` are the only parts that know the store's types.
enum CarPlayNodesSource {
  struct Node: Equatable {
    let publicKey: Data
    let name: String
    let type: ContactType
    /// The time the Nodes list shows and sorts by (`ContactDTO.recencyTimestamp`).
    let lastHeard: Date?
    let latitude: Double?
    let longitude: Double?
    /// "Direct", "3 hops" or "Flood", as the node rows say it.
    let route: String
    /// The hops the Hops sort uses; nil when flood-routed and never heard via advert.
    var hops: Int?
    let isFavorite: Bool
    /// The route's hops, a known repeater by name and the rest by hash: "Hilltop → 7F → Summit".
    var path: String?
    /// Hops the last advert came over.
    var advertHops: Int?
    var lastAdvert: Date?
    var unread = 0
    var lastMessage: Date?
    var isMuted = false
    /// Saved on the radio; false for a node only heard by advert (the phone's Heard list).
    var isSaved = true
  }

  /// The saved nodes, not blocked. A heard record supplies the hops its advert came over, as the
  /// Nodes list's route falls back to.
  static func nodes(contacts: [ContactDTO], discovered: [DiscoveredNodeDTO]) -> [Node] {
    let inboundHops = Dictionary(discovered.map { ($0.publicKey, $0.inboundHopCount) }, uniquingKeysWith: { first, _ in first })
    let repeaters = contacts.filter { $0.type == .repeater }.map { ($0.publicKeyHex.uppercased(), $0.displayName) }
    var seen: Set<Data> = []
    return contacts.compactMap { contact in
      guard !contact.isBlocked, seen.insert(contact.publicKey).inserted else { return nil }
      let advertHops = inboundHops[contact.publicKey] ?? nil
      let hops = contact.displayedHopCount(inboundHopCount: advertHops)
      let timestamp = contact.recencyTimestamp
      let hopHexes = contact.isFloodRouted ? [] : contact.pathNodesHex
      return Node(
        publicKey: contact.publicKey,
        name: contact.displayName,
        type: contact.type,
        lastHeard: timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil,
        latitude: contact.hasLocation ? contact.latitude : nil,
        longitude: contact.hasLocation ? contact.longitude : nil,
        route: NodeRouteFormat.routeLabel(
          isFloodRouted: contact.isFloodRouted,
          pathHopCount: contact.pathHopCount,
          displayedHopCount: hops
        ),
        hops: hops,
        isFavorite: contact.isFavorite,
        path: hopHexes.isEmpty ? nil : hopHexes.map { name(ofHop: $0, repeaters: repeaters) }.joined(separator: " \u{2192} "),
        advertHops: advertHops,
        lastAdvert: contact.lastAdvertTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp)) : nil,
        unread: contact.unreadCount,
        lastMessage: contact.lastMessageDate,
        isMuted: contact.isMuted
      )
    }
  }

  /// A hop of a contact's stored route (the radio's configuration, not traffic it heard) by the
  /// one saved repeater whose key starts with its hash, or the hash when none or several do. A
  /// heard packet's relays are named from what this radio observed instead
  /// (`NodeHeardSignal.heardPath(of:in:)`).
  static func name(ofHop hex: String, repeaters: [(keyHex: String, name: String)]) -> String {
    knownName(ofHop: hex, repeaters: repeaters) ?? hex
  }

  /// The one saved repeater whose key starts with the stored route hop's hash; nil when none or
  /// several do. Never for a heard packet's relays.
  static func knownName(ofHop hex: String, repeaters: [(keyHex: String, name: String)]) -> String? {
    let matches = repeaters.filter { $0.keyHex.hasPrefix(hex.uppercased()) }
    return matches.count == 1 ? CarPlaySnapshotBuilder.glanceName(matches[0].name) : nil
  }

  /// Nodes heard by advert and not saved, the phone's Heard list (`DiscoveryViewModel`): never a
  /// node in `savedKeys`, each listed once.
  static func heardNodes(discovered: [DiscoveredNodeDTO], savedKeys: Set<Data>) -> [Node] {
    var seen = savedKeys
    return discovered.compactMap { heard in
      guard seen.insert(heard.publicKey).inserted else { return nil }
      let hops = heard.displayedHopCount
      return Node(
        publicKey: heard.publicKey,
        name: heard.name,
        type: heard.nodeType,
        lastHeard: heard.lastHeard,
        latitude: heard.hasLocation ? heard.latitude : nil,
        longitude: heard.hasLocation ? heard.longitude : nil,
        route: NodeRouteFormat.routeLabel(
          isFloodRouted: heard.isFloodRouted,
          pathHopCount: heard.pathHopCount,
          displayedHopCount: hops
        ),
        hops: hops,
        isFavorite: false,
        advertHops: heard.inboundHopCount,
        lastAdvert: heard.lastAdvertTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(heard.lastAdvertTimestamp)) : nil,
        isSaved: false
      )
    }
  }

  // MARK: - Groups

  /// The Nodes tab's groups in the order it lists them: the app's own (Favorites, then its
  /// Contacts, Repeaters and Rooms filters), the nodes heard in the last hour, then the phone's
  /// Heard list. Find goes above them all.
  static let categoryOrder: [CarPlaySnapshot.NodeCategory] = [.nearby, .favorites, .contacts, .repeaters, .rooms, .recentlyHeard, .heard]

  /// A group's name, in the phone's words.
  static func title(_ category: CarPlaySnapshot.NodeCategory) -> String {
    switch category {
    case .recentlyHeard: L10n.Localizable.CarPlay.Nodes.recent
    case .favorites: L10n.Contacts.Contacts.Segment.favorites
    case .contacts: NodeSegment.contacts.localizedTitle
    case .repeaters: NodeSegment.repeaters.localizedTitle
    case .rooms: NodeSegment.rooms.localizedTitle
    case .heard: L10n.Contacts.Contacts.Section.heard
    case .nearby: L10n.Localizable.CarPlay.Nodes.nearby
    }
  }

  /// What an empty group's list says, as the phone's empty Nodes list does.
  static func emptyTitle(_ category: CarPlaySnapshot.NodeCategory) -> String {
    switch category {
    case .favorites: L10n.Contacts.Contacts.List.Empty.Favorites.title
    case .heard, .recentlyHeard: L10n.Contacts.Contacts.Discovery.Empty.title
    case .contacts, .repeaters, .rooms: L10n.Contacts.Contacts.List.Empty.Contacts.title
    case .nearby: L10n.Map.Map.Empty.NoNodes.title
    }
  }

  /// The nodes in a group. A favorite is in Favorites and in its kind's group too, as the phone's
  /// filters list it; the saved groups never hold a node that is only heard. Recently Heard is
  /// the nodes whose adverts arrived in the last hour, saved or not (`heardKeys`, from
  /// `LiveActivityManager.nodesHeardKeys`): a contact edited or synced is not heard.
  /// Nearby is every node with a position, saved or heard, nearest `origin` first; nothing
  /// without an origin, when there is no "near".
  static func members(
    of category: CarPlaySnapshot.NodeCategory,
    in nodes: [Node],
    heardKeys: Set<Data>,
    origin: CLLocation? = nil
  ) -> [Node] {
    switch category {
    case .recentlyHeard: nodes.filter { heardKeys.contains($0.publicKey) }
    case .favorites: nodes.filter { $0.isSaved && $0.isFavorite }
    case .contacts: nodes.filter { $0.isSaved && $0.type == .chat }
    case .repeaters: nodes.filter { $0.isSaved && $0.type == .repeater }
    case .rooms: nodes.filter { $0.isSaved && $0.type == .room }
    case .heard: nodes.filter { !$0.isSaved }
    case .nearby: nearby(nodes, origin: origin)
    }
  }

  /// The nodes with a position, nearest `origin` first (by name between equals); none without
  /// an origin.
  static func nearby(_ nodes: [Node], origin: CLLocation?) -> [Node] {
    guard let origin else { return [] }
    return nodes
      .compactMap { node in distance(to: node, from: origin).map { (node: node, distance: $0) } }
      .sorted { lhs, rhs in
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
      }
      .map(\.node)
  }

  /// The nodes in one of the user's own groups (`ContactGroup`).
  static func members(of group: ContactGroup, in nodes: [Node]) -> [Node] {
    nodes.filter { group.contains($0.publicKey) }
  }

  /// A collapsed group: its count and the node in it heard most recently.
  static func groupRow(
    _ list: CarPlaySnapshot.NodeList,
    title: String,
    symbol: String,
    tint: CarPlayTint,
    members: [Node],
    now: Date
  ) -> CarPlaySnapshot.NodeGroupRow {
    let latest = members.filter { $0.lastHeard != nil }.max { ($0.lastHeard ?? .distantPast) < ($1.lastHeard ?? .distantPast) }
    return .init(
      list: list,
      title: title,
      count: members.count,
      latestName: latest.map { CarPlaySnapshotBuilder.glanceName($0.name) },
      latestAge: latest?.lastHeard.map { HomeFormat.age(now.timeIntervalSince($0)) },
      symbol: symbol,
      tint: tint
    )
  }

  /// The Nodes tab's root: Find, then each group that holds a node, with its count. Nothing with
  /// no nodes, when the list's empty view says why. Nearby (with an `origin`) shows its nearest
  /// node and how far, where the other groups show their freshest.
  static func categories(_ nodes: [Node], heardKeys: Set<Data>, origin: CLLocation? = nil, now: Date) -> [CarPlaySnapshot.NodeGroupRow] {
    guard !nodes.isEmpty else { return [] }
    let find = groupRow(
      .find,
      title: L10n.Localizable.CarPlay.Nodes.find,
      symbol: findSymbol,
      tint: .feature(.nodes),
      members: nodes,
      now: now
    )
    return [find] + categoryOrder.compactMap { category in
      let members = Self.members(of: category, in: nodes, heardKeys: heardKeys, origin: origin)
      guard !members.isEmpty else { return nil }
      if category == .nearby, let nearest = members.first {
        return .init(
          list: .category(category),
          title: title(category),
          count: members.count,
          latestName: CarPlaySnapshotBuilder.glanceName(nearest.name),
          latestAge: distanceAndBearing(nearest, origin: origin),
          symbol: CarPlayAvatar.symbol(category),
          tint: CarPlayAvatar.tint(category)
        )
      }
      return groupRow(
        .category(category),
        title: title(category),
        symbol: CarPlayAvatar.symbol(category),
        tint: CarPlayAvatar.tint(category),
        members: members,
        now: now
      )
    }
  }

  /// The user's own groups that hold a node, in the order the phone lists them, with the
  /// group's own icon and colour.
  static func groups(_ nodes: [Node], groups: [ContactGroup], now: Date) -> [CarPlaySnapshot.NodeGroupRow] {
    groups.compactMap { group in
      let members = Self.members(of: group, in: nodes)
      guard !members.isEmpty else { return nil }
      return groupRow(.group(group.id), title: group.name, symbol: group.symbol, tint: .color(group.tint), members: members, now: now)
    }
  }

  // MARK: - Find

  /// Find's glyph, the phone's search field's.
  static let findSymbol = "magnifyingglass"
  /// A letter group's glyph.
  static let lettersSymbol = "textformat.abc"
  /// Names that start with a digit or only symbols are filed under this.
  static let otherInitial = "#"
  /// Most letter groups Find offers, so they fit the car's screen at once.
  static let maxLetterGroups = 8

  /// The letter a name is filed under: its first letter, upper case, without accents (an emoji or
  /// symbol before it is skipped, as the name's tile skips it); "#" for a digit or no letter.
  static func initial(_ name: String) -> String {
    guard let first = name.first(where: { $0.isLetter || $0.isNumber }), first.isLetter else { return otherInitial }
    let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    return String(folded.uppercased().prefix(1))
  }

  /// "A", or "A–C" for a group of several letters.
  static func lettersTitle(_ letters: String) -> String {
    guard let first = letters.first, let last = letters.last else { return otherInitial }
    return first == last ? String(first) : "\(first)\u{2013}\(last)"
  }

  /// Find's letter groups, built from the names there are: every letter its own group while
  /// there are few, otherwise neighbouring letters packed so the groups hold about as many nodes
  /// each, at most `maximum` of them. Only groups with nodes; digits and symbols last, as "#".
  static func letterGroups(_ nodes: [Node], now: Date, maximum: Int = maxLetterGroups) -> [CarPlaySnapshot.NodeGroupRow] {
    let byInitial = Dictionary(grouping: nodes) { initial($0.name) }
    let letters = byInitial.keys.filter { $0 != otherInitial }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let hasOther = byInitial[otherInitial] != nil
    var slots = max(1, maximum - (hasOther ? 1 : 0))
    var packs: [[String]] = []
    if letters.count <= slots {
      packs = letters.map { [$0] }
    } else {
      var remaining = letters.reduce(0) { $0 + (byInitial[$1]?.count ?? 0) }
      var current: [String] = []
      var count = 0
      for (index, letter) in letters.enumerated() {
        current.append(letter)
        count += byInitial[letter]?.count ?? 0
        let lettersLeft = letters.count - index - 1
        // Close the group at its fair share of what is left, or when each group still to come
        // needs one of the letters left.
        if slots > 1, Double(count) >= Double(remaining) / Double(slots) || lettersLeft < slots {
          packs.append(current)
          remaining -= count
          slots -= 1
          current = []
          count = 0
        }
      }
      if !current.isEmpty { packs.append(current) }
    }
    if hasOther { packs.append([otherInitial]) }
    return packs.map { pack in
      let key = pack.joined()
      return groupRow(
        .letters(key),
        title: lettersTitle(key),
        symbol: lettersSymbol,
        tint: .feature(.nodes),
        members: pack.flatMap { byInitial[$0] ?? [] },
        now: now
      )
    }
  }

  /// The nodes whose names are filed under one of `letters`.
  static func members(ofLetters letters: String, in nodes: [Node]) -> [Node] {
    let initials = Set(letters.map(String.init))
    return nodes.filter { initials.contains(initial($0.name)) }
  }

  // MARK: - Lists

  /// A list the Nodes tab opens: its nodes as the phone's list orders them (favourites first,
  /// then the sort chosen in the app's Nodes settings; a letter group by name). When there are
  /// more than `limit`, the favourites and the newest are kept, with a note saying how many.
  static func page(
    _ list: CarPlaySnapshot.NodeList,
    nodes: [Node],
    groups: [ContactGroup] = [],
    sortOrder: NodeSortOrder = .lastHeard,
    heardKeys: Set<Data>,
    origin: CLLocation?,
    now: Date,
    hashSize: Int = 1,
    limit: Int = CarPlaySnapshotBuilder.maxListItems
  ) -> CarPlaySnapshot.NodeListPage {
    let members: [Node]
    let title: String
    let emptyTitle: String
    var order = sortOrder
    switch list {
    case let .category(category):
      members = Self.members(of: category, in: nodes, heardKeys: heardKeys, origin: origin)
      title = Self.title(category)
      emptyTitle = Self.emptyTitle(category)
      // Nearby is nearest first whatever the app's order says.
      if category == .nearby { order = .distance }
    case let .group(id):
      let group = groups.first { $0.id == id }
      members = group.map { Self.members(of: $0, in: nodes) } ?? []
      title = group?.name ?? L10n.Contacts.Contacts.Groups.title
      emptyTitle = L10n.Contacts.Contacts.Groups.filterEmptyTitle
    case let .letters(letters):
      members = Self.members(ofLetters: letters, in: nodes)
      title = lettersTitle(letters)
      emptyTitle = L10n.Contacts.Contacts.List.Empty.Contacts.title
      order = .name
    case .find:
      members = []
      title = L10n.Localizable.CarPlay.Nodes.find
      emptyTitle = L10n.Contacts.Contacts.List.Empty.Contacts.title
    }
    let cap = max(0, limit)
    let kept = members.count > cap ? Array(newestFirst(members).prefix(cap)) : members
    let sorted = order.sorted(
      kept,
      recency: { $0.lastHeard?.timeIntervalSince1970 ?? 0 },
      name: \.name,
      distance: { distance(to: $0, from: origin) },
      hops: \.hops
    )
    let ordered = sorted.filter(\.isFavorite) + sorted.filter { !$0.isFavorite }
    return .init(
      list: list,
      title: title,
      note: members.count > kept.count ? L10n.Localizable.CarPlay.Nodes.showing(kept.count, members.count) : nil,
      rows: ordered.map { row($0, origin: origin, now: now, hashSize: hashSize) },
      emptyTitle: emptyTitle
    )
  }

  /// Favourites first, then the most recently heard, then by name: which nodes a cut list keeps.
  static func newestFirst(_ nodes: [Node]) -> [Node] {
    nodes.sorted { lhs, rhs in
      if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
      let left = lhs.lastHeard ?? .distantPast
      let right = rhs.lastHeard ?? .distantPast
      if left != right { return left > right }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  // MARK: - Cards (iOS 26)

  /// The card rows on the Nodes tab and under Find.
  static let categoriesRowID = "nodes.categories"
  static let groupsRowID = "nodes.groups"
  static let lettersRowID = "nodes.letters"
  /// Most condensed cards in one row; more go on a row of their own.
  static let maxTilesPerRow = 8

  /// A collapsed group as a condensed card: its glyph tile, its name, and its count with how
  /// long ago its freshest node was heard. A tap opens its list.
  static func tile(_ row: CarPlaySnapshot.NodeGroupRow) -> CarPlaySnapshot.Tile {
    .init(
      id: row.id,
      symbol: row.symbol,
      tint: row.tint,
      title: CarPlayCardBuilder.short(row.title),
      subtitle: row.shortDetail,
      action: .nodeList(row.list),
      // The phone's avatar, as the rows before iOS 26 draw it, so a light fill (Favorites'
      // yellow, the companions' teal) gets a dark glyph.
      isAvatar: true
    )
  }

  /// Groups as rows of condensed cards, several to a line, so a whole set fits one screen.
  static func tileRows(_ rows: [CarPlaySnapshot.NodeGroupRow], id: String) -> [CarPlaySnapshot.TileRow] {
    stride(from: 0, to: rows.count, by: maxTilesPerRow).map { start in
      let chunk = rows[start ..< min(rows.count, start + maxTilesPerRow)]
      return .init(id: start == 0 ? id : "\(id).\(start)", title: nil, tiles: chunk.map(tile), style: .condensed)
    }
  }

  /// The Nodes tab as cards: Find and the app's groups, then the user's groups under their
  /// heading.
  static func tileSections(_ nodes: CarPlaySnapshot.Nodes) -> [CarPlaySnapshot.TileSection] {
    var sections: [CarPlaySnapshot.TileSection] = []
    if !nodes.categories.isEmpty {
      sections.append(.init(header: nil, rows: tileRows(nodes.categories, id: categoriesRowID)))
    }
    if !nodes.groups.isEmpty {
      sections.append(.init(header: L10n.Contacts.Contacts.Groups.title, rows: tileRows(nodes.groups, id: groupsRowID)))
    }
    return sections
  }

  /// Find's letter groups as cards.
  static func letterTileSections(_ nodes: CarPlaySnapshot.Nodes) -> [CarPlaySnapshot.TileSection] {
    nodes.letterGroups.isEmpty ? [] : [.init(header: nil, rows: tileRows(nodes.letterGroups, id: lettersRowID))]
  }

  /// The app's node row in two lines: the name, then when it was last heard, the radio's short
  /// id, the route and how far away. The avatar says the type, as on the phone (`CarPlayAvatar`).
  static func row(_ node: Node, origin: CLLocation?, now: Date, hashSize: Int = 1, heard: Heard? = nil) -> CarPlaySnapshot.NodeRow {
    let age = node.lastHeard.map { HomeFormat.age(now.timeIntervalSince($0)) }
    let distance = distanceAndBearing(node, origin: origin)
    let shortID = node.publicKey.prefix(max(1, hashSize)).uppercaseHexString()
    return CarPlaySnapshot.NodeRow(
      publicKey: node.publicKey,
      name: node.name,
      detail: NodeRouteFormat.joined([age, shortID, node.route, distance]),
      symbol: CarPlayAvatar.symbol(node.type, name: node.name),
      info: info(node, age: age, distance: distance, heard: heard, now: now),
      tint: CarPlayAvatar.tint(node.type, name: node.name)
    )
  }

  /// The last packet the RX log holds from the node: the path it took here and how strong it was.
  struct Heard: Equatable {
    /// "Hilltop → 7F → Ridge" or Direct (`NodeHeardSignal.heardPath`); nil for a direct packet.
    var path: String?
    var snr: Double?
    var rssi: Int?
    var date: Date
  }

  /// Everything the app knows about the node, two facts to a line where they belong together,
  /// within the car's ten lines. Only what is known is listed. The way out (Route) and the way in
  /// (Heard Via) sit together, so a one-way route shows at a glance.
  static func info(_ node: Node, age: String?, distance: String?, heard: Heard? = nil, now: Date) -> [CarPlaySnapshot.InfoRow] {
    let detail = L10n.Contacts.Contacts.Detail.self
    var rows: [CarPlaySnapshot.InfoRow] = [
      .init(title: detail.type, detail: NodeRouteFormat.joined([
        node.type.localizedName,
        node.isFavorite ? detail.favorite : nil,
        node.isMuted ? L10n.Chats.Chats.Row.muted : nil,
        node.isSaved ? nil : L10n.Contacts.Contacts.Section.heard,
      ])),
      // "2 hops · Hilltop → 7F": how messages go out.
      .init(title: detail.route, detail: NodeRouteFormat.joined([node.route, node.path])),
    ]
    if let heard, let path = heard.path {
      // "Ridge → 7F · 5m": how the last packet came in, and when.
      rows.append(.init(title: detail.heardVia, detail: NodeRouteFormat.joined([
        path,
        HomeFormat.age(now.timeIntervalSince(heard.date)),
      ])))
    }
    if let age {
      // "2m · ↓ 8.5 dB · -92 dBm": the last packet's signal beside when it was heard.
      rows.append(.init(title: detail.lastHeard, detail: NodeRouteFormat.joined([
        age,
        heard?.snr.map { L10n.Tools.Tools.NodeDiscovery.snrDown(NodeDiscoveryResultCard.snrNumber($0)) },
        heard?.rssi.map { SpectrumFormat.dBm(Double($0)) },
      ])))
    }
    if let lastAdvert = node.lastAdvert {
      rows.append(.init(title: detail.lastAdvert, detail: NodeRouteFormat.joined([
        HomeFormat.age(now.timeIntervalSince(lastAdvert)),
        node.advertHops.map { NodeRouteFormat.hopCount($0) },
      ])))
    }
    if let distance {
      rows.append(.init(title: detail.distance, detail: distance))
    }
    if let latitude = node.latitude, let longitude = node.longitude {
      let fraction = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(4))
      rows.append(.init(title: detail.location, detail: "\(latitude.formatted(fraction)), \(longitude.formatted(fraction))"))
    }
    if node.type != .repeater, node.unread > 0 || node.lastMessage != nil {
      rows.append(.init(title: detail.unreadMessages, detail: NodeRouteFormat.joined([
        node.unread.formatted(),
        node.lastMessage.map { HomeFormat.age(now.timeIntervalSince($0)) },
      ])))
    }
    rows.append(.init(title: detail.publicKey, detail: node.publicKey.prefix(8).uppercaseHexString() + "\u{2026}"))
    return Array(rows.prefix(CarPlaySnapshotBuilder.maxInfoItems))
  }

  /// A ping's outcome as the detail screen's first line: the round trip and the SNR each way, as
  /// on the node's app page, or no response.
  static func pingRow(_ result: PingResult) -> CarPlaySnapshot.InfoRow {
    let title = L10n.Contacts.Contacts.Detail.ping
    return switch result {
    case let .success(latencyMs, snrThere, snrBack):
      .init(title: title, detail: NodeRouteFormat.joined([
        Duration.milliseconds(latencyMs).formatted(.units(allowed: [.milliseconds], width: .abbreviated)),
        L10n.Contacts.Contacts.Detail.pingSNR(
          NodeDiscoveryResultCard.snrNumber(snrThere),
          NodeDiscoveryResultCard.snrNumber(snrBack)
        ),
      ]))
    case let .error(message):
      .init(title: title, detail: message)
    }
  }

  /// Metres to the node, or nil without both positions.
  static func distance(to node: Node, from origin: CLLocation?) -> Double? {
    guard let origin, let latitude = node.latitude, let longitude = node.longitude else { return nil }
    return CLLocation(latitude: latitude, longitude: longitude).distance(from: origin)
  }

  /// "3.4 mi NE", or nil without both positions.
  static func distanceAndBearing(_ node: Node, origin: CLLocation?) -> String? {
    guard let origin, let latitude = node.latitude, let longitude = node.longitude,
          let distance = NodeRouteFormat.distance(from: origin, latitude: latitude, longitude: longitude) else {
      return nil
    }
    let destination = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    let direction = HomeFormat.compassPoint(bearing: HomeFormat.bearing(from: origin.coordinate, to: destination))
    return "\(distance) \(direction)"
  }
}
