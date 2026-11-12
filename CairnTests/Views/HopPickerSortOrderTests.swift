import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("HopPickerSortOrder")
struct HopPickerSortOrderTests {
  private func contact(_ name: String, heard: UInt32) -> PickerNode {
    .contact(ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: UInt8(truncatingIfNeeded: name.hashValue), count: 32),
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: heard,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    ))
  }

  private func discovered(_ name: String, heard: TimeInterval) -> PickerNode {
    .discovered(DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: UInt8(truncatingIfNeeded: name.hashValue), count: 32),
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: Date(timeIntervalSince1970: heard),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    ))
  }

  private func names(_ nodes: [PickerNode]) -> [String] {
    nodes.map(\.sortName)
  }

  @Test
  func `name sorts alphabetically ignoring case`() {
    let nodes = [contact("ridge", heard: 300), contact("Alpha", heard: 100), contact("Summit", heard: 200)]
    #expect(names(HopPickerSortOrder.name.sorted(nodes)) == ["Alpha", "ridge", "Summit"])
  }

  @Test
  func `last heard puts the most recent first`() {
    let nodes = [contact("Alpha", heard: 100), contact("Ridge", heard: 300), contact("Summit", heard: 200)]
    #expect(names(HopPickerSortOrder.lastHeard.sorted(nodes)) == ["Ridge", "Summit", "Alpha"])
  }

  @Test
  func `last heard breaks ties by name so never-heard nodes stay alphabetical`() {
    let nodes = [contact("Zulu", heard: 0), contact("Bravo", heard: 0), contact("Heard", heard: 50)]
    #expect(names(HopPickerSortOrder.lastHeard.sorted(nodes)) == ["Heard", "Bravo", "Zulu"])
  }

  @Test
  func `last heard compares contacts and discovered nodes on one timeline`() {
    let nodes = [contact("Contact", heard: 100), discovered("Discovered", heard: 900)]
    #expect(names(HopPickerSortOrder.lastHeard.sorted(nodes)) == ["Discovered", "Contact"])
  }
}
