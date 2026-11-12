import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Contact detail name and route summary")
struct ContactDetailNameAndRouteTests {
  // MARK: - Rename

  @Test
  func `a new name is saved trimmed`() {
    #expect(ContactNameEdit.nicknameToSave(text: "  Hilltop  ", advertisedName: "RPT-01") == "Hilltop")
  }

  @Test
  func `typing the advertised name back clears the nickname`() {
    #expect(ContactNameEdit.nicknameToSave(text: "RPT-01", advertisedName: "RPT-01").isEmpty)
    #expect(ContactNameEdit.nicknameToSave(text: " RPT-01 ", advertisedName: "RPT-01").isEmpty)
  }

  @Test
  func `a blank field clears the nickname`() {
    #expect(ContactNameEdit.nicknameToSave(text: "   ", advertisedName: "RPT-01").isEmpty)
  }

  // MARK: - Route summary

  private static func contact(outPathLength: UInt8, outPath: Data = Data()) -> ContactDTO {
    ContactDTO(from: Contact(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Alice",
      outPathLength: outPathLength,
      outPath: outPath,
      lastHeardTimestamp: 0
    ))
  }

  private static func summary(for contact: ContactDTO, names: [Data: String] = [:]) -> String {
    ContactRouteSummary.text(
      isFloodRouted: contact.isFloodRouted,
      pathHopCount: contact.pathHopCount,
      hopNames: ContactRouteSummary.hopNames(for: contact) { names[$0] }
    )
  }

  @Test
  func `flood routed reads Flood`() {
    let contact = Self.contact(outPathLength: PacketBuilder.floodPathSentinel)
    #expect(Self.summary(for: contact) == L10n.Contacts.Contacts.Route.flood)
  }

  @Test
  func `zero hops reads Direct`() {
    let contact = Self.contact(outPathLength: 0)
    #expect(Self.summary(for: contact) == L10n.Contacts.Contacts.Route.direct)
  }

  @Test
  func `hops read their count and names, falling back to hex`() {
    let contact = Self.contact(outPathLength: 2, outPath: Data([0xA3, 0x7F]))
    let names = ContactRouteSummary.hopNames(for: contact) { $0 == Data([0xA3]) ? "Hilltop" : nil }
    #expect(names == ["Hilltop", "7F"])
    #expect(Self.summary(for: contact, names: [Data([0xA3]): "Hilltop"]) == L10n.Contacts.Contacts.Route.via(
      NodeRouteFormat.hopCount(2),
      "Hilltop \u{2192} 7F"
    ))
  }
}
