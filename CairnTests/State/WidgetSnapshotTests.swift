import Foundation
@testable import Cairn
import Testing

@Suite("WidgetSnapshot store")
struct WidgetSnapshotStoreTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private var sample: WidgetSnapshot {
    WidgetSnapshot(
      radioName: "Ridge Relay",
      connectionState: .connected,
      batteryPercent: 76,
      unreadCount: 3,
      lastHeard: WidgetSnapshot.HeardNode(name: "Alex", date: now.addingTimeInterval(-300)),
      updatedAt: now
    )
  }

  @Test
  func `encodes and decodes every field`() throws {
    let decoded = try WidgetSnapshotStore.decode(WidgetSnapshotStore.encode(sample))
    #expect(decoded == sample)
  }

  @Test
  func `nil fields survive a round trip`() throws {
    let bare = WidgetSnapshot(
      radioName: nil, connectionState: .disconnected, batteryPercent: nil, unreadCount: 0,
      lastHeard: nil, updatedAt: now
    )
    let decoded = try WidgetSnapshotStore.decode(WidgetSnapshotStore.encode(bare))
    #expect(decoded == bare)
    #expect(decoded.radioName == nil)
    #expect(decoded.lastHeard == nil)
  }

  @Test
  func `saves to and loads from a defaults suite`() throws {
    let suite = "WidgetSnapshotStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(WidgetSnapshotStore.load(from: defaults) == nil)
    WidgetSnapshotStore.save(sample, to: defaults)
    #expect(WidgetSnapshotStore.load(from: defaults) == sample)
  }

  @Test
  func `garbage in the store reads as no snapshot`() throws {
    let suite = "WidgetSnapshotStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not json".utf8), forKey: WidgetSnapshotStore.defaultsKey)
    #expect(WidgetSnapshotStore.load(from: defaults) == nil)
  }

  @Test
  func `same content ignores the write time`() {
    var later = sample
    later.updatedAt = now.addingTimeInterval(600)
    #expect(sample.hasSameContent(as: later))
    later.unreadCount += 1
    #expect(!sample.hasSameContent(as: later))
  }

  @Test
  func `app group follows the bundle, dev and release, app and widget alike`() {
    #expect(WidgetSnapshotStore.appGroupID(bundleIdentifier: "cvhvisuals.Cairn") == "group.cvhvisuals.Cairn")
    #expect(WidgetSnapshotStore.appGroupID(bundleIdentifier: "cvhvisuals.Cairn.widgets") == "group.cvhvisuals.Cairn")
    #expect(WidgetSnapshotStore.appGroupID(bundleIdentifier: "cvhvisuals.Cairn.dev") == "group.cvhvisuals.Cairn.dev")
    #expect(WidgetSnapshotStore.appGroupID(bundleIdentifier: "cvhvisuals.Cairn.dev.widgets") == "group.cvhvisuals.Cairn.dev")
  }
}

@Suite("WidgetSnapshotPublisher debounce")
@MainActor
struct WidgetSnapshotPublisherTests {
  /// A publisher on a clock the test moves, recording every write.
  @MainActor
  final class Harness {
    var now: Date
    var writes: [WidgetSnapshot] = []
    private(set) var publisher: WidgetSnapshotPublisher!

    init(start: Date = Date(timeIntervalSinceReferenceDate: 1_000_000), interval: TimeInterval = 30) {
      now = start
      publisher = WidgetSnapshotPublisher(
        interval: interval,
        now: { [unowned self] in self.now },
        write: { [unowned self] in self.writes.append($0) }
      )
    }

    func advance(by seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
    }
  }

  private func snapshot(
    state: WidgetSnapshot.ConnectionState = .connected,
    unread: Int = 0,
    battery: Int? = 50
  ) -> WidgetSnapshot {
    WidgetSnapshot(
      radioName: "Ridge Relay", connectionState: state, batteryPercent: battery, unreadCount: unread,
      lastHeard: nil, updatedAt: .distantPast
    )
  }

