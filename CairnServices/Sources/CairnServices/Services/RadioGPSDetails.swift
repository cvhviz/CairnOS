import Foundation

/// What a radio's GPS receiver knows beyond its position: Cairn firmware's `gps_info` custom var
/// (`src/helpers/sensors/GpsInfoFormat.h`), "sats/in view/hdop x 10/knots x 1000/degrees x 1000/ms since
/// the last sentence/fix". What the receiver doesn't say arrives as -1, here nil. Other firmware doesn't
/// send it, so a radio's details are nil there.
public struct RadioGPSDetails: Sendable, Equatable {
  public let satellites: Int?
  public let satellitesInView: Int?
  public let hdop: Double?
  public let metersPerSecond: Double?
  public let courseDegrees: Double?
  /// Seconds since the receiver last sent anything.
  public let secondsSinceSignal: TimeInterval?
  public let hasFix: Bool

  private static let metersPerSecondPerKnot = 0.514444

  /// Nil unless the value has at least the seven fields; a later firmware may add more after them.
  public init?(customVar value: String) {
    let fields = value.split(separator: "/", omittingEmptySubsequences: false).map { Int($0) }
    guard fields.count >= 7, fields.prefix(7).allSatisfy({ $0 != nil }) else { return nil }
    func known(_ index: Int) -> Int? {
      fields[index].flatMap { $0 >= 0 ? $0 : nil }
    }
    satellites = known(0)
    satellitesInView = known(1)
    hdop = known(2).map { Double($0) / 10 }
    metersPerSecond = known(3).map { Double($0) / 1000 * Self.metersPerSecondPerKnot }
    courseDegrees = known(4).map { Double($0) / 1000 }
    secondsSinceSignal = known(5).map { TimeInterval($0) / 1000 }
    hasFix = known(6) == 1
  }
}
