import Foundation

/// Today's sunrise and sunset for a position, from the NOAA solar calculator equations (Meeus):
/// the same method Cairn's Home strip uses (`SunCalc.h`), so the phone and the radio agree.
///
/// Pure and cheap (a few dozen trig calls), so Home recomputes it whenever it redraws the header
/// rather than caching it. Accurate to about a minute away from the poles.
enum SolarCalculator {
  enum Result: Equatable {
    case times(sunrise: Date, sunset: Date)
    /// The sun stays above the horizon all day (midsummer at high latitudes).
    case polarDay
    /// The sun stays below the horizon all day (midwinter at high latitudes).
    case polarNight
  }

  /// The sun's centre is this far below the horizon at sunrise and sunset: 0.833° for the
  /// sun's radius plus atmospheric refraction, the standard almanac value.
  private static let zenith = 90.833

  /// Sunrise and sunset on the calendar day `date` falls on in `timeZone`, at the given position
  /// (degrees; east and north positive). The returned times are absolute instants, so formatting
  /// them in `timeZone` gives the local clock times, daylight saving included.
  static func sunTimes(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> Result {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return .polarNight }

    // Julian day at 00:00 UTC of the local calendar date. Event times are minutes from that
    // instant and may fall outside 0..<1440 (Tokyo's sunrise is the UTC day before).
    let julianDay = julianDayAtMidnightUTC(year: year, month: month, day: dayOfMonth)
    let midnightUTC = Date(timeIntervalSince1970: (julianDay - 2_440_587.5) * 86400)

    // Polar day or night: the hour angle has no solution at local solar noon.
    let noon = julianDay + 0.5 - longitude / 360
    if let argument = hourAngleArgument(julianCentury: julianCentury(noon), latitude: latitude) {
      if argument < -1 { return .polarDay }
      if argument > 1 { return .polarNight }
    }

    guard let sunrise = eventMinutesUTC(rising: true, julianDay: julianDay, latitude: latitude, longitude: longitude),
          let sunset = eventMinutesUTC(rising: false, julianDay: julianDay, latitude: latitude, longitude: longitude) else {
      // Near the polar circles the refined pass can lose the event the noon check still found;
      // the sun barely crosses the horizon then, so call it by the noon elevation.
      return latitude * declination(julianCentury(noon)) > 0 ? .polarDay : .polarNight
    }
    return .times(
      sunrise: midnightUTC.addingTimeInterval(sunrise * 60),
      sunset: midnightUTC.addingTimeInterval(sunset * 60)
    )
  }

  // MARK: - Event times

  /// Minutes after 00:00 UTC of `julianDay` at which the sun rises or sets: a first estimate
  /// from the sun's position at midnight, then one pass recomputed at the estimated time.
  private static func eventMinutesUTC(rising: Bool, julianDay: Double, latitude: Double, longitude: Double) -> Double? {
    guard let estimate = eventMinutes(rising: rising, julianDay: julianDay, latitude: latitude, longitude: longitude) else {
      return nil
    }
    return eventMinutes(rising: rising, julianDay: julianDay + estimate / 1440, latitude: latitude, longitude: longitude)
      ?? estimate
  }

  private static func eventMinutes(rising: Bool, julianDay: Double, latitude: Double, longitude: Double) -> Double? {
    let century = julianCentury(julianDay)
    guard let argument = hourAngleArgument(julianCentury: century, latitude: latitude), abs(argument) <= 1 else {
      return nil
    }
    let hourAngle = degrees(acos(argument)) * (rising ? 1 : -1)
    return 720 - 4 * (longitude + hourAngle) - equationOfTime(century)
  }

  /// The cosine of the event's hour angle; outside -1...1 the sun never reaches the horizon.
  private static func hourAngleArgument(julianCentury century: Double, latitude: Double) -> Double? {
    let latitudeRadians = radians(latitude)
    let declinationRadians = radians(declination(century))
    let denominator = cos(latitudeRadians) * cos(declinationRadians)
    guard abs(denominator) > 1e-12 else { return nil }
    return cos(radians(zenith)) / denominator - tan(latitudeRadians) * tan(declinationRadians)
  }

  // MARK: - Solar position (NOAA)

  static func julianDayAtMidnightUTC(year: Int, month: Int, day: Int) -> Double {
    var year = year
    var month = month
    if month <= 2 {
      year -= 1
      month += 12
    }
    let century = (Double(year) / 100).rounded(.down)
    let gregorian = 2 - century + (century / 4).rounded(.down)
    return (365.25 * Double(year + 4716)).rounded(.down)
      + (30.6001 * Double(month + 1)).rounded(.down)
      + Double(day) + gregorian - 1524.5
  }

  private static func julianCentury(_ julianDay: Double) -> Double {
    (julianDay - 2_451_545) / 36525
  }

  private static func geometricMeanLongitude(_ t: Double) -> Double {
    var longitude = 280.46646 + t * (36000.76983 + t * 0.0003032)
    longitude = longitude.truncatingRemainder(dividingBy: 360)
    return longitude < 0 ? longitude + 360 : longitude
  }

  private static func geometricMeanAnomaly(_ t: Double) -> Double {
    357.52911 + t * (35999.05029 - 0.0001537 * t)
  }

  private static func orbitEccentricity(_ t: Double) -> Double {
    0.016708634 - t * (0.000042037 + 0.0000001267 * t)
  }

  private static func equationOfCentre(_ t: Double) -> Double {
    let anomaly = radians(geometricMeanAnomaly(t))
    return sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
      + sin(2 * anomaly) * (0.019993 - 0.000101 * t)
      + sin(3 * anomaly) * 0.000289
  }

  private static func apparentLongitude(_ t: Double) -> Double {
    let trueLongitude = geometricMeanLongitude(t) + equationOfCentre(t)
    return trueLongitude - 0.00569 - 0.00478 * sin(radians(125.04 - 1934.136 * t))
  }

  private static func obliquityCorrection(_ t: Double) -> Double {
    let seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
    let mean = 23 + (26 + seconds / 60) / 60
    return mean + 0.00256 * cos(radians(125.04 - 1934.136 * t))
  }

  private static func declination(_ t: Double) -> Double {
    degrees(asin(sin(radians(obliquityCorrection(t))) * sin(radians(apparentLongitude(t)))))
  }

  /// Minutes the sundial runs ahead of the clock.
  private static func equationOfTime(_ t: Double) -> Double {
    let obliquity = radians(obliquityCorrection(t))
    let meanLongitude = radians(geometricMeanLongitude(t))
    let eccentricity = orbitEccentricity(t)
    let anomaly = radians(geometricMeanAnomaly(t))
    let y = pow(tan(obliquity / 2), 2)

    let value = y * sin(2 * meanLongitude)
      - 2 * eccentricity * sin(anomaly)
      + 4 * eccentricity * y * sin(anomaly) * cos(2 * meanLongitude)
      - 0.5 * y * y * sin(4 * meanLongitude)
      - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
    return degrees(value) * 4
  }

  private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
  private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
