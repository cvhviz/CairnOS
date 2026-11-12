import CoreLocation
import MapKit
import CairnServices
import SwiftUI

/// The state badge on each of the GPS tab's device cards, the same words for the radio and the
/// phone: Fix, Searching, On, Off, No receiver, Not allowed, No radio, or Checking while the app
/// is still asking. Derived purely from what each side reports, so it can be unit tested.
enum GNSSStatus: Equatable {
  /// A current position from the device's own receiver.
  case fix
  /// The receiver is running but has no fix yet.
  case searching
  /// The radio's receiver is on, but the radio sent nothing that says whether it has a fix.
  case on
  /// The radio's receiver is powered down.
  case off
  /// The radio has no GPS receiver.
  case noReceiver
  /// The app may not use the phone's location (refused, restricted, or not asked yet).
  case notAllowed
  /// No radio is connected.
  case noRadio
  /// Connected, but the radio's GPS state hasn't been read yet.
  case checking

  /// How old the phone's last fix may be and still count as a fix. The page asks for continuous
  /// updates, so a fix older than this means the phone has lost the sky.
  static let phoneFixMaxAge: TimeInterval = 120

  /// The radio's badge, from the connection and what the radio last said about its GPS.
  static func radio(isConnected: Bool, status: RadioGPSStatus) -> GNSSStatus {
    guard isConnected else { return .noRadio }
    switch status {
    case .unknown: return .checking
    case .noReceiver: return .noReceiver
    case .off: return .off
    case .on: return .on
    case .searching: return .searching
    case .fix: return .fix
    }
  }

  /// The phone's badge, from the app's location permission and the latest fix.
  static func phone(authorization: CLAuthorizationStatus, location: CLLocation?, now: Date) -> GNSSStatus {
    switch authorization {
    case .authorizedAlways, .authorizedWhenInUse:
      guard let location,
            location.horizontalAccuracy >= 0,
            now.timeIntervalSince(location.timestamp) <= phoneFixMaxAge else { return .searching }
      return .fix
    default:
      return .notAllowed
    }
  }

  /// The badge's words. Color only echoes them.
  var text: String {
    switch self {
    case .fix: L10n.Map.Map.Gps.fix
    case .searching: L10n.Map.Map.Gps.Status.searching
    case .on: L10n.Localizable.Home.Gps.on
    case .off: L10n.Localizable.Home.Gps.off
    case .noReceiver: L10n.Map.Map.Gps.Pill.noReceiver
    case .notAllowed: L10n.Map.Map.Gps.Status.notAllowed
    case .noRadio: L10n.Localizable.Home.noRadio
    case .checking: L10n.Map.Map.Gps.Status.checking
    }
  }

  var systemImage: String {
    switch self {
    case .fix: "location.fill"
    case .searching, .on: "location"
    case .off, .noReceiver, .notAllowed: "location.slash"
    case .noRadio: "antenna.radiowaves.left.and.right.slash"
    case .checking: "ellipsis"
    }
  }

  var tint: Color {
    switch self {
    case .fix, .on: .green
    case .searching: .orange
    case .off, .noReceiver, .noRadio, .checking: .secondary
    case .notAllowed: .red
    }
  }
}

/// How good the phone's horizontal accuracy is, for the accuracy ring's color and word.
enum GNSSAccuracyGrade: Equatable {
  case excellent
  case good
  case fair
  case poor

  /// A few metres is what open sky gives a phone; tens of metres is a city street or indoors;
  /// past that the fix is Wi-Fi or cell based (or approximate location).
  init(meters: CLLocationAccuracy) {
    switch meters {
    case ..<5.5: self = .excellent
    case ..<15.5: self = .good
    case ..<50.5: self = .fair
    default: self = .poor
    }
  }

  var text: String {
    switch self {
    case .excellent: L10n.Map.Map.Gps.Accuracy.excellent
    case .good: L10n.Map.Map.Gps.Accuracy.good
    case .fair: L10n.Map.Map.Gps.Accuracy.fair
    case .poor: L10n.Map.Map.Gps.Accuracy.poor
    }
  }

