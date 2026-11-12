import CoreBluetooth
import Foundation
@testable import CairnServices
import ObjectiveC
import Testing

/// `armPendingReconnect(deviceID:)`: the wake source a suspended app keeps. An idle machine issues
/// one CoreBluetooth connect with no timeout (iOS holds it until the radio is reachable, relaunching
/// the app if it was terminated) and claims the reconnect cycle, so the session is rebuilt and the
/// radio's queue drained when it completes.
@Suite("BLEStateMachine wake source", .serialized)
struct BLEStateMachineWakeSourceTests {
  private func makeMachine(poweredOn: Bool = true, known: Bool = true) async
    -> (BLEStateMachine, WakeTestCentralManager, WakeClaimRecorder) {
    let sm = BLEStateMachine()
    let central = WakeTestCentralManager(delegate: nil, queue: nil)
    WakeTestCentralManager.poweredOn = poweredOn
    WakeTestCentralManager.knownPeripherals = known ? [makeLeakedWakePeripheral()] : []
    WakeTestCentralManager.connectOptions = []
    await sm.injectCentralManagerForWakeTests(central)
    let claims = WakeClaimRecorder()
    await sm.setAutoReconnectingHandler { deviceID, info in claims.append(deviceID, info) }
    return (sm, central, claims)
  }

  @Test
  func `an idle machine arms exactly one untimed pending connect and claims the cycle`() async {
    let (sm, _, claims) = await makeMachine()

    #expect(await sm.armPendingReconnect(deviceID: WakeTestPeripheral.uuid))
    #expect(await sm.currentPhase.name == "autoReconnecting", "no .connecting phase: nothing times the connect out")
    #expect(WakeTestCentralManager.connectOptions.count == 1)
    #expect(WakeTestCentralManager.connectOptions.first?[CBConnectPeripheralOptionEnableAutoReconnect] as? Bool == true)
    #expect(claims.events.map(\.info) == ["wake-source"])

    // A wake source exists now: arming again does nothing.
    #expect(await !sm.armPendingReconnect(deviceID: WakeTestPeripheral.uuid))
    #expect(WakeTestCentralManager.connectOptions.count == 1)

    await sm.cancelAutoReconnectTimeoutForWakeTests()
  }

  @Test
  func `no pending connect while Bluetooth is off or for a peripheral CoreBluetooth doesn't know`() async {
    let (off, _, offClaims) = await makeMachine(poweredOn: false)
    #expect(await !off.armPendingReconnect(deviceID: WakeTestPeripheral.uuid))
    #expect(await off.currentPhase.name == "idle")
    #expect(offClaims.events.isEmpty)

    let (unknown, _, unknownClaims) = await makeMachine(known: false)
    #expect(await !unknown.armPendingReconnect(deviceID: WakeTestPeripheral.uuid))
    #expect(await unknown.currentPhase.name == "idle")
    #expect(unknownClaims.events.isEmpty)
    #expect(WakeTestCentralManager.connectOptions.isEmpty)
  }
}

// MARK: - Test doubles

private final class WakeClaimRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [(deviceID: UUID, info: String)] = []
  var events: [(deviceID: UUID, info: String)] { lock.withLock { stored } }
  func append(_ deviceID: UUID, _ info: String) { lock.withLock { stored.append((deviceID, info)) } }
}

private final class WakeTestCentralManager: CBCentralManager, @unchecked Sendable {
  nonisolated(unsafe) static var poweredOn = true
  nonisolated(unsafe) static var knownPeripherals: [CBPeripheral] = []
  nonisolated(unsafe) static var connectOptions: [[String: Any]] = []

  override var state: CBManagerState { Self.poweredOn ? .poweredOn : .poweredOff }

  override func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
    Self.knownPeripherals.filter { identifiers.contains($0.identifier) }
  }

  override func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
    Self.connectOptions.append(options ?? [:])
  }

  override func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
}

private enum WakePeripheralStore {
  nonisolated(unsafe) static var retained: [AnyObject] = []
}

/// Created with `class_createInstance` (no stored properties; never deallocated).
private final class WakeTestPeripheral: CBPeripheral, @unchecked Sendable {
  static let uuid = UUID()

  override var identifier: UUID { Self.uuid }

  override var state: CBPeripheralState { .disconnected }

  override var delegate: CBPeripheralDelegate? {
    get { nil }
    set {}
  }
}

private func makeLeakedWakePeripheral() -> WakeTestPeripheral {
  // swiftlint:disable:next force_cast
  let peripheral = class_createInstance(WakeTestPeripheral.self, 0) as! WakeTestPeripheral
  WakePeripheralStore.retained.append(peripheral)
  return peripheral
}

private extension BLEStateMachine {
  func injectCentralManagerForWakeTests(_ manager: CBCentralManager) {
    centralManager = manager
  }

  func cancelAutoReconnectTimeoutForWakeTests() {
    autoReconnectDiscoveryTimeoutTask?.cancel()
    autoReconnectDiscoveryTimeoutTask = nil
  }
}
