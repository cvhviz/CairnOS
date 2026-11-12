import Foundation
@testable import CairnServices
import MeshCore
import MeshCoreTestSupport
import Testing

/// Follow-ups to background delivery: repairs that link activity starts in the background back off
/// while they keep failing, a radio queue loss is never cleared before the user can see it, and
/// DMs drained before their sender's contact existed are linked (and announced) by the contact phase.
@Suite("Background delivery: backoff")
@MainActor
struct BackgroundRepairBackoffTests {
  private let deviceID = UUID()

  @Test
  func `link-activity resyncs back off from a minute to at most thirty minutes`() {
    let delays = (0...8).map { ConnectionManager.linkActivityResyncDelay(failedLoops: $0) }
    #expect(delays == [60, 60, 120, 240, 480, 960, 1800, 1800, 1800])
    #expect(ConnectionManager.linkActivityResyncDelay(failedLoops: 1000) == 1800)
  }

  @Test
  func `link-activity rebuilds back off from thirty seconds to at most fifteen minutes`() {
    let delays = (0...7).map { ConnectionManager.linkActivityRebuildDelay(failures: $0) }
    #expect(delays == [0, 30, 60, 120, 240, 480, 900, 900])
    #expect(ConnectionManager.linkActivityRebuildDelay(failures: 1000) == 900)
  }

  private func makeManager() throws -> PairingTestEnvironment {
    let env = try ConnectionManager.createForPairingTesting()
    env.manager.appStateProvider = MockAppStateProvider(isInForeground: false)
    env.manager.testLastConnectedDeviceID = deviceID
    env.manager.setTestState(
      connectionState: .connecting,
      currentTransportType: .bluetooth,
      connectionIntent: .wantsConnection()
    )
    return env
  }

  @Test
  func `a failed background rebuild holds off the next link-activity rebuild until its backoff passes`() async throws {
    let env = try makeManager()
    defer { env.cleanup() }
    await env.stateMachine.setStubbedIsConnected(true)
    await env.stateMachine.setStubbedConnectedDeviceID(deviceID)
    let rebuilds = ValueTracker<UUID>()
    env.manager.rebuildSessionForHealthCheckOverride = { id in rebuilds.record(id) }

    await env.manager.handleReconnectionFailure()
    #expect(env.manager.backgroundRebuildFailures == 1)
    #expect(await env.transport.disconnectInvocations == 0, "the link (the wake source) stays")

    await env.manager.handleLinkActivity()
    #expect(rebuilds.values.isEmpty, "inside the backoff: no rebuild on this notification")

    env.manager.lastBackgroundRebuildFailureAt = Date().addingTimeInterval(
      -ConnectionManager.linkActivityRebuildDelay(failures: 1) - 1
    )
    await env.manager.handleLinkActivity()
    #expect(rebuilds.values == [deviceID], "past the backoff the dead stack is rebuilt in place")
  }

  @Test
  func `the return to the foreground resets the background backoffs`() async throws {
    let env = try makeManager()
    defer { env.cleanup() }
    env.manager.rebuildSessionForHealthCheckOverride = { _ in }
    env.manager.backgroundRebuildFailures = 4
    env.manager.lastBackgroundRebuildFailureAt = Date()
    env.manager.backgroundResyncFailedLoops = 3

    await env.manager.appDidBecomeActive()

    #expect(env.manager.backgroundRebuildFailures == 0)
    #expect(env.manager.lastBackgroundRebuildFailureAt == nil)
    #expect(env.manager.backgroundResyncFailedLoops == 0)
  }
}

@Suite("Background delivery: radio queue loss reaches the user")
struct RadioQueueLossSurfaceTests {
  private func makeDefaults() throws -> UserDefaults {
    let suite = "RadioQueueLossSurfaceTests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suite))
  }

  private let loss = CairnQueueLoss(channelEvicted: 5, refused: 2, snapshotLost: 0, confirmationsEvicted: 0)

