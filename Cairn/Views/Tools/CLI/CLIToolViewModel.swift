import Foundation
import CairnServices
import OSLog
import UIKit

@Observable
@MainActor
final class CLIToolViewModel {
  private static let maxOutputLines = 1000
  private static let maxHistoryEntries = 100
  static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "CLIToolViewModel")

  // MARK: - State

  // Internal set: a late companion reply goes in under its command (CLIToolViewModel+Sessions).
  var outputLines: [CLIOutputLine] = []
  private(set) var commandHistory: [String] = []
  private(set) var historyIndex: Int?
  var activeSession: CLISession?
  var remoteSessions: [CLISession] = []
  var isWaitingForResponse = false
  private var hasShownWelcome = false

  var currentInput: String = ""
  private var countdownTask: Task<Void, Never>?
  var remainingSeconds: Int?
  var pendingLoginContact: ContactDTO?

  /// A parsed dangerous local command awaiting a yes/no confirmation line.
  var pendingConfirmation: CLILocalCommand?

  // MARK: - Completion State

  let completionEngine = CLICompletionEngine()
  var ghostText: String = ""
  private var nodeNamesTask: Task<Void, Never>?

  /// Prefetches custom-var completion keys once per connection. Kept separate
  /// from `nodeNamesTask` because `configure` re-runs on every view appearance
  /// and would otherwise cancel an in-flight session command each time.
  private var customVarKeysTask: Task<Void, Never>?

  /// Current tab completion suggestions (nil when hidden)
  var tabSuggestions: [String]?

  /// Selected index within suggestions (nil = not in selection mode)
  var tabSelectionIndex: Int?

  // MARK: - Task Management

  private var currentCommandTask: Task<Void, Never>?
  /// Timed-out companion commands whose late reply still shows under them.
  var companionLateLines = CompanionCLILateLines()
  /// Passes this connection's late companion replies to ``receiveLateReply(_:)``.
  private var lateRepliesTask: Task<Void, Never>?

  // MARK: - Dependencies

  /// Per-connection dependencies, each read live at every call site so a nil read
  /// means disconnected. `connectedDevice` reads the synchronously-updated live
  /// DTO on `AppState`, deliberately not the persisted row (written by an
  /// error-swallowed detached task, so it can lag).
  struct Dependencies {
    let repeaterAdminService: @MainActor () -> RepeaterAdminService?
    let remoteNodeService: @MainActor () -> RemoteNodeService?
    let settingsService: @MainActor () -> SettingsService?
    let dataStore: @MainActor () -> PersistenceStoreProtocol?
    let radioID: @MainActor () -> UUID?
    let connectedDevice: @MainActor () -> DeviceDTO?
    /// Sends to another companion's command line; nil while disconnected.
    var companionCLI: @MainActor () -> CompanionCLISend? = { nil }
    /// Where each radio's command history is kept between sessions (``CLIHistoryStore``).
    var historyStore: UserDefaults = .standard
  }

  /// A radio's command history in `UserDefaults`, under its id, so the up arrow reaches last
  /// week's commands and another radio's never show.
  enum CLIHistoryStore {
    static func key(for radioID: UUID) -> String {
      "cli.commandHistory.\(radioID.uuidString)"
    }

    static func load(radioID: UUID, from defaults: UserDefaults) -> [String] {
      defaults.stringArray(forKey: key(for: radioID)) ?? []
    }

    static func save(_ history: [String], radioID: UUID, to defaults: UserDefaults) {
      defaults.set(history, forKey: key(for: radioID))
    }
  }

  private var repeaterAdminServiceProvider: @MainActor () -> RepeaterAdminService? = { nil }
  private var remoteNodeServiceProvider: @MainActor () -> RemoteNodeService? = { nil }
  private var settingsServiceProvider: @MainActor () -> SettingsService? = { nil }
  private var dataStoreProvider: @MainActor () -> PersistenceStoreProtocol? = { nil }
  private var radioIDProvider: @MainActor () -> UUID? = { nil }
  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }
  private var companionCLIProvider: @MainActor () -> CompanionCLISend? = { nil }
  private var sendSelfAdvertAction: @MainActor (_ flood: Bool) async throws -> Void = { _ in }
  private var historyStore: UserDefaults = .standard
  /// The radio whose history is loaded.
  private var historyRadioID: UUID?
  /// The transcript ends with the disconnected marker: a reconnect adds its own.
  private var transcriptIsDisconnected = false

  /// Both old and new providers read the same live state, so change detection
  /// needs the instance seen at the previous configure. Weak, so a torn-down
  /// container's deallocated service reads as a change.
  private weak var lastConfiguredAdminService: RepeaterAdminService?

  var repeaterAdminService: RepeaterAdminService? {
    repeaterAdminServiceProvider()
  }

  var remoteNodeService: RemoteNodeService? {
    remoteNodeServiceProvider()
  }

  var settingsService: SettingsService? {
    settingsServiceProvider()
  }

  var dataStore: PersistenceStoreProtocol? {
    dataStoreProvider()
  }

  var radioID: UUID? {
    radioIDProvider()
  }

  var connectedDevice: DeviceDTO? {
    connectedDeviceProvider()
  }

  var companionCLI: CompanionCLISend? {
    companionCLIProvider()
  }

  func sendSelfAdvert(_ flood: Bool) async throws {
    try await sendSelfAdvertAction(flood)
  }

  var localDeviceName: String = ""

  // MARK: - Prompt

  var promptText: String {
    if let seconds = remainingSeconds {
      return L10n.Tools.Tools.Cli.loggingIn(seconds)
    }

    if isWaitingForResponse {
      return ""
    }

    if let pendingConfirmation {
      return "\(L10n.Tools.Tools.Cli.confirmPrompt(pendingConfirmation.displayName)) "
    }

    if pendingLoginContact != nil {
      return "\(L10n.Tools.Tools.Cli.passwordPrompt) "
    }

    guard let session = activeSession else {
      return "\(L10n.Tools.Tools.Cli.disconnected)\(L10n.Tools.Tools.Cli.promptSuffix) "
    }

    if session.isLocal {
      return "\(session.name)\(L10n.Tools.Tools.Cli.promptSuffix) "
    } else {
      return "@\(session.name)\(L10n.Tools.Tools.Cli.promptSuffix) "
    }
  }

  // MARK: - Setup

  func configure(
    dependencies: Dependencies,
    localDeviceName: String,
    sendSelfAdvert: @escaping @MainActor (_ flood: Bool) async throws -> Void
  ) {
    self.localDeviceName = localDeviceName
    remoteNodeServiceProvider = dependencies.remoteNodeService
    settingsServiceProvider = dependencies.settingsService
    dataStoreProvider = dependencies.dataStore
    radioIDProvider = dependencies.radioID
    connectedDeviceProvider = dependencies.connectedDevice
    companionCLIProvider = dependencies.companionCLI
    sendSelfAdvertAction = sendSelfAdvert
    historyStore = dependencies.historyStore
    listenForLateReplies(from: dependencies.remoteNodeService())
    loadHistoryIfRadioChanged()

    let incomingService = dependencies.repeaterAdminService()
    repeaterAdminServiceProvider = dependencies.repeaterAdminService

    if lastConfiguredAdminService !== incomingService {
      if incomingService != nil {
        if activeSession == nil {
          activeSession = .local(deviceName: localDeviceName)
          if transcriptIsDisconnected {
            // The transcript carried over the gap: mark where the new connection starts.
            transcriptIsDisconnected = false
            appendOutput(L10n.Tools.Tools.Cli.Transcript.reconnected, type: .response)
          }
          showWelcomeBanner()
        }
        customVarKeysTask?.cancel()
        customVarKeysTask = Task {
          await updateCustomVarKeysForCompletion()
        }
      } else {
        activeSession = nil
        remoteSessions.removeAll()
        customVarKeysTask?.cancel()
        customVarKeysTask = nil
        completionEngine.updateCustomVarKeys([])
      }
    }
    lastConfiguredAdminService = incomingService

    // Update node names for completion
    nodeNamesTask?.cancel()
    nodeNamesTask = Task {
      await updateNodeNamesForCompletion()
    }
  }

  func cleanup() {
    currentCommandTask?.cancel()
    currentCommandTask = nil
    lateRepliesTask?.cancel()
    lateRepliesTask = nil
    nodeNamesTask?.cancel()
    nodeNamesTask = nil
    customVarKeysTask?.cancel()
    customVarKeysTask = nil
    stopCountdown()
  }

  /// Follows the connection's late companion replies; a new connection's service replaces the
  /// old one's stream (which ends at teardown).
  private func listenForLateReplies(from service: RemoteNodeService?) {
    lateRepliesTask?.cancel()
    lateRepliesTask = nil
    guard let service else { return }
    let replies = service.companionCLILateReplies()
    lateRepliesTask = Task { [weak self] in
      for await reply in replies {
        self?.receiveLateReply(reply)
      }
    }
  }

  /// Ends the connection's sessions and input, keeping the transcript (with a line marking the
  /// gap) and the command history: a reconnect carries on under it (`configure`).
  func reset() {
    cleanup()
    companionLateLines = CompanionCLILateLines()
    currentInput = ""
    ghostText = ""
    activeSession = nil
    remoteSessions = []
    isWaitingForResponse = false
    pendingLoginContact = nil
    pendingConfirmation = nil
    clearTabState()
    if !outputLines.isEmpty, !transcriptIsDisconnected {
      transcriptIsDisconnected = true
      appendOutput(L10n.Tools.Tools.Cli.Transcript.disconnected, type: .response)
    }
  }

  /// Empties the transcript, the ⋯ menu's Clear and the `clear` command alike.
  func clearTranscript() {
    outputLines.removeAll()
    companionLateLines = CompanionCLILateLines()
    transcriptIsDisconnected = false
  }

  /// The transcript as text, one line each, for sharing.
  var transcriptText: String {
    outputLines.map(\.text).joined(separator: "\n")
  }

  /// Loads the connected radio's history the first time it is seen; another radio's goes away.
  private func loadHistoryIfRadioChanged() {
    let radioID = radioIDProvider()
    guard radioID != historyRadioID else { return }
    historyRadioID = radioID
    historyIndex = nil
    commandHistory = radioID.map { CLIHistoryStore.load(radioID: $0, from: historyStore) } ?? []
  }

  func stopCountdown() {
    countdownTask?.cancel()
    countdownTask = nil
    remainingSeconds = nil
  }

  func startCountdown(_ seconds: Int) {
    remainingSeconds = seconds
    countdownTask = Task {
      var remaining = seconds
      while remaining > 0, !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if !Task.isCancelled {
          remaining -= 1
          remainingSeconds = remaining
        }
      }
    }
  }

  private func showWelcomeBanner() {
    guard !hasShownWelcome else { return }
    hasShownWelcome = true

    appendOutput(L10n.Tools.Tools.Cli.welcomeLine1, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.welcomeConnected(localDeviceName), type: .response)
    appendOutput(L10n.Tools.Tools.Cli.welcomeHint, type: .response)
    appendOutput("", type: .response)
  }

  // MARK: - Command Execution

  func executeCommand(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isWaitingForResponse else { return }
    let promptPrefix = promptText.trimmingCharacters(in: .whitespaces)

    // Handle password input for pending login
    if let contact = pendingLoginContact {
      // Echo masked password
      appendOutput("\(promptPrefix) ****", type: .command)
      pendingLoginContact = nil
      currentInput = ""

      // Empty password cancels login
      guard !trimmed.isEmpty else {
        appendOutput(L10n.Tools.Tools.Cli.cancelled, type: .error)
        return
      }

      // Claim the busy state synchronously so a second submit can't pass
      // the guard before the spawned task starts running.
      isWaitingForResponse = true
      var task: Task<Void, Never>!
      task = Task {
        defer { clearWaitingIfCurrent(task) }
        await completeLogin(contact: contact, password: trimmed)
      }
      currentCommandTask = task
      return
    }

    // Handle yes/no answer for a pending dangerous command
    if let command = pendingConfirmation {
      appendOutput("\(promptPrefix) \(trimmed)", type: .command)
      pendingConfirmation = nil
      currentInput = ""

      let answer = trimmed.lowercased()
      guard answer == "yes" || answer == "y" else {
        appendOutput(L10n.Tools.Tools.Cli.cancelled, type: .error)
        return
      }

      // Claim the busy state synchronously, matching the login path.
      isWaitingForResponse = true
      var task: Task<Void, Never>!
      task = Task {
        defer { clearWaitingIfCurrent(task) }
        await executeLocal(command)
      }
      currentCommandTask = task
      return
    }

    // Echo prompt when empty input is submitted, matching terminal behavior
    guard !trimmed.isEmpty else {
      appendOutput(promptPrefix, type: .command)
      return
    }

    addToHistory(trimmed)
    appendOutput("\(promptPrefix) \(trimmed)", type: .command)

    // Parse and execute
    let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts[0].lowercased()
    let args = parts.count > 1 ? parts[1] : ""

    // Claim the busy state synchronously so a second submit can't pass the
    // guard before the spawned task starts running.
    isWaitingForResponse = true
    var task: Task<Void, Never>!
    task = Task {
      defer { clearWaitingIfCurrent(task) }
      await handleCommand(cmd, args: args, raw: trimmed)
    }
    currentCommandTask = task

    currentInput = ""
  }

  func cancelCurrentCommand() {
    currentCommandTask?.cancel()
    currentCommandTask = nil
    // A pending confirmation has no running task and leaves isWaitingForResponse
    // false, so it must be cleared here or the confirm prompt would wedge.
    if pendingConfirmation != nil {
      pendingConfirmation = nil
      appendOutput(L10n.Tools.Tools.Cli.cancelled, type: .error)
      return
    }
    if isWaitingForResponse {
      isWaitingForResponse = false
      appendOutput(L10n.Tools.Tools.Cli.cancelled, type: .error)
    }
  }

  private func clearWaitingIfCurrent(_ task: Task<Void, Never>) {
    // A cancelled older command can resume after a newer one claimed the
    // busy flag; only the task still owning currentCommandTask may clear it.
    guard currentCommandTask == task else { return }
    currentCommandTask = nil
    isWaitingForResponse = false
  }

  private func addToHistory(_ command: String) {
    // The same command again moves to the end rather than filling the history with repeats.
    commandHistory.removeAll { $0 == command }
    commandHistory.append(command)
    if commandHistory.count > Self.maxHistoryEntries {
      commandHistory.removeFirst()
    }
    historyIndex = nil
    if let radioID = historyRadioID {
      CLIHistoryStore.save(commandHistory, radioID: radioID, to: historyStore)
    }
  }

  private func handleCommand(_ cmd: String, args: String, raw: String) async {
    // Handle "s1", "s2", etc. as shorthand for "session 1", "session 2"
    if let number = parseSessionShortcut(cmd) {
      handleSessionCommand(String(number))
      return
    }

    // Local radio commands are interpreted app-side; the same words keep passing
    // through to repeaters on remote sessions.
    if activeSession?.isLocal == true {
      switch CLILocalCommandParser.parse(raw) {
      case let .command(command):
        if command.requiresConfirmation {
          pendingConfirmation = command
        } else {
          await executeLocal(command)
        }
        return
      case let .invalid(error):
        renderParseError(error)
        return
      case .notLocal:
        break
      }
    }

    switch cmd {
    case "help": showHelp()
    case "clear" where activeSession?.isLocal == true || args.isEmpty: clearOutput()
    case "session": handleSessionCommand(args)
    case "login": await handleLogin(args)
    case "logout": await handleLogout()
    case "nodes" where activeSession?.isLocal == true: await handleNodesCommand()
    case "companions" where activeSession?.isLocal == true: await handleCompanionsCommand()
    case "channels" where activeSession?.isLocal == true: await handleChannelsCommand()
    default: await handleUnknownCommand(cmd, raw: raw)
    }
  }

  private func parseSessionShortcut(_ cmd: String) -> Int? {
    guard cmd.hasPrefix("s"), cmd.count > 1 else { return nil }
    return Int(cmd.dropFirst())
  }

  private func handleUnknownCommand(_ cmd: String, raw: String) async {
    if activeSession?.isLocal == true {
      appendOutput("\(L10n.Tools.Tools.Cli.unknownCommand) \(cmd)", type: .error)
    } else if activeSession != nil {
      await sendRemoteCommand(raw)
    } else {
      appendOutput("\(L10n.Tools.Tools.Cli.unknownCommand) \(cmd)", type: .error)
    }
  }

  // MARK: - Built-in Commands

  private func showHelp() {
    appendOutput(L10n.Tools.Tools.Cli.helpHeader, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpLogin, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpLoginCompanion, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpLogout, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpSessionList, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpSessionLocal, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpSessionName, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpSessionShortcut, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpClear, type: .response)
    appendOutput(L10n.Tools.Tools.Cli.helpHelp, type: .response)

    if activeSession?.isLocal == true {
      appendOutput(L10n.Tools.Tools.Cli.helpNodes, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpCompanions, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpChannels, type: .response)
      appendOutput("", type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalHeader, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalList1, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalList2, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalList3, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalList4, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpLocalList5, type: .response)
    } else if activeSession?.isCompanion == true {
      appendOutput("", type: .response)
      for line in CompanionCLIExchange.helpLines {
        appendOutput(line, type: .response)
      }
    } else if activeSession != nil {
      appendOutput("", type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpRepeaterHeader, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpRepeaterList1, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpRepeaterList2, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpRepeaterList3, type: .response)
      appendOutput(L10n.Tools.Tools.Cli.helpRepeaterList4, type: .response)
    }
  }

  private func clearOutput() {
    clearTranscript()
  }

  // MARK: - Input

  /// Starts the input line with a command for the rest to be typed (a picked Change command,
  /// "set name "), leaving history browsing.
  func prefill(_ text: String) {
    clearCompletionState()
    historyIndex = nil
    currentInput = text
  }

  // MARK: - History Navigation

  func historyUp() {
    guard !commandHistory.isEmpty else { return }

    if let index = historyIndex {
      if index > 0 {
        historyIndex = index - 1
      }
    } else {
      historyIndex = commandHistory.count - 1
    }

    if let index = historyIndex {
      currentInput = commandHistory[index]
    }
  }

  func historyDown() {
    guard let index = historyIndex else { return }

    if index < commandHistory.count - 1 {
      historyIndex = index + 1
      currentInput = commandHistory[index + 1]
    } else {
      historyIndex = nil
      currentInput = ""
    }
  }

  // MARK: - Output Management

  @discardableResult
  func appendOutput(_ text: String, type: CLIOutputType) -> CLIOutputLine {
    let line = CLIOutputLine(text: text, type: type)
    outputLines.append(line)
    trimOutput()
    return line
  }

  func trimOutput() {
    if outputLines.count > Self.maxOutputLines {
      outputLines.removeFirst()
    }
  }

  // MARK: - Clipboard

  /// Returns the full response block containing the given line.
  /// A response block is all consecutive non-command lines.
  func getResponseBlock(containing line: CLIOutputLine) -> String {
    guard let index = outputLines.firstIndex(where: { $0.id == line.id }) else {
      return line.text
    }

    // Command lines: strip prompt prefix (e.g., "local > " or "@node > ")
    if line.type == .command {
      if let range = line.text.range(of: "> ") {
        return String(line.text[range.upperBound...])
      }
      return line.text
    }

    // Find start of block (walk back until we hit a .command or start)
    var startIndex = index
    while startIndex > 0, outputLines[startIndex - 1].type != .command {
      startIndex -= 1
    }

    // Find end of block (walk forward until we hit a .command or end)
    var endIndex = index
    while endIndex < outputLines.count - 1, outputLines[endIndex + 1].type != .command {
      endIndex += 1
    }

    return outputLines[startIndex...endIndex]
      .map { line in
        // Strip "> " prefix from MeshCore CLI responses
        if line.text.hasPrefix("> ") {
          return String(line.text.dropFirst(2))
        }
        return line.text
      }
      .joined(separator: "\n")
  }

  /// Inserts clipboard text at the given cursor position.
  func pasteFromClipboard(at cursorPosition: Int) {
    guard let text = UIPasteboard.general.string else { return }

    let safePosition = min(cursorPosition, currentInput.count)
    let index = currentInput.index(currentInput.startIndex, offsetBy: safePosition)
    currentInput.insert(contentsOf: text, at: index)
  }
}
