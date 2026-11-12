import CairnServices
import SwiftUI

/// Guest standalone sheet for room server stats, telemetry, and battery curve.
struct RoomStatusView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let session: RemoteNodeSessionDTO
  /// Pushed onto the node page's stack (a Mac), rather than a sheet with its own stack and Done.
  var isPushed = false
  @State private var viewModel = RoomStatusViewModel()
  @State private var lifetime = NodePageLifetime()

  var body: some View {
    if isPushed {
      page
        .onAppear {
          // Pushed, `onDisappear` also fires under every page pushed over this one: teardown waits
          // for the page itself to go.
          lifetime.onEnd = { [viewModel] in
            Task { await viewModel.cleanup() }
          }
        }
    } else {
      NavigationStack {
        page
          .toolbar {
            // Back where the page's reload used to be (the reload is on the page now); no Done
            ToolbarItem(placement: .cancellationAction) {
              NodePageBackButton { dismiss() }
            }
          }
      }
      .onDisappear {
        Task { await viewModel.cleanup() }
      }
      .presentationDetents([.large])
    }
  }

  private var page: some View {
    RoomStatusContent(
      viewModel: viewModel,
      session: session,
      connectionState: appState.connectionState,
      connectedDeviceID: appState.connectedDevice?.radioID,
      userLocation: appState.bestAvailableLocation
    )
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.RoomStatus.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button(L10n.RemoteNodes.RemoteNodes.done) {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
          )
        }
      }
    }
    .task {
      viewModel.configure(
        roomAdminService: { appState.services?.roomAdminService },
        contactService: { appState.services?.contactService },
        nodeSnapshotService: { appState.services?.nodeSnapshotService }
      )
      await viewModel.registerHandlers()

      // Pre-load OCV settings
      if let radioID = appState.connectedDevice?.radioID {
        await viewModel.helper.loadOCVSettings(publicKey: session.publicKey, radioID: radioID)
      }
      // The dashboard asks for status as it appears; this covers it appearing before the
      // configure above took effect. A request on its way, or one that already failed, makes this
      // a no-op.
      if viewModel.helper.shouldBackstopAutoLoadStatus(connectionState: appState.connectionState) {
        await viewModel.requestStatus(for: session)
      }
    }
  }
}

#Preview {
  RoomStatusView(
    session: RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Room",
      role: .roomServer,
      isConnected: true,
      permissionLevel: .admin
    )
  )
  .environment(\.appState, AppState())
}