  @Test
  func `a posted notification leaves the ledger empty`() async throws {
    let ledger = RadioQueueLossLedger(defaults: try makeDefaults())
    let surfaced = await SyncCoordinator.surfaceQueueLoss(loss, ledger: ledger) { "T096" } post: { _, _ in true }
    #expect(surfaced)
    #expect(ledger.unseenLostMessages == 0)
  }

  @Test
  func `a loss no notification could report is kept for Settings before the radio clears it`() async throws {
    let ledger = RadioQueueLossLedger(defaults: try makeDefaults())
    let surfaced = await SyncCoordinator.surfaceQueueLoss(loss, ledger: ledger) { "T096" } post: { _, _ in false }
    #expect(surfaced, "recorded in the app, so the radio's counters may be cleared")
    #expect(ledger.unseenLostMessages == loss.lostMessages)
    #expect(ledger.deviceName == "T096")

    _ = await SyncCoordinator.surfaceQueueLoss(loss, ledger: ledger) { "T096" } post: { _, _ in false }
    #expect(ledger.unseenLostMessages == 2 * loss.lostMessages, "reports add up until the user dismisses them")

    ledger.dismiss()
    #expect(ledger.unseenLostMessages == 0)
    #expect(ledger.deviceName == nil)
  }

  @Test
  func `a loss of only delivery confirmations needs no notice`() async throws {
    let ledger = RadioQueueLossLedger(defaults: try makeDefaults())
    let confirmationsOnly = CairnQueueLoss(channelEvicted: 0, refused: 0, snapshotLost: 0, confirmationsEvicted: 3)
    let posted = ValueTracker<Int>()
    let surfaced = await SyncCoordinator.surfaceQueueLoss(confirmationsOnly, ledger: ledger) { "T096" } post: { _, count in
      posted.record(count)
      return false
    }
    #expect(surfaced)
    #expect(posted.values.isEmpty)
    #expect(ledger.unseenLostMessages == 0)
  }
}

@Suite("Background delivery: DMs drained before contacts")
struct OrphanDrainAdoptionTests {
  private let senderKey = Data([0x5A, 0x11, 0x22, 0x33, 0x44, 0x55] + Array(repeating: 0x77, count: 26))

  private func orphanDM(radioID: UUID, prefix: Data, text: String) -> MessageDTO {
    let stamp = UInt32(1_800_000_000)
    return MessageDTO(
      id: UUID(),
      radioID: radioID,
      contactID: nil,
      channelIndex: nil,
      text: text,
      timestamp: stamp,
      createdAt: Date(timeIntervalSince1970: TimeInterval(stamp)),
      sortDate: Date(timeIntervalSince1970: TimeInterval(stamp)),
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      pathNodes: nil,
      senderKeyPrefix: prefix,
      senderNodeName: nil,
      isRead: false,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      containsSelfMention: false
    )
  }

  @Test
  func `the contact phase links a DM stored before its sender's contact existed`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let prefix = Data(senderKey.prefix(6))
    let orphan = orphanDM(radioID: radioID, prefix: prefix, text: "sent while the app was away")
    try await store.saveMessage(orphan)

    let coordinator = SyncCoordinator()
    await coordinator.notePendingOrphanSender(prefix)
    // Unknown on the radio too: stays pending, nothing linked.
    await coordinator.adoptPendingOrphanDirectMessages(
      radioID: radioID, dataStore: store, notificationService: nil, postBanners: true
    )
    #expect(await coordinator.pendingOrphanSenderPrefixes == [prefix])

    // The contact phase brings the contact the radio added meanwhile.
    let contact = ContactDTO.testContact(radioID: radioID, publicKey: senderKey, name: "Late Sender")
    try await store.saveContact(contact)
    await coordinator.adoptPendingOrphanDirectMessages(
      radioID: radioID, dataStore: store, notificationService: nil, postBanners: true
    )

    let linked = try await store.fetchMessages(contactID: contact.id, limit: 10, offset: 0)
    #expect(linked.map(\.id) == [orphan.id])
    #expect(try await store.fetchContact(id: contact.id)?.unreadCount == 1)
    #expect(await coordinator.pendingOrphanSenderPrefixes.isEmpty)
  }
}
