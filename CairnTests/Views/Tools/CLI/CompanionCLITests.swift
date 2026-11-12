import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

// MARK: - Fixtures

/// Records what the terminals send to another companion and answers with a set reply or error.
@MainActor
private final class CompanionSendSpy {
  private(set) var calls: [(publicKey: Data, command: String)] = []
  /// The request ID each send went with, as a late reply names it.
  private(set) var requestIDs: [UUID] = []
  var reply = ""
  var error: Error?

  var send: CompanionCLISend {
    { [self] publicKey, command, _, requestID in
      calls.append((publicKey, command))
      requestIDs.append(requestID)
      if let error { throw error }
      return reply
    }
  }

  var companionSend: NodeCLIViewModel.CompanionSend {
    { [self] command, _, requestID in
      calls.append((Data(), command))
      requestIDs.append(requestID)
      if let error { throw error }
      return reply
    }
  }

  var nodeSend: @MainActor (String, Duration) async throws -> String {
    { [self] command, _ in
      calls.append((Data(), command))
      if let error { throw error }
      return reply
    }
  }
}

/// A late reply to the spy's last send.
@MainActor
private func lateReply(to spy: CompanionSendSpy, command: String, text: String) throws -> CompanionCLILateReply {
  CompanionCLILateReply(
    requestID: try #require(spy.requestIDs.last),
    publicKeyPrefix: Data(repeating: 0x5A, count: 6),
    command: command,
    text: text
  )
}

private func makeDevice(firmwareVersion: UInt8, radioID: UUID) -> DeviceDTO {
  DeviceDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: Data(repeating: 0x01, count: 32),
    nodeName: "TestDevice",
    firmwareVersion: firmwareVersion,
    firmwareVersionString: firmwareVersion >= 14 ? "v1.18.0" : "v1.17.1",
    manufacturerName: "TestMfg",
    buildDate: "01 Jan 2026",
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

private func makeContact(radioID: UUID, name: String, type: ContactType, keyByte: UInt8) -> ContactDTO {
  ContactDTO(
    id: UUID(),
    radioID: radioID,
    publicKey: Data(repeating: keyByte, count: 32),
    name: name,
    typeRawValue: type.rawValue,
    flags: 0,
    outPathLength: 0,
    outPath: Data(),
    lastAdvertTimestamp: 0,
    latitude: 0,
    longitude: 0,
    lastModified: 0,
    lastHeardTimestamp: nil,
    nickname: nil,
    isBlocked: false,
    isMuted: false,
    isFavorite: false,
    lastMessageDate: nil,
    unreadCount: 0
  )
}

// MARK: - Exchange

@Suite("Companion CLI exchange")
@MainActor
struct CompanionCLIExchangeTests {
  private func run(_ command: String, spy: CompanionSendSpy) async -> CompanionCLIExchange.Outcome? {
    let send = spy.send
    return await CompanionCLIExchange.run(command) { try await send(Data(), $0, .seconds(3), UUID()) }
  }

  @Test
  func `A reply shows without the CLI's lead and the command goes cleaned`() async {
    let spy = CompanionSendSpy()
    spy.reply = "> TestNode"
    let outcome = await run("  get name  ", spy: spy)
    #expect(outcome == .init(text: "TestNode", type: .response))
    #expect(spy.calls.map(\.command) == ["get name"])
  }

  @Test
  func `An empty reply says so`() async {
    let spy = CompanionSendSpy()
    let outcome = await run("set wifi.enabled 1", spy: spy)
    #expect(outcome == .init(text: L10n.Tools.Tools.Cli.Companion.emptyReply, type: .response))
  }

  @Test
  func `Unknown and ERR replies show as errors, as the firmware colours them`() async {
    let spy = CompanionSendSpy()
    spy.reply = "Unknown command"
    #expect(await run("get wifi.ip", spy: spy)?.type == .error)
    spy.reply = "ERR: bad value"
    #expect(await run("set tz.offset x", spy: spy)?.type == .error)
  }

  @Test
  func `Silence says a reply may still come, and waits for it`() async {
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    let outcome = await run("ver", spy: spy)
    #expect(outcome == .init(text: L10n.Tools.Tools.Cli.Companion.noReply, type: .error, awaitsLateReply: true))
    #expect(spy.calls.count == 1)
  }

  @Test
  func `A restart always says sent, with the device's words when it answered`() async {
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    #expect(await run("reboot", spy: spy) == .init(
      text: L10n.Tools.Tools.Cli.Companion.restartSent, type: .success, awaitsLateReply: true
    ))
    spy.error = nil
    spy.reply = "OK - restarting"
    let answered = await run("poweroff", spy: spy)
    #expect(answered == .init(text: L10n.Tools.Tools.Cli.Companion.restartSentReply("OK - restarting"), type: .success))
    #expect(answered?.text == "Sent · it restarts (OK - restarting)")
    spy.reply = ""
    #expect(await run("reboot", spy: spy) == .init(text: L10n.Tools.Tools.Cli.Companion.restartSent, type: .success))
  }

  @Test
  func `The not-a-command line counts bytes, not letters`() {
    #expect(L10n.Tools.Tools.Cli.Companion.notACommand.contains("bytes"))
    // 32 two-byte letters are 64 bytes: over the limit though only 32 letters.
    #expect(CompanionCLICatalog.clean("set name " + String(repeating: "é", count: 32)) == nil)
  }

  @Test
  func `An older radio's refusal asks for 1_18 firmware`() async {
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.sessionError(.deviceError(code: FirmwareDeviceErrorCode.unsupportedCommand))
    let outcome = await run("ver", spy: spy)
    #expect(outcome == .init(text: L10n.Tools.Tools.Cli.Companion.needsFirmware, type: .error))
  }

  @Test
  func `A command that can't be sent never reaches the radio`() async {
    let spy = CompanionSendSpy()
    for input in ["a", "00|ver", "get\tname", String(repeating: "x", count: 64)] {
      let outcome = await run(input, spy: spy)
      #expect(outcome == .init(text: L10n.Tools.Tools.Cli.Companion.notACommand, type: .error))
    }
    #expect(spy.calls.isEmpty)
  }
}

