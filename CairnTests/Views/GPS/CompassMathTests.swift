@testable import Cairn
import CairnServices
import CoreLocation
import Foundation
import MeshCore
import Testing

@Suite("Compass maths")
struct CompassMathTests {
  private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test
  func `The equinox sun at Greenwich noon stands due south at 90° minus the latitude`() {
    let sun = SunPosition.at(utc(2026, 3, 20, 12, 7), latitude: 51.4779, longitude: 0)
    #expect(abs(sun.azimuth - 180) < 1.5)
    #expect(abs(sun.elevation - (90 - 51.4779)) < 1)
    #expect(sun.isUp)
  }

  @Test
  func `The sun rises in the east and is down at midnight`() {
    // San Francisco, June solstice: mid-morning sun in the east, midnight sun well below.
    let morning = SunPosition.at(utc(2026, 6, 21, 15), latitude: 37.7749, longitude: -122.4194)
    #expect(morning.azimuth > 60 && morning.azimuth < 120)
    #expect(morning.elevation > 20)
    let midnight = SunPosition.at(utc(2026, 6, 21, 8), latitude: 37.7749, longitude: -122.4194)
    #expect(!midnight.isUp)
  }

  @Test
  func `Nodes place nearest first, only those with a position`() {
    let origin = CLLocation(latitude: 37.7749, longitude: -122.4194)
    func contact(_ name: String, _ lat: Double, _ lon: Double) -> ContactDTO {
      ContactDTO(
        id: UUID(), radioID: UUID(), publicKey: Data(repeating: 1, count: ProtocolLimits.publicKeySize),
        name: name, typeRawValue: ContactType.chat.rawValue, flags: 0, outPathLength: 0, outPath: Data(),
        lastAdvertTimestamp: 0, latitude: lat, longitude: lon, lastModified: 0, lastHeardTimestamp: nil,
        nickname: nil, isBlocked: false, isMuted: false, isFavorite: false, lastMessageDate: nil, unreadCount: 0
      )
    }
    let far = contact("Far", 37.80, -122.4194)
    let near = contact("Near", 37.7749, -122.41)
    let none = contact("Nowhere", 0, 0)
    let nodes = CompassNode.nearest([far, none, near], from: origin, limit: 5)
    #expect(nodes.map(\.contact.name) == ["Near", "Far"])
    // Near lies due east, far due north.
    #expect(abs(nodes[0].bearing - 90) < 1)
    #expect(nodes[1].bearing < 1 || nodes[1].bearing > 359)
  }
}