  var tint: Color {
    switch self {
    case .excellent: .green
    case .good: .teal
    case .fair: .orange
    case .poor: .red
    }
  }

  /// How full the ring is drawn: full at 1 m, empty at 1 km, on a log scale so the metres that
  /// matter outdoors move it most.
  static func ringFraction(meters: CLLocationAccuracy) -> Double {
    guard meters > 0 else { return 1 }
    let fraction = 1 - log10(max(meters, 1)) / 3
    return min(max(fraction, 0), 1)
  }
}

/// Where the radio's position comes from, shown under its coordinates.
enum RadioPositionSource: Equatable {
  /// The radio's receiver has a fix and keeps the position current.
  case liveGPS
  /// The phone sends its position when an advert is sent from this app.
  case phone
  /// A position saved on the radio (set by hand or by an earlier update).
  case saved
  /// No position at all.
  case notSet

  /// `sharesLocationPublicly` is the device's advert policy: the phone only writes the radio's
  /// position on the way to sending an advert, which skips the write when adverts carry no
  /// position, so the phone counts as the source only when that refresh can run.
  static func derive(
    status: RadioGPSStatus,
    hasPosition: Bool,
    sharesLocationPublicly: Bool,
    autoUpdate: Bool,
    gpsSource: GPSSource
  ) -> RadioPositionSource {
    if status == .fix { return .liveGPS }
    guard hasPosition else { return .notSet }
    let refresh = GPSSource.advertRefresh(
      sharesLocationPublicly: sharesLocationPublicly,
      autoUpdate: autoUpdate,
      source: gpsSource
    )
    return refresh == .phone ? .phone : .saved
  }

  var text: String {
    switch self {
    case .liveGPS: L10n.Map.Map.Gps.Source.liveCaption
    case .phone: L10n.Map.Map.Gps.Source.phoneCaption
    case .saved: L10n.Map.Map.Gps.Source.savedCaption
    case .notSet: L10n.Localizable.Home.Gps.noPosition
    }
  }
}

/// Whether the position the radio adverts matches its live fix, for the advert setting.
enum GNSSRelationship {
  /// Whether the advert carries the live fix: "Advert matches the radio's fix", "Advert is
  /// 2.1 km from the radio's fix", or that adverts carry no position. Nil when there is no live
  /// fix to compare with.
  static func advertVersusFix(policy: AdvertLocationPolicy, advertised: CLLocation?, fix: CLLocation?) -> String? {
    guard policy.isEnabled else { return L10n.Map.Map.Gps.Relation.advertNone }
    guard let advertised, let fix else { return nil }
    guard GPSFormat.positionsDiffer(advertised, fix) else {
      return L10n.Map.Map.Gps.Relation.advertMatches
    }
    return L10n.Map.Map.Gps.Relation.advertOffset(GPSFormat.lengthText(advertised.distance(from: fix)))
  }
}

/// The map preview's camera: both positions in view with some room around them.
enum GNSSMapFraming {
  /// Smallest span, about a kilometre: close enough to place the pins, not so close the map is
  /// one street.
  static let minimumSpanDegrees = 0.01

  static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
    guard let first = coordinates.first else { return nil }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for coordinate in coordinates.dropFirst() {
      minLat = min(minLat, coordinate.latitude)
      maxLat = max(maxLat, coordinate.latitude)
      minLon = min(minLon, coordinate.longitude)
      maxLon = max(maxLon, coordinate.longitude)
    }
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    let span = MKCoordinateSpan(
      latitudeDelta: min(max((maxLat - minLat) * 1.6, minimumSpanDegrees), 170),
      longitudeDelta: min(max((maxLon - minLon) * 1.6, minimumSpanDegrees), 350)
    )
    return MKCoordinateRegion(center: center, span: span)
  }
}

extension AdvertLocationPolicy {
  /// "Not Shared" / "Saved Position" / "Live GPS": which position the radio's adverts carry.
  var gnssText: String {
    switch self {
    case .none: L10n.Map.Map.Gps.Advert.none
    case .prefs: L10n.Map.Map.Gps.Advert.saved
    case .share: L10n.Map.Map.Gps.Advert.live
    }
  }
}