// MARK: - Late lines

@Suite("Companion CLI late lines")
@MainActor
struct CompanionCLILateLinesTests {
  private func reply(_ requestID: UUID, _ text: String, command: String = "set name Ridge") -> CompanionCLILateReply {
    CompanionCLILateReply(requestID: requestID, publicKeyPrefix: Data(count: 6), command: command, text: text)
  }

  @Test
  func `A late reply goes under its command's no-reply line, once`() {
    let requestID = UUID()
    let command = CLIOutputLine(text: "@Handheld> set name Ridge", type: .command)
    let noReply = CLIOutputLine(text: L10n.Tools.Tools.Cli.Companion.noReply, type: .error)
    let next = CLIOutputLine(text: "@Handheld> ver", type: .command)
    var lines = [command, noReply, next]
    var late = CompanionCLILateLines()
    late.watch(requestID: requestID, lineID: noReply.id, nodeName: "Handheld")

    #expect(late.place(reply(requestID, "> OK"), in: &lines))
    #expect(lines.map(\.text) == [
      command.text, noReply.text, L10n.Tools.Tools.Cli.Companion.lateReply("OK"), next.text,
    ])
    #expect(lines[2].type == .response)
    #expect(!late.place(reply(requestID, "> OK"), in: &lines), "taken once")
    #expect(lines.count == 4)
  }

  @Test
  func `A late reply whose line is gone names its node and command at the end`() {
    let requestID = UUID()
    var lines: [CLIOutputLine] = []
    var late = CompanionCLILateLines()
    late.watch(requestID: requestID, lineID: UUID(), nodeName: "Handheld")

    #expect(late.place(reply(requestID, "Unknown command", command: "get foo"), in: &lines))
    #expect(lines.map(\.text) == [
      L10n.Tools.Tools.Cli.Companion.lateReplyFrom("Handheld", "get foo", "Unknown command"),
    ])
    #expect(lines.first?.text.contains("Handheld") == true)
    #expect(lines.first?.type == .error)
  }

  @Test
  func `Another terminal's late reply is not placed`() {
    var lines = [CLIOutputLine(text: "x", type: .response)]
    var late = CompanionCLILateLines()
    #expect(!late.place(reply(UUID(), "> OK"), in: &lines))
    #expect(lines.count == 1)
  }
}

// MARK: - Picker

@Suite("Companion command picker")
@MainActor
struct CompanionCommandPickerTests {
  @Test
  func `Each kind leads where the firmware's does`() {
    for command in CompanionCLICatalog.commands {
      let choice = CompanionCommandPicker.choice(for: command)
      switch command.kind {
      case .send: #expect(choice == .pick(.run(command.command)))
      case .edit:
        #expect(choice == .pick(.edit(command.command)))
        #expect(command.command.hasSuffix(" "))
      case .confirm: #expect(choice == .confirm(command))
      }
    }
  }

