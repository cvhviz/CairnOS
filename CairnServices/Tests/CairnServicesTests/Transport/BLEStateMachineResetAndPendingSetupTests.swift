import CoreBluetooth
import Foundation
@testable import CairnServices
import MeshCoreTestSupport
import ObjectiveC
import os
import Testing

/// Covers links the Bluetooth stack drops without telling the phase: state restoration
/// arriving while a connect is mid setup must fail that connect rather than strand its
/// continuation, and a bluetoothd reset (or a keepalive that keeps finding the peripheral
/// gone) must tear down a phase still holding a peripheral that is no longer connected.
@Suite("BLEStateMachine reset and pending-setup safety")
struct BLEStateMachineResetAndPendingSetupTests {
  /// Spins up a suspended `CheckedContinuation` so a phase can own a live
  /// continuation without the test blocking on it.
  private func suspendedContinuation() async -> (SetupContinuationBox, Task<Void, Never>) {
    let box = SetupContinuationBox()
    let driver = Task {
      do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          box.continuation = continuation
        }
        box.outcome = .success(())
      } catch {
        box.outcome = .failure(error)
      }
    }
    while box.continuation == nil {
      await Task.yield()
    }
    return (box, driver)
  }

  private func isConnectionFailed(_ outcome: Result<Void, Error>?) -> Bool {
    guard case let .failure(error) = outcome,
          let bleError = error as? BLEError,
          case .connectionFailed = bleError else { return false }
    return true
  }

  // MARK: - State restoration vs a connect mid setup

  @Test
  func `willRestoreState fails a connect still waiting on its CoreBluetooth connect`() async {
    let sm = BLEStateMachine()
    let connecting = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let restored = makeRetainedPeripheral(ResetOtherPeripheral.self)
    let (box, driver) = await suspendedContinuation()
    await sm.primeConnecting(peripheral: connecting, box: box)

    await sm.handleWillRestoreState(restored)
    await driver.value

    #expect(isConnectionFailed(box.outcome), "The pending connect must be resumed, not left hanging")
    #expect(await sm.currentPhase.name == "restoringState")
  }

  @Test
  func `willRestoreState fails a connect in service discovery`() async {
    let sm = BLEStateMachine()
    let discovering = makeRetainedPeripheral(ResetConnectedPeripheral.self)
    let (box, driver) = await suspendedContinuation()
    await sm.primeDiscoveringServices(peripheral: discovering, box: box)

    await sm.handleWillRestoreState(discovering)
    await driver.value

    #expect(isConnectionFailed(box.outcome))
    #expect(await sm.currentPhase.name == "restoringState")
  }

  @Test
  func `willRestoreState records a teardown error for a connect between discovery and adoption`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetConnectedPeripheral.self)
    await sm.primeDiscoveryCompletePhase(peripheral: peripheral)

    await sm.handleWillRestoreState(peripheral)

    guard case .connectionFailed = await sm.discoveryCompleteTeardownError else {
      Issue.record("connect() must find why its discoveryComplete phase was taken")
      return
    }
    #expect(await sm.currentPhase.name == "restoringState")
  }

  // MARK: - bluetoothd reset

  @Test
  func `resetting tears down a connected phase whose peripheral the stack dropped`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.primeConnectedPhase(peripheral: peripheral)
    #expect(await sm.isConnected == false, "A connected phase over a dropped peripheral is not a connection")

    await sm.handleCentralManagerDidUpdateState(.resetting)

    #expect(await sm.currentPhase.name == "idle")
    #expect(lost.devices == [ResetDisconnectedPeripheral.uuid], "The loss must reach the connection manager")
  }

  @Test
  func `resetting leaves a phase whose peripheral is still connected`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetConnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.primeConnectedPhase(peripheral: peripheral)

    await sm.handleCentralManagerDidUpdateState(.resetting)

    #expect(await sm.currentPhase.name == "connected")
    #expect(await sm.isConnected)
    #expect(lost.devices.isEmpty)
  }

  @Test
  func `resetting tears down an auto-reconnect whose pending connect the stack lost`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.primeAutoReconnecting(peripheral: peripheral)

    await sm.handleCentralManagerDidUpdateState(.resetting)

    #expect(await sm.currentPhase.name == "idle")
    #expect(await sm.isAutoReconnecting == false)
    #expect(lost.devices == [ResetDisconnectedPeripheral.uuid])
  }

  @Test
  func `resetting fails a connect mid setup through its continuation`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    let (box, driver) = await suspendedContinuation()
    await sm.primeConnecting(peripheral: peripheral, box: box)

    await sm.handleCentralManagerDidUpdateState(.resetting)
    await driver.value

    #expect(isConnectionFailed(box.outcome))
    #expect(await sm.currentPhase.name == "idle")
    #expect(lost.devices.isEmpty, "A setup failure reports through the connect, not the loss handler")
  }

  /// The startup report must not be mistaken for a recovery: state restoration can already
  /// have put the machine in `.autoReconnecting` over a peripheral that is not connected yet.
  @Test
  func `the first poweredOn leaves a restoration-driven auto-reconnect alone`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    await sm.primeAutoReconnecting(peripheral: peripheral)

    await sm.handleCentralManagerDidUpdateState(.poweredOn)

    #expect(await sm.currentPhase.name == "autoReconnecting")
  }

  @Test
  func `poweredOn after a reset tears down a link the stack dropped meanwhile`() async {
    let sm = BLEStateMachine()
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.handleCentralManagerDidUpdateState(.poweredOn)
    await sm.handleCentralManagerDidUpdateState(.resetting)
    // A phase that still read as connected during the reset, its peripheral dropped since.
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    await sm.primeConnectedPhase(peripheral: peripheral)

    await sm.handleCentralManagerDidUpdateState(.poweredOn)

    #expect(await sm.currentPhase.name == "idle")
    #expect(lost.devices == [ResetDisconnectedPeripheral.uuid])
  }

  // MARK: - Keepalive escalation

  @Test
  func `repeated keepalive failures on a dropped peripheral tear the link down`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.primeConnectedPhase(peripheral: peripheral)

    for _ in 1..<BLEStateMachine.rssiFailureEscalationThreshold {
      await sm.recordRSSIFailure(description: "test")
    }
    #expect(await sm.currentPhase.name == "connected", "A single slow read is not a lost link")

    await sm.recordRSSIFailure(description: "test")

    #expect(await sm.currentPhase.name == "idle")
    #expect(lost.devices == [ResetDisconnectedPeripheral.uuid])
  }

  @Test
  func `keepalive failures on a still-connected peripheral are only logged`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetConnectedPeripheral.self)
    let lost = LostDeviceRecorder()
    await sm.setDisconnectionHandler { deviceID, _ in lost.record(deviceID) }
    await sm.primeConnectedPhase(peripheral: peripheral)

    for _ in 0..<(BLEStateMachine.rssiFailureEscalationThreshold * 2) {
      await sm.recordRSSIFailure(description: "test")
    }

    #expect(await sm.currentPhase.name == "connected")
    #expect(lost.devices.isEmpty)
  }

  // MARK: - Late didDisconnect

  @Test
  func `a late didDisconnect from an earlier cancel does not fail the next connect`() async {
    let sm = BLEStateMachine()
    let peripheral = makeRetainedPeripheral(ResetDisconnectedPeripheral.self)
    let (box, driver) = await suspendedContinuation()
    await sm.primeConnecting(peripheral: peripheral, box: box)
    await sm.fenceLateDisconnect(of: ResetDisconnectedPeripheral.uuid)

    await sm.handleDidDisconnect(
      peripheral,
      timestamp: CFAbsoluteTimeGetCurrent(),
      isReconnecting: false,
      error: nil
    )

    #expect(await sm.currentPhase.name == "connecting", "The late callback belongs to the cancelled link")
    #expect(!box.isResumed)

    await sm.failPendingConnectSetup(reason: "test cleanup", keepingPeripheral: nil)
    await driver.value
  }
}

