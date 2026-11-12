import CoreLocation
import Foundation
import MapKit
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("MapViewModel Hidden Nodes")
@MainActor
struct MapViewModelHiddenNodesTests {
  private static let nearLatitude = 37.0
  private static let farLatitude = 45.0
  private static let longitude = -122.0
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)

  private static let aliceKey = Data(repeating: 0xA1, count: 32)
  private static let bobKey = Data(repeating: 0xB2, count: 32)
  private static let hilltopKey = Data(repeating: 0xC3, count: 32)

  private static func makeContact(
    radioID: UUID = UUID(),
    publicKey: Data = aliceKey,
    name: String = "Alice",
    latitude: Double = nearLatitude,
    type: ContactType = .chat,
    isFavorite: Bool = false
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: publicKey,
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: isFavorite,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  private static func makeDiscovered(
    publicKey: Data = hilltopKey,
    name: String = "Hilltop",
    latitude: Double = nearLatitude,
    type: ContactType = .repeater,
    lastHeard: Date = now
  ) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: publicKey,
      name: name,
      typeRawValue: type.rawValue,
      lastHeard: lastHeard,
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  private static func makeDiscoveredFrame(
    publicKey: Data = hilltopKey,
    name: String = "Hilltop",
    latitude: Double = nearLatitude,
    type: ContactType = .repeater
  ) -> ContactFrame {
    ContactFrame(
      publicKey: publicKey,
      type: type,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      name: name,
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0
    )
  }

  private static func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  private static func makeViewModel(dataStore: PersistenceStore, radioID: UUID) -> MapViewModel {
    let viewModel = MapViewModel()
    viewModel.configure(dataStore: { dataStore }, radioID: { radioID })
    return viewModel
  }

  // MARK: - Pin decision

  @Test
  func `a hidden contact is left out and the rest keep their order`() {
    let alice = Self.makeContact()
    let bob = Self.makeContact(publicKey: Self.bobKey, name: "Bob")
    let carol = Self.makeContact(publicKey: Self.hilltopKey, name: "Carol")

    let visible = MapViewModel.visibleContactPins(
      located: [alice, bob, carol],
      filter: MapFilterState(),
      hiddenKeys: [Self.bobKey]
    )

    #expect(visible.map(\.id) == [alice.id, carol.id])
  }

  @Test
  func `nothing hidden leaves the filter's pins unchanged`() {
    let chat = Self.makeContact()
    let repeater = Self.makeContact(publicKey: Self.bobKey, name: "Relay", type: .repeater)

    let visible = MapViewModel.visibleContactPins(
      located: [chat, repeater],
      filter: MapFilterState(showChat: false, showRepeater: true, showRoom: true),
      hiddenKeys: []
    )

    #expect(visible.map(\.id) == [repeater.id])
  }

  @Test
  func `a hidden favorite stays hidden under Favorites`() {
    let alice = Self.makeContact(isFavorite: true)
    let bob = Self.makeContact(publicKey: Self.bobKey, name: "Bob", isFavorite: true)
    var filter = MapFilterState()
    filter.setFavoritesOnly(true)

    let visible = MapViewModel.visibleContactPins(
      located: [alice, bob],
      filter: filter,
      hiddenKeys: [Self.aliceKey]
    )

    #expect(visible.map(\.id) == [bob.id])
  }

  @Test
  func `a hidden discovered node is left out`() {
    let hilltop = Self.makeDiscovered()
    let valley = Self.makeDiscovered(publicKey: Self.bobKey, name: "Valley")

    let visible = MapViewModel.visibleDiscoveredPins(
      located: [hilltop, valley],
      filter: MapFilterState(showDiscovered: true),
      hiddenKeys: [Self.hilltopKey],
      now: Self.now
    )

    #expect(visible.map(\.id) == [valley.id])
  }

  @Test
  func `discovered pins still follow the layer, type and recency filters`() {
    let recent = Self.makeDiscovered()
    let stale = Self.makeDiscovered(
      publicKey: Self.bobKey,
      name: "Stale",
      lastHeard: Self.now.addingTimeInterval(-10 * 86400)
    )
    let chat = Self.makeDiscovered(publicKey: Self.aliceKey, name: "Walker", type: .chat)

    let layerOff = MapViewModel.visibleDiscoveredPins(
      located: [recent, stale, chat],
      filter: MapFilterState(showDiscovered: false),
      hiddenKeys: [],
      now: Self.now
    )
    let weekOfRepeaters = MapViewModel.visibleDiscoveredPins(
      located: [recent, stale, chat],
      filter: MapFilterState(showDiscovered: true, showChat: false, heardWithin: .week),
      hiddenKeys: [],
      now: Self.now
    )

    #expect(layerOff.isEmpty)
    #expect(weekOfRepeaters.map(\.id) == [recent.id])
  }

  // MARK: - Hidden list

  @Test
  func `hidden list names contacts and discovered nodes in name order`() {
    let zoe = Self.makeContact(name: "Zoe")
    let hilltop = Self.makeDiscovered()
    let shown = Self.makeContact(publicKey: Self.bobKey, name: "Bob")

    let hidden = MapViewModel.resolvedHiddenNodes(
      contacts: [zoe, shown],
      discovered: [hilltop],
      hiddenKeys: [Self.aliceKey, Self.hilltopKey]
    )

    #expect(hidden == [
      HiddenMapNode(publicKey: Self.hilltopKey, name: "Hilltop", type: .repeater, isDiscovered: true),
      HiddenMapNode(publicKey: Self.aliceKey, name: "Zoe", type: .chat, isDiscovered: false)
    ])
  }

  @Test
  func `hidden list shows a key once, as the contact`() {
    let contact = Self.makeContact(publicKey: Self.hilltopKey, name: "Hilltop Relay", type: .repeater)
    let discovered = Self.makeDiscovered()

    let hidden = MapViewModel.resolvedHiddenNodes(
      contacts: [contact],
      discovered: [discovered],
      hiddenKeys: [Self.hilltopKey]
    )

    #expect(hidden.map(\.name) == ["Hilltop Relay"])
    #expect(hidden.first?.isDiscovered == false)
  }

  @Test
  func `hidden list is empty when nothing is hidden or no record matches`() {
    let alice = Self.makeContact()

    #expect(MapViewModel.resolvedHiddenNodes(contacts: [alice], discovered: [], hiddenKeys: []).isEmpty)
    #expect(MapViewModel.resolvedHiddenNodes(
      contacts: [alice],
      discovered: [],
      hiddenKeys: [Self.bobKey]
    ).isEmpty)
  }

  // MARK: - View model

  @Test
  func `hiding removes the pin, its lookup and its cluster membership`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let alice = Self.makeContact(radioID: radioID)
    let bob = Self.makeContact(radioID: radioID, publicKey: Self.bobKey, name: "Bob")
    try await dataStore.saveContact(alice)
    try await dataStore.saveContact(bob)
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    await viewModel.loadMapData(filter: MapFilterState())
    #expect(Set(viewModel.mapPoints.map(\.id)) == [alice.id, bob.id])

    viewModel.setHiddenKeys([Self.aliceKey])

    #expect(viewModel.mapPoints.map(\.id) == [bob.id])
    #expect(viewModel.contact(forPointID: alice.id) == nil)
    let clusterable = MapPointClustering.partition(viewModel.mapPoints, clusteringEnabled: true).clusterable
    #expect(clusterable.map(\.id) == [bob.id])
    #expect(viewModel.hiddenNodes.map(\.publicKey) == [Self.aliceKey])
  }

  @Test
  func `the connected radio's own key never gets a node pin, since the map pins the radio itself`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let alice = Self.makeContact(radioID: radioID)
    try await dataStore.saveContact(alice)
    try await dataStore.saveContact(Self.makeContact(radioID: radioID, publicKey: Self.bobKey, name: "Me"))
    _ = try await dataStore.upsertDiscoveredNode(radioID: radioID, from: Self.makeDiscoveredFrame(publicKey: Self.bobKey))
    let viewModel = MapViewModel()
    viewModel.configure(dataStore: { dataStore }, radioID: { radioID }, selfPublicKey: { Self.bobKey })

    await viewModel.loadMapData(filter: MapFilterState(showDiscovered: true))

    #expect(viewModel.mapPoints.map(\.id) == [alice.id])
    #expect(viewModel.pointID(forPublicKey: Self.bobKey) == nil)
  }

  @Test
  func `hiding a discovered node removes its pin`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let hilltop = try await dataStore.upsertDiscoveredNode(
      radioID: radioID,
      from: Self.makeDiscoveredFrame()
    ).node
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    await viewModel.loadMapData(filter: MapFilterState(showDiscovered: true))
    #expect(viewModel.mapPoints.map(\.id) == [hilltop.id])

    viewModel.setHiddenKeys([Self.hilltopKey])

    #expect(viewModel.mapPoints.isEmpty)
    #expect(viewModel.discovered(forPointID: hilltop.id) == nil)
    #expect(viewModel.hiddenNodes == [
      HiddenMapNode(publicKey: Self.hilltopKey, name: "Hilltop", type: .repeater, isDiscovered: true)
    ])
  }

  @Test
  func `center all frames only the nodes still shown`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    try await dataStore.saveContact(Self.makeContact(radioID: radioID))
    try await dataStore.saveContact(Self.makeContact(
      radioID: radioID,
      publicKey: Self.bobKey,
      name: "Far",
      latitude: Self.farLatitude
    ))
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    await viewModel.loadMapData(filter: MapFilterState())

    viewModel.setHiddenKeys([Self.bobKey])
    viewModel.centerOnAllContacts()

    let region = try #require(viewModel.cameraRegion)
    #expect(region.center.latitude == Self.nearLatitude)
    #expect(region.center.latitude + region.span.latitudeDelta / 2 < Self.farLatitude)
  }

  @Test
  func `center all is unavailable when every node is hidden`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    try await dataStore.saveContact(Self.makeContact(radioID: radioID))
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    await viewModel.loadMapData(filter: MapFilterState())
    #expect(viewModel.hasPinsForCenterAll)

    viewModel.setHiddenKeys([Self.aliceKey])

    #expect(!viewModel.hasPinsForCenterAll)
    viewModel.centerOnAllContacts()
    #expect(viewModel.cameraRegion == nil)
  }

  @Test
  func `showing a node again restores its pin without a reload`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let alice = Self.makeContact(radioID: radioID)
    try await dataStore.saveContact(alice)
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    await viewModel.loadMapData(filter: MapFilterState())
    viewModel.setHiddenKeys([Self.aliceKey])
    let generation = viewModel.loadGenerationForTesting

    viewModel.setHiddenKeys([])

    #expect(viewModel.mapPoints.map(\.id) == [alice.id])
    #expect(viewModel.hiddenNodes.isEmpty)
    #expect(viewModel.loadGenerationForTesting == generation)
  }

  @Test
  func `hidden nodes set before the first load stay hidden through reloads`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let alice = Self.makeContact(radioID: radioID)
    let bob = Self.makeContact(radioID: radioID, publicKey: Self.bobKey, name: "Bob")
    try await dataStore.saveContact(alice)
    try await dataStore.saveContact(bob)
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    viewModel.setHiddenKeys([Self.aliceKey])

    await viewModel.loadMapData(filter: MapFilterState())
    #expect(viewModel.mapPoints.map(\.id) == [bob.id])

    viewModel.applyFilter(MapFilterState(showChat: true, showRepeater: false, showRoom: false))
    await viewModel.loadMapData(filter: MapFilterState())

    #expect(viewModel.mapPoints.map(\.id) == [bob.id])
    #expect(viewModel.hiddenNodes.map(\.name) == ["Alice"])
  }

  @Test
  func `a hidden discovered node stays hidden once it is added as a contact`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    _ = try await dataStore.upsertDiscoveredNode(radioID: radioID, from: Self.makeDiscoveredFrame())
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    viewModel.setHiddenKeys([Self.hilltopKey])
    await viewModel.loadMapData(filter: MapFilterState(showDiscovered: true))
    #expect(viewModel.hiddenNodes.first?.isDiscovered == true)

    try await dataStore.saveContact(Self.makeContact(
      radioID: radioID,
      publicKey: Self.hilltopKey,
      name: "Hilltop",
      type: .repeater
    ))
    await viewModel.loadMapData(filter: MapFilterState(showDiscovered: true))

    #expect(viewModel.mapPoints.isEmpty)
    #expect(viewModel.hiddenNodes == [
      HiddenMapNode(publicKey: Self.hilltopKey, name: "Hilltop", type: .repeater, isDiscovered: false)
    ])
  }

  @Test
  func `a hidden node is listed while the filter would not show it`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    _ = try await dataStore.upsertDiscoveredNode(radioID: radioID, from: Self.makeDiscoveredFrame())
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    viewModel.setHiddenKeys([Self.hilltopKey])

    await viewModel.loadMapData(filter: MapFilterState(showDiscovered: false))

    #expect(viewModel.hiddenNodes.map(\.publicKey) == [Self.hilltopKey])
  }

  @Test
  func `losing the radio empties the hidden list but keeps the hidden keys`() async throws {
    let radioID = UUID()
    let dataStore = try Self.makeStore()
    let alice = Self.makeContact(radioID: radioID)
    try await dataStore.saveContact(alice)
    let viewModel = Self.makeViewModel(dataStore: dataStore, radioID: radioID)
    viewModel.setHiddenKeys([Self.aliceKey])
    await viewModel.loadMapData(filter: MapFilterState())
    #expect(viewModel.hiddenNodes.count == 1)

    viewModel.configure(dataStore: { dataStore }, radioID: { nil })
    await viewModel.loadMapData(filter: MapFilterState())
    #expect(viewModel.hiddenNodes.isEmpty)

    viewModel.configure(dataStore: { dataStore }, radioID: { radioID })
    await viewModel.loadMapData(filter: MapFilterState())
    #expect(viewModel.mapPoints.isEmpty)
    #expect(viewModel.hiddenNodes.map(\.publicKey) == [Self.aliceKey])
  }
}
