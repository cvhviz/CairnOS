import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// Remove Nodes forgets the removed nodes' heard records (`deleteDiscoveredNodes`), so they leave
/// the maps and the Heard list rather than turning from saved into heard.
@Suite("Forgetting heard records")
struct DiscoveredNodeForgetTests {
  private func frame(_ byte: UInt8, name: String) -> ContactFrame {
    ContactFrame(
      publicKey: Data(repeating: byte, count: 32),
      type: .chat,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      name: name,
      lastAdvertTimestamp: 1,
      latitude: 1,
      longitude: 1,
      lastModified: 0
    )
  }

  @Test
  func `Only the named nodes on the named radio are forgotten`() async throws {
    let store = PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
    let radio = UUID()
    let otherRadio = UUID()
    for (byte, name) in [(UInt8(0x01), "A"), (0x02, "B"), (0x03, "C")] {
      _ = try await store.upsertDiscoveredNode(radioID: radio, from: frame(byte, name: name))
    }
    _ = try await store.upsertDiscoveredNode(radioID: otherRadio, from: frame(0x01, name: "A elsewhere"))

    let deleted = try await store.deleteDiscoveredNodes(
      radioID: radio,
      publicKeys: [Data(repeating: 0x01, count: 32), Data(repeating: 0x03, count: 32), Data(repeating: 0x09, count: 32)]
    )

    #expect(deleted == 2)
    #expect(try await store.fetchDiscoveredNodes(radioID: radio).map(\.name) == ["B"])
    #expect(try await store.fetchDiscoveredNodes(radioID: otherRadio).count == 1)
  }

  @Test
  func `No keys forgets nothing`() async throws {
    let store = PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
    let radio = UUID()
    _ = try await store.upsertDiscoveredNode(radioID: radio, from: frame(0x01, name: "A"))

    #expect(try await store.deleteDiscoveredNodes(radioID: radio, publicKeys: []) == 0)
    #expect(try await store.fetchDiscoveredNodes(radioID: radio).count == 1)
  }
}
