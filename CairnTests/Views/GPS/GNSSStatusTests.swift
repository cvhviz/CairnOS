import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("GNSS dashboard")
struct GNSSStatusTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func fix(
    latitude: Double = 41.8823,
    longitude: Double = -87.6232,
    accuracy: CLLocationAccuracy = 5,
    age: TimeInterval = 0
  ) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: 180,
      horizontalAccuracy: accuracy,
      verticalAccuracy: 3,
      timestamp: now.addingTimeInterval(-age)
    )
  }

  // MARK: - Radio status

  @Test(arguments: [
    (RadioGPSStatus.unknown, GNSSStatus.checking),
    (.noReceiver, .noReceiver),
    (.off, .off),
    (.on, .on),
    (.searching, .searching),
    (.fix, .fix),
  ])
  func `connected radio status follows its gps reading`(reading: RadioGPSStatus, expected: GNSSStatus) {
    #expect(GNSSStatus.radio(isConnected: true, status: reading) == expected)
  }

  @Test
  func `no radio wins over any stale reading`() {
    #expect(GNSSStatus.radio(isConnected: false, status: .fix) == .noRadio)
  }

  // MARK: - Phone status

  @Test(arguments: [CLAuthorizationStatus.notDetermined, .denied, .restricted])
  func `phone without permission is not allowed`(authorization: CLAuthorizationStatus) {
    #expect(GNSSStatus.phone(authorization: authorization, location: Self.fix(), now: Self.now) == .notAllowed)
  }

  @Test
  func `phone with a fresh valid fix has a fix`() {
    let status = GNSSStatus.phone(authorization: .authorizedWhenInUse, location: Self.fix(age: 30), now: Self.now)
    #expect(status == .fix)
  }

  @Test
  func `phone without a usable fix is searching`() {
    #expect(GNSSStatus.phone(authorization: .authorizedWhenInUse, location: nil, now: Self.now) == .searching)
    // Negative accuracy marks an invalid fix.
    let invalid = Self.fix(accuracy: -1)
    #expect(GNSSStatus.phone(authorization: .authorizedWhenInUse, location: invalid, now: Self.now) == .searching)
    let stale = Self.fix(age: GNSSStatus.phoneFixMaxAge + 1)
    #expect(GNSSStatus.phone(authorization: .authorizedWhenInUse, location: stale, now: Self.now) == .searching)
  }

  @Test
  func `every status has words`() {
    let all: [GNSSStatus] = [.fix, .searching, .on, .off, .noReceiver, .notAllowed, .noRadio, .checking]
    for status in all {
      #expect(!status.text.isEmpty)
    }
  }

  // MARK: - Accuracy

  @Test(arguments: [
    (3.0, GNSSAccuracyGrade.excellent),
    (5, .excellent),
    (10, .good),
    (15, .good),
    (30, .fair),
    (50, .fair),
    (65, .poor),
    (1500, .poor),
  ])
  func `accuracy grades by metres`(meters: Double, expected: GNSSAccuracyGrade) {
    #expect(GNSSAccuracyGrade(meters: meters) == expected)
  }

  @Test
  func `ring fills on a log scale between a metre and a kilometre`() {
    #expect(GNSSAccuracyGrade.ringFraction(meters: 0.5) == 1)
    #expect(GNSSAccuracyGrade.ringFraction(meters: 1) == 1)
    #expect(abs(GNSSAccuracyGrade.ringFraction(meters: 10) - 2.0 / 3) < 0.0001)
    #expect(abs(GNSSAccuracyGrade.ringFraction(meters: 100) - 1.0 / 3) < 0.0001)
    #expect(GNSSAccuracyGrade.ringFraction(meters: 1000) == 0)
    #expect(GNSSAccuracyGrade.ringFraction(meters: 5000) == 0)
    #expect(GNSSAccuracyGrade.ringFraction(meters: 5) > GNSSAccuracyGrade.ringFraction(meters: 20))
  }

  @Test
  func `accuracy text carries the plus minus sign`() {
    #expect(GPSFormat.accuracyText(5).hasPrefix("±"))
    #expect(GPSFormat.accuracyText(5).hasSuffix(GPSFormat.lengthText(5)))
  }

  // MARK: - Radio position source

  @Test
  func `a live fix is the radio's source whatever the preferences`() {
    let source = RadioPositionSource.derive(
      status: .fix, hasPosition: true, sharesLocationPublicly: true, autoUpdate: true, gpsSource: .phone
    )
    #expect(source == .liveGPS)
    let unshared = RadioPositionSource.derive(
      status: .fix, hasPosition: true, sharesLocationPublicly: false, autoUpdate: false, gpsSource: .device
    )
    #expect(unshared == .liveGPS)
  }

  @Test
  func `without a fix the source is the phone, the saved position, or nothing`() {
    #expect(RadioPositionSource.derive(
      status: .off, hasPosition: true, sharesLocationPublicly: true, autoUpdate: true, gpsSource: .phone
    ) == .phone)
    #expect(RadioPositionSource.derive(
      status: .searching, hasPosition: true, sharesLocationPublicly: true, autoUpdate: true, gpsSource: .device
    ) == .saved)
    #expect(RadioPositionSource.derive(
      status: .noReceiver, hasPosition: true, sharesLocationPublicly: true, autoUpdate: false, gpsSource: .phone
    ) == .saved)
    #expect(RadioPositionSource.derive(
      status: .off, hasPosition: false, sharesLocationPublicly: true, autoUpdate: true, gpsSource: .phone
    ) == .notSet)
  }

  @Test
  func `the phone is not the source when adverts carry no position`() {
    // Auto-update from the phone is on, but the advert policy skips the refresh, so nothing
    // writes the radio's position: it is the saved one.
    #expect(RadioPositionSource.derive(
      status: .off, hasPosition: true, sharesLocationPublicly: false, autoUpdate: true, gpsSource: .phone
    ) == .saved)
    #expect(RadioPositionSource.derive(
      status: .noReceiver, hasPosition: false, sharesLocationPublicly: false, autoUpdate: true, gpsSource: .phone
    ) == .notSet)
  }

  @Test
  func `the advert refresh gate needs both the policy and auto-update`() {
    #expect(GPSSource.advertRefresh(sharesLocationPublicly: true, autoUpdate: true, source: .phone) == .phone)
    #expect(GPSSource.advertRefresh(sharesLocationPublicly: true, autoUpdate: true, source: .device) == .device)
    #expect(GPSSource.advertRefresh(sharesLocationPublicly: false, autoUpdate: true, source: .phone) == nil)
    #expect(GPSSource.advertRefresh(sharesLocationPublicly: true, autoUpdate: false, source: .phone) == nil)
    #expect(GPSSource.advertRefresh(sharesLocationPublicly: false, autoUpdate: false, source: .device) == nil)
  }

  // MARK: - Relationship

  @Test
  func `combined readings run the radio's down the left and the phone's down the right`() {
    let phone = Self.fix(age: 10)
    let radioPosition = CLLocation(latitude: 41.8893, longitude: -87.6138)
    let reading = RadioGPSReading(
      receiver: DeviceGPSState(isSupported: true, isEnabled: true),
      telemetry: .init(latitude: 41.8893, longitude: -87.6138, altitude: 190),
      readAt: Self.now
    )
    let readings = GNSSReadings.combined(radio: reading, radioPosition: radioPosition, phone: phone, now: Self.now)
    #expect(readings.map(\.id) == [
      "radio.altitude", "phone.altitude", "both.distance", "phone.updated", "radio.updated", "sun.next",
    ])
    #expect(readings[2].caption == GPSFormat.bearingText(GPSFormat.bearing(from: phone.coordinate, to: radioPosition.coordinate)))
  }

  @Test
  func `combined readings skip the distance without both positions`() {
    let readings = GNSSReadings.combined(radio: RadioGPSReading(), radioPosition: nil, phone: Self.fix(), now: Self.now)
    #expect(readings.map(\.id) == ["phone.altitude", "phone.updated", "sun.next"])
    let together = GNSSReadings.combined(
      radio: RadioGPSReading(),
      radioPosition: CLLocation(latitude: 41.88231, longitude: -87.62321),
      phone: Self.fix(),
      now: Self.now
    )
    #expect(together.first { $0.id == "both.distance" }?.caption == L10n.Map.Map.Gps.Relation.together)
  }

  @Test
  func `advert line says when adverts carry no position`() {
    let text = GNSSRelationship.advertVersusFix(policy: .none, advertised: nil, fix: nil)
    #expect(text == L10n.Map.Map.Gps.Relation.advertNone)
  }

  @Test
  func `advert line compares the advert with the live fix`() {
    let advertised = CLLocation(latitude: 41.8823, longitude: -87.6232)
    #expect(GNSSRelationship.advertVersusFix(policy: .prefs, advertised: advertised, fix: nil) == nil)

    let sameSpot = CLLocation(latitude: 41.88231, longitude: -87.62321)
    #expect(
      GNSSRelationship.advertVersusFix(policy: .share, advertised: advertised, fix: sameSpot)
        == L10n.Map.Map.Gps.Relation.advertMatches
    )

    let elsewhere = CLLocation(latitude: 41.9023, longitude: -87.6232)
    #expect(
      GNSSRelationship.advertVersusFix(policy: .prefs, advertised: advertised, fix: elsewhere)
        == L10n.Map.Map.Gps.Relation.advertOffset(GPSFormat.lengthText(advertised.distance(from: elsewhere)))
    )
  }

  // MARK: - Map framing

  @Test
  func `no positions, no map`() {
    #expect(GNSSMapFraming.region(for: []) == nil)
  }

  @Test
  func `one position gets the minimum span around it`() {
    let point = CLLocationCoordinate2D(latitude: 10, longitude: 20)
    let region = GNSSMapFraming.region(for: [point])
    #expect(region?.center.latitude == 10)
    #expect(region?.center.longitude == 20)
    #expect(region?.span.latitudeDelta == GNSSMapFraming.minimumSpanDegrees)
  }

  @Test
  func `two positions are both in view with room around them`() {
    let first = CLLocationCoordinate2D(latitude: 10, longitude: 20)
    let second = CLLocationCoordinate2D(latitude: 11, longitude: 22)
    let region = GNSSMapFraming.region(for: [first, second])
    #expect(region?.center.latitude == 10.5)
    #expect(region?.center.longitude == 21)
    #expect(abs((region?.span.latitudeDelta ?? 0) - 1.6) < 0.0001)
    #expect(abs((region?.span.longitudeDelta ?? 0) - 3.2) < 0.0001)
  }

  // MARK: - Advert policy

  @Test
  func `sharing uses the live gps only when the radio's own gps keeps the position`() {
    #expect(RadioLocationActions.advertPolicy(share: false, autoUpdate: true, deviceHasGPS: true, gpsSource: .device) == .none)
    #expect(RadioLocationActions.advertPolicy(share: true, autoUpdate: true, deviceHasGPS: true, gpsSource: .device) == .share)
    #expect(RadioLocationActions.advertPolicy(share: true, autoUpdate: false, deviceHasGPS: true, gpsSource: .device) == .prefs)
    #expect(RadioLocationActions.advertPolicy(share: true, autoUpdate: true, deviceHasGPS: false, gpsSource: .device) == .prefs)
    #expect(RadioLocationActions.advertPolicy(share: true, autoUpdate: true, deviceHasGPS: true, gpsSource: .phone) == .prefs)
  }

  // MARK: - Readings shown

  private static func moving(speed: CLLocationSpeed, course: CLLocationDirection, verticalAccuracy: Double = 3) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232),
      altitude: 180,
      horizontalAccuracy: 5,
      verticalAccuracy: verticalAccuracy,
      course: course,
      courseAccuracy: 4,
      speed: speed,
      speedAccuracy: 0.5,
      timestamp: now
    )
  }

  @Test
  func `radio shows altitude only after a fix and updated only once read`() {
    #expect(GNSSReadings.radio(RadioGPSReading(), now: Self.now).isEmpty)

    let on = DeviceGPSState(isSupported: true, isEnabled: true)
    let searching = RadioGPSReading(
      receiver: on,
      telemetry: .init(latitude: 41.88, longitude: -87.62, altitude: 0),
      readAt: Self.now
    )
    #expect(GNSSReadings.radio(searching, now: Self.now).map(\.id) == ["radio.updated"])

    let fixed = RadioGPSReading(
      receiver: on,
      telemetry: .init(latitude: 41.88, longitude: -87.62, altitude: 181),
      readAt: Self.now
    )
    #expect(GNSSReadings.radio(fixed, now: Self.now).map(\.id) == ["radio.altitude", "radio.updated"])
  }

  @Test
  func `phone shows nothing without a fix`() {
    #expect(GNSSReadings.phone(nil, now: Self.now).isEmpty)
  }

  @Test
  func `phone standing still reads zero speed and no course`() {
    let still = Self.moving(speed: 0.1, course: 90)
    let readings = GNSSReadings.phone(still, now: Self.now)
    #expect(readings.map(\.id) == ["phone.altitude", "phone.speed", "phone.updated"])
    #expect(readings[1].value == GPSFormat.speedText(0))
    #expect(GNSSReadings.course(of: still) == nil)
  }

  @Test
  func `phone fix without a speed leaves it out`() {
    let noSpeed = Self.moving(speed: -1, course: -1)
    #expect(GNSSReadings.phone(noSpeed, now: Self.now).map(\.id) == ["phone.altitude", "phone.updated"])
  }

  @Test
  func `phone moving adds speed and course`() {
    let walking = Self.moving(speed: 1.4, course: 90)
    #expect(GNSSReadings.phone(walking, now: Self.now).map(\.id) == [
      "phone.altitude", "phone.speed", "phone.course", "phone.updated",
    ])
    #expect(GNSSReadings.course(of: walking) == 90)
  }

  @Test
  func `phone fix without altitude or course leaves those out`() {
    let noAltitude = Self.moving(speed: 1.4, course: -1, verticalAccuracy: -1)
    #expect(GNSSReadings.phone(noAltitude, now: Self.now).map(\.id) == ["phone.speed", "phone.updated"])
  }

  @Test
  func `phone reading says how old its fix is`() {
    let reading = GNSSReadings.phone(Self.fix(age: 300), now: Self.now).first { $0.id == "phone.updated" }
    #expect(reading?.value == GPSFormat.fixAgeText(300))
  }

  // MARK: - Daylight

  @Test
  func `the next sun event is this evening's sunset at noon and tomorrow's sunrise at night`() throws {
    let chicago = CLLocationCoordinate2D(latitude: 41.8823, longitude: -87.6232)
    let zone = try #require(TimeZone(identifier: "America/Chicago"))
    let noon = try #require(ISO8601DateFormatter().date(from: "2026-10-09T17:00:00Z"))
    let evening = try #require(GNSSReadings.nextSunEvent(after: noon, at: chicago, timeZone: zone))
    #expect(!evening.isSunrise)
    #expect(evening.date > noon && evening.date.timeIntervalSince(noon) < 8 * 3600)
    let night = noon.addingTimeInterval(10 * 3600)
    let morning = try #require(GNSSReadings.nextSunEvent(after: night, at: chicago, timeZone: zone))
    #expect(morning.isSunrise)
    #expect(morning.date > night)
  }

  @Test
  func `no sunrise or sunset through a polar night`() throws {
    let midwinter = try #require(ISO8601DateFormatter().date(from: "2026-12-21T12:00:00Z"))
    let pole = CLLocationCoordinate2D(latitude: 85, longitude: 0)
    #expect(GNSSReadings.nextSunEvent(after: midwinter, at: pole, timeZone: .gmt) == nil)
    #expect(GNSSReadings.daylight(at: nil, now: midwinter) == nil)
  }

  // MARK: - Steady speed

  private static func speedFix(_ speed: CLLocationSpeed, secondsAgo: TimeInterval) -> CLLocation {
    CLLocation(
      coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
      altitude: 0,
      horizontalAccuracy: 5,
      verticalAccuracy: 5,
      course: -1,
      speed: speed,
      timestamp: Self.now.addingTimeInterval(-secondsAgo)
    )
  }

  @Test
  func `a fix without a speed keeps the last one showing`() {
    let last = Self.speedFix(3, secondsAgo: 5)
    let none = Self.speedFix(-1, secondsAgo: 0)
    #expect(GNSSReadings.steadySpeed(current: none, lastWithSpeed: last, now: Self.now) == 3)
  }

  @Test
  func `a held speed runs out`() {
    let old = Self.speedFix(3, secondsAgo: GNSSReadings.speedHold + 1)
    let none = Self.speedFix(-1, secondsAgo: 0)
    #expect(GNSSReadings.steadySpeed(current: none, lastWithSpeed: old, now: Self.now) == nil)
    #expect(GNSSReadings.steadySpeed(current: nil, lastWithSpeed: nil, now: Self.now) == nil)
  }

  @Test
  func `a speed under walking pace reads zero, and a fresh one wins`() {
    let last = Self.speedFix(3, secondsAgo: 5)
    #expect(GNSSReadings.steadySpeed(current: Self.speedFix(0.1, secondsAgo: 0), lastWithSpeed: last, now: Self.now) == 0)
    #expect(GNSSReadings.steadySpeed(current: Self.speedFix(9, secondsAgo: 0), lastWithSpeed: last, now: Self.now) == 9)
  }

  // MARK: - Nearby nodes

  private struct Node {
    let name: String
    let coordinate: CLLocationCoordinate2D
  }

  /// `kilometres` north of the anchor at (0, 0); a degree of latitude is about 111 km.
  private static func node(_ name: String, kilometresNorth kilometres: Double) -> Node {
    Node(name: name, coordinate: CLLocationCoordinate2D(latitude: kilometres / 111.2, longitude: 0))
  }

  @Test
  func `nearby keeps the closest first and drops nodes past the radius`() {
    let anchor = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let nodes = [
      Self.node("far", kilometresNorth: 900),
      Self.node("mid", kilometresNorth: 12),
      Self.node("near", kilometresNorth: 1),
    ]
    let nearby = GNSSMapFraming.nearby(nodes, coordinate: \.coordinate, around: anchor)
    #expect(nearby.map(\.name) == ["near", "mid"])
  }

  @Test
  func `nearby caps the count`() {
    let anchor = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let nodes = (1...40).map { Self.node("n\($0)", kilometresNorth: Double($0) / 10) }
    let nearby = GNSSMapFraming.nearby(nodes, coordinate: \.coordinate, around: anchor, limit: 5)
    #expect(nearby.map(\.name) == ["n1", "n2", "n3", "n4", "n5"])
    #expect(GNSSMapFraming.nearby(nodes, coordinate: \.coordinate, around: anchor).count == GNSSMapFraming.nearbyLimit)
    #expect(GNSSMapFraming.nearby(nodes, coordinate: \.coordinate, around: anchor, limit: 0).isEmpty)
  }

  // MARK: - Settings summary

  @Test
  func `summary without a radio says so`() {
    let text = GNSSSettingsSummary.text(isConnected: false, receiver: nil, advert: .prefs, usesPhoneLocation: true)
    #expect(text == L10n.Localizable.Home.noRadio)
  }

  @Test
  func `summary lists the receiver only when the radio has one`() {
    let withReceiver = GNSSSettingsSummary.text(
      isConnected: true,
      receiver: DeviceGPSState(isSupported: true, isEnabled: true),
      advert: .prefs,
      usesPhoneLocation: false
    )
    #expect(withReceiver == [
      L10n.Map.Map.Gps.Summary.receiver(L10n.Localizable.Home.Gps.on),
      L10n.Map.Map.Gps.Summary.advert(L10n.Map.Map.Gps.Advert.saved),
      L10n.Map.Map.Gps.Summary.phoneToRadio(L10n.Localizable.Home.Gps.off),
    ].joined(separator: " · "))

    let noReceiver = GNSSSettingsSummary.text(
      isConnected: true,
      receiver: DeviceGPSState(isSupported: false, isEnabled: false),
      advert: .none,
      usesPhoneLocation: true
    )
    #expect(noReceiver == [
      L10n.Map.Map.Gps.Summary.advert(L10n.Map.Map.Gps.Advert.none),
      L10n.Map.Map.Gps.Summary.phoneToRadio(L10n.Localizable.Home.Gps.on),
    ].joined(separator: " · "))
  }
}
