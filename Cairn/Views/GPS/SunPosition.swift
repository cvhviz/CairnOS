import Foundation

/// Where the sun stands in the sky right now, for the compass's sun marker: its azimuth (degrees
/// clockwise from true north) and elevation above the horizon. NOAA's solar position equations,
/// good to a fraction of a degree, which is finer than any phone compass. `SolarCalculator` gives
/// the day's sunrise and sunset; this gives the sun's place at one moment.
enum SunPosition {
  struct Result: Equatable {
    let azimuth: Double
    let elevation: Double

    /// Whether the sun is up: the top of its disc above the horizon, refraction included.
    var isUp: Bool { elevation > -0.833 }
  }

  static func at(_ date: Date, latitude: Double, longitude: Double) -> Result {
    let julianDay = date.timeIntervalSince1970 / 86400 + 2_440_587.5
    let t = (julianDay - 2_451_545) / 36525

    let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
    let meanAnomaly = radians(357.52911 + t * (35999.05029 - 0.0001537 * t))
    let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    let centre = sin(meanAnomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
      + sin(2 * meanAnomaly) * (0.019993 - 0.000101 * t)
      + sin(3 * meanAnomaly) * 0.000289
    let omega = radians(125.04 - 1934.136 * t)
    let apparentLongitude = radians(meanLongitude + centre - 0.00569 - 0.00478 * sin(omega))
    let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
    let obliquity = radians(meanObliquity + 0.00256 * cos(omega))
    let declination = asin(sin(obliquity) * sin(apparentLongitude))

    // The equation of time, in minutes: how far the sun runs ahead of or behind the clock.
    let y = pow(tan(obliquity / 2), 2)
    let l0 = radians(meanLongitude)
    let equationOfTime = 4 * degrees(
      y * sin(2 * l0)
        - 2 * eccentricity * sin(meanAnomaly)
        + 4 * eccentricity * y * sin(meanAnomaly) * cos(2 * l0)
        - 0.5 * y * y * sin(4 * l0)
        - 1.25 * eccentricity * eccentricity * sin(2 * meanAnomaly)
    )

    let minutesUTC = (julianDay + 0.5 - (julianDay + 0.5).rounded(.down)) * 1440
    var solarMinutes = (minutesUTC + equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
    if solarMinutes < 0 { solarMinutes += 1440 }
    let hourAngle = radians(solarMinutes / 4 - 180)

    let latitude = radians(latitude)
    let cosZenith = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
    let elevation = 90 - degrees(acos(min(1, max(-1, cosZenith))))
    let azimuth = degrees(atan2(sin(hourAngle), cos(hourAngle) * sin(latitude) - tan(declination) * cos(latitude))) + 180
    return Result(azimuth: GPSFormat.normalizedDegrees(azimuth), elevation: elevation)
  }

  private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
  private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