// MARK: - Test doubles and seams

/// Carries a phase continuation across the actor boundary and records how the
/// state machine ultimately resumed it (or that it was left suspended).
private final class SetupContinuationBox: @unchecked Sendable {
  var continuation: CheckedContinuation<Void, Error>?
  var outcome: Result<Void, Error>?
  var isResumed: Bool {
    outcome != nil
  }
}

/// Records the device IDs the state machine reports as lost.
private final class LostDeviceRecorder: Sendable {
  private let storage = OSAllocatedUnfairLock<[UUID]>(initialState: [])

  var devices: [UUID] {
    storage.withLock { $0 }
  }

  func record(_ deviceID: UUID) {
    storage.withLock { $0.append(deviceID) }
  }
}


/// A `CBPeripheral` double the stack reports as `.disconnected`.
private final class ResetDisconnectedPeripheral: CBPeripheral, @unchecked Sendable {
  static let uuid = UUID()
  override var identifier: UUID {
    Self.uuid
  }

  override var state: CBPeripheralState {
    .disconnected
  }
}

/// A second disconnected peripheral, for restoration of a different radio.
private final class ResetOtherPeripheral: CBPeripheral, @unchecked Sendable {
  static let uuid = UUID()
  override var identifier: UUID {
    Self.uuid
  }

