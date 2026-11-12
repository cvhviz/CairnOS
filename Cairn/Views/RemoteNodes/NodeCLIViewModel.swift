import Foundation
import CairnServices
import UIKit

@Observable
@MainActor
final class NodeCLIViewModel {
  /// What the terminal talks to.
  enum Target {
    /// A logged-in repeater or room server.
    case node
    /// Another companion's command line (MeshCore 1.18): no login, its catalogue's commands,
    /// and silence read as "No reply yet · it may still arrive", with a late reply under it.
    case companion
  }

  private static let maxOutputLines = 1000
  private static let maxHistoryEntries = 100
  private static let rebootTimeout = RemoteOperationTimeoutPolicy.fireAndForgetCLI
  private static let defaultCommandTimeout: Duration = .seconds(10)

  // MARK: - Terminal State

  private(set) var outputLines: [CLIOutputLine] = []
  private(set) var commandHistory: [String] = []
  private(set) var historyIndex: Int?
  var currentInput: String = ""
  var isWaitingForResponse = false
  /// The node's key, when the history is kept per node between visits (`NodeCLIHistoryStore`).
  private var historyKey: Data?
  /// A typed command that throws something away (reboot, poweroff, clear stats, log erase, set
  /// radio), held until the user confirms it as the Controls page's tiles ask.
  struct PendingConfirmation: Identifiable, Equatable {
    let id = UUID()
    let command: String
    let message: String
  }

  var pendingConfirmation: PendingConfirmation?
  /// Bumped by ``prefill(_:)`` so the view moves the cursor to the end and raises the keyboard.
  private(set) var prefillCount = 0

  // MARK: - Completion State

  let completionEngine = CLICompletionEngine()
  var ghostText: String = ""
  var tabSuggestions: [String]?
  var tabSelectionIndex: Int?

  // MARK: - Dependencies

  /// Sends one command to the companion; `requestID` names it if its reply comes late.
  typealias CompanionSend = @MainActor (_ command: String, _ timeout: Duration, _ requestID: UUID) async throws -> String

  private var sessionName: String = ""
  private(set) var target: Target = .node
  private var sendRawCommand: (@MainActor (_ command: String, _ timeout: Duration) async throws -> String)?
  private var companionSend: CompanionSend?
  private var currentCommandTask: Task<Void, Never>?
  private var hasConfigured = false
  /// Timed-out companion commands whose late reply still shows under them.
  private var lateLines = CompanionCLILateLines()

  // MARK: - Prompt

  var promptText: String {
    if isWaitingForResponse { return "" }
    return "@\(sessionName)\(L10n.Tools.Tools.Cli.promptSuffix) "
  }

  // MARK: - Setup

  /// Configures the node CLI with its display name and send closure.
  /// Idempotent: the connection banner is appended only on the first call,
  /// so toggling the Settings/CLI segment does not re-banner.
  func configure(
    sessionName: String,
    historyKey: Data? = nil,
    sendRawCommand: @escaping @MainActor (_ command: String, _ timeout: Duration) async throws -> String
  ) {
    self.sendRawCommand = sendRawCommand
    if let historyKey, self.historyKey != historyKey {
      self.historyKey = historyKey
      commandHistory = NodeCLIHistoryStore.load(publicKey: historyKey)
      historyIndex = nil
    }
    configureOnce(sessionName: sessionName, target: .node)
  }

  /// The terminal's output as text, for Share and Copy.
  var transcript: String {
    NodeCLITranscript.text(lines: outputLines, nodeName: sessionName)
  }

  /// Configures the terminal for another companion's command line (MeshCore 1.18). Idempotent
  /// as ``configure(sessionName:sendRawCommand:)``.
  func configureCompanion(sessionName: String, send: @escaping CompanionSend) {
    companionSend = send
    configureOnce(sessionName: sessionName, target: .companion)
  }

