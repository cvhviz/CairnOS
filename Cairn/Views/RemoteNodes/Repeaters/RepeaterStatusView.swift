import CairnServices
import SwiftUI

/// Guest standalone sheet for repeater stats, telemetry, and neighbors.
struct RepeaterStatusView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let session: RemoteNodeSessionDTO
  /// Pushed onto the node page's stack (a Mac), rather than a sheet with its own stack and Done.
  var isPushed = false
  @State private var viewModel = RepeaterStatusViewModel()
  @State private var lifetime = NodePageLifetime()
  @State private var contacts: [ContactDTO] = []
  @State private var discoveredNodes: [DiscoveredNodeDTO] = []
  /// The node's contact, kept live so the route section reflects the path the firmware learns after
  /// a flood login (delivered asynchronously as a contact update).
  @State private var routeContact: ContactDTO?

  var body: some View {
    if isPushed {
      page
        .onAppear {
          // Pushed, `onDisappear` also fires under every page pushed over this one: teardown waits
          // for the page itself to go.
          lifetime.onEnd = { [viewModel] in
            viewModel.stopDiscovery()
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
        viewModel.stopDiscovery()
        Task { await viewModel.cleanup() }
      }
      .presentationDetents([.large])
    }
  }

  private var page: some View {
    RepeaterStatusContent(
      viewModel: viewModel,
      session: session,
      connectionState: appState.connectionState,
      contacts: contacts,
      discoveredNodes: discoveredNodes,
      userLocation: appState.bestAvailableLocation,
      connectedDeviceID: appState.connectedDevice?.radioID,
      routePathContact: routeContact
    )
    .discoveryFeedback(viewModel)
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Status.title)
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
        repeaterAdminService: { appState.services?.repeaterAdminService },
        contactService: { appState.services?.contactService },
        nodeSnapshotService: { appState.services?.nodeSnapshotService },
        deviceHashSize: { appState.connectedDevice?.hashSize }
      )
      await viewModel.registerHandlers()

      if let radioID = appState.connectedDevice?.radioID {
        await viewModel.helper.loadOCVSettings(publicKey: session.publicKey, radioID: radioID)
      }
      await loadNeighborNameSources()
      await refreshRouteContact()
      // The dashboard asks for status as it appears; this covers it appearing before the
      // configure above took effect. A request on its way, or one that already failed, makes this
      // a no-op.
      if viewModel.helper.shouldBackstopAutoLoadStatus(connectionState: appState.connectionState) {
        await viewModel.requestStatus(for: session)
      }
    }
    .onChange(of: appState.contactsVersion) {
      // An advert heard while this sheet is open can name a neighbour shown as a bare prefix.
      Task {
        await loadNeighborNameSources()
        await refreshRouteContact()
      }
    }
  }

  /// Contacts and discovered nodes that neighbour prefixes are matched against for names.
  private func loadNeighborNameSources() async {
    guard let radioID = appState.connectedDevice?.radioID,
          let dataStore = appState.services?.dataStore else { return }
    contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
    discoveredNodes = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID)) ?? []
  }

  private func refreshRouteContact() async {
    guard let dataStore = appState.services?.dataStore else { return }
    if let updated = await (try? dataStore.fetchContact(
      radioID: session.radioID,
      publicKey: session.publicKey
    )).flatMap(\.self) {
      routeContact = updated
    }
  }
}

#Preview {
  RepeaterStatusView(
    session: RemoteNodeSessionDTO(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Test Repeater",
      role: .repeater,
      isConnected: true,
      permissionLevel: .admin
    )
  )
  .environment(\.appState, AppState())
}
