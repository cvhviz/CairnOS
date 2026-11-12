import CairnServices
import CoreLocation
import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("DiscoveryProbeCoordinator")
@MainActor
struct DiscoveryProbeCoordinatorTests {
  private nonisolated static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: - Fakes

  /// One connection's radio: records each request sent and each tag noted, and plays overheard
  /// discover requests to whoever subscribed.
  private actor FakeRadio {
    struct Send: Equatable {
      let filter: UInt8
      let tag: UInt32
      let at: Date
    }

    struct Note: Equatable {
      let tag: UInt32
      let filter: UInt8
      let at: Date
    }

    private let now: @Sendable () -> Date
    private(set) var sends: [Send] = []
    private(set) var notes: [Note] = []
    /// Each hold of the session's background traffic asked for, in order.
    private(set) var holds: [Duration] = []
    /// How many times the hold was ended early.
    private(set) var releases = 0
    /// "mark", "hold" and "send", in the order the probe did them.
    private(set) var steps: [String] = []
    private var overheardSubscribers: [AsyncStream<Date>.Continuation] = []
    private var nextSendError: MeshCoreError?

    init(now: @escaping @Sendable () -> Date) {
      self.now = now
    }

    func failNextSend(with error: MeshCoreError = .timeout) {
      nextSendError = error
    }

    func send(filter: UInt8, tag: UInt32) throws {
      if let error = nextSendError {
        nextSendError = nil
        throw error
      }
      steps.append("send")
      sends.append(Send(filter: filter, tag: tag, at: now()))
    }

    func hold(_ duration: Duration) {
      steps.append("hold")
      holds.append(duration)
    }

    func release() {
      releases += 1
    }

    func noteMark() {
      steps.append("mark")
    }

    func note(tag: UInt32, filter: UInt8, at date: Date) {
      notes.append(Note(tag: tag, filter: filter, at: date))
    }

    func overheardRequests() -> AsyncStream<Date> {
      let (stream, continuation) = AsyncStream.makeStream(of: Date.self)
      overheardSubscribers.append(continuation)
      return stream
    }

    var overheardSubscriberCount: Int {
      overheardSubscribers.count
    }

    func overhear(at date: Date) {
      for subscriber in overheardSubscribers {
        subscriber.yield(date)
      }
    }
  }

  /// What the coordinator told the location service, in order.
  @MainActor
  private final class DemandLog {
    var demands: [NodeDiscoveryLocationDemand] = []
  }

  /// A connection's identity.
  private final class Connection {}

