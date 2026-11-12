import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The CLI's command history kept per radio between sessions, and the transcript kept across a
/// disconnect with a marker line.
@Suite("CLI history persistence")
@MainActor
struct CLIHistoryPersistenceTests {
  private let radioA = UUID()
  private let radioB = UUID()

  private func defaults() -> UserDefaults {
    let name = "CLIHistoryPersistenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func makeViewModel(radioID: UUID?, defaults: UserDefaults) -> CLIToolViewModel {
    let viewModel = CLIToolViewModel()
    configure(viewModel, radioID: radioID, defaults: defaults)
    return viewModel
  }

  private func configure(_ viewModel: CLIToolViewModel, radioID: UUID?, defaults: UserDefaults) {
    viewModel.configure(
      dependencies: CLIToolViewModel.Dependencies(
        repeaterAdminService: { nil },
        remoteNodeService: { nil },
        settingsService: { nil },
        dataStore: { nil },
        radioID: { radioID },
        connectedDevice: { nil },
        historyStore: defaults
      ),
      localDeviceName: "TestDevice",
      sendSelfAdvert: { _ in }
    )
  }

  /// Runs `command` and waits for it to finish, so the next one isn't refused as busy.
  private func run(_ command: String, on viewModel: CLIToolViewModel) async throws {
    viewModel.executeCommand(command)
    try await waitUntil { !viewModel.isWaitingForResponse }
  }

  @Test
  func `commands are kept under the radio and come back in a new view model`() async throws {
    let defaults = defaults()
    let first = makeViewModel(radioID: radioA, defaults: defaults)
    try await run("help", on: first)
    try await run("nodes", on: first)
    #expect(first.commandHistory == ["help", "nodes"])
    #expect(CLIToolViewModel.CLIHistoryStore.load(radioID: radioA, from: defaults) == ["help", "nodes"])

    let second = makeViewModel(radioID: radioA, defaults: defaults)
    #expect(second.commandHistory == ["help", "nodes"])
    second.historyUp()
    #expect(second.currentInput == "nodes")
    second.historyUp()
    #expect(second.currentInput == "help")
  }

  @Test
  func `another radio has its own history`() async throws {
    let defaults = defaults()
    let onA = makeViewModel(radioID: radioA, defaults: defaults)
    try await run("help", on: onA)

    let onB = makeViewModel(radioID: radioB, defaults: defaults)
    #expect(onB.commandHistory.isEmpty)
    try await run("channels", on: onB)
    #expect(onB.commandHistory == ["channels"])
    #expect(CLIToolViewModel.CLIHistoryStore.load(radioID: radioA, from: defaults) == ["help"])

    // The same view model switching radios loads the other radio's history
    configure(onB, radioID: radioA, defaults: defaults)
    #expect(onB.commandHistory == ["help"])
  }

  @Test
  func `a command run again moves to the end instead of repeating`() async throws {
    let defaults = defaults()
    let viewModel = makeViewModel(radioID: radioA, defaults: defaults)
    try await run("help", on: viewModel)
    try await run("nodes", on: viewModel)
    try await run("help", on: viewModel)
    #expect(viewModel.commandHistory == ["nodes", "help"])
  }

  @Test
  func `a disconnect keeps the transcript with a marker, and clearing empties it`() async throws {
    let defaults = defaults()
    let viewModel = makeViewModel(radioID: radioA, defaults: defaults)
    try await run("help", on: viewModel)
    let before = viewModel.outputLines.count
    #expect(before > 0)

    viewModel.reset()
    #expect(viewModel.outputLines.count == before + 1)
    #expect(viewModel.outputLines.last?.text == L10n.Tools.Tools.Cli.Transcript.disconnected)
    #expect(viewModel.commandHistory == ["help"], "the history outlives the connection")

    viewModel.reset()
    #expect(viewModel.outputLines.count == before + 1, "one marker per gap")
    #expect(viewModel.transcriptText.hasSuffix(L10n.Tools.Tools.Cli.Transcript.disconnected))

    viewModel.clearTranscript()
    #expect(viewModel.outputLines.isEmpty)
    #expect(viewModel.transcriptText.isEmpty)
  }
}