  @Test
  func `Only Restart and Power off ask first`() {
    let confirmed = CompanionCLICatalog.commands.filter {
      if case .confirm = CompanionCommandPicker.choice(for: $0) { return true }
      return false
    }
    #expect(confirmed.map(\.command) == ["reboot", "poweroff"])
  }

  @Test
  func `Rename starts the line for the name to be typed`() {
    let rename = CompanionCLICatalog.commands.first { $0.id == "rename" }
    #expect(rename.map(CompanionCommandPicker.choice(for:)) == .pick(.edit("set name ")))
  }

  @Test
  func `Every command has its own title and its group's look`() {
    for command in CompanionCLICatalog.commands {
      #expect(!command.title.isEmpty)
      // A missing title falls back to the command itself.
      #expect(command.title != command.command.trimmingCharacters(in: .whitespaces))
    }
    #expect(Set(CompanionCLICatalog.commands.map(\.systemImage)) == ["info.circle", "pencil", "power"])
    // The quick tiles send, as the firmware's QUICK tiles: Send, link tint.
    #expect(CompanionCLICommand.quickSystemImage == "paperplane")
    #expect(CompanionCLICommand.quickTint == .blue)
    #expect(CompanionCLICatalog.quick.map(\.quickTitle) == [
      L10n.Tools.Tools.Cli.Companion.Command.version,
      L10n.Tools.Tools.Cli.Companion.Quick.wifi,
      L10n.Tools.Tools.Cli.Companion.Command.ipAddress,
      L10n.Tools.Tools.Cli.Companion.Command.board,
    ])
  }
}

// MARK: - Completion

@Suite("Companion CLI completion")
@MainActor
struct CompanionCLICompletionTests {
  @Test
  func `A companion session offers the catalogue's commands, not a repeater's`() {
    let engine = CLICompletionEngine()
    let commands = engine.completions(for: "", isLocal: false, isCompanion: true)
    for command in ["ver", "board", "get", "set", "reboot", "poweroff"] {
      #expect(commands.contains(command))
    }
    #expect(!commands.contains("neighbors"))
    #expect(!commands.contains("login"))
  }

  @Test
  func `get and set offer the catalogue's keys, and never wifi.pwd to read`() {
    let engine = CLICompletionEngine()
    let getKeys = engine.completions(for: "get ", isLocal: false, isCompanion: true)
    #expect(getKeys.contains("wifi.ip"))
    #expect(!getKeys.contains("wifi.pwd"))
    let setKeys = engine.completions(for: "set ", isLocal: false, isCompanion: true)
    #expect(setKeys.contains("pin"))
    #expect(setKeys.contains("wifi.pwd"))
    #expect(engine.completions(for: "set wifi.enabled ", isLocal: false, isCompanion: true) == ["0", "1"])
  }

  @Test
  func `login offers companions alongside repeaters`() {
    let engine = CLICompletionEngine()
    engine.updateNodeNames(["Hilltop"])
    engine.updateCompanionNames(["Handheld"])
    #expect(engine.completions(for: "login H", isLocal: true) == ["Handheld", "Hilltop"])
  }
}

// MARK: - Tools CLI

@Suite("CLIToolViewModel companion sessions")
@MainActor
struct CLIToolViewModelCompanionTests {
  private func makeViewModel(
    store: PersistenceStore,
    radioID: UUID,
    firmwareVersion: UInt8,
    spy: CompanionSendSpy
  ) -> CLIToolViewModel {
    let device = makeDevice(firmwareVersion: firmwareVersion, radioID: radioID)
    let viewModel = CLIToolViewModel()
    viewModel.configure(
      dependencies: CLIToolViewModel.Dependencies(
        repeaterAdminService: { nil },
        remoteNodeService: { nil },
        settingsService: { nil },
        dataStore: { store },
        radioID: { radioID },
        connectedDevice: { device },
        companionCLI: { spy.send }
      ),
      localDeviceName: "TestDevice",
      sendSelfAdvert: { _ in }
    )
    viewModel.activeSession = .local(deviceName: "TestDevice")
    return viewModel
  }

  private func makeStore(radioID: UUID) async throws -> (PersistenceStore, ContactDTO) {
    let store = PersistenceStore(modelContainer: try PersistenceStore.createContainer(inMemory: true))
    let companion = makeContact(radioID: radioID, name: "Handheld", type: .chat, keyByte: 0x5A)
    try await store.saveContact(companion)
    try await store.saveContact(makeContact(radioID: radioID, name: "Hilltop", type: .repeater, keyByte: 0x6B))
    return (store, companion)
  }

  private func run(_ command: String, on viewModel: CLIToolViewModel) async throws {
    viewModel.executeCommand(command)
    try await waitUntil("\(command) should finish") { !viewModel.isWaitingForResponse }
  }

