import Foundation
@testable import Cairn
@testable import CairnServices
import SwiftUI
import Testing

/// Locks the Saved list's Favorites group: the favorites among the nodes shown come out into the
/// group in the list's order and aren't listed again below it, the segment, search and group
/// filters narrow the group as they do the rest, an empty group isn't shown, the favorites-only
/// filter leaves the list flat, and the folded state outlives a relaunch.
@Suite("Nodes list Favorites group")
@MainActor
struct NodeFavoritesGroupingTests {
  private static let radioID = UUID()

  private func makeContact(
    id: UUID = UUID(),
    publicKey: Data? = nil,
    name: String,
    type: ContactType = .chat,
    isFavorite: Bool = false,
    lastModified: UInt32 = 0
  ) -> ContactDTO {
    ContactDTO(
      id: id,
      radioID: Self.radioID,
      publicKey: publicKey ?? Data((0..<ProtocolLimits.publicKeySize).map { _ in UInt8.random(in: 0...255) }),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: lastModified,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: isFavorite,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func filtered(
    _ viewModel: ContactsViewModel,
    searchText: String = "",
    segment: NodeSegment = .all,
    favoritesOnly: Bool = false
  ) -> [ContactDTO] {
    viewModel.filteredContacts(
      searchText: searchText,
      segment: segment,
      favoritesOnly: favoritesOnly,
      sortOrder: .name,
      userLocation: nil
    )
  }

  // MARK: - Splitting

  @Test
  func `favorites come out into the group in list order and are not listed again`() {
    let alpha = makeContact(name: "Alpha")
    let bravo = makeContact(name: "Bravo", isFavorite: true)
    let charlie = makeContact(name: "Charlie")
    let delta = makeContact(name: "Delta", isFavorite: true)

    let grouping = NodeFavoritesGrouping([alpha, bravo, charlie, delta], favoritesOnly: false)

    #expect(grouping.showsFavoritesGroup)
    #expect(grouping.favorites.map(\.name) == ["Bravo", "Delta"])
    #expect(grouping.others.map(\.name) == ["Alpha", "Charlie"])
    #expect(grouping.favorites.map(\.id) == [bravo.id, delta.id])
    let ids = (grouping.favorites + grouping.others).map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.count == 4)
  }

  @Test
  func `no favorites shows no group and lists every node`() {
    let nodes = [makeContact(name: "Alpha"), makeContact(name: "Bravo")]

    let grouping = NodeFavoritesGrouping(nodes, favoritesOnly: false)

    #expect(!grouping.showsFavoritesGroup)
    #expect(grouping.favorites.isEmpty)
    #expect(grouping.others == nodes)
  }

  @Test
  func `an empty result shows no group`() {
    let grouping = NodeFavoritesGrouping([], favoritesOnly: false)

    #expect(!grouping.showsFavoritesGroup)
    #expect(grouping.others.isEmpty)
  }

  @Test
  func `a list of favorites alone still gets its group when favorites only is off`() {
    let nodes = [makeContact(name: "Alpha", isFavorite: true), makeContact(name: "Bravo", isFavorite: true)]

    let grouping = NodeFavoritesGrouping(nodes, favoritesOnly: false)

    #expect(grouping.favorites == nodes)
    #expect(grouping.others.isEmpty)
  }

  // MARK: - Favorites Only

  /// With the filter in effect every node listed is a favorite: a group would only add a header.
  @Test
  func `favorites only leaves the list flat`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Alpha", isFavorite: true),
      makeContact(name: "Bravo"),
      makeContact(name: "Charlie", isFavorite: true),
    ]

    let grouping = NodeFavoritesGrouping(filtered(viewModel, favoritesOnly: true), favoritesOnly: true)

