import Foundation
import SwiftData

/// A trip a radio recorded on its card (Cairn firmware's trip logs, `net/TRIP_SYNC.md`), as this phone
/// copied it: the radio's own numbers for it, and how many of its points are here (`TripLogPoint`). The
/// radio is the recorder; the phone keeps copies for offline use. A log's identity is its radio and its
/// file name. Scalar fields only and no relationships, so adding it is a lightweight migration. Kept on
/// this phone alone, like the rest of the store, and left out of backups.
@Model
final class TripLog {
  #Index<TripLog>([\.startedAt])

  /// `TripLogDTO.makeID(radioID:name:)`
  @Attribute(.unique)
  var id: String
  var radioID: UUID
  /// The radio's name when the log was last listed.
  var radioName: String
  /// The file on the radio's card, e.g. `TRIP_20261109_142205.trk`.
  var name: String
  var startedAt: Date
  var endedAt: Date
  /// The radio's point count at its last listing.
  var pointCount: Int
  /// Points copied here (indices 0..<syncedCount).
  var syncedCount: Int
  /// The radio's numbers (metres, seconds), as its Trip page shows them.
  var distance: Double
  var movingTime: Double
  var climb: Double
  var descent: Double
  var isRecording: Bool
  /// Listed by its radio at that radio's last listing; false once the card no longer has it.
  var onRadio: Bool
  var updatedAt: Date

  init(_ dto: TripLogDTO) {
    id = dto.id
    radioID = dto.radioID
    radioName = dto.radioName
    name = dto.name
    startedAt = dto.startedAt
    endedAt = dto.endedAt
    pointCount = dto.pointCount
    syncedCount = dto.syncedCount
    distance = dto.distance
    movingTime = dto.movingTime
    climb = dto.climb
    descent = dto.descent
    isRecording = dto.isRecording
    onRadio = dto.onRadio
    updatedAt = .now
  }
}

public struct TripLogDTO: Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let radioID: UUID
  public let radioName: String
  public let name: String
  public let startedAt: Date
  public let endedAt: Date
  public let pointCount: Int
  public let syncedCount: Int
  public let distance: Double
  public let movingTime: TimeInterval
  public let climb: Double
  public let descent: Double
  public let isRecording: Bool
  public let onRadio: Bool

  public static func makeID(radioID: UUID, name: String) -> String { "\(radioID.uuidString)|\(name)" }

  /// Every point the radio had at its last listing is here.
  public var isComplete: Bool { syncedCount >= pointCount }

  public init(
    radioID: UUID, radioName: String, name: String, startedAt: Date, endedAt: Date, pointCount: Int,
    syncedCount: Int = 0, distance: Double, movingTime: TimeInterval, climb: Double, descent: Double,
    isRecording: Bool, onRadio: Bool = true
  ) {
    id = Self.makeID(radioID: radioID, name: name)
    self.radioID = radioID
    self.radioName = radioName
    self.name = name
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.pointCount = pointCount
    self.syncedCount = syncedCount
    self.distance = distance
    self.movingTime = movingTime
    self.climb = climb
    self.descent = descent
    self.isRecording = isRecording
    self.onRadio = onRadio
  }

  init(_ model: TripLog) {
    id = model.id
    radioID = model.radioID
    radioName = model.radioName
    name = model.name
    startedAt = model.startedAt
    endedAt = model.endedAt
    pointCount = model.pointCount
    syncedCount = model.syncedCount
    distance = model.distance
    movingTime = model.movingTime
    climb = model.climb
    descent = model.descent
    isRecording = model.isRecording
    onRadio = model.onRadio
  }
}

/// One point of a `TripLog`, as the radio recorded it.
@Model
final class TripLogPoint {
  #Index<TripLogPoint>([\.logID, \.index])

  @Attribute(.unique)
  var id: String
  var logID: String
  /// The point's place in its log, from 0.
  var index: Int
  var timestamp: Date
  var latitude: Double
  var longitude: Double
  /// Metres above sea level; nil when the radio's GPS gave none.
  var altitude: Double?

  init(logID: String, index: Int, point: TripLogPointDTO) {
    id = "\(logID)#\(index)"
    self.logID = logID
    self.index = index
    timestamp = point.timestamp
    latitude = point.latitude
    longitude = point.longitude
    altitude = point.altitude
  }
}

public struct TripLogPointDTO: Sendable, Equatable {
  public let timestamp: Date
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double?

  public init(timestamp: Date, latitude: Double, longitude: Double, altitude: Double?) {
    self.timestamp = timestamp
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
  }
}

/// A radio's step count for one day (Cairn firmware counts steps since local midnight and reports the
/// running total): the highest total read that day, so a reading taken before the day's last walk never
/// lowers it. One row per radio per day.
@Model
final class DailySteps {
  @Attribute(.unique)
  var id: String
  /// The day's local midnight.
  var day: Date
  var radioID: UUID
  var steps: Int
  var updatedAt: Date

  init(day: Date, radioID: UUID, steps: Int, updatedAt: Date) {
    id = Self.rowID(day: day, radioID: radioID)
    self.day = day
    self.radioID = radioID
    self.steps = steps
    self.updatedAt = updatedAt
  }

  static func rowID(day: Date, radioID: UUID) -> String {
    "\(Int(day.timeIntervalSince1970))|\(radioID.uuidString)"
  }
}

public struct DailyStepsDTO: Sendable, Equatable, Identifiable {
  public let day: Date
  public let radioID: UUID
  public let steps: Int

  public var id: String { DailySteps.rowID(day: day, radioID: radioID) }

  public init(day: Date, radioID: UUID, steps: Int) {
    self.day = day
    self.radioID = radioID
    self.steps = steps
  }
}