  @Test
  func `login opens a companion's command line with no password`() async throws {
    let radioID = UUID()
    let (store, companion) = try await makeStore(radioID: radioID)
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: CompanionSendSpy())

    try await run("login handheld", on: viewModel)

    #expect(viewModel.pendingLoginContact == nil)
    #expect(viewModel.activeSession?.companionPublicKey == companion.publicKey)
    #expect(viewModel.remoteSessions.count == 1)
    #expect(viewModel.outputLines.contains { $0.text == L10n.Tools.Tools.Cli.Companion.note })
  }

  @Test
  func `login to a companion on older firmware says what it needs`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 13, spy: CompanionSendSpy())

    try await run("login Handheld", on: viewModel)

    #expect(viewModel.activeSession?.isLocal == true)
    #expect(viewModel.remoteSessions.isEmpty)
    #expect(viewModel.outputLines.last?.text == L10n.Tools.Tools.Cli.Companion.needsFirmware)
  }

  @Test
  func `A repeater keeps its password login when a companion shares the radio`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: CompanionSendSpy())

    // No RemoteNodeService here, so the repeater path stops at "not connected": never a companion session.
    try await run("login Hilltop", on: viewModel)

    #expect(viewModel.remoteSessions.isEmpty)
    #expect(viewModel.activeSession?.isLocal == true)
  }

  @Test
  func `Commands go to the companion and its reply shows under them`() async throws {
    let radioID = UUID()
    let (store, companion) = try await makeStore(radioID: radioID)
    let spy = CompanionSendSpy()
    spy.reply = "> Handheld"
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: spy)
    try await run("login Handheld", on: viewModel)

    try await run("get name", on: viewModel)

    #expect(spy.calls.map(\.command) == ["get name"])
    #expect(spy.calls.first?.publicKey == companion.publicKey)
    #expect(viewModel.outputLines.suffix(2).map(\.text) == [
      "@Handheld\(L10n.Tools.Tools.Cli.promptSuffix) get name",
      "Handheld",
    ])
  }

  @Test
  func `Silence prints the no-reply line once`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: spy)
    try await run("login Handheld", on: viewModel)

    try await run("ver", on: viewModel)

    #expect(spy.calls.count == 1)
    #expect(viewModel.outputLines.last?.text == L10n.Tools.Tools.Cli.Companion.noReply)
    #expect(viewModel.outputLines.last?.type == .error)
    #expect(viewModel.outputLines.filter { $0.text == L10n.Tools.Tools.Cli.Companion.noReply }.count == 1)
  }

  @Test
  func `A late reply shows under its command's no-reply line`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: spy)
    try await run("login Handheld", on: viewModel)
    try await run("set name Ridge", on: viewModel)
    spy.error = nil
    spy.reply = "v1.18.0"
    let late = try lateReply(to: spy, command: "set name Ridge", text: "> OK")
    try await run("ver", on: viewModel)

    viewModel.receiveLateReply(late)

    #expect(viewModel.outputLines.suffix(5).map(\.text) == [
      "@Handheld\(L10n.Tools.Tools.Cli.promptSuffix) set name Ridge",
      L10n.Tools.Tools.Cli.Companion.noReply,
      L10n.Tools.Tools.Cli.Companion.lateReply("OK"),
      "@Handheld\(L10n.Tools.Tools.Cli.promptSuffix) ver",
      "v1.18.0",
    ])
  }

  @Test
  func `logout closes a companion session here and sends nothing`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let spy = CompanionSendSpy()
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: spy)
    try await run("login Handheld", on: viewModel)

    try await run("logout", on: viewModel)

    #expect(spy.calls.isEmpty)
    #expect(viewModel.remoteSessions.isEmpty)
    #expect(viewModel.activeSession?.isLocal == true)
    #expect(viewModel.outputLines.last?.text == L10n.Tools.Tools.Cli.Companion.closed("Handheld"))
  }

  @Test
  func `A picked Change command starts the input line`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: CompanionSendSpy())
    try await run("login Handheld", on: viewModel)
    viewModel.historyUp()

    viewModel.prefill("set name ")

    #expect(viewModel.currentInput == "set name ")
    #expect(viewModel.historyIndex == nil)
  }

  @Test
  func `companions lists the radio's companions only`() async throws {
    let radioID = UUID()
    let (store, _) = try await makeStore(radioID: radioID)
    let viewModel = makeViewModel(store: store, radioID: radioID, firmwareVersion: 14, spy: CompanionSendSpy())

    try await run("companions", on: viewModel)

    let output = viewModel.outputLines.map(\.text)
    #expect(output.contains(L10n.Tools.Tools.Cli.companionsHeader(1)))
    #expect(output.contains { $0.contains("Handheld") })
    #expect(!output.contains { $0.contains("Hilltop") })
  }
}

