import Foundation
import SwiftData

/// The Trips page's store: the radios' trip logs as this phone copied them (`TripLog`,
/// `TripLogPoint`), and their daily step totals (`DailySteps`).
extension PersistenceStore {
  // MARK: - Logs

  /// A radio's listing of its card: each log's numbers updated (or added, nothing copied yet), and its
  /// logs the listing no longer has marked as gone from the radio (their copies here stay).
  public func applyTripListing(radioID: UUID, radioName: String, entries: [TripLogDTO]) throws {
    let existing = try modelContext.fetch(FetchDescriptor<TripLog>(predicate: #Predicate { $0.radioID == radioID }))
    var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var listed = Set<String>()
    for entry in entries {
      listed.insert(entry.id)
      if let row = byID[entry.id] {
        row.radioName = radioName
        row.startedAt = entry.startedAt
        row.endedAt = entry.endedAt
        row.pointCount = max(entry.pointCount, row.syncedCount)
        row.distance = entry.distance
        row.movingTime = entry.movingTime
        row.climb = entry.climb
        row.descent = entry.descent
        row.isRecording = entry.isRecording
        row.onRadio = true
        row.updatedAt = .now
      } else {
        let row = TripLog(entry)
        modelContext.insert(row)
        byID[entry.id] = row
      }
    }
    for row in existing where !listed.contains(row.id) && (row.onRadio || row.isRecording) {
      row.onRadio = false
      row.isRecording = false
      row.updatedAt = .now
    }
    try modelContext.save()
  }

  /// Every log here, newest first.
  public func fetchTripLogs() throws -> [TripLogDTO] {
    try modelContext.fetch(FetchDescriptor<TripLog>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
      .map(TripLogDTO.init)
  }

  public func fetchTripLog(id: String) throws -> TripLogDTO? {
    try modelContext.fetch(FetchDescriptor<TripLog>(predicate: #Predicate { $0.id == id })).first.map(TripLogDTO.init)
  }

  /// Points copied from the radio, starting at `from`. Only a page that continues what is here is
  /// kept (`from` == the log's synced count), so the copy has no holes; returns the synced count after.
  /// `total` is the radio's count now (a running log's grows).
  @discardableResult
  public func appendTripLogPoints(logID: String, from: Int, points: [TripLogPointDTO], total: Int) throws -> Int {
    guard let row = try modelContext.fetch(FetchDescriptor<TripLog>(predicate: #Predicate { $0.id == logID })).first
    else { return 0 }
    guard from == row.syncedCount else { return row.syncedCount }
    for (offset, point) in points.enumerated() {
      modelContext.insert(TripLogPoint(logID: logID, index: from + offset, point: point))
    }
    row.syncedCount = from + points.count
    row.pointCount = max(total, row.syncedCount)
    if let last = points.last, last.timestamp > row.endedAt { row.endedAt = last.timestamp }
    row.updatedAt = .now
    try modelContext.save()
    return row.syncedCount
  }

  /// A log's points here, oldest first.
  public func fetchTripLogPoints(logID: String) throws -> [TripLogPointDTO] {
    let descriptor = FetchDescriptor<TripLogPoint>(
      predicate: #Predicate { $0.logID == logID },
      sortBy: [SortDescriptor(\.index)]
    )
    return try modelContext.fetch(descriptor).map {
      TripLogPointDTO(timestamp: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
    }
  }

  /// Removes this phone's copy of a log and its points (the radio's file is the radio's).
  public func deleteTripLog(id: String) throws {
    try modelContext.delete(model: TripLogPoint.self, where: #Predicate { $0.logID == id })
    try modelContext.delete(model: TripLog.self, where: #Predicate { $0.id == id })
    try modelContext.save()
  }

  // MARK: - Steps

  /// A step count read from a radio: kept as the day's total when it is the highest seen that day.
  public func recordDailySteps(radioID: UUID, day: Date, steps: Int, at now: Date = .now) throws {
    let id = DailySteps.rowID(day: day, radioID: radioID)
    let descriptor = FetchDescriptor<DailySteps>(predicate: #Predicate { $0.id == id })
    if let row = try modelContext.fetch(descriptor).first {
      guard steps > row.steps else { return }
      row.steps = steps
      row.updatedAt = now
    } else {
      modelContext.insert(DailySteps(day: day, radioID: radioID, steps: steps, updatedAt: now))
    }
    try modelContext.save()
  }

  /// Every radio's daily totals since `start`, oldest first.
  public func fetchDailySteps(since start: Date) throws -> [DailyStepsDTO] {
    let descriptor = FetchDescriptor<DailySteps>(
      predicate: #Predicate { $0.day >= start },
      sortBy: [SortDescriptor(\.day)]
    )
    return try modelContext.fetch(descriptor).map { DailyStepsDTO(day: $0.day, radioID: $0.radioID, steps: $0.steps) }
  }
}
