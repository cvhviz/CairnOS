import Foundation
@testable import CairnServices
import MeshCore
import MeshCoreTestSupport
import Testing

/// Background delivery: what keeps a backgrounded app receiving everything the radio queues.
///
/// - A suspended app wakes only for a live GATT subscription or a pending connect, so whenever
///   the Bluetooth state machine ends up idle in the background a pending connect is armed, and
///   app-layer failures there never cut the link.
/// - Draining the radio's queue never waits on the contact sync: a contact phase that fails
///   still leaves auto-fetch on, and a background connect drains before contacts.
@Suite("Background delivery: wake source")
@MainActor
struct BackgroundWakeSourceTests {
  private let deviceID = UUID()

  private func makeManager(
    background: Bool = true,
    intent: ConnectionIntent = .wantsConnection()
  ) async throws -> PairingTestEnvironment {
    let env = try ConnectionManager.createForPairingTesting()
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: !background)
    env.manager.testLastConnectedDeviceID = deviceID
    env.manager.setTestState(
      connectionState: .disconnected,
      currentTransportType: .bluetooth,
      connectionIntent: intent
    )
    return env
  }

  @Test
  func `entering the background with an idle link arms exactly one pending connect`() async throws {
    let env = try await makeManager(background: false)
    defer { env.cleanup() }

    await env.manager.appDidEnterBackground()

    #expect(await env.stateMachine.armPendingReconnectCalls == [deviceID])
    #expect(env.manager.lastDisconnectDiagnostic?.contains("source=ensureWakeSource") == true)
  }

  @Test
  func `no pending connect while a wake source already exists`() async throws {
    let env = try await makeManager()
    defer { env.cleanup() }

    await env.stateMachine.setStubbedPhase(.autoReconnecting)
    #expect(await env.manager.ensureWakeSource(context: "test") == false)

    await env.stateMachine.setStubbedPhase(.connected)
    #expect(await env.manager.ensureWakeSource(context: "test") == false)

    #expect(await env.stateMachine.armPendingReconnectCalls.isEmpty)
  }

  @Test
  func `no pending connect in front, after a user disconnect, or while Bluetooth is off`() async throws {
    let foreground = try await makeManager(background: false)
    defer { foreground.cleanup() }
    #expect(await foreground.manager.ensureWakeSource(context: "test") == false)
    #expect(await foreground.stateMachine.armPendingReconnectCalls.isEmpty)

    let userDisconnected = try await makeManager(intent: .userDisconnected)
    defer { userDisconnected.cleanup() }
    #expect(await userDisconnected.manager.ensureWakeSource(context: "test") == false)
    #expect(await userDisconnected.stateMachine.armPendingReconnectCalls.isEmpty)

    let poweredOff = try await makeManager()
    defer { poweredOff.cleanup() }
    await poweredOff.stateMachine.setStubbedIsBluetoothPoweredOff(true)
    #expect(await poweredOff.manager.ensureWakeSource(context: "test") == false)
    #expect(await poweredOff.stateMachine.armPendingReconnectCalls.isEmpty)
  }

  @Test
  func `a connection lost in the background arms a pending connect`() async throws {
    let env = try await makeManager()
    defer { env.cleanup() }
    env.manager.setTestState(connectionState: .ready)

    await env.manager.handleConnectionLoss(deviceID: deviceID, error: nil)

    try await waitUntil("the watchdog's background hand-off should arm a pending connect") {
      await env.stateMachine.armPendingReconnectCalls == [deviceID]
    }
  }

  @Test
  func `a bond failure in the background never re-arms a pending connect`() async throws {
    let env = try await makeManager()
    defer { env.cleanup() }
    env.manager.setTestState(connectionState: .ready)

    await env.manager.handleConnectionLoss(deviceID: deviceID, error: BLEError.authenticationFailed)
    // Let the watchdog's hand-off task run.
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(100))

    #expect(await env.stateMachine.armPendingReconnectCalls.isEmpty)
  }

  @Test
  func `an exhausted rebuild budget in the background keeps the link`() async throws {
    let env = try await makeManager()
    defer { env.cleanup() }
    await env.stateMachine.setStubbedIsConnected(true)
    env.manager.setTestState(connectionState: .connecting)

    let budget = ConnectionManager.maxRebuildFailuresPreservingLink
    for _ in 0...(budget + 2) {
      await env.manager.handleReconnectionFailure()
    }

    #expect(await env.transport.disconnectInvocations == 0, "cutting the link would cancel the only wake source")
    #expect(env.manager.consecutiveRebuildFailures == budget + 3)
  }

  @Test
  func `link activity on a live link without an app stack rebuilds in place`() async throws {
    let env = try await makeManager()
    defer { env.cleanup() }
    await env.stateMachine.setStubbedIsConnected(true)
    await env.stateMachine.setStubbedConnectedDeviceID(deviceID)
    let rebuilds = ValueTracker<UUID>()
    env.manager.rebuildSessionForHealthCheckOverride = { id in rebuilds.record(id) }

    await env.manager.handleLinkActivity()

    #expect(rebuilds.values == [deviceID])
  }

  @Test
  func `link activity tells the app even with nothing to repair`() async throws {
    let env = try await makeManager(intent: .userDisconnected)
    defer { env.cleanup() }
    let heartbeats = CallTracker()
    env.manager.onLinkActivity = { heartbeats.markCalled() }

    await env.manager.handleLinkActivity()

    #expect(heartbeats.wasCalled)
  }
}

