@testable import CairnServices
import Testing

@Suite("CairnServices Basic Tests")
struct CairnServicesTests {
  @Test
  func `Version is accessible`() {
    #expect(CairnServicesVersion.version == "0.1.0")
  }

  @Test
  func `MeshCore types are re-exported`() {
    // Verify MeshCore types are accessible without explicit import
    let _: MeshEvent.Type = MeshEvent.self
    let _: PacketBuilder.Type = PacketBuilder.self
    let _: PacketParser.Type = PacketParser.self
  }
}
