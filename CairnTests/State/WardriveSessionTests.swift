import CairnServices
import CoreLocation
import Foundation
@testable import Cairn
import MeshCore
import Testing

/// Wardrive as one session: its distance from the fixes, the prompts before it starts, and the
/// coordinator keeping one scan (one list) from Start to Stop however many probes it sends.
@Suite("Wardrive session")
@MainActor
struct WardriveSessionTests {
  private nonisolated static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: - Distance

  private func fix(_ latitude: Double, _ longitude: Double, accuracy: Double = 5) -> NeighbourFix {
    NeighbourFix(latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy, timestamp: Self.base)
  }

  @Test
  func `the distance adds up real moves and ignores jitter and poor fixes`() {
    var session = DiscoveryProbeCoordinator.WardriveSession(filter: .repeaters, startedAt: Self.base)
    #expect(session.distanceMeters == 0)
    #expect(session.isRunning)

    session.note(fix: nil)
    #expect(session.lastPoint == nil, "no fix, nothing to measure from")

    session.note(fix: fix(37.7749, -122.4194))
    #expect(session.distanceMeters == 0, "the first fix only sets where the drive starts")

    // About 1.1 km north
    session.note(fix: fix(37.7849, -122.4194))
    #expect(session.distanceMeters > 1000 && session.distanceMeters < 1200)

    // Two metres on: GPS jitter, not a move
    let before = session.distanceMeters
    session.note(fix: fix(37.78492, -122.4194))
    #expect(session.distanceMeters == before)

    // A 60 m move under a 200 m fix is no move either
    session.note(fix: fix(37.7855, -122.4194, accuracy: 200))
    #expect(session.distanceMeters == before)

    session.endedAt = Self.base.addingTimeInterval(90)
    #expect(!session.isRunning)
    #expect(session.elapsed(now: Self.base.addingTimeInterval(3600)) == 90, "a finished drive's elapsed time stands")
  }

  // MARK: - Prompts

  @Test
  func `the prompts come in order and each is asked once`() {
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: 80, lowPowerMode: false, acknowledged: []) == nil)
    #expect(WardrivePrompt.next(locationDenied: true, hasSeenNote: false, batteryPercent: 10, lowPowerMode: true, acknowledged: []) == .locationDenied)
    #expect(WardrivePrompt.next(locationDenied: true, hasSeenNote: false, batteryPercent: 10, lowPowerMode: true, acknowledged: [.locationDenied]) == .firstRun)
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: 10, lowPowerMode: true, acknowledged: []) == .lowBattery(percent: 10))
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: 19, lowPowerMode: false, acknowledged: []) == .lowBattery(percent: 19))
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: 20, lowPowerMode: false, acknowledged: []) == nil)
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: nil, lowPowerMode: true, acknowledged: []) == .lowPowerMode)
    #expect(WardrivePrompt.next(locationDenied: false, hasSeenNote: true, batteryPercent: 10, lowPowerMode: true, acknowledged: [.lowBattery(percent: 10), .lowPowerMode]) == nil)
  }

  @Test
  func `the view model asks before starting and starts once every prompt is answered`() {
    let viewModel = NodeDiscoveryViewModel()
    var noteSeen = false
    viewModel.configure(dependencies: NodeDiscoveryViewModel.Dependencies(
      directory: { nil },
      dataStore: { nil },
      radioID: { nil },
      contactService: { nil },
      maxContacts: { nil },
      isLocationDenied: { true },
      batteryPercent: { 15 },
      isLowPowerMode: { false },
      hasSeenWardriveNote: { noteSeen },
      markWardriveNoteSeen: { noteSeen = true }
    ))
    viewModel.startWardrive()
    #expect(viewModel.wardrivePrompt == .locationDenied)
    viewModel.confirmWardrivePrompt()
    #expect(viewModel.wardrivePrompt == .firstRun)
    viewModel.confirmWardrivePrompt()
    #expect(noteSeen)
    #expect(viewModel.wardrivePrompt == .lowBattery(percent: 15))
    viewModel.cancelWardrivePrompt()
    #expect(viewModel.wardrivePrompt == nil)
    // Cancelled: the next Start asks again from the top (the note is read, so not that one)
    viewModel.startWardrive()
    #expect(viewModel.wardrivePrompt == .locationDenied)
    viewModel.confirmWardrivePrompt()
    #expect(viewModel.wardrivePrompt == .lowBattery(percent: 15))
    viewModel.confirmWardrivePrompt()
    // Every prompt answered: it tried to start (and, with no coordinator, said it isn't connected)
    #expect(viewModel.wardrivePrompt == nil)
    #expect(viewModel.errorMessage != nil)
  }

  // MARK: - One scan per drive

  private actor FakeRadio {
    private(set) var sends: [Date] = []
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
      self.now = now
    }

    func send() {
      sends.append(now())
    }

    func overheardRequests() -> AsyncStream<Date> {
      AsyncStream { _ in }
    }
  }

  private final class Connection {}

  @Test
  func `Wardrive keeps one scan from Start to Stop and counts its probes`() async throws {
    let clock = TestClock()
    let now: @Sendable () -> Date = {
      let offset = clock.now.offset.components
      return Self.base.addingTimeInterval(TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18)
    }
    let gate = DiscoverRequestGate(now: now)
    let coordinator = DiscoveryProbeCoordinator(
      gate: gate,
      location: DiscoveryProbeCoordinator.Location(latestFix: { nil }, canFollow: { false }, setDemand: { _ in }),
      now: now,
      sleep: { try await clock.sleep(for: $0) }
    )
    let radio = FakeRadio(now: now)
    let connection = Connection()
    let radioID = UUID()
    coordinator.bind(DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(connection),
      radioID: radioID,
      listenWindow: 6,
      sendDiscoverRequest: { _, _ in await radio.send() },
      noteProbe: { _, _, _ in },
      overheardRequests: { await radio.overheardRequests() },
      updateLocationFix: { _ in }
    ))

    coordinator.startWardrive(filter: .repeaters)
    let session = try #require(coordinator.wardriveSession)
    #expect(session.isRunning)
    #expect(session.startedAt == now())
    let scan = try #require(coordinator.currentScan)
    #expect(scan.startedAt == session.startedAt)
    #expect(scan.filter == .repeaters)

    // Through the first probe's window and the gate's spacing to a second send, and a third
    for _ in 0..<120 {
      clock.advance(by: .seconds(1))
      for _ in 0..<8 { await Task.yield() }
      try await Task.sleep(for: .milliseconds(1))
    }
    try await waitUntil { await radio.sends.count >= 2 }
    let sendCount = await radio.sends.count
    #expect(coordinator.wardriveSession?.probeCount == sendCount)
    #expect(coordinator.currentScan?.startedAt == scan.startedAt, "a Wardrive probe adds to the drive's list rather than starting a new one")

    coordinator.stopWardrive()
    let ended = try #require(coordinator.wardriveSession)
    #expect(!ended.isRunning)
    #expect(ended.endedAt == now())
    #expect(ended.probeCount == sendCount)
    #expect(coordinator.currentScan?.startedAt == scan.startedAt, "stopping keeps the drive's list on screen")

    coordinator.dismissWardriveSession()
    #expect(coordinator.wardriveSession == nil)
    withExtendedLifetime(connection) {}
  }
}
