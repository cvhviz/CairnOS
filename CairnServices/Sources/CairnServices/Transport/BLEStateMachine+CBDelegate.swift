// BLEStateMachine+CBDelegate.swift
@preconcurrency import CoreBluetooth
import Foundation
import os
import Synchronization

// MARK: - Delegate Handler

/// Bridges CoreBluetooth delegate callbacks to the actor.
///
/// This class is necessary because actors cannot directly conform to
/// Objective-C delegate protocols. All callbacks dispatch to the actor.
///
/// ## Callback ordering (C11)
/// Control callbacks (didConnect, didDiscoverServices, etc.) are forwarded via
/// unstructured `Task {}`, which does not guarantee FIFO ordering on the actor.
/// This is safe because each handler validates the expected phase before proceeding.
/// An out-of-order callback (e.g., didDiscoverServices arriving before didConnect
/// has been processed) will fail the phase guard and be ignored. The timeout
/// mechanism will then retry the operation.
///
/// For data reception (`didUpdateValueFor`), data is yielded directly to an AsyncStream
/// continuation rather than spawning Tasks. This preserves the ordering guaranteed by
/// the serial CBCentralManager queue, avoiding the race conditions that occur when
/// multiple unstructured Tasks compete for actor access with priority-based scheduling.
/// Every yield result is checked: a notification the full stream refuses is counted,
/// not silently lost, and the deepest backlog the stream has held is recorded.
final class BLEDelegateHandler: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
  weak var stateMachine: BLEStateMachine?

  private let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "BLEDelegateHandler")

  /// Lock-protected continuation for yielding received data directly.
  /// Using OSAllocatedUnfairLock ensures thread-safe access from the CBCentralManager queue.
  private let dataContinuationLock = OSAllocatedUnfairLock<AsyncStream<Data>.Continuation?>(initialState: nil)

  /// Notifications the data stream refused because its buffer was full. Monotonic
  /// for the handler's lifetime (it spans reconnects and stream renewals) so a
  /// reader can diff two samples.
  private let droppedNotifications = Atomic<Int>(0)

  /// Deepest backlog, in frames, any data stream has held since the handler was
  /// created. Reaching `BLEStateMachine.dataStreamBufferLimit` means the consumer
  /// fell a full buffer behind.
  private let notificationBufferHighWater = Atomic<Int>(0)

  /// Holds the link-activity handler by reference.
  ///
  /// The lock must not hold the closure itself: the optimizer re-abstracts a function value
  /// stored in the lock's generic state and writes the wrapped copy back on every read, so
  /// each `withLock { $0 }` nested it one thunk pair deeper. After ~8,300 link-activity reads
  /// (a day or two connected) calling the handler overflowed the CoreBluetooth queue's stack
  /// (1.1 (18) TestFlight crash). A class reference is copied as is.
  private final class LinkActivityHandlerBox: Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
  }

  /// The link-activity handler (``BLEStateMachine/setLinkActivityHandler(_:)``).
  private let linkActivityHandlerLock = OSAllocatedUnfairLock<LinkActivityHandlerBox?>(initialState: nil)

  /// `DispatchTime` uptime of the last link-activity callback, 0 before the first.
  private let lastLinkActivityNanos = Atomic<UInt64>(0)

  /// The least time between two link-activity callbacks.
  static let linkActivityInterval: UInt64 = 15_000_000_000

  func setLinkActivityHandler(_ handler: (@Sendable () -> Void)?) {
    let box = handler.map(LinkActivityHandlerBox.init)
    linkActivityHandlerLock.withLock { $0 = box }
  }

  /// Tells the link-activity handler, at most once per ``linkActivityInterval``.
  private func noteLinkActivity() {
    let now = DispatchTime.now().uptimeNanoseconds
    let last = lastLinkActivityNanos.load(ordering: .relaxed)
    guard last == 0 || now &- last >= Self.linkActivityInterval else { return }
    guard lastLinkActivityNanos.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged else { return }
    let box = linkActivityHandlerLock.withLock { $0 }
    box?.handler()
  }

  /// Notifications dropped at the full data stream since the handler was created.
  var droppedNotificationCount: Int {
    droppedNotifications.load(ordering: .relaxed)
  }

  /// Deepest data stream backlog, in frames, since the handler was created.
  var notificationBufferHighWaterMark: Int {
    notificationBufferHighWater.load(ordering: .relaxed)
  }

  /// FIFO of sequence numbers for `.withResponse` writes issued but not yet
  /// acknowledged. CoreBluetooth delivers exactly one `didWriteValueFor` per
  /// write request, in issue order, on the serial queue, so popping the head
  /// tags each callback with the sequence of the write that produced it.
  /// Tagging at write time (not delivery time) lets a callback that arrives
  /// after its write already timed out be recognized as the old write instead
  /// of being mistaken for the current one.
  private let issuedWriteSequencesLock = OSAllocatedUnfairLock<[UInt64]>(initialState: [])

  /// Records a write's sequence as issued. The actor calls this immediately
  /// before `writeValue` so the callback can never outrun the record.
  func recordIssuedWriteSequence(_ sequence: UInt64) {
    issuedWriteSequencesLock.withLock { $0.append(sequence) }
  }

  /// Drops all recorded write sequences. Called when pending writes are
  /// cancelled (disconnect, auto-reconnect teardown), where the outstanding
  /// callbacks either never arrive or no longer have a continuation; a stale
  /// entry left behind would mis-tag the next connection's first callback.
  func clearIssuedWriteSequences() {
    issuedWriteSequencesLock.withLock { $0.removeAll() }
  }

  /// Sets the data continuation for direct yielding from delegate callbacks.
  /// Call this when transitioning to connected state.
  func setDataContinuation(_ continuation: AsyncStream<Data>.Continuation?) {
    dataContinuationLock.withLock { $0 = continuation }
  }

  /// Yields one notification payload to the current data stream and accounts for
  /// the result. Runs on the serial CBCentralManager queue, so yields stay in
  /// arrival order.
  func deliverNotification(_ data: Data) {
    let result = dataContinuationLock.withLock { $0?.yield(data) }
    switch result {
    case let .enqueued(remaining):
      // An unbounded continuation reports Int.max remaining; it has no backlog limit to track.
      let depth = BLEStateMachine.dataStreamBufferLimit - remaining
      if depth > 0 { recordBufferDepth(depth) }
    case .dropped:
      let total = droppedNotifications.wrappingAdd(1, ordering: .relaxed).newValue
      // First drop, then every 256th, so a sustained overflow doesn't flood the log.
      if total == 1 || total.isMultiple(of: 256) {
        logger.warning("[BLE] Data stream full, notification dropped, total dropped: \(total)")
      }
    case .terminated, nil:
      break
    @unknown default:
      break
    }
  }

  /// Raises the high-water mark to `depth` if it is deeper than any seen before.
  private func recordBufferDepth(_ depth: Int) {
    var current = notificationBufferHighWater.load(ordering: .relaxed)
    while depth > current {
      let (exchanged, original) = notificationBufferHighWater.compareExchange(
        expected: current,
        desired: depth,
        ordering: .relaxed
      )
      if exchanged { return }
      current = original
    }
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleCentralManagerDidUpdateState(central.state) }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard let sm = stateMachine else { return }
    // Extract peripheral synchronously before crossing actor boundary
    guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
          let peripheral = peripherals.first else {
      return
    }
    Task { await sm.handleWillRestoreState(peripheral) }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard let sm = stateMachine else { return }
    let peripheralID = peripheral.identifier
    let rssiValue = RSSI.intValue
    // Prefer the advertised local name; it is present before a connection is established
    // and fresher than the cached `peripheral.name`.
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
    Task { await sm.handleDidDiscoverPeripheral(peripheralID: peripheralID, name: name, rssi: rssiValue) }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidConnect(peripheral) }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidFailToConnect(peripheral, error: error) }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidDisconnect(peripheral, timestamp: timestamp, isReconnecting: isReconnecting, error: error) }
  }

  // MARK: - CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidDiscoverServices(peripheral, error: error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidDiscoverCharacteristics(peripheral, service: service, error: error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidUpdateNotificationState(peripheral, characteristic: characteristic, error: error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    // Yield data directly to preserve ordering from the serial CBCentralManager queue.
    // Do not spawn a Task here - that breaks ordering guarantees.
    if let error {
      logger.warning("[BLE] didUpdateValueFor error: \(peripheral.identifier.uuidString.prefix(8)), char: \(characteristic.uuid.uuidString.prefix(8)), error: \(error.localizedDescription)")
      return
    }
    guard let data = characteristic.value, !data.isEmpty else {
      logger.debug("[BLE] didUpdateValueFor: empty data from \(peripheral.identifier.uuidString.prefix(8)), char: \(characteristic.uuid.uuidString.prefix(8))")
      return
    }
    deliverNotification(data)
    noteLinkActivity()
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    guard let sm = stateMachine else { return }
    Task { await sm.handleDidReadRSSI(RSSI: RSSI, error: error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let sm = stateMachine else { return }
    // Pop the oldest unacknowledged write's sequence (callbacks arrive in
    // issue order on this serial queue) so the callback is tagged with the
    // write that produced it, not whichever write is current by delivery time.
    let seq = issuedWriteSequencesLock.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    guard let seq else {
      logger.debug("[BLE] didWriteValueFor with no recorded write, ignoring")
      return
    }
    Task { await sm.handleDidWriteValue(peripheral, characteristic: characteristic, error: error, writeSequence: seq) }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let sm = stateMachine else { return }
    Task { await sm.handlePeripheralReadyForWriteWithoutResponse() }
  }
}