  private func configureOnce(sessionName: String, target: Target) {
    self.sessionName = sessionName
    self.target = target
    guard !hasConfigured else { return }
    hasConfigured = true
    switch target {
    case .node:
      appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.bannerConnected(sessionName), type: .response)
      appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.bannerHint, type: .response)
    case .companion:
      for line in CompanionCLIExchange.bannerLines(name: sessionName) {
        appendOutput(line, type: .response)
      }
    }
    appendOutput("", type: .response)
  }

  /// Starts the input line with a command for the rest to be typed (a picked Change command,
  /// "set name ").
  func prefill(_ text: String) {
    clearTabState()
    ghostText = ""
    historyIndex = nil
    currentInput = text
    prefillCount += 1
  }

  // MARK: - Command Execution

  func executeCommand(_ command: String, confirmed: Bool = false) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isWaitingForResponse else { return }
    let promptPrefix = promptText.trimmingCharacters(in: .whitespaces)

    guard !trimmed.isEmpty else {
      appendOutput(promptPrefix, type: .command)
      return
    }

    // A destructive command on a node asks first, as its tile on the Controls page does.
    if !confirmed, target == .node, let message = NodeCLIConfirmation.message(for: trimmed) {
      pendingConfirmation = PendingConfirmation(command: trimmed, message: message)
      return
    }

    addToHistory(trimmed)
    appendOutput("\(promptPrefix) \(trimmed)", type: .command)

    let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts[0].lowercased()
    let args = parts.count > 1 ? parts[1] : ""

    // Claim the busy state before the task starts, so a second submit (a picked command, the
    // return key) can't pass the guard above and send twice.
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
    if isWaitingForResponse {
      isWaitingForResponse = false
      appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.cancelled, type: .error)
    }
  }

  /// A cancelled older command can finish after a newer one claimed the busy state; only the
  /// task still in `currentCommandTask` may clear it.
  private func clearWaitingIfCurrent(_ task: Task<Void, Never>) {
    guard currentCommandTask == task else { return }
    currentCommandTask = nil
    isWaitingForResponse = false
  }

  private func handleCommand(_ cmd: String, args: String, raw: String) async {
    switch cmd {
    case "help": showHelp()
    case "clear" where args.isEmpty: outputLines.removeAll()
    default:
      switch target {
      case .node: await sendCommand(raw)
      case .companion: await sendCompanionCommand(raw)
      }
    }
  }

  /// One command to the companion: never resent, a restart counts as sent, and silence says why
  /// it may be (`CompanionCLIExchange`).
  private func sendCompanionCommand(_ command: String) async {
    guard let companionSend else { return }
    let requestID = UUID()
    let nodeName = sessionName
    let outcome = await CompanionCLIExchange.run(command) { cleaned in
      try await companionSend(cleaned, RemoteOperationTimeoutPolicy.companionCLIMinimum, requestID)
    }
    guard let outcome, !Task.isCancelled else { return }
    let line = appendOutput(outcome.text, type: outcome.type)
    if outcome.awaitsLateReply {
      lateLines.watch(requestID: requestID, lineID: line.id, nodeName: nodeName)
    }
  }

  /// Shows a companion's reply that came after its command timed out, under that command.
  func receiveLateReply(_ reply: CompanionCLILateReply) {
    guard lateLines.place(reply, in: &outputLines) else { return }
    if outputLines.count > Self.maxOutputLines {
      outputLines.removeFirst()
    }
  }

  /// Shows each late reply from `replies` until the calling task ends (the page goes).
  func showLateReplies(from replies: AsyncStream<CompanionCLILateReply>) async {
    for await reply in replies {
      receiveLateReply(reply)
    }
  }

  private func sendCommand(_ command: String) async {
    guard let sendRawCommand else { return }

    // Reboot does not reply; treat both success and timeout as success.
    let normalized = command.lowercased()
    if normalized == "reboot" || normalized == "reboot now" {
      do {
        _ = try await sendRawCommand(command, Self.rebootTimeout)
        appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.rebootSent, type: .success)
      } catch RemoteNodeError.timeout {
        appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.rebootSent, type: .success)
      } catch is CancellationError {
      } catch {
        appendOutput(error.localizedDescription, type: .error)
      }
      return
    }

    do {
      let response = try await sendRawCommand(command, Self.defaultCommandTimeout)
      guard !Task.isCancelled else { return }
      appendOutput(response, type: .response)
    } catch is CancellationError {
    } catch {
      appendOutput(error.localizedDescription, type: .error)
    }
  }

  private func showHelp() {
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpHeader, type: .response)
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpHelp, type: .response)
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpClear, type: .response)
    if target == .companion {
      appendOutput("", type: .response)
      for line in CompanionCLIExchange.helpLines {
        appendOutput(line, type: .response)
      }
      return
    }
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpClearStats, type: .response)
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpReboot, type: .response)
    appendOutput(L10n.RemoteNodes.RemoteNodes.NodeCli.helpPassthrough, type: .response)
  }

  // MARK: - History

  private func addToHistory(_ command: String) {
    // The last command again isn't worth a second entry.
    if commandHistory.last != command {
      commandHistory.append(command)
    }
    if commandHistory.count > Self.maxHistoryEntries {
      commandHistory.removeFirst()
    }
    historyIndex = nil
    if let historyKey {
      NodeCLIHistoryStore.save(commandHistory, publicKey: historyKey)
    }
  }

  func historyUp() {
    guard !commandHistory.isEmpty else { return }
    if let index = historyIndex {
      if index > 0 { historyIndex = index - 1 }
    } else {
      historyIndex = commandHistory.count - 1
    }
    if let index = historyIndex { currentInput = commandHistory[index] }
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

  // MARK: - Output

  @discardableResult
  func appendOutput(_ text: String, type: CLIOutputType) -> CLIOutputLine {
    let line = CLIOutputLine(text: text, type: type)
    outputLines.append(line)
    if outputLines.count > Self.maxOutputLines {
      outputLines.removeFirst()
    }
    return line
  }

  /// Returns the full response block containing the given line, stripping
  /// prompt and MeshCore "> " prefixes. Twin of `CLIToolViewModel.getResponseBlock(containing:)`;
  /// keep the two in sync.
  func getResponseBlock(containing line: CLIOutputLine) -> String {
    guard let index = outputLines.firstIndex(where: { $0.id == line.id }) else {
      return line.text
    }
    if line.type == .command {
      if let range = line.text.range(of: "> ") {
        return String(line.text[range.upperBound...])
      }
      return line.text
    }
    var startIndex = index
    while startIndex > 0, outputLines[startIndex - 1].type != .command {
      startIndex -= 1
    }
    var endIndex = index
    while endIndex < outputLines.count - 1, outputLines[endIndex + 1].type != .command {
      endIndex += 1
    }
    return outputLines[startIndex...endIndex]
      .map { $0.text.hasPrefix("> ") ? String($0.text.dropFirst(2)) : $0.text }
      .joined(separator: "\n")
  }

  func pasteFromClipboard(at cursorPosition: Int) {
    guard let text = UIPasteboard.general.string else { return }
    let safePosition = min(cursorPosition, currentInput.count)
    let index = currentInput.index(currentInput.startIndex, offsetBy: safePosition)
    currentInput.insert(contentsOf: text, at: index)
  }
}

