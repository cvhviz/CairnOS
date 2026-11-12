import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// Covers another companion's command line through `RemoteNodeService`: the command goes
/// as `TXT_TYPE_CLI_COMMAND` with a hex tag and no login, only a reply carrying that tag
/// resolves it, and silence is a timeout that is neither resent nor rerouted.
@Suite("RemoteNodeService companion CLI")
struct RemoteNodeCompanionCLITests {
  private static let publicKey = Data(repeating: 0xD7, count: 32)
  private static let cliTextType: UInt8 = 0x01

  private struct Harness {
    let service: RemoteNodeService
    let session: MockMeshCoreSession
  }

  /// A service with no stored remote session: the companion path needs none.
  private func makeHarness(cliPrefixSeed: UInt8? = nil) async throws -> Harness {
    let radioID = UUID()
    let dataStore = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let session = MockMeshCoreSession()
    let service = if let cliPrefixSeed {
      RemoteNodeService(
        session: session,
        dataStore: dataStore,
        keychainService: KeychainService(),
        cliPrefixSeed: cliPrefixSeed
      )
    } else {
      RemoteNodeService(session: session, dataStore: dataStore, keychainService: KeychainService())
    }
    await service.startEventMonitoring()
    try await waitUntil("event monitor never subscribed") {
      await session.eventSubscriptionCount == 1
    }
    return Harness(service: service, session: session)
  }

  private func yieldReply(_ text: String, to session: MockMeshCoreSession, from key: Data = publicKey) async {
    await session.yieldEvent(.contactMessageReceived(ContactMessage(
      senderPublicKeyPrefix: Data(key.prefix(6)),
      pathLength: 0,
      textType: Self.cliTextType,
      senderTimestamp: Date(),
      signature: nil,
      text: text,
      snr: nil
    )))
  }

  private func waitForSend(_ harness: Harness, count: Int = 1) async throws {
    try await waitUntil("command was never sent") {
      await harness.session.sendCommandInvocations.count == count
    }
  }

  /// The tag of the most recently sent command.
  private func sentTag(_ session: MockMeshCoreSession) async -> String {
    String((await session.sendCommandInvocations.last?.command ?? "").prefix(3))
  }

  private func expectTimeout(_ task: Task<String, Error>) async {
    do {
      let response = try await task.value
      Issue.record("expected timeout, got response '\(response)'")
    } catch RemoteNodeError.timeout {
      // Expected: nothing this command's own answered it.
    } catch {
      Issue.record("expected timeout, got \(error)")
    }
  }

  // MARK: - Sending

