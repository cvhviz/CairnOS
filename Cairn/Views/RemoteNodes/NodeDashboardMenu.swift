import CairnServices
import SwiftUI

/// The dashboard's bar menu for a logged-in repeater or room: refresh while open, the saved login,
/// a comparison with another node, and logging out (keeping or forgetting the password).
struct NodeDashboardMenu: View {
  @Environment(\.appState) private var appState
  let session: RemoteNodeSessionDTO
  /// The node's contact, for the saved login; nil while it loads.
  let contact: ContactDTO?
  @Binding var refreshMinutes: Int?
  var onCompare: (() -> Void)?
  /// Logs out; `forget` drops the saved password and session too.
  let onLogout: (_ forget: Bool) -> Void

  @AppStorage(AppStorageKey.remoteNodesLoadSettingsOnOpen.rawValue)
  private var loadsSettingsOnOpen = AppStorageKey.defaultRemoteNodesLoadSettingsOnOpen
  /// The disclosure before Preload Settings goes on: what it costs the mesh.
  @State private var showsPreloadPrompt = false
  @State private var savedLogin: NodeSavedLoginModel?
  @State private var errorMessage: String?

  var body: some View {
    Menu {
      Section {
        Picker(selection: $refreshMinutes) {
          Text(L10n.RemoteNodes.RemoteNodes.Dashboard.refreshOff).tag(Int?.none)
          ForEach(RemoteNodePreferences.refreshChoices, id: \.self) { minutes in
            Text(L10n.RemoteNodes.RemoteNodes.Dashboard.refreshMinutes(minutes)).tag(Int?.some(minutes))
          }
        } label: {
          Label(L10n.RemoteNodes.RemoteNodes.Dashboard.refreshEvery, systemImage: "arrow.clockwise")
        }
        .pickerStyle(.menu)

        // Off by default: opening a node asks for its status alone, and each card reads its own
        // settings when it's opened. On: the settings and the clock check follow the status.
        // Turning it on asks first, saying what it costs the mesh; turning it off doesn't.
        Toggle(isOn: Binding(
          get: { loadsSettingsOnOpen },
          set: { on in
            if on { showsPreloadPrompt = true } else { loadsSettingsOnOpen = false }
          }
        )) {
          Label(L10n.RemoteNodes.RemoteNodes.Dashboard.loadSettingsOnOpen, systemImage: "arrow.down.circle")
        }
      }

      if let savedLogin {
        NodeSavedLoginMenuItems(model: savedLogin, errorMessage: $errorMessage)
      }

      if let onCompare {
        Section {
          Button(action: onCompare) {
            Label(L10n.RemoteNodes.RemoteNodes.Compare.menu, systemImage: "rectangle.split.2x1")
          }
        }
      }

      Section {
        Button {
          onLogout(false)
        } label: {
          Label(L10n.RemoteNodes.RemoteNodes.Dashboard.logOut, systemImage: "rectangle.portrait.and.arrow.right")
        }
        Button(role: .destructive) {
          onLogout(true)
        } label: {
          Label(L10n.RemoteNodes.RemoteNodes.Dashboard.logOutForget, systemImage: "key.slash")
        }
      }
    } label: {
      Label(L10n.Contacts.Contacts.Detail.more, systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier("node.dashboard.more")
    .alert(L10n.RemoteNodes.RemoteNodes.Dashboard.Preload.title, isPresented: $showsPreloadPrompt) {
      Button(L10n.RemoteNodes.RemoteNodes.Dashboard.Preload.confirm) { loadsSettingsOnOpen = true }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.RemoteNodes.RemoteNodes.Dashboard.Preload.message)
    }
    .task(id: contact?.id) {
      guard let contact else { return }
      let model = NodeSavedLoginModel(contact: contact)
      await model.load(services: appState.services)
      savedLogin = model
    }
    .errorAlert($errorMessage)
  }
}
