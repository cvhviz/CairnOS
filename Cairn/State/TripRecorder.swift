import CairnServices
import Foundation
import MeshCore
import OSLog

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "Trips")

/// The radio's trip recorder, from the phone (firmware's `net/TRIP_SYNC.md`). The radio is the recorder:
/// a Cairn radio with a card slot keeps each trip on its card from its own GPS, Start to Stop. The phone
/// starts and stops it (Record Trip), lists the card's trips and copies their points here when asked
/// (opening a trip, Copy All), so they can be seen offline (`TripLog`, `TripLogPoint`). The phone's own
/// GPS records nothing. All of it goes over the radio's link (Bluetooth, USB or Wi-Fi), never the mesh.
///
/// Also keeps the radio's daily step totals (`DailySteps`) from its readings.
@Observable
@MainActor
final class TripRecorder {
  enum Support: Equatable {
    /// No radio connected, or not asked yet.
    case unknown
    /// The connected radio has no trip logs (no card slot, or older firmware).
    case unsupported
    case supported
  }

  /// The connected radio's recorder as last read; nil without one.
  private(set) var radioState: CairnTripState?
  private(set) var support: Support = .unknown
  /// Start or Stop on its way to the radio.
  private(set) var isSwitching = false
  /// How much of each trip being copied is here: done of total.
  private(set) var copying: [String: (done: Int, total: Int)] = [:]
  /// Moves whenever the store's trips changed.
  private(set) var version = 0

  var isRecording: Bool { radioState?.isRecording ?? false }
  var recordingStartedAt: Date? { radioState?.startedAt }

  /// The connected radio's session and record (AppState sets it).
  @ObservationIgnored var connection: @MainActor () -> (session: MeshCoreSession, device: DeviceDTO)? = { nil }

  private let store: PersistenceStore
  @ObservationIgnored private var lastSteps: [UUID: (day: Date, steps: Int)] = [:]
  private static let timeout: TimeInterval = 6

  init(store: PersistenceStore) {
    self.store = store
  }

  /// The connected radio, when it's a Cairn radio that can answer (not the simulator's stand-in).
  private var radio: (session: MeshCoreSession, device: DeviceDTO)? {
    guard let link = connection(), link.device.isCairnFirmware,
          link.device.id != MockDataProvider.simulatorDeviceID else { return nil }
    return link
  }

  // MARK: - The radio's recorder

  /// Reads the radio's recorder (the Map tab's bar, the Trips page). Cheap: one short exchange.
  func refreshState() async {
    guard let radio else {
      #if DEBUG
        if TripsDemo.isOn { radioState = TripsDemo.state; support = .supported; return }
      #endif
      radioState = nil
      support = connection() == nil ? .unknown : .unsupported
      return
    }
    do {
      radioState = try await radio.session.cairnTripState(timeout: Self.timeout)
      support = .supported
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      radioState = nil
      support = .unsupported
    } catch {
      logger.info("Trip state not read: \(error.localizedDescription)")
    }
  }

  /// The recorder and the card's list of trips (the Trips page opening, after Start / Stop / a delete).
  func refresh() async {
    await refreshState()
    guard support == .supported, let radio else { return }
    do {
      let entries = try await radio.session.listCairnTrips(timeout: Self.timeout)
      let device = radio.device
      try await store.applyTripListing(radioID: device.radioID, radioName: device.nodeName, entries: entries.map {
        TripLogDTO(
          radioID: device.radioID, radioName: device.nodeName, name: $0.name, startedAt: $0.startedAt,
          endedAt: $0.endedAt, pointCount: $0.points, distance: $0.distance, movingTime: $0.movingTime,
          climb: $0.climb, descent: $0.descent, isRecording: $0.isRecording
        )
      })
      version += 1
    } catch {
      logger.info("Trip list not read: \(String(describing: error))")
    }
  }

