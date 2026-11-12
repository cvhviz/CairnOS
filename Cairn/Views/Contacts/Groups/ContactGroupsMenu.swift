import CairnServices
import SwiftUI

/// "Groups" submenu for a node's context menu: toggles membership in each group and
/// offers creating a new group that starts with this node.
struct ContactGroupsMenu: View {
  let contact: ContactDTO
  let viewModel: ContactsViewModel

  private let store = ContactGroupStore.shared

  var body: some View {
    Menu {
      ForEach(store.groups) { group in
        Toggle(isOn: Binding(
          get: { group.contains(contact.publicKey) },
          set: { _ in store.toggle(contact.publicKey, in: group.id) }
        )) {
          Label(group.name, systemImage: group.symbol)
        }
      }
      if !store.groups.isEmpty {
        Divider()
      }
      Button {
        viewModel.groupEditorRequest = ContactGroupEditorItem(mode: .create(initialMember: contact.publicKey))
      } label: {
        Label(L10n.Contacts.Contacts.Groups.new, systemImage: "plus")
      }
    } label: {
      Label(L10n.Contacts.Contacts.Groups.title, systemImage: "person.3")
    }
  }
}
