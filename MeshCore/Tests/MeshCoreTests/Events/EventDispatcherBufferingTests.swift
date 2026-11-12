import Foundation
@testable import MeshCore
import Testing

@Suite("EventDispatcher buffering policy and labelled drops")
struct EventDispatcherBufferingTests {
  @Test
  func `default policy keeps the newest 100 of 500 and counts 400 drops under the label`() async {
    let dispatcher = EventDispatcher()
    let (id, stream) = await dispatcher.subscribeTracked(label: "slow")

    for i in 0..<500 {
      await dispatcher.dispatch(advert(i))
    }
    await dispatcher.finishSubscription(id: id)

    let received = await collect(stream).compactMap(advertIndex)
    #expect(received == Array(400..<500))
    #expect(await dispatcher.droppedEventCount(label: "slow") == 400)
    #expect(await dispatcher.dropCounts == ["slow": 400])
    #expect(await dispatcher.droppedEventCount == 400)
  }

  @Test
  func `a 4096-event buffer keeps all 500 in order with no drops`() async {
    let dispatcher = EventDispatcher()
    let (id, stream) = await dispatcher.subscribeTracked(bufferingPolicy: .bufferingNewest(4096), label: "deep")

    for i in 0..<500 {
      await dispatcher.dispatch(advert(i))
    }
    await dispatcher.finishSubscription(id: id)

    let received = await collect(stream).compactMap(advertIndex)
    #expect(received == Array(0..<500))
    #expect(await dispatcher.droppedEventCount(label: "deep") == 0)
    #expect(await dispatcher.dropCounts.isEmpty)
  }

  @Test
  func `drops count per label, and unlabelled drops only in the total`() async {
    let dispatcher = EventDispatcher()
    let labelled = await dispatcher.subscribe(filter: nil, bufferingPolicy: .bufferingNewest(10), label: "a")
    let unlabelled = await dispatcher.subscribe(filter: nil, bufferingPolicy: .bufferingNewest(20), label: nil)

    for i in 0..<30 {
      await dispatcher.dispatch(advert(i))
    }

    #expect(await dispatcher.dropCounts == ["a": 20])
    #expect(await dispatcher.droppedEventCount == 30)
    _ = labelled
    _ = unlabelled
  }

  @Test
  func `the session's buffered subscription applies its filter and reports drops by label`() async throws {
    let session = MeshCoreSession(transport: MockTransport())
    let stream = await session.events(filter: .rxLogData, buffering: .bufferingNewest(2), label: "rx")

    await session.dispatchForTesting(advert(0))
    for _ in 0..<5 {
      await session.dispatchForTesting(.rxLogData(rxLog()))
    }

    #expect(await session.eventDropCount(label: "rx") == 3)
    #expect(await session.eventDropCounts == ["rx": 3])
    await session.stop()
    let received = await collect(stream)
    #expect(received.count == 2)
    #expect(received.allSatisfy { if case .rxLogData = $0 { true } else { false } })
  }

  @Test
  func `a conformer without buffer control falls back to the plain filtered stream`() async {
    let streaming = PlainStreaming()
    _ = await streaming.events(filter: .rxLogData, buffering: .bufferingNewest(4096), label: "x")
    #expect(await streaming.plainCalls == 1)
    #expect(await streaming.eventDropCount(label: "x") == 0)
  }
}

private func advert(_ i: Int) -> MeshEvent {
  .advertisement(publicKey: Data([UInt8(i & 0xFF), UInt8(i >> 8)]))
}

private func advertIndex(_ event: MeshEvent) -> Int? {
  guard case let .advertisement(key) = event, key.count == 2 else { return nil }
  return Int(key[0]) | Int(key[1]) << 8
}

private func rxLog() -> ParsedRxLogData {
  RxLogParser.parse(snr: 5, rssi: -80, payload: Data([0x11, 0x00, 0x01]))!
}

private func collect(_ stream: AsyncStream<MeshEvent>) async -> [MeshEvent] {
  var events: [MeshEvent] = []
  for await event in stream {
    events.append(event)
  }
  return events
}

/// A test double that implements only the original requirements.
private actor PlainStreaming: SessionEventStreaming {
  var plainCalls = 0

  var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { $0.finish() }
  }

  func events() async -> AsyncStream<MeshEvent> {
    AsyncStream { $0.finish() }
  }

  func events(filter _: EventFilter) async -> AsyncStream<MeshEvent> {
    plainCalls += 1
    return AsyncStream { $0.finish() }
  }

  func waitForEvent(filter _: EventFilter, timeout _: TimeInterval?) async -> MeshEvent? {
    nil
  }
}