  /// Record Trip / Stop Recording: the radio starts or stops. Returns why a start was refused (no card,
  /// GPS off, clock not set), nil when it did what was asked.
  func toggleRecording() async -> CairnTripStatus? {
    guard let radio, !isSwitching else { return nil }
    isSwitching = true
    defer { isSwitching = false }
    do {
      let (status, state) = isRecording
        ? try await radio.session.stopCairnTrip(timeout: Self.timeout)
        : try await radio.session.startCairnTrip(timeout: Self.timeout)
      radioState = state
      await refresh()
      return status == .ok ? nil : status
    } catch {
      logger.warning("Trip start / stop failed: \(String(describing: error))")
      return .failed
    }
  }

  // MARK: - Copies

  /// Whether `log` can be copied now: it is on the connected radio's card.
  func canCopy(_ log: TripLogDTO) -> Bool {
    guard let radio else { return false }
    return log.onRadio && log.radioID == radio.device.radioID
  }

  /// Copies a trip's points the phone doesn't have yet (all of it the first time, then only what a
  /// running one recorded since), 9 at a time. Opening a trip asks for this; so does Copy All.
  func copy(_ log: TripLogDTO) async {
    guard copying[log.id] == nil, canCopy(log), let radio else { return }
    var from = log.syncedCount
    copying[log.id] = (from, max(log.pointCount, from))
    defer { copying[log.id] = nil }
    var busyTries = 0
    var pages = 0
    while !Task.isCancelled {
      do {
        let page = try await radio.session.fetchCairnTripPoints(name: log.name, from: from, timeout: Self.timeout)
        let points = page.points.map {
          TripLogPointDTO(timestamp: $0.time, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
        }
        let after = try await store.appendTripLogPoints(logID: log.id, from: from, points: points, total: page.total)
        copying[log.id] = (after, max(page.total, after))
        pages += 1
        if pages % 12 == 0 { version += 1 }   // the trip's page redraws as it fills, every ~100 points
        if points.isEmpty || after >= page.total || after == from { break }
        from = after
        busyTries = 0
      } catch let error as CairnTripError where error.status == .busy && busyTries < 3 {
        busyTries += 1
        try? await Task.sleep(for: .seconds(2))
      } catch {
        logger.info("Trip copy stopped at \(from): \(String(describing: error))")
        break
      }
    }
    version += 1
  }

  /// Copies every trip on the connected radio's card that isn't all here yet, newest first.
  func copyAll() async {
    let logs = (try? await store.fetchTripLogs()) ?? []
    for log in logs where canCopy(log) && !log.isComplete {
      if Task.isCancelled { break }
      await copy(log)
    }
  }

  // MARK: - Deletes

  /// Removes the phone's copy. The radio's file stays (and the trip is listed as on the radio again).
  func deleteCopy(_ log: TripLogDTO) async {
    do {
      try await store.deleteTripLog(id: log.id)
    } catch {
      logger.warning("Trip copy not deleted: \(error.localizedDescription)")
    }
    version += 1
  }

  /// Removes the trip's file from the radio's card. The phone's copy stays.
  func deleteFromRadio(_ log: TripLogDTO) async -> Bool {
    guard canCopy(log), let radio else { return false }
    do {
      try await radio.session.deleteCairnTrip(name: log.name, timeout: Self.timeout)
      await refresh()
      return true
    } catch {
      logger.warning("Trip not deleted on the radio: \(String(describing: error))")
      return false
    }
  }

  // MARK: - Steps

  /// The radio's readings (Home, the Map tab): a Cairn radio's step count today, kept as the day's total.
  func noteSensors(_ points: [LPPDataPoint], radioID: UUID, cairnFirmware: Bool) {
    guard cairnFirmware else { return }
    for point in points {
      guard case let .steps(count)? = CairnSensorReading(point), count >= 0 else { continue }
      let day = Calendar.current.startOfDay(for: .now)
      if let last = lastSteps[radioID], last.day == day, last.steps >= count { return }
      lastSteps[radioID] = (day, count)
      Task { [store] in
        do {
          try await store.recordDailySteps(radioID: radioID, day: day, steps: count)
          self.version += 1
        } catch {
          logger.warning("Steps not saved: \(error.localizedDescription)")
        }
      }
      return
    }
  }
}
