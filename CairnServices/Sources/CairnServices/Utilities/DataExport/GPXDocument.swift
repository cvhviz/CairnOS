import Foundation

/// A GPX 1.1 waypoint.
public struct GPXWaypoint: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double
  public let name: String
  public let description: String?
  public let time: Date?
  public let type: String?

  public init(
    latitude: Double,
    longitude: Double,
    name: String,
    description: String? = nil,
    time: Date? = nil,
    type: String? = nil
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.name = name
    self.description = description
    self.time = time
    self.type = type
  }
}

/// Renders GPX 1.1 documents containing waypoints.
public enum GPXDocument {
  public static func render(waypoints: [GPXWaypoint], creator: String = "Cairn", name: String? = nil) -> String {
    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="\(escape(creator))" xmlns="http://www.topografix.com/GPX/1/1" \
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
    xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">

    """
    if let name {
      xml += "  <metadata>\n    <name>\(escape(name))</name>\n  </metadata>\n"
    }
    for waypoint in waypoints {
      let lat = ExportFormat.number(waypoint.latitude, fractionDigits: 7) ?? "0"
      let lon = ExportFormat.number(waypoint.longitude, fractionDigits: 7) ?? "0"
      xml += "  <wpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
      // GPX 1.1 schema order: time, name, desc, type.
      if let time = ExportFormat.timestamp(waypoint.time) {
        xml += "    <time>\(time)</time>\n"
      }
      xml += "    <name>\(escape(waypoint.name))</name>\n"
      if let description = waypoint.description {
        xml += "    <desc>\(escape(description))</desc>\n"
      }
      if let type = waypoint.type {
        xml += "    <type>\(escape(type))</type>\n"
      }
      xml += "  </wpt>\n"
    }
    xml += "</gpx>\n"
    return xml
  }

  /// A GPX 1.1 track: one segment of points in time order, each with its elevation and time when known
  /// (the Trips page's export: Gaia, Strava, Google Earth read it).
  public static func renderTrack(
    points: [(latitude: Double, longitude: Double, elevation: Double?, time: Date?)],
    creator: String = "Cairn",
    name: String? = nil
  ) -> String {
    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="\(escape(creator))" xmlns="http://www.topografix.com/GPX/1/1" \
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
    xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">

    """
    if let name {
      xml += "  <metadata>\n    <name>\(escape(name))</name>\n  </metadata>\n"
    }
    xml += "  <trk>\n"
    if let name { xml += "    <name>\(escape(name))</name>\n" }
    xml += "    <trkseg>\n"
    for point in points {
      let lat = ExportFormat.number(point.latitude, fractionDigits: 7) ?? "0"
      let lon = ExportFormat.number(point.longitude, fractionDigits: 7) ?? "0"
      xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
      // GPX 1.1 schema order: ele, then time
      if let elevation = point.elevation, let ele = ExportFormat.number(elevation, fractionDigits: 1) {
        xml += "        <ele>\(ele)</ele>\n"
      }
      if let time = ExportFormat.timestamp(point.time) {
        xml += "        <time>\(time)</time>\n"
      }
      xml += "      </trkpt>\n"
    }
    xml += "    </trkseg>\n  </trk>\n</gpx>\n"
    return xml
  }

  /// Escapes XML special characters and drops characters XML 1.0 cannot carry.
  public static func escape(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": output += "&amp;"
      case "<": output += "&lt;"
      case ">": output += "&gt;"
      case "\"": output += "&quot;"
      case "'": output += "&apos;"
      case "\t", "\n", "\r": output.unicodeScalars.append(scalar)
      default:
        // XML 1.0 forbids other C0 controls and the U+FFFE/U+FFFF noncharacters.
        if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
        output.unicodeScalars.append(scalar)
      }
    }
    return output
  }
}
