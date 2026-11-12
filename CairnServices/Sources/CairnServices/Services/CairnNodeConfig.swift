import Foundation

/// A Cairn repeater's settings in one CLI reply (`get cairn.cfg`), so the admin dashboard's cards fill
/// from one round trip over the mesh instead of nine single gets:
///
///     > la=40.123456|lo=-75.654321|r=910.525,62.5,7,5|tx=9|txm=16|txa=23,28|rp=on|ai=240|fai=12|fm=64|n=Hilltop Rpt
///
/// Short keys, `|` between them, the name last (`n=` runs to the end, so a `|` or `=` in a name is
/// kept). Units as the single gets: `ai` minutes, `fai` hours, `fm` hops. `tx` is the radio chip's
/// setting (what `set tx` takes); newer Cairn firmware adds `txm`, the highest setting the node takes,
/// and `txa`, the power at the antenna for the setting and for that maximum (more than the setting on
/// a board with a PA: a T096 at 9 radiates 23 dBm). Older Cairn firmware leaves those out. A stock
/// MeshCore node answers the query as an unknown setting, which `parse` returns nil for: callers then
/// fall back to the single gets.
public struct CairnNodeConfig: Sendable, Equatable {
  public var latitude: Double
  public var longitude: Double
  public var frequency: Double
  public var bandwidth: Double
  public var spreadingFactor: Int
  public var codingRate: Int
  /// The radio chip's TX power setting, dBm.
  public var txPower: Int
  /// The highest setting the node takes (`txm`); nil from older firmware.
  public var txPowerMax: Int?
  /// The power at the antenna for ``txPower`` (`txa`, first value); nil from older firmware.
  public var txAntennaPower: Int?
  /// The power at the antenna for ``txPowerMax`` (`txa`, second value); nil from older firmware.
  public var txAntennaMax: Int?
  public var repeatEnabled: Bool
  public var advertIntervalMinutes: Int
  public var floodAdvertIntervalHours: Int
  public var floodMaxHops: Int
  public var name: String

  public static let query = "get cairn.cfg"

  /// The highest TX power setting assumed for a node that doesn't report one (stock or older
  /// firmware): the SX1262's own maximum, which every supported chip shares.
  public static let defaultTxPowerMax = 22

  /// The lowest TX power setting any supported chip takes.
  public static let txPowerFloor = -9

  /// The settings a remote TX control offers: the chip's floor up to the node's maximum (or
  /// ``defaultTxPowerMax``). Never widened for a stored value outside it: older firmware saved any
  /// `set tx` unchecked, but its radio never applied one past the chip's range, so offering such
  /// values would only let the app store them again. A control shows that value on its own instead.
  public static func txPowerRange(maximum: Int?) -> ClosedRange<Int> {
    txPowerFloor...max(maximum ?? defaultTxPowerMax, txPowerFloor)
  }

  /// The range in a refused `set tx` reply ("Error: range -9..16", Cairn firmware), so a control
  /// that offered more (the node's maximum unknown) can narrow to what the node takes.
  public static func txPowerRange(fromRefusal reply: String) -> ClosedRange<Int>? {
    guard let match = reply.firstMatch(of: /range\s+(-?\d+)\s*\.\.\s*(-?\d+)/),
          let low = Int(match.output.1), let high = Int(match.output.2), low <= high else { return nil }
    return low...high
  }

  public static func parse(_ text: String) -> CairnNodeConfig? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("> ") { body = String(body.dropFirst(2)) }
    guard let nameRange = body.range(of: "|n=") else { return nil }
    let name = String(body[nameRange.upperBound...])
    var fields: [String: String] = [:]
    for part in body[..<nameRange.lowerBound].split(separator: "|") {
      guard let eq = part.firstIndex(of: "=") else { return nil }
      fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
    }
    let radio = (fields["r"] ?? "").split(separator: ",").map { String($0) }
    guard
      let latitude = fields["la"].flatMap(Double.init),
      let longitude = fields["lo"].flatMap(Double.init),
      radio.count == 4,
      let frequency = Double(radio[0]), let bandwidth = Double(radio[1]),
      let spreadingFactor = Int(radio[2]), let codingRate = Int(radio[3]),
      let txPower = fields["tx"].flatMap(Int.init),
      let repeatText = fields["rp"], repeatText == "on" || repeatText == "off",
      let advert = fields["ai"].flatMap(Int.init),
      let floodAdvert = fields["fai"].flatMap(Int.init),
      let floodMax = fields["fm"].flatMap(Int.init)
    else { return nil }
    let antenna = (fields["txa"] ?? "").split(separator: ",").compactMap { Int($0) }
    return CairnNodeConfig(
      latitude: latitude, longitude: longitude, frequency: frequency, bandwidth: bandwidth,
      spreadingFactor: spreadingFactor, codingRate: codingRate, txPower: txPower,
      txPowerMax: fields["txm"].flatMap(Int.init),
      txAntennaPower: antenna.count == 2 ? antenna[0] : nil,
      txAntennaMax: antenna.count == 2 ? antenna[1] : nil,
      repeatEnabled: repeatText == "on", advertIntervalMinutes: advert,
      floodAdvertIntervalHours: floodAdvert, floodMaxHops: floodMax, name: name
    )
  }
}

extension CairnNodeConfig {
  /// Whether a reply to ``query`` is a node saying it has no such setting (stock MeshCore answers
  /// "??: cairn.cfg"), as against a reply lost or mixed up with another command's.
  public static func isUnsupportedReply(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("??") || lower.contains("unknown")
  }
}

/// The nodes known to answer ``CairnNodeConfig/query`` as an unknown setting, kept per node so a
/// stock repeater isn't asked again on every visit. Asked again after ``reprobeInterval``, or as
/// soon as the node reports a different firmware (it may have been flashed with Cairn).
public enum CairnNodeConfigSupport {
  public static let reprobeInterval: TimeInterval = 7 * 24 * 60 * 60

  struct Record: Codable, Equatable {
    var firmwareVersion: String?
    var checkedAt: Date
  }

  static func key(for publicKey: Data) -> String {
    "cairnConfigUnsupported." + publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// True when the node answered as unsupported within ``reprobeInterval`` and, when both are
  /// known, on the firmware it reports now.
  public static func isKnownUnsupported(
    publicKey: Data,
    firmwareVersion: String?,
    now: Date = Date(),
    defaults: UserDefaults = .standard
  ) -> Bool {
    guard let data = defaults.data(forKey: key(for: publicKey)),
          let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
    guard now.timeIntervalSince(record.checkedAt) < reprobeInterval else { return false }
    if let firmwareVersion, let checked = record.firmwareVersion, firmwareVersion != checked { return false }
    return true
  }

  public static func markUnsupported(
    publicKey: Data,
    firmwareVersion: String?,
    now: Date = Date(),
    defaults: UserDefaults = .standard
  ) {
    let record = Record(firmwareVersion: firmwareVersion, checkedAt: now)
    guard let data = try? JSONEncoder().encode(record) else { return }
    defaults.set(data, forKey: key(for: publicKey))
  }

  /// The node answered the query: forget any earlier unsupported answer.
  public static func markSupported(publicKey: Data, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(for: publicKey))
  }
}
