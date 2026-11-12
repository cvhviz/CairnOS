import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("Message details region reading")
struct MessageRegionReadingTests {
  @Test
  func `Plain flood shows an explicit unscoped value`() {
    let message = Self.message(routeType: .flood)
    #expect(MessageRegionReading(message: message) == MessageRegionReading(value: L10n.Chats.Chats.Message.Info.Region.unscoped, caption: nil))
  }

  @Test
  func `Scoped flood with one matching region shows its name`() {
    let message = Self.message(routeType: .tcFlood, regionScope: "Germany", matches: ["Germany"])
    #expect(MessageRegionReading(message: message) == MessageRegionReading(value: "Germany", caption: nil))
  }

  @Test
  func `Scoped flood that matched no known region stays unresolved, not unscoped`() {
    let message = Self.message(routeType: .tcFlood)
    #expect(MessageRegionReading(message: message) == MessageRegionReading(value: L10n.Chats.Chats.Message.Info.Region.unknown, caption: nil))
  }

  @Test
  func `Scoped flood with several matching regions lists them as ambiguous`() {
    let message = Self.message(routeType: .tcFlood, matches: ["de-by", "de-hh"])
    let list = ListFormatter.localizedString(byJoining: ["de-by", "de-hh"])
    #expect(MessageRegionReading(message: message) == MessageRegionReading(value: list, caption: L10n.Chats.Chats.Message.Info.Region.ambiguous))
  }

  @Test(arguments: [RouteType.direct, RouteType.tcDirect])
  func `Direct routes show no region tile`(routeType: RouteType) {
    #expect(MessageRegionReading(message: Self.message(routeType: routeType)) == nil)
  }

  @Test
  func `Uncorrelated route shows no region tile`() {
    #expect(MessageRegionReading(message: Self.message(routeType: nil)) == nil)
  }

  private static func message(
    routeType: RouteType?,
    regionScope: String? = nil,
    matches: [String] = []
  ) -> MessageDTO {
    let message = Message(
      radioID: UUID(),
      contactID: UUID(),
      text: "Test",
      directionRawValue: MessageDirection.incoming.rawValue,
      statusRawValue: MessageStatus.delivered.rawValue,
      routeTypeRawValue: routeType.map { Int($0.rawValue) } ?? -1,
      regionScope: regionScope,
      regionScopeMatches: matches
    )
    return MessageDTO(from: message)
  }
}
