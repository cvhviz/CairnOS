import CoreLocation
import Foundation
@testable import Cairn
import Testing

@Suite("HomeFormat")
struct HomeFormatTests {
  private let locale = Locale(identifier: "en_US")

  @Test
  func `Ages use one narrow unit`() {
    #expect(HomeFormat.age(30, locale: locale) == L10n.Chats.Chats.Timestamp.now)
    #expect(HomeFormat.age(150, locale: locale) == "2m")
    #expect(HomeFormat.age(3 * 3600 + 59 * 60, locale: locale) == "3h")
    #expect(HomeFormat.age(2 * 86400 + 5, locale: locale) == "2d")
  }

  @Test
  func `Uptime keeps its two largest units`() {
    #expect(HomeFormat.uptime(seconds: 3 * 3600 + 12 * 60 + 40, locale: locale) == "3h 12m")
    #expect(HomeFormat.uptime(seconds: 3 * 86400 + 4 * 3600 + 5 * 60, locale: locale) == "3d 4h")
    #expect(HomeFormat.uptime(seconds: 12 * 60, locale: locale) == "12m")
  }

  @Test
  func `Coordinates show four signed decimals`() {
    #expect(HomeFormat.coordinate(latitude: 41.88234, longitude: -87.62321, locale: locale) == "41.8823, -87.6232")
  }

  @Test
  func `Bearings point the right way`() {
    let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    #expect(abs(HomeFormat.bearing(from: origin, to: .init(latitude: 1, longitude: 0))) < 0.001)
    #expect(abs(HomeFormat.bearing(from: origin, to: .init(latitude: 0, longitude: 1)) - 90) < 0.001)
    #expect(abs(HomeFormat.bearing(from: origin, to: .init(latitude: -1, longitude: 0)) - 180) < 0.001)
    #expect(abs(HomeFormat.bearing(from: origin, to: .init(latitude: 0, longitude: -1)) - 270) < 0.001)
  }

  @Test
  func `Compass points round to the nearest of eight`() {
    #expect(HomeFormat.compassPointIndex(bearing: 0) == 0)
    #expect(HomeFormat.compassPointIndex(bearing: 22) == 0)
    #expect(HomeFormat.compassPointIndex(bearing: 23) == 1)
    #expect(HomeFormat.compassPointIndex(bearing: 180) == 4)
    #expect(HomeFormat.compassPointIndex(bearing: 350) == 0)
    #expect(HomeFormat.compassPointIndex(bearing: -45) == 7)
  }

  @Test
  func `New nodes are recent and not already contacts`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let saved = Data([1])
    let heard: [(publicKey: Data, lastHeard: Date)] = [
      (saved, now),
      (Data([2]), now.addingTimeInterval(-60)),
      (Data([3]), now.addingTimeInterval(-90000)),
    ]
    #expect(HomeFormat.newNodeCount(heard: heard, contactKeys: [saved], now: now) == 1)
  }

  @Test
  func `Newest conversations sort by date and skip undated`() {
    let base = Date(timeIntervalSince1970: 0)
    let items: [(String, Date?)] = [("a", base), ("b", nil), ("c", base.addingTimeInterval(10)), ("d", base.addingTimeInterval(5))]
    #expect(HomeFormat.newest(items, limit: 2, date: \.1).map(\.0) == ["c", "d"])
  }
}
