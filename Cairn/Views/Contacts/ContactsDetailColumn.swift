import CairnServices
import SwiftUI

/// The Nodes tab's detail column at regular width (`ContactsTabSplit`): the saved node picked in
/// `ContactsContentColumn`, or on the Heard list the heard node picked there (the same page the
/// compact layout shows as a sheet), or an empty placeholder. Selection is read from
/// `appState.navigation` so this column stays in sync with the content column.
struct ContactsDetailColumn: View {
  @Environment(\.appState) private var appState

  @State private var isAdding = false
  @State private var errorMessage: String?

  var body: some View {
    let navigation = appState.navigation
    if navigation.nodesSection == .heard, let node = navigation.selectedHeardNode {
      DiscoveredNodeDetailSheet(
        node: node,
        isAdding: isAdding,
        onAdd: { add(node) },
        isInColumn: true,
        showsMap: true
      )
      .id(node.id)
      .errorAlert($errorMessage, title: L10n.Contacts.Contacts.Common.error)
    } else if navigation.nodesSection == .saved, let selectedContact = navigation.selectedContact {
      ContactDetailView(contact: selectedContact)
        .id(selectedContact.id)
    } else {
      ContentUnavailableView(L10n.Contacts.Contacts.List.selectNode, systemImage: "flipphone")
    }
  }

  /// Saves the heard node to the radio, as the Heard list's Add does; the node then leaves the
  /// Heard list, so its page leaves the column.
  private func add(_ node: DiscoveredNodeDTO) {
    guard !isAdding else { return }
    guard let contactService = appState.services?.contactService else {
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    isAdding = true
    Task {
      defer { isAdding = false }
      do {
        try await contactService.addOrUpdateContact(radioID: node.radioID, contact: node.makeContactFrame())
        if appState.navigation.selectedHeardNode?.id == node.id {
          appState.navigation.selectedHeardNode = nil
        }
      } catch ContactServiceError.contactTableFull {
        errorMessage = appState.connectedDevice.map { L10n.Contacts.Contacts.Add.Error.nodeListFull(Int($0.maxContacts)) }
          ?? L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}

#Preview {
  NavigationStack {
    ContactsDetailColumn()
  }
  .environment(\.appState, AppState())
}