  @Test
  func `the first snapshot writes at once, stamped with the clock`() {
    let harness = Harness()
    harness.publisher.publish(snapshot())
    #expect(harness.writes.count == 1)
    #expect(harness.writes.first?.updatedAt == harness.now)
  }

  @Test
  func `changes inside the interval wait and fold into the newest`() {
    let harness = Harness()
    harness.publisher.publish(snapshot(unread: 0))
    harness.advance(by: 5)
    harness.publisher.publish(snapshot(unread: 1))
    harness.advance(by: 5)
    harness.publisher.publish(snapshot(unread: 2))
    #expect(harness.writes.count == 1)
    #expect(harness.publisher.pending?.unreadCount == 2)

    harness.advance(by: 20)
    harness.publisher.flushPending()
    #expect(harness.writes.count == 2)
    #expect(harness.writes.last?.unreadCount == 2)
    #expect(harness.writes.last?.updatedAt == harness.now)
    #expect(harness.publisher.pending == nil)
  }

  @Test
  func `a change after the interval writes at once`() {
    let harness = Harness()
    harness.publisher.publish(snapshot(unread: 0))
    harness.advance(by: 30)
    harness.publisher.publish(snapshot(unread: 1))
    #expect(harness.writes.count == 2)
    #expect(harness.writes.last?.unreadCount == 1)
  }

  @Test
  func `a connection change skips the interval`() {
    let harness = Harness()
    harness.publisher.publish(snapshot(state: .connected))
    harness.advance(by: 1)
    harness.publisher.publish(snapshot(state: .disconnected, battery: nil))
    #expect(harness.writes.count == 2)
    #expect(harness.writes.last?.connectionState == .disconnected)
    // and it supersedes anything that was waiting
    #expect(harness.publisher.pending == nil)
  }

  @Test
  func `a snapshot that says what the widget shows writes nothing`() {
    let harness = Harness()
    harness.publisher.publish(snapshot(unread: 1))
    harness.advance(by: 60)
    harness.publisher.publish(snapshot(unread: 1))
    #expect(harness.writes.count == 1)
  }

  @Test
  func `returning to the shown state drops the waiting write`() {
    let harness = Harness()
    harness.publisher.publish(snapshot(unread: 1))
    harness.advance(by: 2)
    harness.publisher.publish(snapshot(unread: 2))
    #expect(harness.publisher.pending != nil)
    harness.publisher.publish(snapshot(unread: 1))
    #expect(harness.publisher.pending == nil)
    harness.advance(by: 60)
    harness.publisher.flushPending()
    #expect(harness.writes.count == 1)
  }

  @Test
  func `the trailing write lands on its own once the interval passes`() async throws {
    let harness = Harness(interval: 0.05)
    harness.publisher.publish(snapshot(unread: 0))
    harness.advance(by: 0.01)
    harness.publisher.publish(snapshot(unread: 3))
    #expect(harness.writes.count == 1)
    try await waitUntil(timeout: .seconds(5), "trailing write never ran") { harness.writes.count == 2 }
    #expect(harness.writes.last?.unreadCount == 3)
  }

  @Test
  func `immediate-write rule`() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let shown = snapshot(state: .connected)
    #expect(WidgetSnapshotPublisher.writesImmediately(previous: nil, next: shown, lastWriteDate: nil, now: now))
    #expect(!WidgetSnapshotPublisher.writesImmediately(
      previous: shown, next: snapshot(unread: 1), lastWriteDate: now.addingTimeInterval(-29), now: now
    ))
    #expect(WidgetSnapshotPublisher.writesImmediately(
      previous: shown, next: snapshot(unread: 1), lastWriteDate: now.addingTimeInterval(-30), now: now
    ))
    #expect(WidgetSnapshotPublisher.writesImmediately(
      previous: shown, next: snapshot(state: .connecting), lastWriteDate: now, now: now
    ))
  }
}