/// The Location Settings card's one line: only the settings that exist for this radio, e.g.
/// "Receiver On · Advert: Saved Position · Phone → Radio Off", or "No radio".
enum GNSSSettingsSummary {
  static func text(
    isConnected: Bool,
    receiver: DeviceGPSState?,
    advert: AdvertLocationPolicy,
    usesPhoneLocation: Bool
  ) -> String {
    guard isConnected else { return L10n.Localizable.Home.noRadio }
    var parts: [String] = []
    if let receiver, receiver.isSupported {
      parts.append(L10n.Map.Map.Gps.Summary.receiver(onOff(receiver.isEnabled)))
    }
    parts.append(L10n.Map.Map.Gps.Summary.advert(advert.gnssText))
    parts.append(L10n.Map.Map.Gps.Summary.phoneToRadio(onOff(usesPhoneLocation)))
    return parts.joined(separator: " · ")
  }

  private static func onOff(_ isOn: Bool) -> String {
    isOn ? L10n.Localizable.Home.Gps.on : L10n.Localizable.Home.Gps.off
  }
}

extension GNSSMapFraming {
  /// How many nodes the preview shows and frames at most.
  static let nearbyLimit = 25
  /// How far from the radio (or the phone) a node may be and still be framed: about a day's
  /// mesh range, so one far-off node doesn't zoom the preview out to a continent.
  static let nearbyRadius: CLLocationDistance = 50_000

  /// The items nearest `anchor`, closest first, within `radius` and at most `limit` of them.
  static func nearby<Item>(
    _ items: [Item],
    coordinate: (Item) -> CLLocationCoordinate2D,
    around anchor: CLLocationCoordinate2D,
    limit: Int = nearbyLimit,
    radius: CLLocationDistance = nearbyRadius
  ) -> [Item] {
    let origin = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
    return items
      .map { item -> (item: Item, distance: CLLocationDistance) in
        let point = coordinate(item)
        return (item, origin.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)))
      }
      .filter { $0.distance <= radius }
      .sorted { $0.distance < $1.distance }
      .prefix(max(limit, 0))
      .map(\.item)
  }
}

extension GPSFormat {
  /// "±5 m": a horizontal or vertical accuracy.
  static func accuracyText(_ meters: CLLocationAccuracy) -> String {
    "±\(lengthText(meters))"
  }
}

/// The reading tiles each side really has, so the page never keeps a tile that can only say "—":
/// the radio's altitude only once it has had a fix, the phone's speed whenever its fix carries one,
/// its course only while it moves, altitude only when the fix has one.
enum GNSSReadings {
  /// Below about 1 mph the course over ground is noise; Cairn hides its needle under 0.9 kn too.
  static let movingSpeed: CLLocationSpeed = 0.46

  static func radio(_ reading: RadioGPSReading, now: Date) -> [GNSSReading] {
    var readings: [GNSSReading] = []
    if let altitude = reading.altitude {
      readings.append(GNSSReading(
        id: "radio.altitude",
        title: L10n.Map.Map.Gps.Reading.radioAltitude,
        systemImage: "mountain.2",
        value: GPSFormat.lengthText(altitude)
      ))
    }
    // The radio doesn't timestamp its fixes, so when the app last heard from it is the freshest
    // time the page can honestly show.
    if let readAt = reading.readAt {
      readings.append(GNSSReading(
        id: "radio.updated",
        title: L10n.Map.Map.Gps.Reading.radioUpdated,
        systemImage: "clock",
        value: GPSFormat.fixAgeText(now.timeIntervalSince(readAt)),
        caption: readAt.formatted(date: .omitted, time: .shortened)
      ))
    }
    return readings
  }