  override var state: CBPeripheralState {
    .disconnected
  }
}

/// A `CBPeripheral` double the stack reports as `.connected`.
private final class ResetConnectedPeripheral: CBPeripheral, @unchecked Sendable {
  static let uuid = UUID()
  override var identifier: UUID {
    Self.uuid
  }

  override var state: CBPeripheralState {
    .connected
  }
}

/// Allocates a mock peripheral without `CBPeripheral`'s unavailable initializer and leaks it:
/// its `-dealloc` touches internals a runtime-allocated instance never set up, so releasing
/// one crashes. An unbalanced retain keeps it alive with no shared store for parallel tests
/// to race on.
private func makeRetainedPeripheral<T: CBPeripheral>(_ type: T.Type) -> T {
  // swiftlint:disable:next force_cast
  let peripheral = class_createInstance(type, 0) as! T
  _ = Unmanaged.passRetained(peripheral)
  return peripheral
}

private func makeCharacteristics() -> (tx: CBMutableCharacteristic, rx: CBMutableCharacteristic) {
  let tx = CBMutableCharacteristic(
    type: CBUUID(string: BLEServiceUUID.txCharacteristic),
    properties: [.write],
    value: nil,
    permissions: [.writeable]
  )
  let rx = CBMutableCharacteristic(
    type: CBUUID(string: BLEServiceUUID.rxCharacteristic),
    properties: [.notify],
    value: nil,
    permissions: [.readable]
  )
  return (tx, rx)
}

/// Actor-isolated seams that install the phases these handlers switch on.
private extension BLEStateMachine {
  func primeConnecting(peripheral: CBPeripheral, box: SetupContinuationBox) {
    guard let continuation = box.continuation else { return }
    phase = .connecting(peripheral: peripheral, continuation: continuation, timeoutTask: Task {})
    phaseStartTime = Date()
  }

  func primeDiscoveringServices(peripheral: CBPeripheral, box: SetupContinuationBox) {
    guard let continuation = box.continuation else { return }
    phase = .discoveringServices(peripheral: peripheral, continuation: continuation)
    phaseStartTime = Date()
  }

  func primeDiscoveryCompletePhase(peripheral: CBPeripheral) {
    let (tx, rx) = makeCharacteristics()
    phase = .discoveryComplete(peripheral: peripheral, tx: tx, rx: rx)
    phaseStartTime = Date()
  }

  func primeConnectedPhase(peripheral: CBPeripheral) {
    let (tx, rx) = makeCharacteristics()
    let (_, continuation) = AsyncStream.makeStream(of: Data.self)
    phase = .connected(peripheral: peripheral, tx: tx, rx: rx, dataContinuation: continuation)
    phaseStartTime = Date()
  }

  func primeAutoReconnecting(peripheral: CBPeripheral) {
    phase = .autoReconnecting(peripheral: peripheral, tx: nil, rx: nil)
    phaseStartTime = Date()
  }

  func fenceLateDisconnect(of peripheralID: UUID) {
    lateDisconnectFence = (peripheralID, CFAbsoluteTimeGetCurrent() + Self.lateDisconnectFenceWindow)
  }
}
