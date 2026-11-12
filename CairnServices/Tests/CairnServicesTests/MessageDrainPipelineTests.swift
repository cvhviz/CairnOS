import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// The radio's offline queue, from the frames it answers `CMD_SYNC_NEXT_MESSAGE` with to the
/// rows the Chats and Comm lists read (`fetchConversations`, `fetchChannels`).
@Suite("Message drain pipeline")
@MainActor
struct MessageDrainPipelineTests {
  private let bobKey = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6] + Array(repeating: 0x42, count: 26))
  private let stamp = UInt32(Date().timeIntervalSince1970) - 120

  private struct Fixture {
    let radioID: UUID
    let store: PersistenceStore
    let polling: MessagePollingService
    let coordinator: SyncCoordinator
    let dependencies: SyncDependencies
    let bob: ContactDTO
    let channel: ChannelDTO
  }

  /// A store with Bob and channel 1, and the real ingestion handlers wired to `polling`.
  private func makeFixture(session: any MeshCoreSessionProtocol, services: ServiceContainer) async throws -> Fixture {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let bob = ContactDTO.testContact(radioID: radioID, publicKey: bobKey, name: "Bob")
    try await store.saveContact(bob)
    let channel = ChannelDTO.testChannel(radioID: radioID, index: 1, name: "Hike")
    try await store.saveChannel(channel)

    let polling = MessagePollingService(session: session, dataStore: store)
    let dependencies = services.syncDependencies.with(dataStore: store, messagePollingService: polling)
    let coordinator = SyncCoordinator()
    await coordinator.wireMessageHandlers(dependencies: dependencies, radioID: radioID)
    await polling.startMessageEventMonitoring(radioID: radioID)
    return Fixture(
      radioID: radioID,
      store: store,
      polling: polling,
      coordinator: coordinator,
      dependencies: dependencies,
      bob: bob,
      channel: channel
    )
  }

  // MARK: - Frames (byte layouts from the firmware's MyMesh.cpp, app_target_ver >= 3)

  private func dmFrame(text: String, timestamp: UInt32? = nil) -> Data {
    var frame = Data([ResponseCode.contactMessageReceivedV3.rawValue, 0x14, 0, 0])
    frame.append(bobKey.prefix(6))
    frame.append(0x02) // path length
    frame.append(0x00) // plain text
    frame.append(contentsOf: withUnsafeBytes(of: (timestamp ?? stamp).littleEndian) { Array($0) })
    frame.append(contentsOf: text.utf8)
    return frame
  }

  private func channelFrame(index: UInt8, text: String) -> Data {
    var frame = Data([ResponseCode.channelMessageReceivedV3.rawValue, 0x14, 0, 0])
    frame.append(index)
    frame.append(0x01) // path length
    frame.append(0x00) // plain text
    frame.append(contentsOf: withUnsafeBytes(of: stamp.littleEndian) { Array($0) })
    frame.append(contentsOf: text.utf8)
    return frame
  }

  private func dmMessage(text: String) -> ContactMessage {
    ContactMessage(
      senderPublicKeyPrefix: bobKey.prefix(6),
      pathLength: 2,
      textType: 0,
      senderTimestamp: Date(timeIntervalSince1970: TimeInterval(stamp)),
      signature: nil,
      text: text,
      snr: 5
    )
  }

  private static let noMoreMessages = Data([ResponseCode.noMoreMessages.rawValue])

  // MARK: - Real session plumbing

  private func makeSelfInfoPacket() -> Data {
    var payload = Data([ResponseCode.selfInfo.rawValue])
    payload.append(1) // adv type
    payload.append(22) // tx power
    payload.append(22) // max tx power
    payload.append(Data(repeating: 0x01, count: 32)) // pubkey
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
    payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
    payload.append(0) // multi acks
    payload.append(0) // adv loc policy
    payload.append(0) // telemetry mode
    payload.append(0) // manual add
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
    payload.append(11) // sf
    payload.append(5) // cr
    return payload
  }

  private func startedSession() async throws -> (MeshCoreSession, MockTransport) {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 2, clientIdentifier: "DrainPipelineTests")
    )
    let start = Task { try await session.start() }
    try await waitUntil("appStart should be sent") { await transport.sentData.count >= 1 }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await start.value
    await transport.clearSentData()
    return (session, transport)
  }

  /// Answers each `CMD_SYNC_NEXT_MESSAGE` the session sends with the next frame, as the radio
  /// pops its offline queue, and the queue sync probe as stock firmware does (unsupported).
  private func answerFetches(_ transport: MockTransport, with frames: [Data]) -> Task<Void, Never> {
    Task {
      var remaining = frames
      var answered = 0
      var probesAnswered = 0
      while !Task.isCancelled {
        let sent = await transport.sentData
        let probes = sent.filter { $0.count >= 2 && $0[0] == CommandCode.cairnFirmware.rawValue && $0[1] == 0x08 }.count
        if probes > probesAnswered {
          probesAnswered += 1
          await transport.simulateReceive(Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue]))
          continue
        }
        let fetches = sent.filter { $0.first == CommandCode.getMessage.rawValue }.count
        if fetches > answered, !remaining.isEmpty {
          answered += 1
          await transport.simulateReceive(remaining.removeFirst())
        } else {
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
  }

  // MARK: - Drain to lists

  /// The catch-up drain stores DMs and channel messages where both lists read them, and an
  /// answer it can't decode (newer firmware's message kind, a truncated frame) no longer ends
  /// it: that used to time the fetch out, fail the drain, and leave the rest of the queue on
  /// the radio until its next MSG_WAITING.
  @Test
  func `drain stores the queue where the lists read it and skips unreadable answers`() async throws {
    let (session, transport) = try await startedSession()
    let services = try await ServiceContainer.forTesting(session: session)
    let fixture = try await makeFixture(session: session, services: services)

    let responder = answerFetches(transport, with: [
      dmFrame(text: "are you on the trail?"),
      Data([0x7E, 0x01, 0x02, 0x03]), // a message kind this app doesn't know
      Data([ResponseCode.contactMessageReceivedV3.rawValue, 0x01]), // truncated
      channelFrame(index: 1, text: "Alice: summit at noon"),
      Self.noMoreMessages
    ])
    defer { responder.cancel() }

    let count = try await fixture.polling.pollAllMessages()
    #expect(count == 2)

    let conversations = try await fixture.store.fetchConversations(radioID: fixture.radioID)
    #expect(conversations.map(\.id) == [fixture.bob.id])
    #expect(conversations.first?.unreadCount == 1)
    let dms = try await fixture.store.fetchMessages(contactID: fixture.bob.id)
    #expect(dms.map(\.text) == ["are you on the trail?"])

    let channels = try await fixture.store.fetchChannels(radioID: fixture.radioID)
    #expect(channels.first { $0.index == 1 }?.lastMessageDate != nil)
    let channelMessages = try await fixture.store.fetchMessages(radioID: fixture.radioID, channelIndex: 1)
    #expect(channelMessages.map(\.text) == ["summit at noon"])
    #expect(channelMessages.first?.senderNodeName == "Alice")
  }

  /// Starting auto-fetch drains whatever is still queued: the radio pushes MSG_WAITING only when
  /// a message arrives, so a backlog a failed catch-up left behind waited for the next message.
  @Test
  func `auto-fetch start drains what the radio still holds`() async throws {
    let (session, transport) = try await startedSession()
    let services = try await ServiceContainer.forTesting(session: session)
    let fixture = try await makeFixture(session: session, services: services)

    let responder = answerFetches(transport, with: [dmFrame(text: "left behind"), Self.noMoreMessages])
    defer { responder.cancel() }

    await fixture.polling.startAutoFetch(radioID: fixture.radioID)
    defer { Task { await fixture.polling.stopAutoFetch() } }

    try await waitUntil("the queued DM should be stored without a MSG_WAITING push") {
      let rows = try? await fixture.store.fetchMessages(contactID: fixture.bob.id)
      return rows?.map(\.text) == ["left behind"]
    }
  }

  // MARK: - Concurrent fetches

  /// A message another fetch drained while `pollAllMessages` ran (the session's auto-drain, a
  /// CLI poll) reaches only the event monitor. The monitor used to drop every message event
  /// during a drain, and the radio had already removed it from its queue: it was lost.
  @Test
  func `message another fetch drains during a drain is stored`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)
    try await waitUntil("event monitor should subscribe") { await session.eventSubscriptionCount >= 1 }

    let other = dmMessage(text: "fetched by someone else")
    await session.setGetMessageResults([
      .success(.contactMessage(dmMessage(text: "drained"))),
      .success(.noMoreMessages)
    ])
    await session.setGetMessageHook { call in
      // The answer to a fetch the drain didn't make lands on the event stream mid-drain.
      if call == 1 {
        await session.yieldEvent(.contactMessageReceived(other))
      }
    }

    _ = try await fixture.polling.pollAllMessages()

    try await waitUntil("both DMs should be stored") {
      let rows = try? await fixture.store.fetchMessages(contactID: fixture.bob.id)
      return Set(rows?.map(\.text) ?? []) == ["drained", "fetched by someone else"]
    }
  }

  /// The drain's own answer reaches both the drain and the event monitor; it is stored once.
  @Test
  func `drain answer seen by the event monitor too is stored once`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)
    try await waitUntil("event monitor should subscribe") { await session.eventSubscriptionCount >= 1 }

    let message = dmMessage(text: "only once")
    await session.setGetMessageResults([.success(.contactMessage(message)), .success(.noMoreMessages)])
    await session.setGetMessageHook { call in
      if call == 1 {
        await session.yieldEvent(.contactMessageReceived(message))
      }
    }

    _ = try await fixture.polling.pollAllMessages()
    try await Task.sleep(for: .milliseconds(200))
    let rows = try await fixture.store.fetchMessages(contactID: fixture.bob.id)
    #expect(rows.map(\.text) == ["only once"])
  }

  /// A lost answer no longer ends the catch-up drain: the fetch is asked again.
  @Test
  func `drain asks again after a fetch timeout`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)

    await session.setGetMessageResults([
      .failure(MeshCoreError.timeout),
      .success(.contactMessage(dmMessage(text: "after the timeout"))),
      .success(.noMoreMessages)
    ])

    let count = try await fixture.polling.pollAllMessages()
    #expect(count == 1)
    let rows = try await fixture.store.fetchMessages(contactID: fixture.bob.id)
    #expect(rows.map(\.text) == ["after the timeout"])
  }

  // MARK: - Companion CLI

  private func dmMessage(text: String, textType: UInt8) -> ContactMessage {
    ContactMessage(
      senderPublicKeyPrefix: bobKey.prefix(6),
      pathLength: 2,
      textType: textType,
      senderTimestamp: Date(timeIntervalSince1970: TimeInterval(stamp)),
      signature: nil,
      text: text,
      snr: 5
    )
  }

  /// A companion command the radio queued because the sender may not run commands here
  /// (txt_type 3, MeshCore 1.18) is not run and is no chat message either.
  @Test
  func `a refused companion command is not stored as a chat message`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)

    await session.setGetMessageResults([
      .success(.contactMessage(dmMessage(text: "4F|set name x", textType: 0x03))),
      .success(.contactMessage(dmMessage(text: "after the command"))),
      .success(.noMoreMessages)
    ])

    _ = try await fixture.polling.pollAllMessages()
    let rows = try await fixture.store.fetchMessages(contactID: fixture.bob.id)
    #expect(rows.map(\.text) == ["after the command"])
  }

  /// Another companion's CLI reply is matched by `RemoteNodeService`; it never reaches a
  /// repeater page's handler and is not a chat message.
  @Test
  func `a companion's CLI reply skips the repeater page handler`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)
    let pageReplies = ReplyCounter()
    await services.repeaterAdminService.setCLIHandler { _, _ in await pageReplies.increment() }

    await session.setGetMessageResults([
      .success(.contactMessage(dmMessage(text: "4F|> Field unit", textType: 0x01))),
      .success(.contactMessage(dmMessage(text: "after the reply"))),
      .success(.noMoreMessages)
    ])

    _ = try await fixture.polling.pollAllMessages()
    #expect(await pageReplies.count == 0)
    let rows = try await fixture.store.fetchMessages(contactID: fixture.bob.id)
    #expect(rows.map(\.text) == ["after the reply"])
  }

  // MARK: - Catch-up notifications

  /// Messages stored under catch-up suppression are summed per conversation; a re-drained
  /// duplicate (same content key) never counts twice.
  @Test
  func `suppressed messages are tallied once per conversation`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)
    fixture.dependencies.notificationService.isSuppressingNotifications = true

    await session.setGetMessageResults([
      .success(.contactMessage(dmMessage(text: "one"))),
      .success(.contactMessage(dmMessage(text: "two"))),
      .success(.contactMessage(dmMessage(text: "three"))),
      .success(.noMoreMessages)
    ])
    _ = try await fixture.polling.pollAllMessages()

    // The same message drained again (a later drain after a lost ACK) is a duplicate.
    await session.setGetMessageResults([.success(.contactMessage(dmMessage(text: "three"))), .success(.noMoreMessages)])
    _ = try await fixture.polling.pollAllMessages()

    let tally = await fixture.coordinator.catchUpTally
    #expect(tally.count == 1)
    #expect(tally[.direct(contactID: fixture.bob.id)]?.count == 3)
    #expect(tally[.direct(contactID: fixture.bob.id)]?.latestText == "three")

    // In the foreground the lists already show them: the tally is dropped, not posted.
    await fixture.coordinator.flushCatchUpNotifications(notificationService: fixture.dependencies.notificationService)
    #expect(await fixture.coordinator.catchUpTally.isEmpty)
  }

  @Test
  func `messages outside suppression are not tallied`() async throws {
    let session = MockMeshCoreSession()
    let services = try await ServiceContainer.forTesting(session: MeshCoreSession(transport: SimulatorMockTransport()))
    let fixture = try await makeFixture(session: session, services: services)

    await session.setGetMessageResults([.success(.contactMessage(dmMessage(text: "live"))), .success(.noMoreMessages)])
    _ = try await fixture.polling.pollAllMessages()

    #expect(await fixture.coordinator.catchUpTally.isEmpty)
  }

  // MARK: - Channels skipped in the background

  /// A connect made in the background skips channels; on return to the foreground the skipped
  /// sync runs once, so a radio first synced in the background still gets its channel rows.
  @Test
  func `background-skipped channel sync runs once on return to foreground`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channelService = MockChannelService()

    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channelService,
      messagePollingService: MockMessagePollingService(),
      appStateProvider: MockAppStateProvider(isInForeground: false)
    )
    #expect(await channelService.syncChannelsInvocations.isEmpty)
    #expect(await coordinator.channelSyncPendingRadioID == radioID)

    let ran = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID,
      dataStore: store,
      channelService: channelService,
      rxLogService: nil
    )
    #expect(ran)
    #expect(await channelService.syncChannelsInvocations.count == 1)
    #expect(await coordinator.channelSyncPendingRadioID == nil)

    let again = await coordinator.runPendingChannelSyncIfNeeded(
      radioID: radioID,
      dataStore: store,
      channelService: channelService,
      rxLogService: nil
    )
    #expect(!again)
    #expect(await channelService.syncChannelsInvocations.count == 1)
  }

  @Test
  func `foreground channel sync clears a pending one`() async throws {
    let coordinator = SyncCoordinator()
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channelService = MockChannelService()
    let appState = MockAppStateProvider(isInForeground: false)

    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channelService,
      messagePollingService: MockMessagePollingService(),
      appStateProvider: appState
    )
    #expect(await coordinator.channelSyncPendingRadioID == radioID)

    await appState.setIsInForeground(true)
    try await coordinator.performFullSync(
      radioID: radioID,
      dataStore: store,
      contactService: MockContactService(),
      channelService: channelService,
      messagePollingService: MockMessagePollingService(),
      appStateProvider: appState
    )
    #expect(await coordinator.channelSyncPendingRadioID == nil)
    #expect(await channelService.syncChannelsInvocations.count == 1)
  }
}

/// Counts replies a handler saw.
private actor ReplyCounter {
  private(set) var count = 0

  func increment() {
    count += 1
  }
}