  /// Both sides' readings in one two-column grid, each once and labelled by source: the radio's
  /// down the left (its altitude, how far it is from the phone when both positions are known, when
  /// it was last heard) and the phone's down the right (its altitude, how old its fix is, then its
  /// movement), so each reading sits under its own device's card; then the next sunrise or sunset.
  static func combined(
    radio reading: RadioGPSReading,
    radioPosition: CLLocation?,
    phone fix: CLLocation?,
    now: Date
  ) -> [GNSSReading] {
    var distance: [GNSSReading] = []
    if let radioPosition, let fix {
      let differs = GPSFormat.positionsDiffer(fix, radioPosition)
      distance.append(GNSSReading(
        id: "both.distance",
        title: L10n.Map.Map.Gps.Reading.distance,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        value: GPSFormat.lengthText(fix.distance(from: radioPosition)),
        caption: differs
          ? GPSFormat.bearingText(GPSFormat.bearing(from: fix.coordinate, to: radioPosition.coordinate))
          : L10n.Map.Map.Gps.Relation.together
      ))
    }
    let isAltitude: (GNSSReading) -> Bool = { $0.id.hasSuffix(".altitude") }
    let isUpdated: (GNSSReading) -> Bool = { $0.id.hasSuffix(".updated") }
    let radioReadings = radio(reading, now: now)
    let phoneReadings = phone(fix, now: now)
    let left = radioReadings.filter(isAltitude) + distance + radioReadings.filter { !isAltitude($0) }
    let right = phoneReadings.filter(isAltitude) + phoneReadings.filter(isUpdated)
      + phoneReadings.filter { !isAltitude($0) && !isUpdated($0) }
    // Left, right, left, right while both columns have readings; then the longer one's rest.
    var grid: [GNSSReading] = []
    for index in 0..<max(left.count, right.count) {
      if index < left.count { grid.append(left[index]) }
      if index < right.count { grid.append(right[index]) }
    }
    let daylight = daylight(at: fix?.coordinate ?? radioPosition?.coordinate, now: now)
    return grid + [daylight].compactMap(\.self)
  }

  /// The GPS tab's own grid: the readings that aren't on a device card. The altitudes and "updated"
  /// times sit on their devices' cards and the distance on the radio's, so the grid keeps the
  /// phone's movement (the sun has its own card under it, the compass page's).
  /// The radio card's lines under its position: its altitude, then how far it is from the phone.
  static func radioCardLines(radio reading: RadioGPSReading, radioPosition: CLLocation?, phone fix: CLLocation?) -> [GNSSReading] {
    var lines: [GNSSReading] = []
    if let altitude = reading.altitude {
      lines.append(GNSSReading(
        id: "radio.altitude",
        title: L10n.Map.Map.Gps.Reading.radioAltitude,
        systemImage: "mountain.2",
        value: GPSFormat.lengthText(altitude)
      ))
    }
    if let radioPosition, let fix {
      let differs = GPSFormat.positionsDiffer(fix, radioPosition)
      lines.append(GNSSReading(
        id: "both.distance",
        title: L10n.Map.Map.Gps.Reading.distance,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        value: differs ? GPSFormat.lengthText(fix.distance(from: radioPosition)) : L10n.Map.Map.Gps.Relation.together,
        caption: differs ? GPSFormat.bearingText(GPSFormat.bearing(from: fix.coordinate, to: radioPosition.coordinate)) : nil
      ))
    }
    return lines
  }

  /// "3m ago" for a device card's corner, nil before the first reading.
  static func updatedText(_ date: Date?, now: Date) -> String? {
    date.map { GPSFormat.fixAgeText(max(now.timeIntervalSince($0), 0)) }
  }

  /// How long a fix's speed stands in for later fixes that carry none.
  static let speedHold: TimeInterval = 30

  /// The speed to show: the current fix's, else the last one's while it's recent; 0 below walking
  /// pace, where GPS speed is noise. Nil when nothing recent has carried a speed.
  static func steadySpeed(current: CLLocation?, lastWithSpeed: CLLocation?, now: Date) -> CLLocationSpeed? {
    let source: CLLocation? = if let current, current.speed >= 0 {
      current
    } else if let lastWithSpeed, now.timeIntervalSince(lastWithSpeed.timestamp) <= speedHold {
      lastWithSpeed
    } else {
      nil
    }
    return source.map { $0.speed >= movingSpeed ? $0.speed : 0 }
  }

