import CairnServices
import SwiftUI

struct NewChatView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let onSelectContact: (ContactDTO) -> Void

  @State private var contacts: [ContactDTO] = []
  @State private var searchText = ""
  @State private var isLoading = true

  private var filteredContacts: [ContactDTO] {
    let eligible = contacts.filter { !$0.isBlocked && $0.type != .repeater && $0.type != .room }
    guard !searchText.isEmpty else { return eligible }
    return eligible.filter { contact in
      contact.displayName.localizedStandardContains(searchText)
    }
  }

  var body: some View {
    NavigationStack {
      let filteredContacts = filteredContacts
      Group {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredContacts.isEmpty, !searchText.isEmpty {
          ContentUnavailableView.search(text: searchText)
        } else if filteredContacts.isEmpty {
          ContentUnavailableView(
            L10n.Chats.Chats.NewChat.EmptyState.title,
            systemImage: "person.2",
            description: Text(L10n.Chats.Chats.NewChat.EmptyState.description)
          )
        } else {
          List(filteredContacts) { contact in
            Button {
              onSelectContact(contact)
            } label: {
              HStack(spacing: 12) {
                ContactAvatar(contact: contact, size: 40)

                VStack(alignment: .leading) {
                  Text(contact.displayName)
                    .font(.headline)

                  Text(contactTypeLabel(for: contact))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .cardListRow(theme)
          }
          // Each contact is its own card on the canvas, like the conversation list.
          .cardListCanvas(theme)
        }
      }
      .flashingNavigationTitle(L10n.Chats.Chats.NewChat.title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: L10n.Chats.Chats.NewChat.Search.placeholder)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task {
        await loadContacts()
      }
    }
  }

  private func loadContacts() async {
    defer { isLoading = false }
    // The offline store keeps contacts readable while the radio is disconnected.
    guard let radioID = appState.currentRadioID,
          let dataStore = appState.offlineDataStore else { return }

    contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
  }

  private func contactTypeLabel(for contact: ContactDTO) -> String {
    switch contact.type {
    case .chat:
      contact.isFloodRouted ? L10n.Chats.Chats.ConnectionStatus.floodRouting : L10n.Chats.Chats.NewChat.ContactType.direct
    case .repeater:
      L10n.Chats.Chats.NewChat.ContactType.repeater
    case .room:
      ""
    }
  }
}
