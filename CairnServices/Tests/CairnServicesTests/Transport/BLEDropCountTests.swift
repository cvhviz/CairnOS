import CoreBluetooth
import Foundation
@testable import CairnServices
import MeshCore
import ObjectiveC
import Testing

/// Covers the notification data stream's bounded buffer: every stream site
/// shares one oldest-first policy, and the delegate handler counts the
/// notifications a full stream refuses instead of losing them silently.
@Suite("BLE Drop Count")
struct BLEDropCountTests {
  /// Frames yielded with no consumer: the first `dataStreamBufferLimit` are
  /// kept in arrival order and every later one is counted as dropped.
  @Test
  func `a full data stream keeps the oldest frames and counts the drops`() async {
    let handler = BLEDelegateHandler()
    let (stream, continuation) = BLEStateMachine.makeDataStream()
    handler.setDataContinuation(continuation)

    for index in 0..<3000 {
      handler.deliverNotification(frame(index))
    }

    #expect(BLEStateMachine.dataStreamBufferLimit == 2048)
    #expect(handler.droppedNotificationCount == 952)
    #expect(handler.notificationBufferHighWaterMark == 2048)

    continuation.finish()
    var received: [Data] = []
    for await chunk in stream {
      received.append(chunk)
    }
    #expect(received.count == 2048)
    #expect(received == (0..<2048).map(frame))
  }

  /// A consumer that keeps up never drops, and the high-water mark reflects
  /// the deepest backlog rather than the total delivered.
  @Test
  func `a drained stream records its deepest backlog without drops`() async {
    let handler = BLEDelegateHandler()
    let (stream, continuation) = BLEStateMachine.makeDataStream()
    handler.setDataContinuation(continuation)
    var iterator = stream.makeAsyncIterator()

    for index in 0..<5 {
      handler.deliverNotification(frame(index))
    }
    for _ in 0..<5 {
      _ = await iterator.next()
    }
    for index in 5..<8 {
      handler.deliverNotification(frame(index))
    }

    #expect(handler.droppedNotificationCount == 0)
    #expect(handler.notificationBufferHighWaterMark == 5)
  }

  /// Notifications arriving with no continuation installed (between links)
  /// or after the stream finished are not counted as buffer drops.
  @Test
  func `notifications without a live stream are not counted as drops`() {
    let handler = BLEDelegateHandler()
    handler.deliverNotification(frame(0))

    let (stream, continuation) = BLEStateMachine.makeDataStream()
    handler.setDataContinuation(continuation)
    continuation.finish()
    withExtendedLifetime(stream) {
      handler.deliverNotification(frame(1))
    }

    #expect(handler.droppedNotificationCount == 0)
    #expect(handler.notificationBufferHighWaterMark == 0)
  }

  /// A renewed stream uses the same bounded policy, and its drops reach the
  /// state machine's counter and its link diagnostics.
  @Test
  func `renewDataStream keeps the bounded policy and drop accounting`() async throws {
    let sm = BLEStateMachine()
    await sm.primeConnectedForDropCount(peripheral: makeDropCountLeakedPeripheral())

    let renewed = try #require(await sm.renewDataStream())
    let handler = await sm.delegateHandler
    for index in 0..<3000 {
      handler.deliverNotification(frame(index))
    }

    #expect(sm.droppedNotificationCount == 952)
    #expect(sm.notificationBufferHighWaterMark == 2048)
    let diagnostics = await sm.linkDiagnostics
    #expect(diagnostics.droppedNotificationCount == 952)
    #expect(diagnostics.notificationBufferHighWaterMark == 2048)

    guard case let .connected(_, _, _, continuation) = await sm.currentPhase else {
      Issue.record("expected .connected after renewal")
      return
    }
    continuation.finish()
    var received: [Data] = []
    for await chunk in renewed {
      received.append(chunk)
    }
    #expect(received == (0..<2048).map(frame))

    await sm.shutdown()
  }

  /// The transport exposes the state machine's counter.
  @Test
  func `iOSBLETransport exposes the state machine drop count`() async {
    let sm = BLEStateMachine()
    let transport = iOSBLETransport(stateMachine: sm)
    let handler = await sm.delegateHandler
    // Hold the stream: releasing it terminates the continuation's storage.
    let (stream, continuation) = BLEStateMachine.makeDataStream()
    handler.setDataContinuation(continuation)

    withExtendedLifetime(stream) {
      for index in 0..<2050 {
        handler.deliverNotification(frame(index))
      }
    }

    #expect(transport.droppedNotificationCount == 2)
    #expect(transport.notificationBufferHighWaterMark == 2048)
  }

  /// The session reads the same counter through `MeshTransport.droppedFrameCount`, for the
  /// drops a connection's delivery line shows.
  @Test
  func `iOSBLETransport reports its drops to the session as dropped frames`() async {
    let sm = BLEStateMachine()
    let transport = iOSBLETransport(stateMachine: sm)
    let handler = await sm.delegateHandler
    let (stream, continuation) = BLEStateMachine.makeDataStream()
    handler.setDataContinuation(continuation)

    withExtendedLifetime(stream) {
      for index in 0..<2053 {
        handler.deliverNotification(frame(index))
      }
    }

    let meshTransport: any MeshTransport = transport
    #expect(await meshTransport.droppedFrameCount == 5)
    #expect(await meshTransport.droppedFrameCount == transport.droppedNotificationCount)
  }
}

/// A distinct, ordered payload per index.
private func frame(_ index: Int) -> Data {
  withUnsafeBytes(of: UInt32(index).littleEndian) { Data($0) }
}

private final class DropCountConnectedPeripheral: CBPeripheral, @unchecked Sendable {
  static let uuid = UUID()
  override var identifier: UUID {
    Self.uuid
  }

  override var state: CBPeripheralState {
    .connected
  }
}

/// Keeps raw-allocated peripheral doubles alive for the process lifetime so
/// CoreBluetooth teardown never runs on an instance that skipped its
/// designated initializer.
private enum DropCountPeripheralStore {
  nonisolated(unsafe) static var retained: [CBPeripheral] = []
}

/// Allocates a mock peripheral without invoking `CBPeripheral`'s unavailable
/// initializer and keeps it alive so it is never deallocated.
private func makeDropCountLeakedPeripheral() -> CBPeripheral {
  // swiftlint:disable:next force_cast
  let peripheral = class_createInstance(DropCountConnectedPeripheral.self, 0) as! CBPeripheral
  DropCountPeripheralStore.retained.append(peripheral)
  return peripheral
}

/// Installs `.connected` on the real actor so renewal is exercised on the
/// code under test rather than a mock.
private extension BLEStateMachine {
  func primeConnectedForDropCount(peripheral: CBPeripheral) {
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
    let (_, continuation) = AsyncStream.makeStream(of: Data.self)
    phase = .connected(peripheral: peripheral, tx: tx, rx: rx, dataContinuation: continuation)
    phaseStartTime = Date()
  }
}