  @Test
  func `command goes as txt_type 3 with a hex tag and no session`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "  ver ")
    }
    try await waitForSend(harness)

    let sent = try #require(await harness.session.sendCommandInvocations.first)
    #expect(sent.textType == .cliCommand)
    #expect(sent.destination == Self.publicKey)
    #expect(sent.command.wholeMatch(of: /[0-9A-F]{2}\|ver/) != nil, "tag + cleaned command, got \(sent.command)")

    await yieldReply(String(sent.command.prefix(3)) + "v1.18.0 (Build: 1 Oct 2026)", to: harness.session)
    #expect(try await task.value == "v1.18.0 (Build: 1 Oct 2026)")
  }

  @Test
  func `a command that can't be sent never reaches the radio`() async throws {
    let harness = try await makeHarness()

    for bad in ["", "a", "00|ver", "get\nname", String(repeating: "x", count: 64)] {
      await #expect(throws: RemoteNodeError.self) {
        try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: bad)
      }
    }
    #expect(await harness.session.sendCommandInvocations.isEmpty)
  }

  @Test
  func `commands are not rewritten as a repeater's are`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "clock sync")
    }
    try await waitForSend(harness)
    let sent = await harness.session.sendCommandInvocations[0].command
    #expect(sent.dropFirst(3) == "clock sync")

    await yieldReply(String(sent.prefix(3)) + "Unknown command", to: harness.session)
    #expect(try await task.value == "Unknown command")
  }

  // MARK: - Reply matching

  @Test
  func `the reply keeps the CLI lead and may be empty`() async throws {
    let harness = try await makeHarness()

    let first = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "get name")
    }
    try await waitForSend(harness)
    await yieldReply(await sentTag(harness.session) + "> Field unit", to: harness.session)
    #expect(try await first.value == "> Field unit")

    let second = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "set wifi.enabled 1")
    }
    try await waitForSend(harness, count: 2)
    await yieldReply(await sentTag(harness.session), to: harness.session)
    #expect(try await second.value == "")
  }

  @Test
  func `untagged and foreign-tagged replies are ignored until the command's own`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "board")
    }
    try await waitForSend(harness)
    let tag = await sentTag(harness.session)
    let otherTag = tag == "00|" ? "01|" : "00|"

    await yieldReply("Unknown command", to: harness.session)
    await yieldReply("^4|OK - restarting", to: harness.session)
    await yieldReply(otherTag + "Heltec V4", to: harness.session)
    await yieldReply(tag + "LilyGo T-Deck", to: harness.session, from: Data(repeating: 0x5A, count: 32))
    await yieldReply(tag + "Seeed Wio Tracker L1", to: harness.session)

    #expect(try await task.value == "Seeed Wio Tracker L1")
  }

  @Test
  func `foreign replies alone end in a timeout`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "ver")
    }
    try await waitForSend(harness)

    // A late reply the radio's own UI missed, and a 1.17-style untagged one.
    await yieldReply("^Z|v1.18.0", to: harness.session)
    await yieldReply("v1.18.0", to: harness.session)
    await expectTimeout(task)
  }

  // MARK: - Silence

  @Test
  func `a timeout is neither resent nor rerouted`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "set name Ridge")
    }
    try await waitForSend(harness)
    await expectTimeout(task)

    #expect(await harness.session.sendCommandInvocations.count == 1, "a resend would repeat the set")
    #expect(await harness.session.resetPathPublicKeys.isEmpty)
  }

  @Test
  func `a refusal from older firmware surfaces as unsupported`() async throws {
    let harness = try await makeHarness()
    await harness.session.setStubbedSendCommandResult(.failure(MeshCoreError.deviceError(code: 1)))

    do {
      _ = try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "ver")
      Issue.record("expected the radio's refusal")
    } catch let error as RemoteNodeError {
      #expect(error.isUnsupportedByRadio)
    }
  }

  // MARK: - Restarts

  @Test
  func `a restart waits only the short window`() async throws {
    let harness = try await makeHarness()

    let start = ContinuousClock.now
    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "reboot")
    }
    await expectTimeout(task)
    #expect(ContinuousClock.now - start < .seconds(3), "the 3 s companion floor does not apply")
    #expect(await harness.session.sendCommandInvocations.count == 1)
  }

  @Test
  func `a Cairn device's restart reply is still taken`() async throws {
    let harness = try await makeHarness()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "poweroff")
    }
    try await waitForSend(harness)
    await yieldReply(await sentTag(harness.session) + "OK - powering off", to: harness.session)
    #expect(try await task.value == "OK - powering off")
  }

  // MARK: - Slot

  @Test
  func `one companion command is in flight at a time`() async throws {
    let harness = try await makeHarness()

    let first = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "ver")
    }
    try await waitForSend(harness)
    let second = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "board")
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.session.sendCommandInvocations.count == 1)

    await yieldReply(await sentTag(harness.session) + "v1.18.0", to: harness.session)
    #expect(try await first.value == "v1.18.0")

    try await waitForSend(harness, count: 2)
    let tags = await harness.session.sendCommandInvocations.map { String($0.command.prefix(3)) }
    #expect(tags[0] != tags[1], "each command gets its own tag")
    await yieldReply(tags[1] + "Heltec V4", to: harness.session)
    #expect(try await second.value == "Heltec V4")
  }

  // MARK: - Tags

  @Test
  func `tags start at the seed and wrap`() async throws {
    let harness = try await makeHarness(cliPrefixSeed: 0xFF)

    let first = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "ver")
    }
    try await waitForSend(harness)
    #expect(await sentTag(harness.session) == "FF|")
    await yieldReply("FF|v1.18.0", to: harness.session)
    _ = try await first.value

    let second = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "board")
    }
    try await waitForSend(harness, count: 2)
    #expect(await sentTag(harness.session) == "00|")
    await yieldReply("00|Heltec V4", to: harness.session)
    _ = try await second.value
  }

  // MARK: - Late replies

  /// Collects what `companionCLILateReplies()` passes on.
  private actor LateReplies {
    private(set) var replies: [CompanionCLILateReply] = []
    func append(_ reply: CompanionCLILateReply) { replies.append(reply) }
  }

  private func collectLateReplies(_ service: RemoteNodeService) -> (LateReplies, Task<Void, Never>) {
    let collected = LateReplies()
    let stream = service.companionCLILateReplies()
    let task = Task {
      for await reply in stream { await collected.append(reply) }
    }
    return (collected, task)
  }

  @Test
  func `a reply after the timeout comes as a late reply under its request`() async throws {
    let harness = try await makeHarness()
    let (late, collector) = collectLateReplies(harness.service)
    defer { collector.cancel() }
    let requestID = UUID()

    let task = Task {
      try await harness.service.sendCompanionCLICommand(
        publicKey: Self.publicKey, command: "set name Ridge", requestID: requestID
      )
    }
    try await waitForSend(harness)
    let tag = await sentTag(harness.session)
    await expectTimeout(task)

    // Another node's reply with the same tag, and a foreign tag, are not it.
    await yieldReply(tag + "> OK", to: harness.session, from: Data(repeating: 0x5A, count: 32))
    await yieldReply("^4|OK", to: harness.session)
    await yieldReply(tag + "> OK", to: harness.session)
    try await waitUntil("late reply never came") { await late.replies.count == 1 }

    let reply = try #require(await late.replies.first)
    #expect(reply.requestID == requestID)
    #expect(reply.command == "set name Ridge")
    #expect(reply.text == "> OK")
    #expect(reply.publicKeyPrefix == Data(Self.publicKey.prefix(6)))

    // Taken once: a duplicate (a flood copy) is not a second late line.
    await yieldReply(tag + "> OK", to: harness.session)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await late.replies.count == 1)
    #expect(await harness.session.sendCommandInvocations.count == 1, "still never resent")
  }

  @Test
  func `a late reply never resolves the next command`() async throws {
    let harness = try await makeHarness()
    let (late, collector) = collectLateReplies(harness.service)
    defer { collector.cancel() }

    let first = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "get name")
    }
    try await waitForSend(harness)
    let firstTag = await sentTag(harness.session)
    await expectTimeout(first)

    let second = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "board")
    }
    try await waitForSend(harness, count: 2)
    let secondTag = await sentTag(harness.session)

    await yieldReply(firstTag + "> Field unit", to: harness.session)
    try await waitUntil("late reply never came") { await late.replies.count == 1 }
    await yieldReply(secondTag + "Heltec V4", to: harness.session)

    #expect(try await second.value == "Heltec V4")
    #expect(await late.replies.map(\.command) == ["get name"])
  }

  @Test
  func `a reply to a command that was answered is never late`() async throws {
    let harness = try await makeHarness()
    let (late, collector) = collectLateReplies(harness.service)
    defer { collector.cancel() }

    let task = Task {
      try await harness.service.sendCompanionCLICommand(publicKey: Self.publicKey, command: "ver")
    }
    try await waitForSend(harness)
    let tag = await sentTag(harness.session)
    await yieldReply(tag + "v1.18.0", to: harness.session)
    _ = try await task.value

    await yieldReply(tag + "v1.18.0", to: harness.session)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await late.replies.isEmpty)
  }
}