@Suite("Background delivery: resync")
@MainActor
struct BackgroundResyncTests {
  /// The resync harness of `ConnectionManagerResyncLoopTests`: every resync fails at once
  /// (transport not connected).
  private func makeHarness(background: Bool) async throws -> (ConnectionManager, ServiceContainer) {
    let (manager, _) = try ConnectionManager.createForTesting()
    manager.appStateProvider = MockAppStateProvider(isInForeground: !background)
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "BackgroundResync")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    let deviceID = UUID()
    try await services.dataStore.saveDevice(DeviceDTO.testDevice(id: deviceID))
    manager.setTestState(
      connectionState: .syncing,
      services: services,
      session: session,
      connectedDevice: DeviceDTO.testDevice(id: deviceID),
      currentTransportType: .bluetooth,
      connectionIntent: .wantsConnection()
    )
    return (manager, services)
  }

  @Test(.timeLimit(.minutes(1)))
  func `exhausted resyncs in the background keep the link and the session`() async throws {
    let (manager, services) = try await makeHarness(background: true)
    let resyncFailed = CallTracker()
    manager.onResyncFailed = { resyncFailed.markCalled() }
    let runtime = ValueTracker<String>()
    manager.beginBackgroundRuntime = { name in
      runtime.record("begin \(name)")
      return { runtime.record("end \(name)") }
    }
    let ended = ValueTracker<Bool>()
    await services.syncCoordinator.setSyncActivityCallbacks(
      onStarted: {},
      onEnded: { ended.record($0) },
      onPhaseChanged: { _ in }
    )

    manager.startResyncLoop(radioID: manager.connectedDevice!.radioID, services: services)

    try await waitUntil(timeout: .seconds(20), "the loop should give up") {
      manager.resyncTask == nil && !ended.values.isEmpty
    }

    #expect(manager.connectionState == .syncing, "a background resync failure must not disconnect")
    #expect(manager.services === services)
    #expect(!resyncFailed.wasCalled)
    #expect(await services.messagePollingService.isAutoFetching, "the failed resyncs leave auto-fetch on")
    #expect(runtime.values == ["begin Resync radio", "end Resync radio"], "the loop runs inside one background task")
    await services.messagePollingService.stopAutoFetch()
  }
}

@Suite("Background delivery: drain before contacts")
@MainActor
struct DrainIndependentOfContactsTests {
  private func makeDependencies(
    services: ServiceContainer,
    dataStore: any PersistenceStoreProtocol,
    contactService: MockContactService,
    polling: any MessagePollingServiceProtocol,
    appStateProvider: AppStateProvider?
  ) -> SyncDependencies {
    let base = services.syncDependencies
    return SyncDependencies(
      dataStore: dataStore,
      contactService: contactService,
      channelService: MockChannelService(),
      messagePollingService: polling,
      notificationService: base.notificationService,
      reactionService: base.reactionService,
      advertisementService: base.advertisementService,
      rxLogService: base.rxLogService,
      heardRepeatsService: base.heardRepeatsService,
      roomServerService: base.roomServerService,
      roomAdminService: base.roomAdminService,
      repeaterAdminService: base.repeaterAdminService,
      appStateProvider: appStateProvider,
      startEventMonitoring: { _, _ in },
      exportPrivateKey: { Data(repeating: 0x07, count: 64) }
    )
  }

