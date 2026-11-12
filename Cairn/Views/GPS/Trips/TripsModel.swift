import CairnServices
import Foundation
import MeshCore

/// The Trips page: the radios' trips as this phone knows them (copied or not, newest first), and the
/// last 14 days of steps (the highest of any radio's each day). Read from the store (`TripRecorder`
/// writes it); `load` again when the recorder's `version` moves.
@Observable
@MainActor
final class TripsModel {
  private(set) var logs: [TripLogDTO] = []
  /// The last 14 days, oldest first, a zero for a day without steps; empty when no radio ever reported any.
  private(set) var steps: [(day: Date, steps: Int)] = []
  private(set) var hasLoaded = false

  static let stepDays = 14

  func load(store: PersistenceStore) async {
    logs = (try? await store.fetchTripLogs()) ?? []
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    if let first = calendar.date(byAdding: .day, value: -(Self.stepDays - 1), to: today) {
      let rows = (try? await store.fetchDailySteps(since: first)) ?? []
      if rows.isEmpty {
        steps = []
      } else {
        steps = (0..<Self.stepDays).compactMap { offset in
          guard let d = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
          let best = rows.filter { calendar.isDate($0.day, inSameDayAs: d) }.map(\.steps).max() ?? 0
          return (d, best)
        }
      }
    }
    hasLoaded = true
  }
}

/// One trip's page: its record and its points worked out (`TripSummary`) from what is copied here.
@Observable
@MainActor
final class TripDetailModel {
  let id: String
  private(set) var log: TripLogDTO?
  private(set) var summary = TripSummary()
  private(set) var hasLoaded = false

  init(id: String) { self.id = id }

  func load(store: PersistenceStore) async {
    log = try? await store.fetchTripLog(id: id)
    let points = (try? await store.fetchTripLogPoints(logID: id)) ?? []
    summary = TripSummary(points)
    hasLoaded = true
  }
}

#if DEBUG
  /// Screenshot runs' sample (`-uiTestTrips YES`): a radio recording now, a two-hour walk up a 300 m hill
  /// and most of the way down copied here, an older trip only on the radio, and two weeks of steps.
  enum TripsDemo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "uiTestTrips") }
    static let radio = UUID(uuidString: "00000000-0000-0000-0000-0000000057e9") ?? UUID()

    static var state: CairnTripState {
      CairnTripState(
        isRecording: true, hasCard: true, hasFix: true, isGPSOn: true, logCount: 3, points: 41,
        startedAt: Date.now.addingTimeInterval(-25 * 60), name: "TRIP_demo_now.trk"
      )
    }

    static func seed(store: PersistenceStore) async {
      guard ((try? await store.fetchTripLogs()) ?? []).isEmpty else { return }
      let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(-86400 + 9 * 3600)
      let points = (0...240).map { i -> TripLogPointDTO in
        let f = Double(i) / 240
        return TripLogPointDTO(
          timestamp: start.addingTimeInterval(Double(i) * 30),
          latitude: 46.5 + f * 0.04,
          longitude: 8.0 + sin(f * 6) * 0.015,
          altitude: 1450 + 300 * sin(f * 3.1) + 4 * sin(Double(i) * 1.7)
        )
      }
      let walk = TripSummary(points)
      let entries = [
        TripLogDTO(radioID: radio, radioName: "Wio L2", name: "TRIP_demo_now.trk",
                   startedAt: state.startedAt ?? .now, endedAt: .now, pointCount: 41, distance: 1830,
                   movingTime: 1320, climb: 64, descent: 12, isRecording: true),
        TripLogDTO(radioID: radio, radioName: "Wio L2", name: "TRIP_demo_walk.trk",
                   startedAt: start, endedAt: start.addingTimeInterval(7200), pointCount: points.count,
                   distance: walk.distance, movingTime: walk.movingTime, climb: walk.climb, descent: walk.descent,
                   isRecording: false),
        TripLogDTO(radioID: radio, radioName: "Wio L2", name: "TRIP_demo_older.trk",
                   startedAt: start.addingTimeInterval(-4 * 86400), endedAt: start.addingTimeInterval(-4 * 86400 + 5400),
                   pointCount: 310, distance: 7420, movingTime: 4980, climb: 410, descent: 405, isRecording: false),
      ]
      try? await store.applyTripListing(radioID: radio, radioName: "Wio L2", entries: entries)
      _ = try? await store.appendTripLogPoints(
        logID: TripLogDTO.makeID(radioID: radio, name: "TRIP_demo_walk.trk"), from: 0, points: points, total: points.count
      )
      let today = Calendar.current.startOfDay(for: .now)
      for back in 0..<14 {
        guard let day = Calendar.current.date(byAdding: .day, value: -back, to: today) else { continue }
        let steps = back == 0 ? 9_412 : 3_000 + (back * 1_733) % 9_000
        try? await store.recordDailySteps(radioID: radio, day: day, steps: steps)
      }
    }
  }
#endif
