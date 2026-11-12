import Foundation
@testable import CairnServices
import Testing

@Suite("ConnectionManager BLE Scanning Tests")
@MainActor
struct ConnectionManagerBLEScanningTests {
  @Test
  func `startBLEScanning starts scan and forwards discoveries`() async throws {
    let (manager, mock) = try ConnectionManager.createForTesting()
    let stream = manager.startBLEScanning()

    let expectedID = UUID()
    let receiveTask = Task { await nextValue(from: stream, timeout: .seconds(10)) }

    try await waitUntil("BLE scanning should start") {
      await mock.isScanning
    }
    await mock.simulateDiscoveredDevice(id: expectedID, name: "MeshCore-Test", rssi: -68)

    let discovery = await receiveTask.value
    #expect(discovery?.id == expectedID)
    #expect(discovery?.name == "MeshCore-Test")
    #expect(discovery?.rssi == -68)
    #expect(await mock.startScanningCallCount == 1)
    #expect(await mock.isScanning)

    await manager.stopBLEScanning()
    #expect(await mock.isScanning == false)
  }

  @Test
  func `terminated scan stream does not leave scanning active`() async throws {
    let (manager, mock) = try ConnectionManager.createForTesting()
    let stream = manager.startBLEScanning()

    let consumeTask = Task {
      for await _ in stream {}
    }
    consumeTask.cancel()
    _ = await consumeTask.result

    try await waitUntil("Stream cleanup should stop scanning") {
      await mock.isScanning == false
    }

    #expect(await mock.isScanning == false)
    #expect(await mock.stopScanningCallCount >= 1)
  }

  @Test
  func `older stream termination does not stop newer scan`() async throws {
    let (manager, mock) = try ConnectionManager.createForTesting()

    let stream1 = manager.startBLEScanning()
    let consumeTask1 = Task {
      for await _ in stream1 {}
    }
    try await waitUntil("stream1 scanning should start") {
      await mock.isScanning
    }

    let stream2 = manager.startBLEScanning()
    let consumeTask2 = Task {
      for await _ in stream2 {}
    }
    try await waitUntil("stream2 scanning should start") {
      await mock.startScanningCallCount == 2
    }

    consumeTask1.cancel()
    _ = await consumeTask1.result

    // Fixed sleep: negative assertion — older stream cleanup must not stop the newer scan.
    // We wait briefly to confirm no erroneous stopScanning call fires.
    try? await Task.sleep(for: .milliseconds(100))

    #expect(await mock.isScanning, "Newer scan should remain active")

    consumeTask2.cancel()
    _ = await consumeTask2.result
  }

  /// A page opened over another that scans (Device Info over Connections) shares the scan: both
  /// hear each radio, Back ending the newer stream leaves the older one scanning, and only the
  /// last stream to end stops it.
  @Test
  func `streams open together share the scan and the last to end stops it`() async throws {
    let (manager, mock) = try ConnectionManager.createForTesting()
    let older = HeardRadios()
    let newer = HeardRadios()

    let olderTask = Task {
      for await discovery in manager.startBLEScanning() { older.ids.append(discovery.id) }
    }
    try await waitUntil("older scanning should start") {
      await mock.isScanning
    }
    let newerTask = Task {
      for await discovery in manager.startBLEScanning() { newer.ids.append(discovery.id) }
    }
    try await waitUntil("newer scanning should start") {
      await mock.startScanningCallCount == 2
    }

    let first = UUID()
    await mock.simulateDiscoveredDevice(id: first, name: "MeshCore-A", rssi: -60)
    try await waitUntil("both streams should hear the radio") {
      older.ids == [first] && newer.ids == [first]
    }

    newerTask.cancel()
    _ = await newerTask.result
    // Fixed sleep: negative assertion — the newer stream's end must not stop the older scan.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await mock.isScanning, "The older stream keeps the scan")

    let second = UUID()
    await mock.simulateDiscoveredDevice(id: second, name: "MeshCore-B", rssi: -70)
    try await waitUntil("the older stream should still hear radios") {
      older.ids == [first, second]
    }
    #expect(newer.ids == [first])

    olderTask.cancel()
    _ = await olderTask.result
    try await waitUntil("the last stream's end should stop scanning") {
      await mock.isScanning == false
    }
  }

  private func nextValue(
    from stream: AsyncStream<DiscoveredDevice>,
    timeout: Duration
  ) async -> DiscoveredDevice? {
    await withTaskGroup(of: DiscoveredDevice?.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }

      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}

/// What one scan consumer heard, in order.
@MainActor
private final class HeardRadios {
  var ids: [UUID] = []
}
