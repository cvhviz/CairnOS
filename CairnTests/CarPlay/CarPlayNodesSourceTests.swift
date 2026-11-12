import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("CarPlayNodesSource")
struct CarPlayNodesSourceTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func node(_ index: Int, favorite: Bool = false, heardMinutesAgo: Int? = 1, type: ContactType = .repeater) -> CarPlayNodesSource.Node {
    CarPlayNodesSource.Node(
      publicKey: Data([UInt8(index)]),
      name: "Node \(index)",
      type: type,
      lastHeard: heardMinutesAgo.map { now.addingTimeInterval(-Double($0) * 60) },
      latitude: nil,
      longitude: nil,
      route: L10n.Contacts.Contacts.Route.direct,
      isFavorite: favorite
    )
  }

  private func named(_ name: String, minutesAgo: Int? = 5, favorite: Bool = false, saved: Bool = true, type: ContactType = .chat) -> CarPlayNodesSource.Node {
    CarPlayNodesSource.Node(
      publicKey: Data(name.utf8),
      name: name,
      type: type,
      lastHeard: minutesAgo.map { now.addingTimeInterval(-Double($0) * 60) },
      latitude: nil,
      longitude: nil,
      route: L10n.Contacts.Contacts.Route.direct,
      isFavorite: favorite,
      isSaved: saved
    )
  }

  // MARK: Groups

  @Test
  func `The root is Find, then the phone's groups with counts, empty ones left out`() {
    let nodes = [
      node(1, favorite: true, type: .chat),
      node(2, heardMinutesAgo: 120, type: .chat),
      node(3, heardMinutesAgo: 30, type: .repeater),
      named("Stranger", minutesAgo: 10, saved: false, type: .repeater),
    ]
    // Heard by advert in the last hour: node 1, node 3 and the stranger.
    let heardKeys: Set<Data> = [Data([1]), Data([3]), Data("Stranger".utf8)]
    let rows = CarPlayNodesSource.categories(nodes, heardKeys: heardKeys, now: now)
    #expect(rows.map(\.list) == [.find, .category(.favorites), .category(.contacts), .category(.repeaters), .category(.recentlyHeard), .category(.heard)])
    #expect(rows.map(\.count) == [4, 1, 2, 1, 3, 1])
    #expect(rows.map(\.title) == [
      L10n.Localizable.CarPlay.Nodes.find,
      L10n.Contacts.Contacts.Segment.favorites,
      NodeSegment.contacts.localizedTitle,
      NodeSegment.repeaters.localizedTitle,
      L10n.Localizable.CarPlay.Nodes.recent,
      L10n.Contacts.Contacts.Section.heard,
    ])
    // The phone's avatars: the walkie-talkie, the mast, the yellow star.
    #expect(rows[2].symbol == CarPlayAvatar.companionSymbol)
    #expect(rows[3].symbol == CarPlayAvatar.repeaterSymbol && rows[3].tint == .avatar(.repeater))
    #expect(rows[1].symbol == CarPlayAvatar.favoriteSymbol)
    #expect(CarPlayNodesSource.categories([], heardKeys: heardKeys, now: now).isEmpty)
  }

  @Test
  func `A collapsed group reads its count, then its freshest node and when`() {
    let nodes = [named("Hilltop", minutesAgo: 2), named("Ridge", minutesAgo: 40)]
    let row = CarPlayNodesSource.categories(nodes, heardKeys: [], now: now).first { $0.list == .category(.contacts) }
    #expect(row?.detail == NodeRouteFormat.joined(["2", "Hilltop \(HomeFormat.age(120))"]))
    #expect(row?.shortDetail == NodeRouteFormat.joined(["2", HomeFormat.age(120)]))
  }

  @Test
  func `Recently heard is the nodes whose adverts the Dashboard counted, saved and heard alike`() async {
    // B was edited or synced a minute ago (its list time is fresh) but no advert came: not heard.
    let nodes = [named("A", minutesAgo: 59), named("B", minutesAgo: 1), named("C", minutesAgo: 5, saved: false), named("D", minutesAgo: nil)]
    let adverts: [Data: Date] = [
      Data("A".utf8): now.addingTimeInterval(-59 * 60),
      Data("C".utf8): now.addingTimeInterval(-5 * 60),
      Data("D".utf8): now.addingTimeInterval(-61 * 60),
      Data("Gone".utf8): now.addingTimeInterval(-60),
    ]
    let heardKeys = await MainActor.run { LiveActivityManager.nodesHeardKeys(lastHeard: adverts, now: now) }
    #expect(heardKeys == [Data("A".utf8), Data("C".utf8), Data("Gone".utf8)])
    let members = CarPlayNodesSource.members(of: .recentlyHeard, in: nodes, heardKeys: heardKeys)
    #expect(members.map(\.name) == ["A", "C"])
    // The count on the group is the list it opens.
    let group = CarPlayNodesSource.categories(nodes, heardKeys: heardKeys, now: now).first { $0.list == .category(.recentlyHeard) }
    #expect(group?.count == members.count)
    let page = CarPlayNodesSource.page(.category(.recentlyHeard), nodes: nodes, heardKeys: heardKeys, origin: nil, now: now)
    #expect(Set(page.rows.map(\.name)) == ["A", "C"])
  }

  @Test
  func `A group's card is the phone's avatar, not a tool tile`() {
    let rows = CarPlayNodesSource.categories([named("Fav", favorite: true)], heardKeys: [], now: now)
    let tiles = CarPlayNodesSource.tileRows(rows, id: CarPlayNodesSource.categoriesRowID).flatMap(\.tiles)
    #expect(!tiles.isEmpty)
    #expect(tiles.allSatisfy { $0.isAvatar })
  }

  @Test
  func `A favorite is under Favorites and its kind, a heard node only under Heard`() {
    let nodes = [named("Fav", favorite: true), named("Heard", saved: false)]
    #expect(CarPlayNodesSource.members(of: .favorites, in: nodes, heardKeys: []).map(\.name) == ["Fav"])
    #expect(CarPlayNodesSource.members(of: .contacts, in: nodes, heardKeys: []).map(\.name) == ["Fav"])
    #expect(CarPlayNodesSource.members(of: .heard, in: nodes, heardKeys: []).map(\.name) == ["Heard"])
  }

  @Test
  func `The user's groups show with their own icon and colour, empty ones left out`() {
    let hilltop = named("Hilltop")
    let family = ContactGroup(name: "Family", symbol: "house.fill", color: ContactGroup.Palette.green.rawValue, memberKeys: [ContactGroup.memberKey(for: hilltop.publicKey)])
    let empty = ContactGroup(name: "Empty")
    let rows = CarPlayNodesSource.groups([hilltop, named("Other")], groups: [family, empty], now: now)
    #expect(rows.map(\.list) == [.group(family.id)])
    #expect(rows.first?.count == 1)
    #expect(rows.first?.symbol == "house.fill")
    #expect(rows.first?.tint == .color(family.tint))
  }

  // MARK: Lists

  @Test
  func `A list follows the app's sort, favourites first`() {
    let nodes = [named("Bravo", minutesAgo: 30), named("Alpha", minutesAgo: 5), named("Zulu", minutesAgo: 90, favorite: true)]
    let byRecency = CarPlayNodesSource.page(.category(.contacts), nodes: nodes, sortOrder: .lastHeard, heardKeys: [], origin: nil, now: now)
    #expect(byRecency.rows.map(\.name) == ["Zulu", "Alpha", "Bravo"])
    let byName = CarPlayNodesSource.page(.category(.contacts), nodes: nodes, sortOrder: .name, heardKeys: [], origin: nil, now: now)
    #expect(byName.rows.map(\.name) == ["Zulu", "Alpha", "Bravo"])
    #expect(byName.title == NodeSegment.contacts.localizedTitle)
    #expect(byName.note == nil)
  }

  @Test
  func `A long list keeps the favourites and the newest, and says how many it shows`() {
    let nodes = (0 ..< 30).map { named(String(format: "N%02d", $0), minutesAgo: $0 + 1) } + [named("Old favourite", minutesAgo: 999, favorite: true)]
    let page = CarPlayNodesSource.page(.category(.contacts), nodes: nodes, sortOrder: .name, heardKeys: [], origin: nil, now: now, limit: 12)
    #expect(page.rows.count == 12)
    #expect(page.rows.first?.name == "Old favourite")
    #expect(Set(page.rows.dropFirst().map(\.name)) == Set((0 ..< 11).map { String(format: "N%02d", $0) }))
    #expect(page.note == L10n.Localizable.CarPlay.Nodes.showing(12, 31))
  }

  @Test
  func `An empty list says so in the phone's words`() {
    let page = CarPlayNodesSource.page(.category(.favorites), nodes: [named("A")], heardKeys: [], origin: nil, now: now)
    #expect(page.rows.isEmpty)
    #expect(page.emptyTitle == L10n.Contacts.Contacts.List.Empty.Favorites.title)
    let gone = CarPlayNodesSource.page(.group(UUID()), nodes: [named("A")], heardKeys: [], origin: nil, now: now)
    #expect(gone.rows.isEmpty)
  }

  // MARK: Find

  @Test
  func `A name is filed under its first letter, folded, past any emoji; digits under #`() {
    #expect(CarPlayNodesSource.initial("ålesund") == "A")
    #expect(CarPlayNodesSource.initial("🚗 Bob") == "B")
    #expect(CarPlayNodesSource.initial("  émile") == "E")
    #expect(CarPlayNodesSource.initial("42 Main") == "#")
    #expect(CarPlayNodesSource.initial("🚗") == "#")
    #expect(CarPlayNodesSource.initial("Москва") == "М")
  }

  @Test
  func `Few letters are a group each, only the letters there are, # last`() {
    let nodes = [named("alpha"), named("Bravo"), named("Bison"), named("9 Pines"), named("Delta")]
    let groups = CarPlayNodesSource.letterGroups(nodes, now: now)
    #expect(groups.map(\.title) == ["A", "B", "D", "#"])
    #expect(groups.map(\.count) == [1, 2, 1, 1])
    #expect(groups.map(\.list) == [.letters("A"), .letters("B"), .letters("D"), .letters("#")])
  }

  @Test
  func `Many letters are packed into ranges of about even size, within the maximum`() {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let nodes = letters.flatMap { letter in (0 ..< 2).map { named("\(letter)node\($0)") } }
    let groups = CarPlayNodesSource.letterGroups(nodes, now: now, maximum: 8)
    #expect(groups.count <= 8)
    #expect(groups.count >= 6)
    #expect(groups.reduce(0) { $0 + $1.count } == nodes.count)
    #expect(groups.first?.title.hasPrefix("A\u{2013}") == true)
    // Every name is in exactly one group, and a group's list holds its names.
    for group in groups {
      guard case let .letters(key) = group.list else { continue }
      let page = CarPlayNodesSource.page(group.list, nodes: nodes, heardKeys: [], origin: nil, now: now, limit: 100)
      #expect(page.rows.count == group.count)
      #expect(page.rows.allSatisfy { key.contains(Character(CarPlayNodesSource.initial($0.name))) })
      #expect(page.rows.map(\.name) == page.rows.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
  }

  @Test
  func `Heard nodes skip the saved ones and are marked as heard`() {
    #expect(CarPlayNodesSource.heardNodes(discovered: [], savedKeys: []).isEmpty)
    let row = CarPlayNodesSource.row(named("Stranger", saved: false), origin: nil, now: now)
    #expect(row.info.first?.detail.contains(L10n.Contacts.Contacts.Section.heard) == true)
  }

  // MARK: Cards

  @Test
  func `On cards, the groups are condensed rows that open their list`() {
    let nodes = CarPlaySnapshot.Nodes(
      categories: CarPlayNodesSource.categories([named("A"), named("B", favorite: true)], heardKeys: [], now: now),
      groups: [],
      emptyTitle: ""
    )
    let sections = CarPlayNodesSource.tileSections(nodes)
    #expect(sections.count == 1)
    #expect(sections[0].rows.map(\.id) == [CarPlayNodesSource.categoriesRowID])
    #expect(sections[0].rows[0].style == .condensed)
    #expect(sections[0].rows[0].tiles.map(\.action) == nodes.categories.map { .nodeList($0.list) })
  }

  @Test
  func `More groups than a row holds wrap onto further rows`() {
    let rows = (0 ..< 11).map { index in
      CarPlaySnapshot.NodeGroupRow(list: .letters("\(index)"), title: "\(index)", count: 1, symbol: "x", tint: .brand)
    }
    let tileRows = CarPlayNodesSource.tileRows(rows, id: "r")
    #expect(tileRows.map(\.tiles.count) == [CarPlayNodesSource.maxTilesPerRow, 11 - CarPlayNodesSource.maxTilesPerRow])
    #expect(Set(tileRows.map(\.id)).count == tileRows.count)
  }

  @Test
  func `A row reads age, short id and route, leaving the type to its tile`() {
    let row = CarPlayNodesSource.row(node(0xA3, heardMinutesAgo: 2), origin: nil, now: now)
    #expect(row.detail == NodeRouteFormat.joined([HomeFormat.age(120), "A3", L10n.Contacts.Contacts.Route.direct]))
    #expect(!row.detail.contains(ContactType.repeater.localizedName))
    #expect(row.symbol == CarPlayAvatar.repeaterSymbol)
    #expect(row.tint == .avatar(.repeater))
  }

  @Test
  func `The detail screen lists only what is known`() {
    let row = CarPlayNodesSource.row(node(1, heardMinutesAgo: nil), origin: nil, now: now)
    let detail = L10n.Contacts.Contacts.Detail.self
    #expect(row.info.map(\.title) == [detail.type, detail.route, detail.publicKey])
    #expect(!row.info.contains { $0.detail == "—" })
  }

  @Test
  func `The detail screen packs in everything known, within ten lines`() {
    let base = node(1, favorite: true, type: .chat)
    let full = CarPlayNodesSource.Node(
      publicKey: Data([0xA3, 1, 2, 3, 4, 5, 6, 7, 8]), name: base.name, type: .chat, lastHeard: base.lastHeard,
      latitude: 1, longitude: 2, route: base.route, hops: 2, isFavorite: true,
      path: "Hilltop \u{2192} 7F", advertHops: 2, lastAdvert: now.addingTimeInterval(-300),
      unread: 3, lastMessage: now.addingTimeInterval(-3600), isMuted: true
    )
    let row = CarPlayNodesSource.row(full, origin: CLLocation(latitude: 0, longitude: 0), now: now)
    let detail = L10n.Contacts.Contacts.Detail.self
    #expect(row.info.map(\.title) == [
      detail.type, detail.route, detail.lastHeard, detail.lastAdvert,
      detail.distance, detail.location, detail.unreadMessages, detail.publicKey,
    ])
    #expect(row.info[0].detail == NodeRouteFormat.joined([ContactType.chat.localizedName, detail.favorite, L10n.Chats.Chats.Row.muted]))
    #expect(row.info[1].detail == NodeRouteFormat.joined([base.route, "Hilltop \u{2192} 7F"]))
    #expect(row.info[3].detail == NodeRouteFormat.joined([HomeFormat.age(300), NodeRouteFormat.hopCount(2)]))
    #expect(row.info.last?.detail == "A301020304050607…")
    #expect(row.info.count <= CarPlaySnapshotBuilder.maxInfoItems)
  }

  @Test
  func `The way in sits under the way out, and the last packet's signal beside Last Heard`() {
    let heard = CarPlayNodesSource.Heard(path: "Ridge \u{2192} 7F", snr: 8.5, rssi: -92, date: now.addingTimeInterval(-300))
    let row = CarPlayNodesSource.row(node(1, heardMinutesAgo: 2), origin: nil, now: now, heard: heard)
    let detail = L10n.Contacts.Contacts.Detail.self
    #expect(Array(row.info.map(\.title).prefix(4)) == [detail.type, detail.route, detail.heardVia, detail.lastHeard])
    #expect(row.info[2].detail == NodeRouteFormat.joined(["Ridge \u{2192} 7F", HomeFormat.age(300)]))
    #expect(row.info[3].detail == NodeRouteFormat.joined([
      HomeFormat.age(120),
      L10n.Tools.Tools.NodeDiscovery.snrDown(NodeDiscoveryResultCard.snrNumber(8.5)),
      SpectrumFormat.dBm(-92),
    ]))
  }

  @Test
  func `A ping reads its round trip and the SNR each way, or no response`() {
    let success = CarPlayNodesSource.pingRow(.success(latencyMs: 120, snrThere: 10.5, snrBack: 8))
    #expect(success.title == L10n.Contacts.Contacts.Detail.ping)
    #expect(success.detail.contains(L10n.Contacts.Contacts.Detail.pingSNR("10.5", "8.0")))
    #expect(success.detail.contains("120"))
    let failed = CarPlayNodesSource.pingRow(.error(L10n.Contacts.Contacts.Detail.pingNoResponse))
    #expect(failed.detail == L10n.Contacts.Contacts.Detail.pingNoResponse)
  }

  @Test
  func `A path hop is named for the one repeater whose key it starts`() {
    let repeaters = [(keyHex: "A3FF", name: "Hilltop"), (keyHex: "7F01", name: "Ridge"), (keyHex: "7F02", name: "Peak")]
    #expect(CarPlayNodesSource.name(ofHop: "A3", repeaters: repeaters) == "Hilltop")
    #expect(CarPlayNodesSource.name(ofHop: "7F", repeaters: repeaters) == "7F")
    #expect(CarPlayNodesSource.name(ofHop: "12", repeaters: repeaters) == "12")
    #expect(CarPlayNodesSource.knownName(ofHop: "7F", repeaters: repeaters) == nil)
  }

  @Test
  func `Distance includes a compass point`() {
    let north = CarPlayNodesSource.Node(
      publicKey: Data([1]), name: "N", type: .chat, lastHeard: now,
      latitude: 1, longitude: 0, route: "", isFavorite: false
    )
    let distance = CarPlayNodesSource.distanceAndBearing(north, origin: CLLocation(latitude: 0, longitude: 0))
    #expect(distance?.hasSuffix(L10n.Localizable.Home.Compass.n) == true)
  }
}
