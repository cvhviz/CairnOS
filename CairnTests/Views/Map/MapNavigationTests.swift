import CoreLocation
@testable import Cairn
import MapLibre
import Testing
import UIKit

@Suite("MapNavigation")
struct MapNavigationTests {
  // MARK: - Tracking mode cycle

  @Test
  func `location button cycles off, follow, heading, off`() {
    let off = MapTrackingMode.none
    let follow = off.next(isNorthLocked: false, isHeadingAvailable: true)
    let heading = follow.next(isNorthLocked: false, isHeadingAvailable: true)
    #expect(follow == .follow)
    #expect(heading == .followWithHeading)
    #expect(heading.next(isNorthLocked: false, isHeadingAvailable: true) == .none)
  }

  @Test
  func `north lock skips heading mode`() {
    #expect(MapTrackingMode.none.next(isNorthLocked: true, isHeadingAvailable: true) == .follow)
    #expect(MapTrackingMode.follow.next(isNorthLocked: true, isHeadingAvailable: true) == .none)
  }

  @Test
  func `no compass skips heading mode`() {
    #expect(MapTrackingMode.follow.next(isNorthLocked: false, isHeadingAvailable: false) == .none)
  }

  @Test
  func `tracking mode round-trips through MapLibre`() {
    for mode in [MapTrackingMode.none, .follow, .followWithHeading] {
      #expect(MapTrackingMode(mode.mlnMode) == mode)
    }
    #expect(MapTrackingMode(MLNUserTrackingMode.followWithCourse) == .followWithHeading)
  }

  @Test
  func `each mode has Apple Maps' glyph`() {
    #expect(MapTrackingMode.none.systemImage == "location")
    #expect(MapTrackingMode.follow.systemImage == "location.fill")
    #expect(MapTrackingMode.followWithHeading.systemImage == "location.north.line.fill")
  }

  // MARK: - Compass visibility

  @Test(arguments: [
    (0.0, 0.0, false),
    (0.3, 0.0, false),
    (359.8, 0.0, false),
    (-0.2, 0.2, false),
    (10, 0, true),
    (350, 0, true),
    (0, 5, true),
  ])
  func `compass shows only when rotated or tilted`(direction: Double, pitch: Double, expected: Bool) {
    #expect(MapNavigationMath.isRotatedOrTilted(direction: direction, pitch: pitch) == expected)
    #expect(MapCameraOrientation(direction: direction, pitch: pitch).isRotatedOrTilted == expected)
  }

  // MARK: - Geometry

  @Test
  func `distance of one degree of latitude is about 111 km`() {
    let distance = MapNavigationMath.distance(
      from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
      to: CLLocationCoordinate2D(latitude: 1, longitude: 0)
    )
    #expect(abs(distance - 110_574) < 500)
  }

  @Test(arguments: [
    (90.0, 0.0, 90.0),
    (10, 350, 20),
    (350, 10, -20),
    (0, 0, 0),
    (180, 0, -180),
    (270, 90, -180),
    (45, 315, 90),
  ])
  func `relative angle is signed left or right of the heading`(bearing: Double, heading: Double, expected: Double) {
    #expect(abs(MapNavigationMath.relativeAngle(bearing: bearing, heading: heading) - expected) < 0.0001)
  }

  @Test(arguments: [
    (0.0, 12),
    (14, 12),
    (16, 1),
    (30, 1),
    (90, 3),
    (180, 6),
    (-180, 6),
    (-90, 9),
    (-30, 11),
    (-14, 12),
  ])
  func `clock position puts straight ahead at twelve`(angle: Double, expected: Int) {
    #expect(MapNavigationMath.clockPosition(relativeAngle: angle) == expected)
  }

  @Test
  func `shortest turn goes the short way past north`() {
    #expect(abs(MapNavigationMath.shortestTurn(from: 350, to: 10) - 20) < 0.0001)
    #expect(abs(MapNavigationMath.shortestTurn(from: 10, to: 350) + 20) < 0.0001)
    // An unwrapped angle a few turns in still turns the short way.
    #expect(abs(MapNavigationMath.shortestTurn(from: 730, to: 20) - 10) < 0.0001)
  }

  // MARK: - Target

  @Test
  func `target equality compares the coordinate`() {
    let id = UUID()
    let here = MapNavigationTarget(pointID: id, name: "A", coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2))
    let same = MapNavigationTarget(pointID: id, name: "A", coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2))
    let moved = MapNavigationTarget(pointID: id, name: "A", coordinate: CLLocationCoordinate2D(latitude: 1.1, longitude: 2))
    #expect(here == same)
    #expect(here != moved)
  }

  // MARK: - Heading orientation

  @Test(arguments: [
    (UIInterfaceOrientation.portrait, CLDeviceOrientation.portrait),
    (.portraitUpsideDown, .portraitUpsideDown),
    (.landscapeLeft, .landscapeRight),
    (.landscapeRight, .landscapeLeft),
    (.unknown, .portrait)
  ])
  func `heading is measured from the screen's top`(interface: UIInterfaceOrientation, device: CLDeviceOrientation) {
    #expect(GPSLiveLocation.headingOrientation(for: interface) == device)
  }
}
