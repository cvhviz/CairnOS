import CairnServices
import SwiftUI
import UIKit

struct CLIToolView: View {
  @Environment(\.appState) private var appState

  @State private var isKeyboardFocused = false
  @State private var scrollPosition = ScrollPosition(edge: .bottom)
  @State private var cursorPosition: Int = 0

  var body: some View {
    content
      .onAppear {
        if appState.cliToolViewModel == nil {
          appState.cliToolViewModel = CLIToolViewModel()
        } else {
          // Restore cursor to end of existing input when returning to CLI
          cursorPosition = appState.cliToolViewModel?.currentInput.count ?? 0
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if let viewModel = appState.cliToolViewModel {
      CLIToolContent(
        viewModel: viewModel,
        appState: appState,
        isKeyboardFocused: $isKeyboardFocused,
        scrollPosition: $scrollPosition,
        cursorPosition: $cursorPosition
      )
    } else {
      ProgressView()
    }
  }
}

private struct CLIToolContent: View {
  @Bindable var viewModel: CLIToolViewModel
  let appState: AppState
  @Binding var isKeyboardFocused: Bool
  @Binding var scrollPosition: ScrollPosition
  @Binding var cursorPosition: Int

  @State private var showsCommandPicker = false
  /// The picker's choice, applied once its sheet has closed so the keyboard can come up.
  @State private var pendingPick: CompanionCommandPicker.Pick?
  @State private var showsSessions = false
  /// A session picked in the Sessions sheet, acted on once it has closed.
  @State private var pendingSessionCommand: String?

  private var isCompanionSession: Bool { viewModel.activeSession?.isCompanion == true }

  var body: some View {
    Group {
      if appState.services?.repeaterAdminService == nil {
        disconnectedState
      } else {
        terminalView
      }
    }
    .flashingNavigationTitle(L10n.Tools.Tools.cli)
    .navigationBarTitleDisplayMode(.inline)
    .liquidGlassToolbarBackground()
    .toolbar {
      if isCompanionSession {
        ToolbarItem(placement: .primaryAction) {
          Button(L10n.Tools.Tools.Cli.Companion.commands, systemImage: "list.bullet.rectangle") {
            showsCommandPicker = true
          }
          .disabled(viewModel.isWaitingForResponse)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button(L10n.Tools.Tools.Cli.Menu.sessions, systemImage: "rectangle.stack") {
            showsSessions = true
          }
          ShareLink(item: viewModel.transcriptText) {
            Label(L10n.Tools.Tools.Cli.Menu.shareTranscript, systemImage: "square.and.arrow.up")
          }
          .disabled(viewModel.outputLines.isEmpty)
          Divider()
          Button(L10n.Tools.Tools.Cli.Menu.clear, systemImage: "trash", role: .destructive) {
            viewModel.clearTranscript()
          }
          .disabled(viewModel.outputLines.isEmpty)
        } label: {
          Label(L10n.Tools.Tools.RxLog.more, systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("cli.more")
      }
    }
    .sheet(isPresented: $showsCommandPicker, onDismiss: applyPendingPick) {
      CompanionCommandPicker { pendingPick = $0 }
    }
    .sheet(isPresented: $showsSessions, onDismiss: applyPendingSession) {
      CLISessionsSheet(viewModel: viewModel) { pendingSessionCommand = $0 }
    }
    .task(id: appState.servicesVersion) {
      viewModel.configure(
        dependencies: CLIToolViewModel.Dependencies(
          repeaterAdminService: { [appState] in appState.services?.repeaterAdminService },
          remoteNodeService: { [appState] in appState.services?.remoteNodeService },
          settingsService: { [appState] in appState.services?.settingsService },
          dataStore: { [appState] in appState.services?.dataStore },
          radioID: { [appState] in appState.connectedDevice?.radioID },
          connectedDevice: { [appState] in appState.connectedDevice },
          companionCLI: { [appState] in appState.services?.remoteNodeService.companionCLISend }
        ),
        localDeviceName: appState.connectedDevice?.nodeName ?? L10n.Tools.Tools.Cli.defaultDevice,
        sendSelfAdvert: { [appState] flood in
          try await appState.sendSelfAdvert(flood: flood, allowLocationPrompt: false)
        }
      )
    }
  }

  // MARK: - Disconnected State

  private var disconnectedState: some View {
    RadioNotConnectedView(
      title: L10n.Tools.Tools.Cli.notConnected,
      systemImage: "terminal",
      description: L10n.Tools.Tools.Cli.notConnectedDescription
    )
  }

  // MARK: - Terminal View

  private var terminalView: some View {
    CLITerminalView(
      outputLines: viewModel.outputLines,
      promptText: viewModel.promptText,
      ghostText: viewModel.ghostText,
      tabSuggestions: viewModel.tabSuggestions,
      tabSelectionIndex: viewModel.tabSelectionIndex,
      isWaitingForResponse: viewModel.isWaitingForResponse,
      showSessionsButton: true,
      currentInput: $viewModel.currentInput,
      isKeyboardFocused: $isKeyboardFocused,
      scrollPosition: $scrollPosition,
      cursorPosition: $cursorPosition,
      onSubmit: {
        if viewModel.applySelectedSuggestion() {
          cursorPosition = viewModel.currentInput.count
        } else {
          viewModel.executeCommand(viewModel.currentInput)
        }
      },
      onHistoryUp: {
        viewModel.historyUp()
        cursorPosition = viewModel.currentInput.count
      },
      onHistoryDown: {
        viewModel.historyDown()
        cursorPosition = viewModel.currentInput.count
      },
      onRightArrowAtEnd: {
        if !viewModel.ghostText.isEmpty {
          viewModel.acceptGhostText()
          cursorPosition = viewModel.currentInput.count
        }
      },
      onTabComplete: {
        viewModel.tabComplete()
        cursorPosition = viewModel.currentInput.count
      },
      onMoveLeft: {
        if cursorPosition > 0 { cursorPosition -= 1 }
      },
      onMoveRight: {
        if !viewModel.ghostText.isEmpty, cursorPosition >= viewModel.currentInput.count {
          viewModel.acceptGhostText()
          cursorPosition = viewModel.currentInput.count
        } else if cursorPosition < viewModel.currentInput.count {
          cursorPosition += 1
        }
      },
      onPaste: {
        viewModel.pasteFromClipboard(at: cursorPosition)
        cursorPosition = min(
          cursorPosition + (UIPasteboard.general.string?.count ?? 0),
          viewModel.currentInput.count
        )
      },
      onSessions: { viewModel.executeCommand("session list") },
      onCancel: { viewModel.cancelCurrentCommand() },
      onDismiss: { isKeyboardFocused = false },
      onClear: { viewModel.executeCommand("clear") },
      onUpdateGhostText: { cursorAtEnd in viewModel.updateGhostText(cursorAtEnd: cursorAtEnd) },
      onClearTabState: { viewModel.clearTabState() },
      onGetResponseBlock: { viewModel.getResponseBlock(containing: $0) },
      onCommands: isCompanionSession ? { showsCommandPicker = true } : nil
    )
  }

  /// Switches to, or logs in to, the session picked in the Sessions sheet, once it has closed.
  private func applyPendingSession() {
    guard let command = pendingSessionCommand else { return }
    pendingSessionCommand = nil
    viewModel.executeCommand(command)
    cursorPosition = viewModel.currentInput.count
    isKeyboardFocused = true
  }

  /// Runs a picked command, or starts the input line with it and brings the keyboard back.
  private func applyPendingPick() {
    guard let pick = pendingPick else { return }
    pendingPick = nil
    switch pick {
    case let .run(command):
      viewModel.executeCommand(command)
    case let .edit(start):
      viewModel.prefill(start)
      cursorPosition = viewModel.currentInput.count
      isKeyboardFocused = true
    }
  }
}

#Preview {
  NavigationStack {
    CLIToolView()
  }
  .environment(\.appState, AppState())
}
