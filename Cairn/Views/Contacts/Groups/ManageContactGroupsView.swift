import CairnServices
import SwiftUI

/// Sheet for creating, renaming, reordering, and deleting contact groups, and for
/// opening a group's member list or broadcast.
struct ManageContactGroupsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  /// The current radio's nodes, used for the member editor and broadcasts.
  let contacts: [ContactDTO]

  @State private var editorMode: ContactGroupEditorItem?
  @State private var groupPendingDelete: ContactGroup?
  @State private var broadcastGroup: ContactGroup?

  private let store = ContactGroupStore.shared

  var body: some View {
    NavigationStack {
      Group {
        if store.groups.isEmpty {
          ContentUnavailableView {
            Label(L10n.Contacts.Contacts.Groups.emptyTitle, systemImage: "person.3")
          } description: {
            Text(L10n.Contacts.Contacts.Groups.emptyDescription)
          } actions: {
            Button(L10n.Contacts.Contacts.Groups.new) {
              editorMode = ContactGroupEditorItem(mode: .create(initialMember: nil))
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          groupList
        }
      }
      .themedCanvas(theme)
      .flashingNavigationTitle(L10n.Contacts.Contacts.Groups.manage)
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: UUID.self) { groupID in
        ContactGroupMembersView(groupID: groupID, contacts: contacts)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.done) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if !store.groups.isEmpty {
            EditButton()
          }
          Button {
            editorMode = ContactGroupEditorItem(mode: .create(initialMember: nil))
          } label: {
            Label(L10n.Contacts.Contacts.Groups.new, systemImage: "plus")
          }
        }
      }
    }
    .sheet(item: $editorMode) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
    .sheet(item: $broadcastGroup) { group in
      GroupBroadcastSheet(group: group, contacts: contacts)
    }
    .alert(
      groupPendingDelete.map { L10n.Contacts.Contacts.Groups.deleteTitle($0.name) } ?? "",
      isPresented: Binding(
        get: { groupPendingDelete != nil },
        set: { if !$0 { groupPendingDelete = nil } }
      ),
      presenting: groupPendingDelete
    ) { group in
      Button(L10n.Contacts.Contacts.Common.delete, role: .destructive) {
        store.delete(group.id)
      }
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
    } message: { _ in
      Text(L10n.Contacts.Contacts.Groups.deleteMessage)
    }
  }

  private var groupList: some View {
    List {
      ForEach(store.groups) { group in
        NavigationLink(value: group.id) {
          ContactGroupRow(group: group)
        }
        .cardListRow(theme)
        .contextMenu {
          groupActions(group)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            groupPendingDelete = group
          } label: {
            Label(L10n.Contacts.Contacts.Common.delete, systemImage: "trash")
          }
          Button {
            editorMode = ContactGroupEditorItem(mode: .edit(group))
          } label: {
            Label(L10n.Contacts.Contacts.Common.edit, systemImage: "pencil")
          }
          .tint(.orange)
        }
      }
      .onMove { source, destination in
        store.move(fromOffsets: source, toOffset: destination)
      }
    }
    // Each group its own card row; still a List, so swipe, reorder and the push keep working.
    .cardListCanvas(theme)
  }

  @ViewBuilder
  private func groupActions(_ group: ContactGroup) -> some View {
    Button {
      broadcastGroup = group
    } label: {
      Label(L10n.Contacts.Contacts.Groups.message, systemImage: "paperplane")
    }
    Button {
      editorMode = ContactGroupEditorItem(mode: .edit(group))
    } label: {
      Label(L10n.Contacts.Contacts.Groups.edit, systemImage: "pencil")
    }
    Divider()
    Button(role: .destructive) {
      groupPendingDelete = group
    } label: {
      Label(L10n.Contacts.Contacts.Groups.delete, systemImage: "trash")
    }
  }
}

/// Identifiable wrapper so the editor can be driven by `.sheet(item:)`.
struct ContactGroupEditorItem: Identifiable {
  let id = UUID()
  let mode: ContactGroupEditorSheet.Mode
}

private struct ContactGroupRow: View {
  let group: ContactGroup

  var body: some View {
    HStack(spacing: 12) {
      ContactGroupIcon(group: group, size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
        Text(L10n.Contacts.Contacts.Groups.memberCount(group.memberKeys.count))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Toggles which of the current radio's nodes belong to a group.
struct ContactGroupMembersView: View {
  @Environment(\.appTheme) private var theme

  let groupID: UUID
  let contacts: [ContactDTO]

  @State private var searchText = ""
  @State private var editorMode: ContactGroupEditorItem?
  @State private var showBroadcast = false

  private let store = ContactGroupStore.shared

  private var group: ContactGroup? {
    store.group(id: groupID)
  }

  private var visibleContacts: [ContactDTO] {
    let sorted = contacts.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    guard !searchText.isEmpty else { return sorted }
    return sorted.filter { $0.displayName.localizedStandardContains(searchText) }
  }

  var body: some View {
    if let group {
      content(group)
    } else {
      ContentUnavailableView(L10n.Contacts.Contacts.Groups.emptyTitle, systemImage: "person.3")
    }
  }

  private func content(_ group: ContactGroup) -> some View {
    let keys = Set(group.memberKeys)
    let members = visibleContacts.filter { keys.contains(ContactGroup.memberKey(for: $0.publicKey)) }
    let others = visibleContacts.filter { !keys.contains(ContactGroup.memberKey(for: $0.publicKey)) }

    return List {
      if !members.isEmpty {
        Section(L10n.Contacts.Contacts.Groups.members) {
          ForEach(members) { contact in
            memberRow(contact, isMember: true, group: group)
              .cardListRow(theme)
          }
        }
      }
      if !others.isEmpty {
        Section(L10n.Contacts.Contacts.Groups.otherNodes) {
          ForEach(others) { contact in
            memberRow(contact, isMember: false, group: group)
              .cardListRow(theme)
          }
        }
      }
    }
    // Nodes are a collection, so each is a card row; a List rather than a card form, since a
    // radio can hold hundreds of them.
    .cardListCanvas(theme)
    .searchable(text: $searchText)
    .flashingNavigationTitle(group.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            showBroadcast = true
          } label: {
            Label(L10n.Contacts.Contacts.Groups.message, systemImage: "paperplane")
          }
          Button {
            editorMode = ContactGroupEditorItem(mode: .edit(group))
          } label: {
            Label(L10n.Contacts.Contacts.Groups.edit, systemImage: "pencil")
          }
        } label: {
          Label(L10n.Contacts.Contacts.List.options, systemImage: "ellipsis.circle")
        }
      }
    }
    .sheet(item: $editorMode) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
    .sheet(isPresented: $showBroadcast) {
      GroupBroadcastSheet(group: group, contacts: contacts)
    }
  }

  private func memberRow(_ contact: ContactDTO, isMember: Bool, group: ContactGroup) -> some View {
    Button {
      withAnimation {
        store.toggle(contact.publicKey, in: group.id)
      }
    } label: {
      HStack(spacing: 12) {
        ContactAvatar(contact: contact, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(contact.displayName)
            .foregroundStyle(.primary)
          Label(contact.type.localizedName, systemImage: contact.type.iconSystemName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isMember ? group.tint : .secondary)
          .font(.title3)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isMember ? .isSelected : [])
  }
}