// MARK: - Contact page CLI

@Suite("NodeCLIViewModel companion target")
@MainActor
struct NodeCLIViewModelCompanionTests {
  private func makeViewModel(spy: CompanionSendSpy) -> NodeCLIViewModel {
    let viewModel = NodeCLIViewModel()
    viewModel.configureCompanion(sessionName: "Handheld", send: spy.companionSend)
    return viewModel
  }

  @Test
  func `It opens with the companion's banner, not a connection`() {
    let viewModel = makeViewModel(spy: CompanionSendSpy())
    let output = viewModel.outputLines.map(\.text)
    #expect(output.contains(L10n.Tools.Tools.Cli.Companion.opened("Handheld")))
    #expect(output.contains(L10n.Tools.Tools.Cli.Companion.note))
    #expect(!output.contains(L10n.RemoteNodes.RemoteNodes.NodeCli.bannerConnected("Handheld")))
  }

  @Test
  func `A command goes cleaned and its reply shows`() async throws {
    let spy = CompanionSendSpy()
    spy.reply = "> v1.18.0"
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("ver")
    try await waitUntil("reply shows") { viewModel.outputLines.last?.text == "v1.18.0" }
    #expect(spy.calls.map(\.command) == ["ver"])
  }

  @Test
  func `A restart without a reply counts as sent`() async throws {
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("reboot")
    try await waitUntil("sent shows") {
      viewModel.outputLines.last?.text == L10n.Tools.Tools.Cli.Companion.restartSent
    }
    #expect(spy.calls.count == 1)
  }

  @Test
  func `A second command while one is out is not sent`() async throws {
    let spy = CompanionSendSpy()
    spy.reply = "v1.18.0"
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("ver")
    #expect(viewModel.isWaitingForResponse, "claimed before the task runs")
    viewModel.executeCommand("board")
    try await waitUntil("reply shows") { !viewModel.isWaitingForResponse }

    #expect(spy.calls.map(\.command) == ["ver"])
  }

  @Test
  func `A late reply shows under the no-reply line`() async throws {
    let spy = CompanionSendSpy()
    spy.error = RemoteNodeError.timeout
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("set name Ridge")
    try await waitUntil("no-reply shows") { !viewModel.isWaitingForResponse }
    viewModel.receiveLateReply(try lateReply(to: spy, command: "set name Ridge", text: "> OK"))

    #expect(viewModel.outputLines.suffix(2).map(\.text) == [
      L10n.Tools.Tools.Cli.Companion.noReply,
      L10n.Tools.Tools.Cli.Companion.lateReply("OK"),
    ])
  }

  @Test
  func `Cancelling frees the terminal for the next command`() async throws {
    let spy = CompanionSendSpy()
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("ver")
    viewModel.cancelCurrentCommand()

    #expect(!viewModel.isWaitingForResponse)
    #expect(viewModel.outputLines.last?.text == L10n.RemoteNodes.RemoteNodes.NodeCli.cancelled)
  }

  @Test
  func `help lists the companion's commands and sends nothing`() async throws {
    let spy = CompanionSendSpy()
    let viewModel = makeViewModel(spy: spy)

    viewModel.executeCommand("help")
    try await waitUntil("help shows") {
      viewModel.outputLines.contains { $0.text == L10n.Tools.Tools.Cli.helpCompanionHeader }
    }
    #expect(!viewModel.outputLines.contains { $0.text == L10n.RemoteNodes.RemoteNodes.NodeCli.helpClearStats })
    #expect(spy.calls.isEmpty)
  }

  @Test
  func `A picked Change command starts the line and asks for the keyboard`() {
    let viewModel = makeViewModel(spy: CompanionSendSpy())
    let before = viewModel.prefillCount

    viewModel.prefill("set wifi.ssid ")

    #expect(viewModel.currentInput == "set wifi.ssid ")
    #expect(viewModel.prefillCount == before + 1)
  }

  @Test
  func `A repeater terminal keeps its own completion`() {
    let viewModel = NodeCLIViewModel()
    viewModel.configure(sessionName: "Hilltop", sendRawCommand: CompanionSendSpy().nodeSend)
    viewModel.currentInput = "sens"
    viewModel.updateGhostText(cursorAtEnd: true)
    #expect(viewModel.ghostText == "or")
  }
}
