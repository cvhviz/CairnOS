import CoreLocation
import Foundation
@testable import Cairn
import Testing

@Suite("GPSFormat")
struct GPSFormatTests {
  // MARK: - Compass points

  @Test(arguments: [
    (0.0, CompassPoint.north),
    (22.4, .north),
    (22.5, .northeast),
    (47, .northeast),
    (90, .east),
    (135, .southeast),
    (180, .south),
    (225, .southwest),
    (270, .west),
    (315, .northwest),
    (337.4, .northwest),
    (337.5, .north),
    (359.9, .north),
    (-45, .northwest),
    (405, .northeast),
  ])
  func `compass point owns the wedge centred on it`(degrees: Double, expected: CompassPoint) {
    #expect(CompassPoint(degrees: degrees) == expected)
  }

  @Test
  func `degrees fold into a single turn`() {
    #expect(GPSFormat.normalizedDegrees(-90) == 270)
    #expect(GPSFormat.normalizedDegrees(720) == 0)
    #expect(GPSFormat.wholeDegrees(359.6) == 0)
    #expect(GPSFormat.wholeDegrees(46.6) == 47)
  }

  @Test
  func `bearing text pairs whole degrees with the point`() {
    #expect(GPSFormat.bearingText(47.2) == "47° \(CompassPoint.northeast.abbreviation)")
    #expect(GPSFormat.bearingText(359.7) == "0° \(CompassPoint.north.abbreviation)")
  }

  // MARK: - Coordinates

  @Test
  func `coordinates carry the hemisphere instead of a sign`() {
    #expect(GPSFormat.latitudeText(41.8823) == "41.88230° \(CompassPoint.north.abbreviation)")
    #expect(GPSFormat.latitudeText(-33.86785) == "33.86785° \(CompassPoint.south.abbreviation)")
    #expect(GPSFormat.longitudeText(-87.6232) == "87.62320° \(CompassPoint.west.abbreviation)")
    #expect(GPSFormat.longitudeText(151.2) == "151.20000° \(CompassPoint.east.abbreviation)")
  }

  @Test
  func `copied pair is signed and dotted`() {
    let text = GPSFormat.coordinatePairText(CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232))
    #expect(text == "41.88230, -87.62320")
  }

  // MARK: - Fix age

  @Test
  func `fix under a minute old reads as now`() {
    #expect(GPSFormat.fixAgeText(0) == L10n.Map.Map.Gps.FixAge.now)
    #expect(GPSFormat.fixAgeText(59) == L10n.Map.Map.Gps.FixAge.now)
  }

  @Test
  func `fix age uses the largest unit`() {
    let english = Locale(identifier: "en_US")
    #expect(GPSFormat.shortDuration(3 * 60 + 20, locale: english) == "3m")
    #expect(GPSFormat.shortDuration(2 * 3600 + 15 * 60, locale: english) == "2h")
    #expect(GPSFormat.shortDuration(3 * 86400 + 3600, locale: english) == "3d")
    #expect(GPSFormat.fixAgeText(180, locale: english) == L10n.Map.Map.Gps.FixAge.ago("3m"))
  }

  // MARK: - Units

  @Test
  func `speed follows the measurement preference`() {
    let english = Locale(identifier: "en_US")
    // 1.43 m/s ≈ 3.2 mph ≈ 5.1 km/h
    #expect(GPSFormat.speedText(1.43, imperial: true, locale: english) == "3.2 mph")
    #expect(GPSFormat.speedText(1.43, imperial: false, locale: english) == "5.1 km/h")
    #expect(GPSFormat.speedText(-1, imperial: false, locale: english) == "0.0 km/h")
  }

  // MARK: - Radio vs phone

  @Test
  func `positions within the tolerance are the same place`() {
    let phone = CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232),
      altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: .now
    )
    let near = CLLocation(latitude: 41.88240, longitude: -87.6232) // ~11 m north
    let far = CLLocation(latitude: 41.8833, longitude: -87.6232) // ~111 m north
    #expect(!GPSFormat.positionsDiffer(phone, near))
    #expect(GPSFormat.positionsDiffer(phone, far))
  }

  @Test
  func `bearing points from origin to destination`() {
    let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    #expect(abs(GPSFormat.bearing(from: origin, to: CLLocationCoordinate2D(latitude: 1, longitude: 0))) < 0.001)
    #expect(abs(GPSFormat.bearing(from: origin, to: CLLocationCoordinate2D(latitude: 0, longitude: 1)) - 90) < 0.001)
    #expect(abs(GPSFormat.bearing(from: origin, to: CLLocationCoordinate2D(latitude: 0, longitude: -1)) - 270) < 0.001)
  }
}

@Suite("GPSCompassCard")
@MainActor
struct GPSCompassCardTests {
  @Test
  func `reading line shows the bearing when there is a heading`() {
    #expect(GPSCompassCard.readingText(heading: 47.2) == GPSFormat.bearingText(47.2))
  }

  @Test
  func `reading line says no heading once instead of a dash`() {
    #expect(GPSCompassCard.readingText(heading: nil) == L10n.Map.Map.Gps.noHeading)
    #expect(GPSCompassCard.readingText(heading: nil) != "—")
  }
}