  private func failingContacts() async -> MockContactService {
    let contacts = MockContactService()
    await contacts.setStubbedSyncContactsResult(.failure(SyncCoordinatorError.syncFailed("contacts timed out")))
    return contacts
  }

  @Test
  func `a connection whose contact sync fails still starts auto-fetch`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "DrainFirst")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MockMessagePollingService()
    let coordinator = SyncCoordinator()

    await #expect(throws: (any Error).self) {
      try await coordinator.onConnectionEstablished(
        radioID: radioID,
        dependencies: makeDependencies(
          services: services,
          dataStore: dataStore,
          contactService: await failingContacts(),
          polling: polling,
          appStateProvider: MockAppStateProvider(isInForeground: true)
        )
      )
    }

    #expect(await polling.startAutoFetchRadioIDs == [radioID])
    #expect(await polling.callLog.first == "startAutoFetch", "in front the drain still follows contacts")
    await coordinator.cancelDiscoveryEventMonitoring()
  }

  @Test
  func `a background connection drains and starts auto-fetch before contacts`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "DrainFirst")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let polling = MockMessagePollingService()
    let contacts = await failingContacts()
    let coordinator = SyncCoordinator()

    await #expect(throws: (any Error).self) {
      try await coordinator.onConnectionEstablished(
        radioID: radioID,
        dependencies: makeDependencies(
          services: services,
          dataStore: dataStore,
          contactService: contacts,
          polling: polling,
          appStateProvider: MockAppStateProvider(isInForeground: false)
        )
      )
    }

    #expect(Array(await polling.callLog.prefix(2)) == ["poll", "startAutoFetch"])
    #expect(await contacts.syncContactsInvocations.count >= 1, "contacts still sync after the drain")
    await coordinator.cancelDiscoveryEventMonitoring()
  }

  /// A Background App Refresh run waits for this mark, not for the queue to empty: the drained
  /// messages notify only once suppression is lifted and the catch-up tally flushed.
  @Test
  func `a background connection marks its catch-up delivered once suppression is lifted`() async throws {
    let radioID = UUID()
    let session = MeshCoreSession(
      transport: SimulatorMockTransport(),
      configuration: SessionConfiguration(defaultTimeout: 0.5, clientIdentifier: "DrainFirst")
    )
    let services = try await ServiceContainer.forTesting(session: session)
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let coordinator = SyncCoordinator()
    let dependencies = makeDependencies(
      services: services,
      dataStore: dataStore,
      contactService: await failingContacts(),
      polling: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false)
    )
    #expect(await coordinator.lastCatchUpDeliveredAt == nil)
    let before = Date()

    await #expect(throws: (any Error).self) {
      try await coordinator.onConnectionEstablished(radioID: radioID, dependencies: dependencies)
    }

    let delivered = try #require(await coordinator.lastCatchUpDeliveredAt)
    #expect(delivered >= before)
    #expect(!dependencies.notificationService.isSuppressingNotifications)
    await coordinator.cancelDiscoveryEventMonitoring()
  }
}

@Suite("Background delivery: late delivery confirmations")
@MainActor
struct LateDeliveryConfirmationTests {
  /// A DM the reconnect sweep failed (its ACK came while the link was down) is delivered after
  /// all when the ACK arrives late: a Cairn radio keeps it in its queue for the next drain.
  @Test
  func `a late ACK upgrades a DM already marked failed`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let failed = MessageDTO.testDirectMessage(radioID: radioID, status: .failed, ackCode: 0xA1B2_C3D4)
    try await store.saveMessage(failed)

    let reconciled = try await store.markOutgoingSentDMDelivered(ackCode: 0xA1B2_C3D4, roundTripTime: 4200)