  /// The phone's course over ground, only while it is moving.
  static func course(of fix: CLLocation?) -> CLLocationDirection? {
    guard let fix, fix.speed >= movingSpeed, fix.course >= 0 else { return nil }
    return fix.course
  }

  static func phone(_ fix: CLLocation?, now: Date) -> [GNSSReading] {
    guard let fix else { return [] }
    var readings: [GNSSReading] = []
    // Negative vertical accuracy means the fix has no altitude.
    if fix.verticalAccuracy >= 0 {
      readings.append(GNSSReading(
        id: "phone.altitude",
        title: L10n.Map.Map.Gps.Reading.phoneAltitude,
        systemImage: "mountain.2",
        value: GPSFormat.lengthText(fix.altitude),
        caption: GPSFormat.accuracyText(fix.verticalAccuracy)
      ))
    }
    // Shown whenever the fix carries a speed (negative means none): standing still reads 0
    // rather than vanishing, so the reading doesn't come and go at walking pace.
    if fix.speed >= 0 {
      readings.append(GNSSReading(
        id: "phone.speed",
        title: L10n.Map.Map.Gps.speed,
        systemImage: "speedometer",
        value: GPSFormat.speedText(fix.speed >= movingSpeed ? fix.speed : 0),
        caption: fix.speedAccuracy >= 0 ? "±\(GPSFormat.speedText(fix.speedAccuracy))" : nil
      ))
    }
    if let course = course(of: fix) {
      readings.append(GNSSReading(
        id: "phone.course",
        title: L10n.Map.Map.Gps.course,
        systemImage: "safari",
        value: GPSFormat.bearingText(course),
        caption: fix.courseAccuracy >= 0 ? "±\(Int(fix.courseAccuracy.rounded()))°" : nil
      ))
    }
    // How old the phone's fix is, beside the radio's: a fix the phone stopped updating (indoors,
    // Low Power Mode) reads as stale here rather than passing for live.
    readings.append(GNSSReading(
      id: "phone.updated",
      title: L10n.Map.Map.Gps.Reading.phoneUpdated,
      systemImage: "clock",
      value: GPSFormat.fixAgeText(max(now.timeIntervalSince(fix.timestamp), 0)),
      caption: fix.timestamp.formatted(date: .omitted, time: .shortened)
    ))
    return readings
  }

  /// The next sunrise or sunset where the devices are (the phone's fix, else the radio's
  /// position): the time and how long until it, from the compass's `SolarCalculator`. Nothing
  /// without a position, or through a polar day or night.
  static func daylight(at coordinate: CLLocationCoordinate2D?, now: Date) -> GNSSReading? {
    guard let coordinate, let event = nextSunEvent(after: now, at: coordinate) else { return nil }
    return GNSSReading(
      id: "sun.next",
      title: event.isSunrise ? L10n.Map.Map.Gps.Reading.sunrise : L10n.Map.Map.Gps.Reading.sunset,
      systemImage: event.isSunrise ? "sunrise" : "sunset",
      value: event.date.formatted(date: .omitted, time: .shortened),
      caption: L10n.Map.Map.Gps.Reading.inTime(GPSFormat.shortDuration(event.date.timeIntervalSince(now)))
    )
  }

  /// Today's sunrise or sunset still to come, else tomorrow's sunrise.
  static func nextSunEvent(
    after now: Date,
    at coordinate: CLLocationCoordinate2D,
    timeZone: TimeZone = .current
  ) -> (date: Date, isSunrise: Bool)? {
    for offset in 0...1 {
      let day = now.addingTimeInterval(Double(offset) * 86_400)
      guard case let .times(sunrise, sunset) = SolarCalculator.sunTimes(
        on: day, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: timeZone
      ) else { continue }
      if sunrise > now { return (sunrise, true) }
      if sunset > now { return (sunset, false) }
    }
    return nil
  }
}

