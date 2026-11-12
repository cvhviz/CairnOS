@testable import CairnServices
import Foundation
import Testing

@Suite("DiscoverRequestGate")
struct DiscoverRequestGateTests {
  /// A clock the test moves by hand, in seconds from a fixed origin.
  private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    static let origin = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
      lock.lock()
      defer { lock.unlock() }
      return Self.origin.addingTimeInterval(seconds)
    }

    func set(_ seconds: TimeInterval) {
      lock.lock()
      self.seconds = seconds
      lock.unlock()
    }
  }

  private static func at(_ seconds: TimeInterval) -> Date {
    FakeClock.origin.addingTimeInterval(seconds)
  }

  private func makeGate() -> (DiscoverRequestGate, FakeClock) {
    let clock = FakeClock()
    return (DiscoverRequestGate(now: { clock.now }), clock)
  }

  /// Asks at `seconds` and, when allowed, records the send at the same instant.
  private func press(_ gate: DiscoverRequestGate, _ clock: FakeClock, at seconds: TimeInterval) async -> DiscoverRequestGate.Decision {
    clock.set(seconds)
    let decision = await gate.request()
    if decision == .allowed {
      await gate.recordOwn(at: Self.at(seconds))
    }
    return decision
  }

  @Test
  func `a second request 30 s after the first waits for spacing until 45 s`() async {
    let (gate, clock) = makeGate()
    #expect(await press(gate, clock, at: 0) == .allowed)
    #expect(await press(gate, clock, at: 30) == .coolingDown(until: Self.at(45), reason: .spacing))
  }

  @Test
  func `a third of our requests inside 120 s waits for the first to leave the window`() async {
    let (gate, clock) = makeGate()
    #expect(await press(gate, clock, at: 0) == .allowed)
    #expect(await press(gate, clock, at: 45) == .allowed)
    #expect(await press(gate, clock, at: 90) == .coolingDown(until: Self.at(120), reason: .ownCap))
    #expect(await press(gate, clock, at: 120) == .allowed)
  }

  @Test
  func `two overheard requests after ours refuse the next one`() async {
    let (gate, clock) = makeGate()
    #expect(await press(gate, clock, at: 0) == .allowed)
    await gate.noteOverheard(at: Self.at(50))
    await gate.noteOverheard(at: Self.at(60))
    #expect(await press(gate, clock, at: 100) == .coolingDown(until: Self.at(120), reason: .othersScanning))
  }

  @Test
  func `two overheard requests alone leave room for ours, three do not`() async {
    let (gate, clock) = makeGate()
    clock.set(20)
    await gate.noteOverheard(at: Self.at(0))
    await gate.noteOverheard(at: Self.at(10))
    #expect(await gate.status() == .allowed)

    await gate.noteOverheard(at: Self.at(20))
    #expect(await press(gate, clock, at: 20) == .coolingDown(until: Self.at(120), reason: .othersScanning))
  }

  @Test
  func `the same overheard request replayed after a re-bind counts once`() async {
    let (gate, clock) = makeGate()
    clock.set(5)
    await gate.noteOverheard(at: Self.at(0))
    await gate.noteOverheard(at: Self.at(0.4))
    await gate.noteOverheard(at: Self.at(3))
    #expect(await gate.status() == .allowed)
  }

  @Test
  func `an allowed request is reserved before it is sent`() async {
    let (gate, clock) = makeGate()
    clock.set(0)
    #expect(await gate.request() == .allowed)
    // A second caller asking before the first one sends must not also go on air.
    #expect(await gate.request() == .coolingDown(until: Self.at(45), reason: .spacing))
    // Recording the send moves the reservation to when it went out.
    await gate.recordOwn(at: Self.at(4))
    clock.set(30)
    #expect(await gate.status() == .coolingDown(until: Self.at(49), reason: .spacing))
  }

  @Test
  func `releasing a reservation the radio refused leaves the gate as it was`() async {
    let (gate, clock) = makeGate()
    clock.set(0)
    #expect(await gate.request() == .allowed)
    await gate.releaseReservation()
    #expect(await gate.status() == .allowed)
    #expect(await gate.request() == .allowed)
  }

  @Test
  func `releasing gives back only the outstanding reservation, never a sent request`() async {
    let (gate, clock) = makeGate()
    #expect(await press(gate, clock, at: 0) == .allowed)
    clock.set(50)
    #expect(await gate.request() == .allowed)
    await gate.releaseReservation()
    // The request sent at 0 still counts: once 50 is sent, 95 hits the cap until 0 leaves
    #expect(await press(gate, clock, at: 50) == .allowed)
    #expect(await press(gate, clock, at: 95) == .coolingDown(until: Self.at(120), reason: .ownCap))
  }

  @Test
  func `releasing with no reservation outstanding does nothing`() async {
    let (gate, clock) = makeGate()
    #expect(await press(gate, clock, at: 0) == .allowed)
    await gate.releaseReservation()
    clock.set(30)
    #expect(await gate.status() == .coolingDown(until: Self.at(45), reason: .spacing))
  }

  @Test
  func `status never reserves`() async {
    let (gate, clock) = makeGate()
    clock.set(0)
    #expect(await gate.status() == .allowed)
    #expect(await gate.status() == .allowed)
    #expect(await gate.request() == .allowed)
  }

  /// One hour of random presses and overheard requests. Whenever we send, the trailing 120 s holds
  /// at most 3 requests we know of including ours, and at most 2 of ours; sends are at least
  /// 45 s apart.
  @Test(arguments: [UInt64(1), 7, 42, 2026, 0xC0FFEE])
  func `random traffic never overspends the repeaters' limiter`(seed: UInt64) async {
    var rng = SplitMix64(seed: seed)
    let (gate, clock) = makeGate()
    var ours: [TimeInterval] = []
    var known: [TimeInterval] = []
    var second: TimeInterval = 0

    while second < 3600 {
      second += TimeInterval(Int.random(in: 1...20, using: &rng))
      if Int.random(in: 0..<4, using: &rng) == 0 {
        clock.set(second)
        await gate.noteOverheard(at: Self.at(second))
        known.append(second)
      } else if await press(gate, clock, at: second) == .allowed {
        let trailingKnown = known.filter { second - $0 < 120 }.count
        let trailingOurs = ours.filter { second - $0 < 120 }.count
        #expect(trailingKnown + 1 <= 3)
        #expect(trailingOurs + 1 <= 2)
        if let last = ours.last { #expect(second - last >= 45) }
        ours.append(second)
        known.append(second)
      }
    }
    #expect(!ours.isEmpty)

    // Ours alone, over every sliding window.
    for start in ours {
      #expect(ours.filter { $0 >= start && $0 - start < 120 }.count <= 2)
    }
  }
}

/// A small seeded generator so the random test replays the same traffic every run.
private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