    #expect(reconciled?.messageID == failed.id)
    let row = try #require(try await store.fetchMessage(id: failed.id))
    #expect(row.status == .delivered)
    #expect(row.roundTripTime == 4200)
  }

  @Test
  func `a late ACK never touches a received message or another code`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let incoming = MessageDTO.testDirectMessage(radioID: radioID, direction: .incoming, status: .failed, ackCode: 7)
    try await store.saveMessage(incoming)

    #expect(try await store.markOutgoingSentDMDelivered(ackCode: 7, roundTripTime: nil) == nil)
    #expect(try await store.markOutgoingSentDMDelivered(ackCode: 8, roundTripTime: nil) == nil)
  }
}

@Suite("Background delivery: not-receiving reminder")
@MainActor
struct ListeningReminderTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @Test
  func `the policy arms in the background, is pushed back by activity at most once a minute, and ends on return`() {
    var policy = ListeningReminderPolicy()
    #expect(policy.linkActivity(now: start) == .none, "nothing armed in front")
    #expect(
      policy.enteredBackground(wantsConnection: true, hasRadio: true, enabled: true, now: start)
        == .schedule(after: ListeningReminderPolicy.delay)
    )
    #expect(policy.linkActivity(now: start.addingTimeInterval(30)) == .none, "throttled")
    #expect(policy.linkActivity(now: start.addingTimeInterval(61)) == .schedule(after: ListeningReminderPolicy.delay))
    #expect(policy.becameActive() == .cancel)
    #expect(policy.linkActivity(now: start.addingTimeInterval(200)) == .none)
  }

  @Test
  func `the policy stays off without a wanted radio, when disabled, and after a user disconnect`() {
    var policy = ListeningReminderPolicy()
    #expect(policy.enteredBackground(wantsConnection: false, hasRadio: true, enabled: true, now: start) == .cancel)
    #expect(policy.linkActivity(now: start.addingTimeInterval(120)) == .none)
    #expect(policy.enteredBackground(wantsConnection: true, hasRadio: true, enabled: false, now: start) == .cancel)
    #expect(policy.enteredBackground(wantsConnection: true, hasRadio: false, enabled: true, now: start) == .cancel)

    _ = policy.enteredBackground(wantsConnection: true, hasRadio: true, enabled: true, now: start)
    #expect(policy.connectionAbandoned() == .cancel)
    #expect(policy.linkActivity(now: start.addingTimeInterval(120)) == .none)
  }

  @Test
  func `the connection manager drives the reminder and the Bluetooth-off notice`() async throws {
    let env = try ConnectionManager.createForPairingTesting()
    defer { env.cleanup() }
    let scheduler = RecordingScheduler()
    env.manager.listeningReminder = ListeningReminder(scheduler: scheduler, isEnabled: { true })
    env.manager.persistConnection(deviceID: UUID(), radioID: UUID(), deviceName: "Trail T096")
    env.manager.setTestState(connectionState: .ready, currentTransportType: .bluetooth, connectionIntent: .wantsConnection())

    await env.manager.appDidEnterBackground()
    #expect(scheduler.scheduled.map(\.identifier) == [ListeningReminder.reminderIdentifier])
    #expect(scheduler.scheduled.first?.delay == ListeningReminderPolicy.delay)
    #expect(scheduler.scheduled.first?.body.contains("Trail T096") == true)

    env.manager.handleBluetoothStateChange(.poweredOff)
    try await waitUntil("the Bluetooth-off notice should post at once") {
      scheduler.scheduled.contains { $0.identifier == ListeningReminder.bluetoothOffIdentifier && $0.delay == nil }
    }

    await env.manager.appDidBecomeActive()
    #expect(scheduler.cancelled.contains([ListeningReminder.reminderIdentifier]))
    #expect(scheduler.cancelled.contains([ListeningReminder.bluetoothOffIdentifier]))
  }
}

@MainActor
private final class RecordingScheduler: LocalNotificationScheduling {
  struct Scheduled {
    let identifier: String
    let title: String
    let body: String
    let delay: TimeInterval?
  }

  var scheduled: [Scheduled] = []
  var cancelled: [[String]] = []

  func schedule(identifier: String, title: String, body: String, after delay: TimeInterval?) async {
    scheduled.append(Scheduled(identifier: identifier, title: title, body: body, delay: delay))
  }

  func cancel(identifiers: [String]) {
    cancelled.append(identifiers)
  }
}
