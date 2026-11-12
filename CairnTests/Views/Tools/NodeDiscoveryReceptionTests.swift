import CoreLocation
import Foundation
@testable import Cairn
import Testing

@Suite("NodeDiscoveryReception")
struct NodeDiscoveryReceptionTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func phone(age: TimeInterval, accuracy: Double = 8, latitude: Double = 41.9) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -87.6),
      altitude: 0,
      horizontalAccuracy: accuracy,
      verticalAccuracy: -1,
      timestamp: now.addingTimeInterval(-age)
    )
  }

  private func heard(snr: Double, latitude: Double) -> NodeDiscoveryHeardFrom {
    NodeDiscoveryHeardFrom(
      fix: NodeDiscoveryFix(latitude: latitude, longitude: -87.6, horizontalAccuracy: 5, timestamp: now),
      snr: snr
    )
  }

  // MARK: - Which fix a reply gets

  @Test
  func `a fresh precise phone fix places the reply`() throws {
    let fix = try #require(NodeDiscoveryReception.fix(phone: phone(age: 3), now: now))
    #expect(fix.latitude == 41.9)
    #expect(fix.horizontalAccuracy == 8)
    #expect(fix.timestamp == now.addingTimeInterval(-3))
  }

  @Test
  func `a stale, imprecise or invalid fix places nothing`() {
    #expect(NodeDiscoveryReception.fix(phone: phone(age: 31), now: now) == nil)
    #expect(NodeDiscoveryReception.fix(phone: phone(age: 1, accuracy: 150), now: now) == nil)
    #expect(NodeDiscoveryReception.fix(phone: phone(age: 1, accuracy: -1), now: now) == nil)
    #expect(NodeDiscoveryReception.fix(phone: nil, now: now) == nil)
    #expect(NodeDiscoveryReception.fix(phone: phone(age: 1, latitude: 0).withLongitude(0), now: now) == nil)
  }

  // MARK: - Which reply a line is drawn from

  @Test
  func `the best-heard reply with a fix keeps the line`() {
    let weak = heard(snr: 2, latitude: 41.0)
    let strong = heard(snr: 9, latitude: 41.5)
    #expect(NodeDiscoveryReception.best(stored: nil, reply: weak) == weak)
    #expect(NodeDiscoveryReception.best(stored: weak, reply: strong) == strong)
    #expect(NodeDiscoveryReception.best(stored: strong, reply: weak) == strong)
    #expect(NodeDiscoveryReception.best(stored: strong, reply: nil) == strong)
    #expect(NodeDiscoveryReception.best(stored: strong, reply: heard(snr: 9, latitude: 42)) == strong, "a tie keeps the first")
  }

  // MARK: - Following

  @Test
  func `background updates are on only while a claim asks for them`() throws {
    #expect(LocationService.FollowSettings.following(clients: [:]) == nil)

    let scan = try #require(LocationService.FollowSettings.following(clients: ["phone": false]))
    #expect(!scan.allowsBackground)
    #expect(scan.distanceFilter == kCLDistanceFilterNone)
    #expect(!scan.pausesAutomatically)

    let wardrive = try #require(LocationService.FollowSettings.following(clients: ["phone": true, "carPlay": false]))
    #expect(wardrive.allowsBackground)
    #expect(wardrive.activityType == .otherNavigation)
    #expect(!wardrive.pausesAutomatically)

    #expect(!LocationService.FollowSettings.idle.allowsBackground)
  }

  @Test
  func `one claim ending leaves the others in place`() throws {
    var claims = LocationService.FollowClaims()
    claims.claim("nodeDiscovery.phone.A", inBackground: true)
    claims.claim("nodeDiscovery.carPlay", inBackground: false)
    #expect(try #require(claims.settings).allowsBackground, "the phone's Wardrive runs in the background")

    let releasedPhone = claims.release("nodeDiscovery.phone.A")
    #expect(releasedPhone)
    let carPlay = try #require(claims.settings, "CarPlay's scan keeps following")
    #expect(!carPlay.allowsBackground, "background ends with the Wardrive that asked for it")

    let releasedAgain = claims.release("nodeDiscovery.phone.A")
    #expect(!releasedAgain, "releasing again is harmless")
    let releasedCarPlay = claims.release("nodeDiscovery.carPlay")
    #expect(releasedCarPlay)
    #expect(claims.settings == nil, "updates stop with the last claim")
  }

  @Test
  func `two windows keep their own claims`() throws {
    var claims = LocationService.FollowClaims()
    claims.claim("nodeDiscovery.phone.A", inBackground: true)
    claims.claim("nodeDiscovery.phone.B", inBackground: false)
    #expect(try #require(claims.settings).allowsBackground, "B's scan doesn't turn off A's Wardrive")

    claims.release("nodeDiscovery.phone.B")
    #expect(try #require(claims.settings).allowsBackground, "B's scan ending leaves A following")
    claims.claim("nodeDiscovery.phone.A", inBackground: false)
    #expect(try #require(claims.settings).allowsBackground == false, "a repeated claim updates it")
  }

  @Test
  func `a request is answered at once only with a recent fix`() {
    let current = LocationService.FollowSettings.currentFix
    #expect(current(phone(age: 2), now) != nil)
    #expect(current(phone(age: LocationService.FollowSettings.currentFixAge + 1), now) == nil, "an old fix waits for the next")
    #expect(current(phone(age: 0, accuracy: -1), now) == nil)
    #expect(current(nil, now) == nil)
  }

  @Test
  func `the shown location moves only on a real move or a sharper fix`() {
    let shown = phone(age: 0, accuracy: 30)
    #expect(LocationService.FollowSettings.publishes(shown, over: nil))
    #expect(!LocationService.FollowSettings.publishes(phone(age: 0, accuracy: 25), over: shown))
    #expect(LocationService.FollowSettings.publishes(phone(age: 0, accuracy: 5), over: shown))
    #expect(LocationService.FollowSettings.publishes(phone(age: 0, accuracy: 30, latitude: 41.9002), over: shown))
  }
}

private extension CLLocation {
  /// A copy at the same latitude with `longitude`, for the (0, 0) sentinel.
  func withLongitude(_ longitude: CLLocationDegrees) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: longitude),
      altitude: altitude,
      horizontalAccuracy: horizontalAccuracy,
      verticalAccuracy: verticalAccuracy,
      timestamp: timestamp
    )
  }
}