  /// A radio reading that answers when the test says.
  private actor ReadingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var isWaiting: Bool {
      continuation != nil
    }

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func open() {
      isOpen = true
      continuation?.resume()
      continuation = nil
    }
  }

  /// Set once a waiter has returned.
  @MainActor
  private final class WaitFlag {
    var isSet = false
  }

  private let clock = TestClock()
  private let demandLog = DemandLog()
  private let gate: DiscoverRequestGate
  private let coordinator: DiscoveryProbeCoordinator
  private let now: @Sendable () -> Date
  private let radioID = UUID()

  init() {
    let clock = clock
    let now: @Sendable () -> Date = {
      let offset = clock.now.offset.components
      return Self.base.addingTimeInterval(TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18)
    }
    self.now = now
    gate = DiscoverRequestGate(now: now)
    let demandLog = demandLog
    coordinator = DiscoveryProbeCoordinator(
      gate: gate,
      location: DiscoveryProbeCoordinator.Location(
        latestFix: { nil },
        canFollow: { false },
        setDemand: { demandLog.demands.append($0) }
      ),
      now: now,
      sleep: { try await clock.sleep(for: $0) }
    )
  }

  private func makeRadio() -> FakeRadio {
    FakeRadio(now: now)
  }

  private func binding(
    _ radio: FakeRadio,
    connection: Connection,
    listenWindow: TimeInterval = 6,
    canDiscover: Bool = true,
    missed: Int?? = nil,
    deliveryMark: (@Sendable () async -> DiscoveryProbeCoordinator.DeliveryMark?)? = nil
  ) -> DiscoveryProbeCoordinator.Binding {
    DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(connection),
      radioID: radioID,
      listenWindow: listenWindow,
      sendDiscoverRequest: { filter, tag in try await radio.send(filter: filter, tag: tag) },
      noteProbe: { tag, filter, date in await radio.note(tag: tag, filter: filter, at: date) },
      overheardRequests: { await radio.overheardRequests() },
      updateLocationFix: { _ in },
      canDiscover: canDiscover,
      holdBackgroundTraffic: { await radio.hold($0) },
      releaseBackgroundTraffic: { await radio.release() },
      // nil: delivery can't be measured; .some(count): a mark whose window missed `count`
      deliveryMark: deliveryMark ?? {
        guard let missed else { return nil }
        await radio.noteMark()
        return DiscoveryProbeCoordinator.DeliveryMark { missed }
      }
    )
  }

  /// A connected radio as official companion firmware reports itself in DEVICE_INFO
  /// (FIRMWARE_VER_CODE and the version string, from the release tags).
  private static func device(firmwareVersion: UInt8, firmwareVersionString: String) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "TestDevice",
      firmwareVersion: firmwareVersion,
      firmwareVersionString: firmwareVersionString,
      manufacturerName: "TestMfg",
      buildDate: "01 Jan 2025",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: false,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }

  /// Waits until the running probe has sent and parked on its listen window.
  private func waitForWindow(_ radio: FakeRadio, sends: Int = 1) async throws {
    try await waitUntil { await radio.sends.count == sends && coordinator.activeProbe?.endsAt != nil }
    try await waitUntil { clock.sleeperCount >= 1 }
  }

  /// Lets the coordinator's tasks catch up after the clock moved.
  private func settle() async throws {
    for _ in 0..<8 {
      await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(2))
  }

  /// A neighbour that answered a probe at `replyAt`.
  private func answeringSnapshot(replyAt: Date) -> NeighbourSnapshot {
    let key = Data(repeating: 0xA1, count: 32)
    let reply = NeighbourSourceStats(count: 1, firstHeard: replyAt, lastHeard: replyAt)
    let record = NeighbourRecord(
      identity: .fullKey(key),
      firstHeard: replyAt,
      lastHeard: replyAt,
      heardCount: 1,
      lastSNR: 6,
      snrEWMA: 6,
      sources: [.replyToUs: reply],
      nodeTypeRaw: ContactType.repeater.rawValue,
      name: "Alpha"
    )
    return NeighbourSnapshot(
      radioID: radioID,
      takenAt: replyAt,
      neighbours: NeighbourResolver.resolveAll(NeighbourTable(records: [record]), index: .empty, now: replyAt)
    )
  }

  // MARK: - Probes

  @Test
  func `a CarPlay request during a phone probe attaches with one send`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))

    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .carPlay) == .attached)
    #expect(coordinator.activeProbe?.origins == [.phone, .carPlay])

    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    #expect(await radio.sends.count == 1)
    #expect(coordinator.sentProbeCount == 1)
    #expect(coordinator.lastSummary?.filter == .repeaters)
    #expect(coordinator.state == .coolingDown(until: Self.base.addingTimeInterval(45), reason: .spacing))
  }

  @Test
  func `a press during cooldown sends nothing and exposes until and reason`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()

    clock.advance(by: .seconds(10))
    let until = Self.base.addingTimeInterval(45)
    #expect(await coordinator.requestProbe(filter: .sensors, origin: .phone) == .coolingDown(until: until, reason: .spacing))
    #expect(coordinator.state == .coolingDown(until: until, reason: .spacing))
    #expect(!coordinator.isProbing)
    #expect(await radio.sends.count == 1)
  }

  @Test
  func `requests overheard from others refuse ours before anything is sent`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    try await waitUntil { await radio.overheardSubscriberCount == 1 }
    clock.advance(by: .seconds(30))
    // Two leave room for ours; a third would spend the token others may need
    await radio.overhear(at: now().addingTimeInterval(-30))
    await radio.overhear(at: now().addingTimeInterval(-20))
    await radio.overhear(at: now().addingTimeInterval(-10))
    try await waitUntil { await gate.status() != .allowed }

    let outcome = await coordinator.requestProbe(filter: .repeaters, origin: .phone)
    #expect(outcome == .coolingDown(until: Self.base.addingTimeInterval(120), reason: .othersScanning))
    #expect(await radio.sends.isEmpty)
  }

  @Test
  func `the probe's tag is noted with the neighbour service before the request is sent`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)

    let sends = await radio.sends
    let notes = await radio.notes
    #expect(notes.count == 1)
    #expect(notes.first?.tag == sends.first?.tag)
    #expect(notes.first?.filter == NodeDiscoveryFilter.repeaters.filterValue)
    #expect(sends.first?.filter == NodeDiscoveryFilter.repeaters.filterValue)
    #expect(coordinator.activeProbe?.tag == sends.first?.tag)
    if let noted = notes.first?.at, let sent = sends.first?.at {
      #expect(noted <= sent)
    }
  }

  @Test
  func `a late reply extends the listen window`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    #expect(coordinator.activeProbe?.endsAt == Self.base.addingTimeInterval(6))

    coordinator.noteSnapshot(answeringSnapshot(replyAt: Self.base.addingTimeInterval(4)))
    #expect(coordinator.activeProbe?.endsAt == Self.base.addingTimeInterval(9))

    clock.advance(by: .seconds(6))
    try await settle()
    #expect(coordinator.isProbing)
    clock.advance(by: .seconds(3))
    await coordinator.waitForProbe()
    #expect(!coordinator.isProbing)
    #expect(coordinator.lastSummary?.answered == 1)
  }

  @Test
  func `a services change mid-probe gives interrupted and keeps results`() async throws {
    let oldRadio = makeRadio()
    let oldConnection = Connection()
    coordinator.bind(binding(oldRadio, connection: oldConnection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(oldRadio)
    coordinator.noteSnapshot(answeringSnapshot(replyAt: Self.base.addingTimeInterval(1)))
    let tag = try #require(coordinator.activeProbe?.tag)

    let newRadio = makeRadio()
    let newConnection = Connection()
    coordinator.bind(binding(newRadio, connection: newConnection))
    guard case let .interrupted(probe) = coordinator.state else {
      Issue.record("Expected interrupted, got \(coordinator.state)")
      return
    }
    #expect(probe.tag == tag)
    // The new service learns the tag, so the rest of the window's replies are still answers to us
    try await waitUntil { await newRadio.notes.map(\.tag) == [tag] }

    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    #expect(coordinator.lastSummary?.answered == 1)
    #expect(await oldRadio.sends.count == 1)
    #expect(await newRadio.sends.isEmpty)
  }

  @Test
  func `a send that fails still settles its gate slot, so the next probe confirms its own`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    await radio.failNextSend()
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    await coordinator.waitForProbe()
    #expect(coordinator.lastError != nil)
    // it may have gone on air: the gate counts it from when it was sent
    #expect(coordinator.state == .coolingDown(until: Self.base.addingTimeInterval(45), reason: .spacing))

    clock.advance(by: .seconds(45))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()

    // the failed request leaves the window at 120 s, leaving only the one sent at 45 s
    clock.advance(by: .seconds(120 - 51))
    #expect(await gate.status() == .allowed)
  }

  @Test
  func `attaching while the gate is still asked waits for the probe`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))

    // The request parks on the gate; a waiter that comes in then, as Wardrive's loop would after an
    // attach, must suspend rather than find no probe task and spin on the main actor
    let request = Task { await coordinator.requestProbe(filter: .repeaters, origin: .phone) }
    let waited = WaitFlag()
    let waiter = Task {
      await coordinator.waitForProbe()
      waited.isSet = true
    }
    #expect(await request.value == .started)
    try await waitForWindow(radio)
    try await settle()
    #expect(!waited.isSet, "the probe is still listening")

    clock.advance(by: .seconds(6))
    await waiter.value
    #expect(waited.isSet)
    #expect(!coordinator.isProbing)
  }

  @Test
  func `a probe never carries over to another radio`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)

    // Both connections stay alive, so their identities can't coincide
    let otherConnection = Connection()
    let other = DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(otherConnection),
      radioID: UUID(),
      listenWindow: 6,
      sendDiscoverRequest: { _, _ in },
      noteProbe: { _, _, _ in },
      overheardRequests: { AsyncStream { $0.finish() } },
      updateLocationFix: { _ in }
    )
    coordinator.bind(other)
    #expect(!coordinator.isProbing)
    withExtendedLifetime((connection, otherConnection)) {}
  }

  // MARK: - Firmware Without Discover

  @Test
  func `official firmware before v1_10 can't probe and the rest can`() {
    let firmwares: [(code: UInt8, version: String, canProbe: Bool)] = [
      (7, "v1.9.0", false),
      (8, "v1.10.0", true),
      (8, "v1.11.0", true),
      (14, "v1.18.0", true),
    ]
    var connections: [Connection] = []
    for firmware in firmwares {
      let device = Self.device(firmwareVersion: firmware.code, firmwareVersionString: firmware.version)
      let connection = Connection()
      connections.append(connection)
      coordinator.bind(binding(makeRadio(), connection: connection, canDiscover: device.supportsNodeDiscover))
      #expect(coordinator.isDiscoverSupported == firmware.canProbe, "\(firmware.version)")
    }
    coordinator.handleDisconnect()
    #expect(coordinator.isDiscoverSupported, "nothing is said about a radio that isn't connected")
    withExtendedLifetime(connections) {}
  }

  @Test
  func `a radio without the discover command is refused before the gate is asked`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    let v190 = Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")
    coordinator.bind(binding(radio, connection: connection, canDiscover: v190.supportsNodeDiscover))

    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .unsupported)
    #expect(await coordinator.requestProbe(filter: .sensors, origin: .carPlay) == .unsupported)
    #expect(coordinator.state == .idle)
    #expect(coordinator.lastError == nil)
    #expect(await radio.sends.isEmpty)
    #expect(await radio.notes.isEmpty)
    // No slot was reserved: one would make the gate wait out its spacing
    #expect(await gate.status() == .allowed)

    coordinator.startWardrive(filter: .repeaters)
    #expect(!coordinator.isWardriving)
    #expect(await radio.sends.isEmpty)
  }

  @Test
  func `a radio that refuses the request gives its slot back and stops Wardrive without an error`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    // The version said it could; the radio answers ERR_CODE_UNSUPPORTED_CMD ([0x01][0x01])
    coordinator.bind(binding(radio, connection: connection))
    #expect(await gate.status() == .allowed)
    await radio.failNextSend(with: .deviceError(code: ErrorCode.unsupportedCommand.rawValue))

    coordinator.startWardrive(filter: .repeaters)
    try await waitUntil { !coordinator.isWardriving }
    #expect(!coordinator.isDiscoverSupported)
    #expect(coordinator.lastError == nil)
    #expect(coordinator.lastSummary == nil)
    #expect(coordinator.state == .idle)
    #expect(await radio.sends.isEmpty)
    // Nothing went on air, so the gate is as it was before the request
    #expect(await gate.status() == .allowed)

    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .unsupported)
    // Re-wiring the same connection keeps the refusal; a new connection asks again
    coordinator.bind(binding(radio, connection: connection))
    #expect(!coordinator.isDiscoverSupported)
    let newConnection = Connection()
    coordinator.bind(binding(radio, connection: newConnection))
    #expect(coordinator.isDiscoverSupported)
    withExtendedLifetime((connection, newConnection)) {}
  }

  // MARK: - Delivery and Pacing

  @Test
  func `the summary carries the packets the radio heard during the probe that never reached the app`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection, missed: 3))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()

    // Read just after the probe ended
    try await waitUntil { coordinator.lastSummary?.radioMissed == 3 }
    // Delivery is read before the window's hold, and the hold starts before the request goes out
    #expect(await radio.steps == ["mark", "hold", "send"])
  }

  @Test
  func `a probe ends on time while its missed count is still being read`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    // The end reading waits for a quiet link and a stats round trip, or a dropped reply's timeout
    let reply = ReadingGate()
    let mark = DiscoveryProbeCoordinator.DeliveryMark {
      await reply.wait()
      return 4
    }
    coordinator.bind(binding(radio, connection: connection, deliveryMark: { mark }))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()

    #expect(!coordinator.isProbing, "the scan isn't left at 0 s while the radio is asked")
    #expect(coordinator.lastSummary != nil)
    #expect(coordinator.lastSummary?.radioMissed == nil)
    try await waitUntil { await reply.isWaiting }
    await reply.open()
    try await waitUntil { coordinator.lastSummary?.radioMissed == 4 }
    withExtendedLifetime(connection) {}
  }

  @Test
  func `a slow delivery reading doesn't hold the request back`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    let clock = clock
    // A reading whose stats reply the radio dropped: it would wait the session's whole timeout
    coordinator.bind(binding(radio, connection: connection, deliveryMark: {
      await radio.noteMark()
      try? await clock.sleep(for: .seconds(5))
      return DiscoveryProbeCoordinator.DeliveryMark { 9 }
    }))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    // The reading and its time limit
    try await waitUntil { clock.sleeperCount == 2 }
    try await settle()
    #expect(await radio.sends.isEmpty)

    clock.advance(by: .seconds(DiscoveryProbeCoordinator.startMarkLimit))
    try await waitForWindow(radio)
    #expect(await radio.sends.first?.at == Self.base.addingTimeInterval(DiscoveryProbeCoordinator.startMarkLimit))
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    try await settle()
    // No reading to measure from: no missed count
    #expect(coordinator.lastSummary != nil)
    #expect(coordinator.lastSummary?.radioMissed == nil)
    withExtendedLifetime(connection) {}
  }

  /// How a probe ended, for the hold it placed.
  enum ProbeEnding: String, CaseIterable, Sendable {
    /// The radio refused the send (official companion firmware before v1.10).
    case unsupported
    /// The send failed (a timeout).
    case failed
    /// Stopped early.
    case stopped
    /// The window ran out.
    case finished
  }

  @Test(arguments: ProbeEnding.allCases)
  func `the hold ends with the probe however it ends`(ending: ProbeEnding) async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    switch ending {
    case .unsupported: await radio.failNextSend(with: .deviceError(code: 1))
    case .failed: await radio.failNextSend(with: .timeout)
    case .stopped, .finished: break
    }
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    switch ending {
    case .stopped:
      try await waitForWindow(radio)
      coordinator.stopProbe()
    case .finished:
      try await waitForWindow(radio)
      clock.advance(by: .seconds(6))
    case .unsupported, .failed:
      break
    }
    await coordinator.waitForProbe()
    try await waitUntil { await radio.releases == 1 }
    #expect(await radio.holds.count == 1)
    try await settle()
    #expect(await radio.releases == 1)
    withExtendedLifetime(connection) {}
  }

  @Test
  func `the summary has no missed count when delivery can't be read`() async throws {
    for missed: Int?? in [nil, .some(nil)] {
      let radio = makeRadio()
      let connection = Connection()
      coordinator.bind(binding(radio, connection: connection, missed: missed))
      clock.advance(by: .seconds(120))
      #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
      try await waitForWindow(radio)
      clock.advance(by: .seconds(6))
      await coordinator.waitForProbe()
      #expect(coordinator.lastSummary != nil)
      #expect(coordinator.lastSummary?.radioMissed == nil)
      withExtendedLifetime(connection) {}
    }
  }

  @Test
  func `a probe stopped early has no missed count`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection, missed: 5))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    coordinator.stopProbe()
    #expect(coordinator.lastSummary != nil)
    #expect(coordinator.lastSummary?.radioMissed == nil)
  }

  @Test
  func `background traffic is held for the listen window and again when a late reply extends it`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    #expect(await radio.holds == [.seconds(6)])

    coordinator.noteSnapshot(answeringSnapshot(replyAt: Self.base.addingTimeInterval(4)))
    #expect(coordinator.activeProbe?.endsAt == Self.base.addingTimeInterval(9))
    try await waitUntil { await radio.holds.count == 2 }
    #expect(await radio.holds == [.seconds(6), .seconds(9)])
  }

  // MARK: - Wardrive

  @Test
  func `Wardrive never sends faster than the gate even with injected overheard requests`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    try await waitUntil { await radio.overheardSubscriberCount == 1 }
    coordinator.startWardrive(filter: .repeaters)
    #expect(coordinator.isWardriving)

    // A fixed pseudo-random sequence: others scan about once a minute on average
    var seed: UInt64 = 0x5EED
    var overheard: [Date] = []
    for _ in 0..<900 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      if seed >> 58 == 0 {
        let date = now()
        overheard.append(date)
        await radio.overhear(at: date)
      }
      try await settle()
      clock.advance(by: .seconds(1))
    }
    coordinator.stopWardrive()
    try await settle()

    let sends = await radio.sends.map(\.at)
    #expect(sends.count >= 3)
    #expect(coordinator.wardriveProbeCount == sends.count)
    for (index, sent) in sends.enumerated() {
      // A request leaves the repeaters' window once it is exactly `window` old
      let windowStart = sent.addingTimeInterval(-DiscoverRequestGate.window)
      let ownBefore = sends[..<index].filter { $0 > windowStart }
      if let previous = sends[..<index].last {
        #expect(sent.timeIntervalSince(previous) >= DiscoverRequestGate.minimumSpacing)
      }
      #expect(ownBefore.count <= DiscoverRequestGate.maximumOwnInWindow)
      // Only requests heard at least a second before the send could have reached the gate
      let othersBefore = overheard.filter { $0 > windowStart && $0 <= sent.addingTimeInterval(-1) }
      #expect(ownBefore.count + othersBefore.count <= DiscoverRequestGate.maximumKnownInWindow)
    }
  }

  @Test
  func `disconnect stops Wardrive and releases the location claim`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    coordinator.startWardrive(filter: .repeaters)
    #expect(demandLog.demands.last == .wardrive)
    try await waitForWindow(radio)

    coordinator.handleDisconnect()
    #expect(!coordinator.isWardriving)
    #expect(demandLog.demands.last == NodeDiscoveryLocationDemand.none)
    // The probe already on air is interrupted, not re-sent
    guard case .interrupted = coordinator.state else {
      Issue.record("Expected interrupted, got \(coordinator.state)")
      return
    }

    for _ in 0..<200 {
      clock.advance(by: .seconds(1))
      try await settle()
    }
    #expect(await radio.sends.count == 1)
    #expect(!coordinator.isProbing)
    #expect(demandLog.demands.last == NodeDiscoveryLocationDemand.none)
  }

  // MARK: - Scans

  @Test
  func `a scan starts when the gate lets it go and stands until the next one starts`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(coordinator.currentScan == nil, "nothing scanned yet")

    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    let first = try #require(coordinator.currentScan)
    #expect(first == DiscoveryProbeCoordinator.Scan(radioID: radioID, filter: .repeaters, startedAt: Self.base, listensOnly: false))
    try await waitForWindow(radio)
    let sentAt = try #require(coordinator.activeProbe?.sentAt)
    #expect(first.startedAt <= sentAt, "every answer is stamped after the scan started")
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .carPlay) == .attached)
    #expect(coordinator.currentScan == first, "joining a probe joins its scan")

    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    #expect(coordinator.currentScan == first, "the list stays the scan's after it ends")

    clock.advance(by: .seconds(10))
    #expect(await coordinator.requestProbe(filter: .sensors, origin: .phone)
      == .coolingDown(until: Self.base.addingTimeInterval(45), reason: .spacing))
    #expect(coordinator.currentScan == first, "a refused request starts no scan")

    clock.advance(by: .seconds(45))
    #expect(await coordinator.requestProbe(filter: .sensors, origin: .phone) == .started)
    #expect(coordinator.currentScan == DiscoveryProbeCoordinator.Scan(
      radioID: radioID, filter: .sensors, startedAt: Self.base.addingTimeInterval(61), listensOnly: false
    ))
    try await waitForWindow(radio, sends: 2)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
  }

  @Test
  func `Wardrive keeps one list from Start to Stop, each probe adding to it`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    coordinator.startWardrive(filter: .repeaters)
    try await waitForWindow(radio)
    let first = try #require(coordinator.currentScan)
    #expect(first.startedAt == Self.base)
    let session = try #require(coordinator.wardriveSession)
    #expect(session.startedAt == first.startedAt)
    #expect(session.isRunning)

    var ticks = 0
    while await radio.sends.count < 2, ticks < 200 {
      try await settle()
      clock.advance(by: .seconds(1))
      ticks += 1
    }
    let sends = await radio.sends
    #expect(sends.count == 2)
    // The second probe went out, but the drive's list stands: its start is the drive's
    let second = try #require(coordinator.currentScan)
    #expect(second.startedAt == first.startedAt)
    #expect(coordinator.wardriveSession?.probeCount == 2)
    #expect(coordinator.wardriveProbeCount == 2)

    coordinator.stopWardrive()
    try await settle()
    let ended = try #require(coordinator.wardriveSession)
    #expect(!ended.isRunning)
    #expect(ended.probeCount == 2)
    #expect(coordinator.currentScan?.startedAt == first.startedAt, "stopping keeps the drive's list")
    coordinator.stopProbe()
    try await settle()
  }

  @Test
  func `a scan outlives a disconnect but never carries over to another radio`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    let scan = try #require(coordinator.currentScan)

    coordinator.handleDisconnect()
    #expect(coordinator.currentScan == scan, "the list kept from before the disconnect is still that scan's")
    let reconnection = Connection()
    coordinator.bind(binding(radio, connection: reconnection))
    #expect(coordinator.currentScan == scan, "the same radio again")

    let otherConnection = Connection()
    coordinator.bind(DiscoveryProbeCoordinator.Binding(
      id: ObjectIdentifier(otherConnection),
      radioID: UUID(),
      listenWindow: 6,
      sendDiscoverRequest: { _, _ in },
      noteProbe: { _, _, _ in },
      overheardRequests: { AsyncStream { $0.finish() } },
      updateLocationFix: { _ in }
    ))
    #expect(coordinator.currentScan == nil)
    withExtendedLifetime((connection, reconnection, otherConnection)) {}
  }

  @Test
  func `a radio that can't send a scan runs one that only listens`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    let v190 = Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")
    coordinator.bind(binding(radio, connection: connection, canDiscover: v190.supportsNodeDiscover))

    #expect(coordinator.requestListen(filter: .repeaters, origin: .phone) == .started)
    let scan = try #require(coordinator.currentScan)
    #expect(scan == DiscoveryProbeCoordinator.Scan(radioID: radioID, filter: .repeaters, startedAt: Self.base, listensOnly: true))
    let probe = try #require(coordinator.activeProbe)
    #expect(probe.listensOnly)
    #expect(probe.tag == nil)
    #expect(probe.sentAt == Self.base)
    #expect(probe.endsAt == Self.base.addingTimeInterval(6))
    #expect(coordinator.locationDemand == .scan, "what it hears gets a heard-from position")
    // Nothing was asked, so no reply extends it
    coordinator.noteSnapshot(answeringSnapshot(replyAt: Self.base.addingTimeInterval(4)))
    #expect(coordinator.activeProbe?.endsAt == Self.base.addingTimeInterval(6))
    #expect(coordinator.requestListen(filter: .repeaters, origin: .carPlay) == .attached)

    try await waitUntil { clock.sleeperCount >= 1 }
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    #expect(coordinator.state == .idle)
    #expect(coordinator.lastSummary == nil, "it asked nobody")
    #expect(coordinator.currentScan == scan)
    #expect(await radio.sends.isEmpty)
    #expect(await radio.notes.isEmpty)
    #expect(await gate.status() == .allowed, "nothing went on air")

    // Stopped early, it starts the next list all the same and still has no summary
    clock.advance(by: .seconds(1))
    #expect(coordinator.requestListen(filter: .repeaters, origin: .phone) == .started)
    #expect(coordinator.currentScan?.startedAt == Self.base.addingTimeInterval(7))
    coordinator.stopProbe()
    #expect(!coordinator.isProbing)
    #expect(coordinator.lastSummary == nil)
  }

  @Test
  func `the gate never holds back a radio that can't send a scan`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    let v190 = Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")
    coordinator.bind(binding(radio, connection: connection, canDiscover: v190.supportsNodeDiscover))
    try await waitUntil { await radio.overheardSubscriberCount == 1 }
    clock.advance(by: .seconds(30))
    // Others nearby scanning: the gate counts them, as for any radio
    await radio.overhear(at: now().addingTimeInterval(-30))
    await radio.overhear(at: now().addingTimeInterval(-20))
    await radio.overhear(at: now().addingTimeInterval(-10))
    try await waitUntil { await gate.status() != .allowed }

    // The screen opening shows no cooldown: this radio's scans only listen
    await coordinator.refreshCooldown()
    #expect(coordinator.state == .idle)
    #expect(coordinator.requestListen(filter: .repeaters, origin: .phone) == .started)
    #expect(coordinator.currentScan?.startedAt == Self.base.addingTimeInterval(30))
    try await waitUntil { clock.sleeperCount >= 1 }
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    try await settle()
    #expect(coordinator.state == .idle, "the window ending doesn't show the gate's cooldown either")
    #expect(await radio.sends.isEmpty)
  }

  @Test
  func `binding a radio that can't send a scan ends the cooldown another radio's scan left`() async throws {
    let radio = makeRadio()
    let connection = Connection()
    coordinator.bind(binding(radio, connection: connection))
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .phone) == .started)
    try await waitForWindow(radio)
    clock.advance(by: .seconds(6))
    await coordinator.waitForProbe()
    try await settle()
    guard case .coolingDown = coordinator.state else {
      Issue.record("a capable radio waits out the gate's spacing after its scan")
      return
    }

    let oldConnection = Connection()
    let v190 = Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")
    coordinator.bind(binding(makeRadio(), connection: oldConnection, canDiscover: v190.supportsNodeDiscover))
    #expect(coordinator.state == .idle)
    await coordinator.refreshCooldown()
    #expect(coordinator.state == .idle)
    #expect(coordinator.requestListen(filter: .repeaters, origin: .phone) == .started)
    withExtendedLifetime((connection, oldConnection)) {}
  }

  @Test
  func `a request with no connection is refused`() async {
    #expect(await coordinator.requestProbe(filter: .repeaters, origin: .carPlay) == .notConnected)
    #expect(coordinator.state == .idle)
  }
}
