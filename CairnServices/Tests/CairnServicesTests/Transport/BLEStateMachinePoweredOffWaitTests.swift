import CoreBluetooth
import Foundation
@testable import CairnServices
import ObjectiveC
import Testing

/// Covers a connect that parks in `.waitingForBluetooth` after the central
/// already reported its state while idle: no further state callback arrives,
/// so the wait itself has to bound a powered-off central.
@Suite("BLEStateMachine powered-off wait")
struct BLEStateMachinePoweredOffWaitTests {
  /// Runs `waitForPoweredOn` off the test task and records how it resumed.
  private func startWaiting(on sm: BLEStateMachine) -> (WaitOutcomeBox, Task<Void, Never>) {
    let box = WaitOutcomeBox()
    let waiter = Task {
      do {
        try await sm.waitForPoweredOn()
        box.outcome = .success(())
      } catch {
        box.outcome = .failure(error)
      }
    }
    return (box, waiter)
  }

  /// Polls until the wait resumed or the window elapses, so a wait that never
  /// resumes fails the assertion instead of suspending the test.
  private func awaitResumed(_ box: WaitOutcomeBox, within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !box.isResumed {
      if ContinuousClock.now > deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  private func awaitPhase(_ name: String, on sm: BLEStateMachine, within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await sm.currentPhase.name != name {
      if ContinuousClock.now > deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  @Test(
    .timeLimit(.minutes(1))
  )
  func `a wait parked while Bluetooth is already off fails after the grace period`() async {
    let sm = BLEStateMachine()
    await sm.installCentralManagerDouble(makeLeakedCentralManager(PoweredOffCentralManager.self))

    let (box, waiter) = startWaiting(on: sm)
    let resumed = await awaitResumed(box, within: poweredOffWaitObservationWindow)

    #expect(resumed, "With no state callback left to arrive, the wait must arm its own grace period")
    if resumed {
      guard case let .failure(error) = box.outcome,
            case .bluetoothPoweredOff = error as? BLEError else {
        Issue.record("Expected bluetoothPoweredOff, got \(String(describing: box.outcome))")
        return
      }
      #expect(await sm.currentPhase.name == "idle")
    } else {
      // Release the still-parked continuation so the waiter task can finish.
      await sm.shutdown()
    }
    await waiter.value
  }

  @Test(
    .timeLimit(.minutes(1))
  )
  func `a wait parked while the central is still resolving arms no grace period`() async {
    let sm = BLEStateMachine()
    await sm.installCentralManagerDouble(makeLeakedCentralManager(UnresolvedCentralManager.self))

    let (box, waiter) = startWaiting(on: sm)
    let parked = await awaitPhase("waitingForBluetooth", on: sm, within: poweredOffWaitObservationWindow)
    #expect(parked)
    #expect(await sm.bluetoothPowerOffGraceTask == nil)

    // Longer than the grace period: an armed timer would have failed the wait by now.
    try? await Task.sleep(for: graceOutlastingDelay)
    #expect(!box.isResumed)

    if parked {
      await sm.handleCentralManagerDidUpdateState(.poweredOn)
    } else {
      await sm.shutdown()
    }
    await waiter.value

    if parked {
      guard case .success = box.outcome else {
        Issue.record("Expected the poweredOn callback to resume the wait, got \(String(describing: box.outcome))")
        return
      }
      #expect(await sm.currentPhase.name == "idle")
    }
  }
}

/// Bounds the wait for a parked continuation to resume; several times the 1s grace period.
private let poweredOffWaitObservationWindow: Duration = .seconds(5)

/// Outlasts the 1s grace period, so an armed timer would have fired within it.
private let graceOutlastingDelay: Duration = .milliseconds(1500)

/// Bounds the wait for the real central's initial state callback before it is swapped out.
private let centralSettleWindow: Duration = .seconds(3)

/// Records how the state machine resumed `waitForPoweredOn` (or that it was left parked).
private final class WaitOutcomeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOutcome: Result<Void, Error>?

  var outcome: Result<Void, Error>? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedOutcome
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storedOutcome = newValue
    }
  }

  var isResumed: Bool {
    outcome != nil
  }
}

/// A `CBCentralManager` double that already settled on `.poweredOff`.
private final class PoweredOffCentralManager: CBCentralManager, @unchecked Sendable {
  override var state: CBManagerState {
    .poweredOff
  }
}

/// A `CBCentralManager` double that has not resolved its state yet.
private final class UnresolvedCentralManager: CBCentralManager, @unchecked Sendable {
  override var state: CBManagerState {
    .unknown
  }
}

/// Retains central manager doubles for the process lifetime. A runtime-
/// allocated instance skipped its initializer, so its `-dealloc` would touch
/// internals that were never set up; never freeing them keeps the doubles usable.
private enum CentralManagerDoubleStore {
  nonisolated(unsafe) static var retained: [CBCentralManager] = []
}

/// Allocates a central manager double without running `CBCentralManager`'s
/// initializer, which would bring up a real CoreBluetooth connection.
private func makeLeakedCentralManager<T: CBCentralManager>(_ type: T.Type) -> T {
  // swiftlint:disable:next force_cast
  let manager = class_createInstance(type, 0) as! T
  CentralManagerDoubleStore.retained.append(manager)
  return manager
}

private extension BLEStateMachine {
  /// Replaces the central with a double whose state the test controls.
  /// `waitForPoweredOn` calls `activate()`, which would overwrite the double
  /// with a real central, so the real one is created first and swapped out
  /// once its initial state callback has landed.
  func installCentralManagerDouble(_ double: CBCentralManager) async {
    activate()
    let deadline = ContinuousClock.now + centralSettleWindow
    while lastCentralState == nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    centralManager = double
  }
}
