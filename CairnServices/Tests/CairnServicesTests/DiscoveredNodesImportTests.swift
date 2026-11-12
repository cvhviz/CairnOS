import Foundation
@testable import CairnServices
import MeshCore
import Testing

private func key(_ byte: UInt8) -> Data {
  Data(repeating: byte, count: 32)
}

private func node(
  _ keyByte: UInt8,
  name: String = "Node",
  type: ContactType = .repeater,
  latitude: Double? = 45.4215,
  longitude: Double? = -75.6972,
  advert: UInt32 = 1_700_000_000,
  heard: TimeInterval = 1_700_000_500
) -> DiscoveredNodesFile.Node {
  DiscoveredNodesFile.Node(
    publicKey: key(keyByte),
    name: name,
    type: type,
    latitude: latitude,
    longitude: longitude,
    lastAdvertTimestamp: advert,
    lastHeard: Date(timeIntervalSince1970: heard)
  )
}

@Suite("DiscoveredNodesImportPlan")
struct DiscoveredNodesImportPlanTests {
  @Test
  func `nodes that are not in the list are new`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1), node(0xB2)],
      existingAdvertTimestamps: [:],
      contactKeys: [],
      selfPublicKey: nil
    )

    #expect(Set(plan.inserts.map(\.publicKey)) == [key(0xA1), key(0xB2)])
    #expect(plan.updates.isEmpty)
    #expect(plan.summary.fileNodeCount == 2)
    #expect(plan.summary.newCount == 2)
    #expect(plan.summary.changesAnything)
  }

  @Test
  func `a node on the contact list is skipped`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1), node(0xB2)],
      existingAdvertTimestamps: [:],
      contactKeys: [key(0xA1)],
      selfPublicKey: nil
    )

    #expect(plan.inserts.map(\.publicKey) == [key(0xB2)])
    #expect(plan.summary.alreadyKnownCount == 1)
    #expect(plan.summary.newCount == 1)
  }

  @Test
  func `a contact is skipped even when the list has an older record of it`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1, advert: 500)],
      existingAdvertTimestamps: [key(0xA1): 100],
      contactKeys: [key(0xA1)],
      selfPublicKey: nil
    )

    #expect(plan.inserts.isEmpty)
    #expect(plan.updates.isEmpty)
    #expect(plan.summary.alreadyKnownCount == 1)
    #expect(!plan.summary.changesAnything)
  }

  @Test
  func `the radio itself is skipped`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1), node(0xB2)],
      existingAdvertTimestamps: [:],
      contactKeys: [],
      selfPublicKey: key(0xB2)
    )

    #expect(plan.inserts.map(\.publicKey) == [key(0xA1)])
    #expect(plan.summary.alreadyKnownCount == 1)
  }

  @Test
  func `a newer advert in the file updates the list`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1, advert: 200)],
      existingAdvertTimestamps: [key(0xA1): 100],
      contactKeys: [],
      selfPublicKey: nil
    )

    #expect(plan.updates.map(\.publicKey) == [key(0xA1)])
    #expect(plan.inserts.isEmpty)
    #expect(plan.summary.updatedCount == 1)
    #expect(plan.summary.unchangedCount == 0)
  }

  @Test(arguments: [UInt32(100), 200])
  func `an advert in the file that is older or the same leaves the list alone`(fileAdvert: UInt32) {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1, advert: fileAdvert)],
      existingAdvertTimestamps: [key(0xA1): 200],
      contactKeys: [],
      selfPublicKey: nil
    )

    #expect(plan.updates.isEmpty)
    #expect(plan.inserts.isEmpty)
    #expect(plan.summary.unchangedCount == 1)
    #expect(!plan.summary.changesAnything)
  }

  @Test
  func `new nodes fill only the room the list has left`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [
        node(0xA1, heard: 100),
        node(0xB2, heard: 400),
        node(0xC3, heard: 300),
        node(0xD4, heard: 200)
      ],
      existingAdvertTimestamps: [key(0x01): 1, key(0x02): 1, key(0x03): 1],
      contactKeys: [],
      selfPublicKey: nil,
      capacity: 5
    )

    #expect(plan.inserts.map(\.publicKey) == [key(0xB2), key(0xC3)])
    #expect(plan.summary.newCount == 2)
    #expect(plan.summary.overCapacityCount == 2)
  }

  @Test
  func `a full list takes no new nodes but still takes updates`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1), node(0x01, advert: 50)],
      existingAdvertTimestamps: [key(0x01): 1, key(0x02): 1],
      contactKeys: [],
      selfPublicKey: nil,
      capacity: 2
    )

    #expect(plan.inserts.isEmpty)
    #expect(plan.updates.map(\.publicKey) == [key(0x01)])
    #expect(plan.summary.overCapacityCount == 1)
    #expect(plan.summary.updatedCount == 1)
  }

  @Test
  func `a list already over its limit takes no new nodes`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xA1)],
      existingAdvertTimestamps: [key(0x01): 1, key(0x02): 1, key(0x03): 1],
      contactKeys: [],
      selfPublicKey: nil,
      capacity: 2
    )

    #expect(plan.inserts.isEmpty)
    #expect(plan.summary.overCapacityCount == 1)
  }

  @Test
  func `nodes heard at the same moment are taken in key order`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [node(0xC3), node(0xA1), node(0xB2)],
      existingAdvertTimestamps: [:],
      contactKeys: [],
      selfPublicKey: nil,
      capacity: 2
    )

    #expect(plan.inserts.map(\.publicKey) == [key(0xA1), key(0xB2)])
  }

  @Test
  func `the limit is the store's`() {
    let nodes = (0..<(PersistenceStore.maxDiscoveredNodes + 5)).map { index in
      DiscoveredNodesFile.Node(
        publicKey: Data([UInt8(index >> 8), UInt8(index & 0xFF)] + [UInt8](repeating: 0x7E, count: 30)),
        name: "Node \(index)",
        type: .repeater,
        latitude: nil,
        longitude: nil,
        lastAdvertTimestamp: 1,
        lastHeard: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let plan = DiscoveredNodesImportPlan.make(
      nodes: nodes,
      existingAdvertTimestamps: [:],
      contactKeys: [],
      selfPublicKey: nil
    )

    #expect(plan.inserts.count == PersistenceStore.maxDiscoveredNodes)
    #expect(plan.summary.overCapacityCount == 5)
    #expect(plan.inserts.first?.name == "Node \(PersistenceStore.maxDiscoveredNodes + 4)")
  }

  @Test
  func `an empty file changes nothing`() {
    let plan = DiscoveredNodesImportPlan.make(
      nodes: [],
      existingAdvertTimestamps: [key(0x01): 1],
      contactKeys: [],
      selfPublicKey: nil
    )

    #expect(plan.summary == DiscoveredNodesImportPlan.Summary())
    #expect(!plan.summary.changesAnything)
  }
}

@Suite("Discovered nodes import into the store")
struct DiscoveredNodesImportStoreTests {
  private let radioID = UUID()
  private let selfPublicKey = Data(repeating: 0x01, count: 32)

  private func makeStore() async throws -> PersistenceStore {
    try await PersistenceStore.createTestDataStore(radioID: radioID)
  }

  private func heardOverRadio(
    _ keyByte: UInt8,
    name: String,
    advert: UInt32,
    in store: PersistenceStore
  ) async throws {
    _ = try await store.upsertDiscoveredNode(
      radioID: radioID,
      from: ContactFrame(
        publicKey: key(keyByte),
        type: .repeater,
        flags: 0,
        outPathLength: 2,
        outPath: Data([0xAA, 0xBB]),
        name: name,
        lastAdvertTimestamp: advert,
        latitude: 10,
        longitude: 20,
        lastModified: advert
      )
    )
  }

  private func row(_ keyByte: UInt8, in store: PersistenceStore) async throws -> DiscoveredNodeDTO? {
    try await store.fetchDiscoveredNodes(radioID: radioID).first { $0.publicKey == key(keyByte) }
  }

  @Test
  func `imports new nodes into the given radio`() async throws {
    let store = try await makeStore()

    let summary = try await store.importDiscoveredNodes(
      [node(0xA1, name: "Alpha", type: .chat), node(0xB2, name: "Bravo", latitude: nil, longitude: nil)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.newCount == 2)
    let rows = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(Set(rows.map(\.name)) == ["Alpha", "Bravo"])
    #expect(rows.map(\.radioID) == [radioID, radioID])

    let alpha = try #require(try await row(0xA1, in: store))
    #expect(alpha.nodeType == .chat)
    #expect(alpha.latitude == 45.4215)
    #expect(alpha.longitude == -75.6972)
    #expect(alpha.lastAdvertTimestamp == 1_700_000_000)
    #expect(alpha.lastHeard == Date(timeIntervalSince1970: 1_700_000_500))
    #expect(alpha.isFloodRouted)
    #expect(alpha.outPath.isEmpty)
    #expect(alpha.inboundHopCount == nil)

    let bravo = try #require(try await row(0xB2, in: store))
    #expect(!bravo.hasLocation)
  }

  @Test
  func `importing the same file twice adds nothing the second time`() async throws {
    let store = try await makeStore()
    let nodes = [node(0xA1), node(0xB2)]

    try await store.importDiscoveredNodes(nodes, radioID: radioID, selfPublicKey: selfPublicKey)
    let second = try await store.importDiscoveredNodes(nodes, radioID: radioID, selfPublicKey: selfPublicKey)

    #expect(second.newCount == 0)
    #expect(second.unchangedCount == 2)
    let rows = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(rows.count == 2)
  }

  @Test
  func `skips nodes that are contacts on this radio`() async throws {
    let store = try await makeStore()
    try await store.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: key(0xA1), name: "Friend"))
    try await store.saveContact(ContactDTO.testContact(radioID: UUID(), publicKey: key(0xB2), name: "Elsewhere"))

    let summary = try await store.importDiscoveredNodes(
      [node(0xA1), node(0xB2)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.alreadyKnownCount == 1)
    #expect(summary.newCount == 1)
    let rows = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(rows.map(\.publicKey) == [key(0xB2)])
  }

  @Test
  func `skips the radio's own key`() async throws {
    let store = try await makeStore()

    let summary = try await store.importDiscoveredNodes(
      [DiscoveredNodesFile.Node(
        publicKey: selfPublicKey,
        name: "Me",
        type: .chat,
        latitude: nil,
        longitude: nil,
        lastAdvertTimestamp: 1,
        lastHeard: Date(timeIntervalSince1970: 1)
      )],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.alreadyKnownCount == 1)
    let rows = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(rows.isEmpty)
  }

  @Test
  func `a newer record replaces what was advertised and keeps what this radio learned`() async throws {
    let store = try await makeStore()
    try await heardOverRadio(0xA1, name: "Old name", advert: 1_000, in: store)
    try await store.setInboundHopCount(radioID: radioID, publicKey: key(0xA1), hopCount: 3, advertTimestamp: 1_000)
    let before = try #require(try await row(0xA1, in: store))

    let summary = try await store.importDiscoveredNodes(
      [node(0xA1, name: "New name", type: .room, latitude: 1.5, longitude: 2.5, advert: 2_000, heard: 100)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.updatedCount == 1)
    #expect(summary.newCount == 0)
    let after = try #require(try await row(0xA1, in: store))
    #expect(after.id == before.id)
    #expect(after.name == "New name")
    #expect(after.nodeType == .room)
    #expect(after.latitude == 1.5)
    #expect(after.longitude == 2.5)
    #expect(after.lastAdvertTimestamp == 2_000)
    #expect(after.lastHeard == before.lastHeard)
    #expect(after.outPathLength == 2)
    #expect(after.outPath == Data([0xAA, 0xBB]))
    #expect(after.inboundHopCount == 3)
    #expect(after.inboundHopAdvertTimestamp == 1_000)
  }

  @Test
  func `a newer record that was heard later moves last heard forward`() async throws {
    let store = try await makeStore()
    try await store.importDiscoveredNodes([node(0xA1, advert: 1_000, heard: 5_000)], radioID: radioID, selfPublicKey: nil)

    try await store.importDiscoveredNodes([node(0xA1, advert: 2_000, heard: 9_000)], radioID: radioID, selfPublicKey: nil)

    let after = try #require(try await row(0xA1, in: store))
    #expect(after.lastHeard == Date(timeIntervalSince1970: 9_000))
  }

  @Test
  func `a newer record without a location clears the old one`() async throws {
    let store = try await makeStore()
    try await heardOverRadio(0xA1, name: "Mobile", advert: 1_000, in: store)

    try await store.importDiscoveredNodes(
      [node(0xA1, latitude: nil, longitude: nil, advert: 2_000)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    let after = try #require(try await row(0xA1, in: store))
    #expect(!after.hasLocation)
  }

  @Test
  func `an older record leaves the list alone`() async throws {
    let store = try await makeStore()
    try await heardOverRadio(0xA1, name: "Current", advert: 2_000, in: store)
    let before = try #require(try await row(0xA1, in: store))

    let summary = try await store.importDiscoveredNodes(
      [node(0xA1, name: "Stale", advert: 1_000)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.unchangedCount == 1)
    #expect(!summary.changesAnything)
    let after = try await row(0xA1, in: store)
    #expect(after == before)
  }

  @Test
  func `another radio's list is neither read nor changed`() async throws {
    let store = try await makeStore()
    let otherRadioID = UUID()
    try await store.saveDevice(DeviceDTO.testDevice(id: otherRadioID, radioID: otherRadioID))
    try await store.importDiscoveredNodes([node(0xA1, name: "Theirs", advert: 5_000)], radioID: otherRadioID, selfPublicKey: nil)

    let summary = try await store.importDiscoveredNodes(
      [node(0xA1, name: "Mine", advert: 1_000)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.newCount == 1)
    let mine = try await store.fetchDiscoveredNodes(radioID: radioID)
    let theirs = try await store.fetchDiscoveredNodes(radioID: otherRadioID)
    #expect(mine.map(\.name) == ["Mine"])
    #expect(theirs.map(\.name) == ["Theirs"])
  }

  @Test
  func `the list never grows past its limit`() async throws {
    let store = try await makeStore()
    let cap = PersistenceStore.maxDiscoveredNodes
    func numbered(_ range: Range<Int>, prefix: UInt8) -> [DiscoveredNodesFile.Node] {
      range.map { index in
        DiscoveredNodesFile.Node(
          publicKey: Data([prefix, UInt8(index >> 8), UInt8(index & 0xFF)] + [UInt8](repeating: 0x7E, count: 29)),
          name: "Node \(index)",
          type: .repeater,
          latitude: nil,
          longitude: nil,
          lastAdvertTimestamp: 1,
          lastHeard: Date(timeIntervalSince1970: TimeInterval(index))
        )
      }
    }
    let local = numbered(0..<(cap - 3), prefix: 0x10)
    try await store.importDiscoveredNodes(local, radioID: radioID, selfPublicKey: selfPublicKey)

    let incoming = numbered(0..<10, prefix: 0x20)
    let preview = try await store.planDiscoveredNodesImport(incoming, radioID: radioID, selfPublicKey: selfPublicKey)
    let summary = try await store.importDiscoveredNodes(incoming, radioID: radioID, selfPublicKey: selfPublicKey)

    #expect(preview == summary)
    #expect(summary.newCount == 3)
    #expect(summary.overCapacityCount == 7)
    let rows = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(rows.count == cap)
    #expect(Set(local.map(\.publicKey)).isSubset(of: Set(rows.map(\.publicKey))))
    let imported = rows.filter { $0.publicKey.first == 0x20 }.map(\.name).sorted()
    #expect(imported == ["Node 7", "Node 8", "Node 9"])
  }

  @Test
  func `a preview writes nothing`() async throws {
    let store = try await makeStore()
    try await heardOverRadio(0xA1, name: "Current", advert: 1_000, in: store)
    let before = try await store.fetchDiscoveredNodes(radioID: radioID)

    let summary = try await store.planDiscoveredNodesImport(
      [node(0xA1, name: "Newer", advert: 2_000), node(0xB2)],
      radioID: radioID,
      selfPublicKey: selfPublicKey
    )

    #expect(summary.fileNodeCount == 2)
    #expect(summary.newCount == 1)
    #expect(summary.updatedCount == 1)
    let after = try await store.fetchDiscoveredNodes(radioID: radioID)
    #expect(after == before)
  }

  @Test
  func `an export from one radio imports into another`() async throws {
    let store = try await makeStore()
    try await heardOverRadio(0xA1, name: "Hilltop", advert: 1_000, in: store)
    try await heardOverRadio(0xB2, name: "Valley", advert: 2_000, in: store)
    let exported = try await DataExportService(store: store).discoveredNodesJSON(radioID: radioID)
    #expect(exported.count == 2)

    let otherRadioID = UUID()
    try await store.saveDevice(DeviceDTO.testDevice(id: otherRadioID, radioID: otherRadioID))
    let contents = try DiscoveredNodesFile.parse(exported.data)
    let summary = try await store.importDiscoveredNodes(contents.nodes, radioID: otherRadioID, selfPublicKey: nil)

    #expect(summary.newCount == 2)
    let imported = try await store.fetchDiscoveredNodes(radioID: otherRadioID)
    #expect(Set(imported.map(\.name)) == ["Hilltop", "Valley"])
    #expect(imported.map(\.latitude) == [10, 10])
    #expect(imported.map(\.longitude) == [20, 20])
    #expect(imported.map(\.isFloodRouted) == [true, true])
  }

  @Test
  func `an export of an empty list is a valid file with no nodes`() async throws {
    let store = try await makeStore()

    let exported = try await DataExportService(store: store).discoveredNodesJSON(radioID: radioID)

    #expect(exported.count == 0)
    #expect(try DiscoveredNodesFile.parse(exported.data).nodes.isEmpty)
  }
}
