@testable import Cairn
import Testing

@Suite("CarPlayRefreshGate")
struct CarPlayRefreshGateTests {
  private let start = ContinuousClock.now

  @Test
  func `The first update applies at once`() {
    var gate = CarPlayRefreshGate()
    #expect(gate.request(at: start, urgent: false) == .applyNow)
  }

  @Test
  func `Routine updates wait out the interval`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .seconds(3), urgent: false) == .schedule(after: .seconds(7)))
  }

  @Test
  func `Only one trailing update is scheduled`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    _ = gate.request(at: start + .seconds(1), urgent: false)
    #expect(gate.request(at: start + .seconds(2), urgent: false) == .alreadyScheduled)
    gate.didApply(at: start + .seconds(10))
    #expect(gate.request(at: start + .seconds(11), urgent: false) == .schedule(after: .seconds(9)))
  }

  @Test
  func `Edge events bypass the interval`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .seconds(1), urgent: true) == .applyNow)
  }

  @Test
  func `A flapping link redraws at most once a second`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .milliseconds(300), urgent: true) == .schedule(after: .milliseconds(700)))
    // The routine change that follows rides on that edge update.
    #expect(gate.request(at: start + .milliseconds(400), urgent: false) == .alreadyScheduled)
    gate.didApply(at: start + .seconds(1))
    #expect(gate.request(at: start + .seconds(2), urgent: true) == .applyNow)
  }

  @Test
  func `An edge event replaces a later routine update`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .milliseconds(100), urgent: false) == .schedule(after: .milliseconds(9900)))
    #expect(gate.request(at: start + .milliseconds(200), urgent: true) == .schedule(after: .milliseconds(800)))
  }

  @Test
  func `After the interval routine updates apply at once`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .seconds(10), urgent: false) == .applyNow)
  }

  @Test
  func `A scan uses the shorter interval`() {
    var gate = CarPlayRefreshGate()
    gate.didApply(at: start)
    #expect(gate.request(at: start + .seconds(2), urgent: false, interval: CarPlayRefreshGate.scanInterval)
      == .schedule(after: .seconds(3)))
  }
}
