import CairnServices
import SwiftUI

/// A companion's own command line (MeshCore 1.18), opened from its contact page: the node
/// terminal with the companion's commands, and the Commands picker in the bar and on the key
/// row. No login: it answers only if its contact for this radio lets this radio send commands.
struct CompanionCLIPage: View {
  @Environment(\.appState) private var appState

  let contact: ContactDTO

  @State private var viewModel = NodeCLIViewModel()
  @State private var showsCommandPicker = false
  /// The picker's choice, applied once its sheet has closed so the keyboard can come up.
  @State private var pendingPick: CompanionCommandPicker.Pick?

  var body: some View {
    NodeCLIView(viewModel: viewModel, onCommands: { showsCommandPicker = true })
      .flashingNavigationTitle(contact.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(L10n.Tools.Tools.Cli.Companion.commands, systemImage: "list.bullet.rectangle") {
            showsCommandPicker = true
          }
          .disabled(viewModel.isWaitingForResponse)
        }
      }
      .sheet(isPresented: $showsCommandPicker, onDismiss: applyPendingPick) {
        CompanionCommandPicker { pendingPick = $0 }
      }
      .task(id: appState.servicesVersion) {
        let publicKey = contact.publicKey
        viewModel.configureCompanion(sessionName: contact.displayName) { [appState] command, timeout, requestID in
          guard let send = appState.services?.remoteNodeService.companionCLISend else {
            throw RemoteNodeError.notConnected
          }
          return try await send(publicKey, command, timeout, requestID)
        }
        // A reply after its command timed out shows under it while the page is open.
        guard let service = appState.services?.remoteNodeService else { return }
        await viewModel.showLateReplies(from: service.companionCLILateReplies())
      }
      .onDisappear {
        // Leaving frees the companion's CLI slot for the next command (and the Tools CLI).
        viewModel.cancelCurrentCommand()
      }
  }

  /// Runs a picked command, or starts the input line with it (the terminal brings the keyboard).
  /// A command still in flight keeps the pick from running (the Commands key and button are off
  /// then, so this is only the last guard).
  private func applyPendingPick() {
    guard let pick = pendingPick else { return }
    pendingPick = nil
    switch pick {
    case let .run(command):
      guard !viewModel.isWaitingForResponse else { return }
      viewModel.executeCommand(command)
    case let .edit(start): viewModel.prefill(start)
    }
  }
}
