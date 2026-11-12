import CairnServices
import SwiftUI

/// The saved login for a repeater or room, as the login sheet keeps it: whether a password is
/// saved, whether opening the node logs in on its own, and a way to forget the password. Shown as
/// items in the ⋯ menu of the node's contact page and of its dashboard, so neither needs the login
/// sheet open to change.
@Observable
@MainActor
final class NodeSavedLoginModel {
  let contact: ContactDTO
  private(set) var hasSavedPassword = false
  var autoLogin: Bool {
    didSet { NodeAutoLogin.set(autoLogin && hasSavedPassword, for: contact.publicKey) }
  }

  private(set) var isLoaded = false

  init(contact: ContactDTO) {
    self.contact = contact
    autoLogin = NodeAutoLogin.isEnabled(for: contact.publicKey)
  }

  func load(services: ServiceContainer?) async {
    guard let services else { return }
    hasSavedPassword = await services.remoteNodeService.hasPassword(forContact: contact)
    if !hasSavedPassword, autoLogin { autoLogin = false }
    isLoaded = true
  }

  /// Drops the saved password; automatic login goes with it.
  func forget(services: ServiceContainer?) async throws {
    guard let services else { return }
    try await services.remoteNodeService.deletePassword(forContact: contact)
    hasSavedPassword = false
    autoLogin = false
    NodeAutoLogin.set(false, for: contact.publicKey)
  }
}

/// The saved-login items for a menu: Log in automatically, Forget password.
struct NodeSavedLoginMenuItems: View {
  @Environment(\.appState) private var appState
  @Bindable var model: NodeSavedLoginModel
  /// Where a forget failure is reported.
  @Binding var errorMessage: String?

  var body: some View {
    Section(L10n.RemoteNodes.RemoteNodes.SavedLogin.title) {
      Toggle(isOn: $model.autoLogin) {
        Label(L10n.RemoteNodes.RemoteNodes.SavedLogin.autoLogin, systemImage: "person.badge.key")
      }
      .disabled(!model.hasSavedPassword)
      Button(role: .destructive) {
        Task {
          do {
            try await model.forget(services: appState.services)
          } catch {
            errorMessage = error.userFacingMessage
          }
        }
      } label: {
        Label(L10n.RemoteNodes.RemoteNodes.SavedLogin.forget, systemImage: "key.slash")
      }
      .disabled(!model.hasSavedPassword)
    }
  }
}