    #expect(!grouping.showsFavoritesGroup)
    #expect(grouping.others.map(\.name) == ["Alpha", "Charlie"])
  }

  /// Search sets favorites-only aside, so its mixed results get the group again.
  @Test
  func `favorites only with a search that lists other nodes keeps the group`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Ridge Alpha", isFavorite: true),
      makeContact(name: "Ridge Bravo"),
      makeContact(name: "Valley", isFavorite: true),
    ]

    let grouping = NodeFavoritesGrouping(
      filtered(viewModel, searchText: "Ridge", favoritesOnly: true),
      favoritesOnly: true
    )

    #expect(grouping.favorites.map(\.name) == ["Ridge Alpha"])
    #expect(grouping.others.map(\.name) == ["Ridge Bravo"])
  }

  // MARK: - Filters

  @Test
  func `search narrows the group and an unmatched favorite drops out of it`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Ridge Alpha", isFavorite: true),
      makeContact(name: "Ridge Bravo"),
      makeContact(name: "Valley", isFavorite: true),
    ]

    let grouping = NodeFavoritesGrouping(filtered(viewModel, searchText: "Ridge"), favoritesOnly: false)

    #expect(grouping.favorites.map(\.name) == ["Ridge Alpha"])
    #expect(grouping.others.map(\.name) == ["Ridge Bravo"])
  }

  @Test
  func `a search matching no favorite hides the group`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Ridge", isFavorite: true),
      makeContact(name: "Valley"),
    ]

    let grouping = NodeFavoritesGrouping(filtered(viewModel, searchText: "Valley"), favoritesOnly: false)

    #expect(!grouping.showsFavoritesGroup)
    #expect(grouping.others.map(\.name) == ["Valley"])
  }

  @Test
  func `the segment narrows the group`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Alpha", type: .chat, isFavorite: true),
      makeContact(name: "Relay1", type: .repeater, isFavorite: true),
      makeContact(name: "Relay2", type: .repeater),
    ]

    let repeaters = NodeFavoritesGrouping(filtered(viewModel, segment: .repeaters), favoritesOnly: false)
    #expect(repeaters.favorites.map(\.name) == ["Relay1"])
    #expect(repeaters.others.map(\.name) == ["Relay2"])

    let rooms = NodeFavoritesGrouping(filtered(viewModel, segment: .rooms), favoritesOnly: false)
    #expect(!rooms.showsFavoritesGroup)
    #expect(rooms.others.isEmpty)
  }

  @Test
  func `the group keeps the list's sort order`() {
    let viewModel = ContactsViewModel()
    viewModel.contacts = [
      makeContact(name: "Alpha", isFavorite: true, lastModified: 100),
      makeContact(name: "Bravo", isFavorite: true, lastModified: 300),
      makeContact(name: "Charlie", lastModified: 200),
    ]

    let byRecency = viewModel.filteredContacts(
      searchText: "", segment: .all, favoritesOnly: false, sortOrder: .lastHeard, userLocation: nil
    )
    let grouping = NodeFavoritesGrouping(byRecency, favoritesOnly: false)

    #expect(grouping.favorites.map(\.name) == ["Bravo", "Alpha"])
    #expect(grouping.others.map(\.name) == ["Charlie"])
  }

  // MARK: - Live Favorite Changes

  @Test
  func `favoriting a node moves it from the list into the group`() {
    let viewModel = ContactsViewModel()
    let bravo = makeContact(name: "Bravo")
    viewModel.contacts = [makeContact(name: "Alpha", isFavorite: true), bravo]

    let before = NodeFavoritesGrouping(filtered(viewModel), favoritesOnly: false)
    #expect(before.favorites.map(\.name) == ["Alpha"])
    #expect(before.others.map(\.name) == ["Bravo"])

    viewModel.upsert(makeContact(id: bravo.id, publicKey: bravo.publicKey, name: "Bravo", isFavorite: true))

    let after = NodeFavoritesGrouping(filtered(viewModel), favoritesOnly: false)
    #expect(after.favorites.map(\.name) == ["Alpha", "Bravo"])
    #expect(after.others.isEmpty)
    #expect(
      NodeFavoritesGrouping.favoriteMembership(viewModel.contacts) == [after.favorites[0].id, bravo.id]
    )
  }

  // MARK: - Animation Key

  /// The list animates when the membership changes, so it must hold still through a search,
  /// segment or sort change that only reshuffles which favorites are shown.
  @Test
  func `favorite membership ignores search, segment and sort and follows a favorite toggle`() {
    let viewModel = ContactsViewModel()
    let alpha = makeContact(name: "Ridge Alpha", type: .chat, isFavorite: true)
    let relay = makeContact(name: "Relay", type: .repeater, isFavorite: true)
    let bravo = makeContact(name: "Ridge Bravo")
    viewModel.contacts = [alpha, relay, bravo]
    let membership = NodeFavoritesGrouping.favoriteMembership(viewModel.contacts)
    #expect(membership == [alpha.id, relay.id])

    // What the view shows changes; the animation key doesn't.
    let searched = NodeFavoritesGrouping(filtered(viewModel, searchText: "Ridge"), favoritesOnly: false)
    let repeaters = NodeFavoritesGrouping(filtered(viewModel, segment: .repeaters), favoritesOnly: false)
    #expect(searched.favorites.map(\.id) != repeaters.favorites.map(\.id))
    #expect(NodeFavoritesGrouping.favoriteMembership(viewModel.contacts) == membership)

    viewModel.upsert(makeContact(id: bravo.id, publicKey: bravo.publicKey, name: "Ridge Bravo", isFavorite: true))
    #expect(NodeFavoritesGrouping.favoriteMembership(viewModel.contacts) == [alpha.id, relay.id, bravo.id])
  }

  // MARK: - Folded State

  @Test
  func `the folded state is stored under the grouping's key and outlives a relaunch`() throws {
    let suite = "NodeFavoritesGrouping-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // `ContactsListContent` declares its `@AppStorage` with this key.
    #expect(NodeFavoritesGrouping.collapsedKey == .nodesFavoritesCollapsed)
    let key = NodeFavoritesGrouping.collapsedKey.rawValue
    #expect(key == "nodesFavoritesCollapsed")

    let firstLaunch = AppStorage(wrappedValue: false, key, store: defaults)
    #expect(firstLaunch.wrappedValue == false)
    firstLaunch.wrappedValue = true

    let relaunch = AppStorage(wrappedValue: false, key, store: defaults)
    #expect(relaunch.wrappedValue == true)
    #expect(defaults.bool(forKey: key))
  }
}
