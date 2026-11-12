import Foundation
import Testing
@testable import CairnServices

@Suite("Trip persistence")
struct TripPersistenceTests {
  private func store() throws -> PersistenceStore {
    PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
  }

  private func entry(_ radio: UUID, _ name: String, points: Int, start: TimeInterval, recording: Bool = false) -> TripLogDTO {
    TripLogDTO(
      radioID: radio, radioName: "L2", name: name,
      startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: start + 3600),
      pointCount: points, distance: 5230, movingTime: 3000, climb: 320, descent: 288, isRecording: recording
    )
  }

  private func points(_ n: Int, from: Int = 0) -> [TripLogPointDTO] {
    (from ..< from + n).map {
      TripLogPointDTO(timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 10),
                      latitude: 45 + Double($0) * 0.0001, longitude: -122, altitude: $0 % 2 == 0 ? 100 : nil)
    }
  }

  @Test
  func `a listing adds logs newest first and keeps the copies of those gone from the card`() async throws {
    let store = try store()
    let radio = UUID()
    try await store.applyTripListing(radioID: radio, radioName: "L2", entries: [
      entry(radio, "TRIP_2.trk", points: 20, start: 2_000, recording: true),
      entry(radio, "TRIP_1.trk", points: 10, start: 1_000),
    ])
    var logs = try await store.fetchTripLogs()
    #expect(logs.map(\.name) == ["TRIP_2.trk", "TRIP_1.trk"])
    #expect(logs.allSatisfy { $0.onRadio && $0.syncedCount == 0 && !$0.isComplete })
    #expect(logs[0].isRecording)

    // the card no longer has TRIP_1 and TRIP_2 has stopped
    try await store.applyTripListing(radioID: radio, radioName: "L2", entries: [entry(radio, "TRIP_2.trk", points: 25, start: 2_000)])
    logs = try await store.fetchTripLogs()
    #expect(logs.count == 2)
    #expect(logs[0].pointCount == 25 && !logs[0].isRecording && logs[0].onRadio)
    #expect(!logs[1].onRadio)

    // another radio's listing leaves these alone
    try await store.applyTripListing(radioID: UUID(), radioName: "T-Deck", entries: [])
    #expect(try await store.fetchTripLogs().count == 2)
  }

  @Test
  func `points are copied in order without holes`() async throws {
    let store = try store()
    let radio = UUID()
    let log = entry(radio, "TRIP_1.trk", points: 20, start: 1_000)
    try await store.applyTripListing(radioID: radio, radioName: "L2", entries: [log])
    #expect(try await store.appendTripLogPoints(logID: log.id, from: 0, points: points(9), total: 20) == 9)
    // a page that does not continue the copy is refused
    #expect(try await store.appendTripLogPoints(logID: log.id, from: 18, points: points(2, from: 18), total: 20) == 9)
    #expect(try await store.appendTripLogPoints(logID: log.id, from: 9, points: points(11, from: 9), total: 22) == 20)
    let copied = try await store.fetchTripLogPoints(logID: log.id)
    #expect(copied == points(20))
    let row = try await store.fetchTripLog(id: log.id)
    #expect(row?.syncedCount == 20)
    #expect(row?.pointCount == 22)   // a running log grew meanwhile
    #expect(row?.isComplete == false)

    try await store.deleteTripLog(id: log.id)
    #expect(try await store.fetchTripLog(id: log.id) == nil)
    #expect(try await store.fetchTripLogPoints(logID: log.id).isEmpty)
  }

  @Test
  func `a day's steps keep the highest count`() async throws {
    let store = try store()
    let radio = UUID()
    let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    try await store.recordDailySteps(radioID: radio, day: day, steps: 1200)
    try await store.recordDailySteps(radioID: radio, day: day, steps: 800)    // an earlier read: ignored
    try await store.recordDailySteps(radioID: radio, day: day, steps: 4100)
    let rows = try await store.fetchDailySteps(since: day)
    #expect(rows == [DailyStepsDTO(day: day, radioID: radio, steps: 4100)])
  }
}