// MARK: - Completion

extension NodeCLIViewModel {
  /// Node CLI always operates on a remote session, so completion uses the
  /// remote command set (`isLocal: false`), or a companion's for that target, and
  /// excludes the app-CLI session-management commands the node firmware can't handle.
  func updateGhostText(cursorAtEnd: Bool) {
    guard !currentInput.isEmpty, cursorAtEnd else { ghostText = ""; return }
    let suggestions = completionEngine.completions(
      for: currentInput,
      isLocal: false,
      includeSessionCommands: false,
      isCompanion: target == .companion
    )
    guard let first = suggestions.first else { ghostText = ""; return }
    let parts = currentInput.split(separator: " ", omittingEmptySubsequences: false)
    let lastPart = parts.last.map(String.init) ?? ""
    ghostText = first.lowercased().hasPrefix(lastPart.lowercased())
      ? String(first.dropFirst(lastPart.count))
      : ""
  }

  func acceptGhostText() {
    guard !ghostText.isEmpty else { return }
    currentInput += ghostText
    ghostText = ""
  }

  @discardableResult
  func tabComplete() -> [String]? {
    if let suggestions = tabSuggestions, !suggestions.isEmpty {
      if let currentIndex = tabSelectionIndex {
        tabSelectionIndex = (currentIndex + 1) % suggestions.count
      } else {
        tabSelectionIndex = 0
      }
      return suggestions
    }
    let suggestions = completionEngine.completions(
      for: currentInput,
      isLocal: false,
      includeSessionCommands: false,
      isCompanion: target == .companion
    )
    guard !suggestions.isEmpty else {
      tabSuggestions = nil
      tabSelectionIndex = nil
      return nil
    }
    if suggestions.count == 1 {
      applyCompletion(suggestions[0])
      return nil
    }
    tabSuggestions = suggestions
    tabSelectionIndex = nil
    return suggestions
  }

  func applySelectedSuggestion() -> Bool {
    guard let suggestions = tabSuggestions,
          let index = tabSelectionIndex,
          index < suggestions.count else {
      return false
    }
    applyCompletion(suggestions[index])
    clearTabState()
    return true
  }

  func clearTabState() {
    tabSuggestions = nil
    tabSelectionIndex = nil
  }

  private func applyCompletion(_ suggestion: String) {
    let parts = currentInput.split(separator: " ", omittingEmptySubsequences: false)
    if parts.count <= 1 {
      currentInput = suggestion + " "
    } else {
      var newParts = parts.dropLast().map(String.init)
      newParts.append(suggestion)
      currentInput = newParts.joined(separator: " ") + " "
    }
    ghostText = ""
  }
}
