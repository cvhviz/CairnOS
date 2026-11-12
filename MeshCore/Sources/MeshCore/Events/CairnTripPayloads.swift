import Foundation

// MARK: - Cairn trip logs (firmware's examples/companion_radio/ui-l2/net/TRIP_SYNC.md)

/// The ops of ``CairnFirmwareSubcommand/trips``: `[0xC0][0x09][op][...]`.
public enum CairnTripOp: UInt8, Sendable {
  case state = 0x00
  case start = 0x01
  case stop = 0x02
  case list = 0x03
  case points = 0x04
  case delete = 0x05
}

/// A trip-log reply's status.
public enum CairnTripStatus: UInt8, Sendable, Equatable {
  case ok = 0
  /// No card in the radio, or it would not mount.
  case noCard = 1
  /// The card is held for something else, or still mounting: ask again in a few seconds.
  case busy = 2
  /// No log of that name on the card.
  case notFound = 3
  /// START: the radio's GPS is off, or it has none.
  case gpsOff = 4
  /// START: the radio's clock is not set yet.
  case noClock = 5
  /// DELETE: that log is the one being recorded.
  case recording = 6
  /// A card write failed.
  case failed = 7
  /// A status this app does not know.
  case unknown = 0xFF

  init(byte: UInt8) { self = CairnTripStatus(rawValue: byte) ?? .unknown }
}

/// The radio's recorder: STATE, and the reply to START and STOP.
public struct CairnTripState: Sendable, Equatable {
  public let isRecording: Bool
  /// A card is in the radio.
  public let hasCard: Bool
  /// The radio's GPS has a fix now.
  public let hasFix: Bool
  /// The radio's GPS is on (On or Eco).
  public let isGPSOn: Bool
  /// The logs the radio last listed (a hint).
  public let logCount: Int
  /// The running log's points so far.
  public let points: Int
  /// When the running log started.
  public let startedAt: Date?
  /// The running log's file name, empty when none runs.
  public let name: String

  public init(
    isRecording: Bool, hasCard: Bool, hasFix: Bool, isGPSOn: Bool,
    logCount: Int, points: Int, startedAt: Date?, name: String
  ) {
    self.isRecording = isRecording
    self.hasCard = hasCard
    self.hasFix = hasFix
    self.isGPSOn = isGPSOn
    self.logCount = logCount
    self.points = points
    self.startedAt = startedAt
    self.name = name
  }
}

/// One of the card's logs, as LIST tells it: the radio's own numbers for it.
public struct CairnTripLogEntry: Sendable, Equatable {
  /// The file name on the card, e.g. `TRIP_20261109_142205.trk`: the log's identity on that radio.
  public let name: String
  public let startedAt: Date
  /// The last point (Stop, once stopped).
  public let endedAt: Date
  public let points: Int
  public let distance: Double
  public let movingTime: TimeInterval
  public let climb: Double
  public let descent: Double
  public let isRecording: Bool

  public init(
    name: String, startedAt: Date, endedAt: Date, points: Int, distance: Double,
    movingTime: TimeInterval, climb: Double, descent: Double, isRecording: Bool
  ) {
    self.name = name
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.points = points
    self.distance = distance
    self.movingTime = movingTime
    self.climb = climb
    self.descent = descent
    self.isRecording = isRecording
  }
}

/// One recorded point.
public struct CairnTripPoint: Sendable, Equatable {
  public let time: Date
  public let latitude: Double
  public let longitude: Double
  /// Metres; nil when the radio's GPS gave none.
  public let altitude: Double?

  public init(time: Date, latitude: Double, longitude: Double, altitude: Double?) {
    self.time = time
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
  }
}

/// A trip-log reply (``MeshEvent/cairnTripReply(_:)``).
public enum CairnTripReply: Sendable, Equatable {
  /// STATE, START or STOP; a refused START carries its reason in `status`.
  case state(op: CairnTripOp, status: CairnTripStatus, CairnTripState)
  /// A page of the card's logs, newest first.
  case list(status: CairnTripStatus, total: Int, from: Int, entries: [CairnTripLogEntry])
  /// A page of one log's points.
  case points(status: CairnTripStatus, total: Int, from: Int, points: [CairnTripPoint])
  /// DELETE's answer.
  case deleted(status: CairnTripStatus)

  var op: CairnTripOp {
    switch self {
    case let .state(op, _, _): op
    case .list: .list
    case .points: .points
    case .deleted: .delete
    }
  }
}
