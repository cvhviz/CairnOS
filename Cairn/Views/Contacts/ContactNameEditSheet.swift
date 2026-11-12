import CairnServices
import SwiftUI

/// What a rename saves as the contact's nickname. The page shows one name, so the field holds
/// that name: typing the advertised name back, or clearing the field, removes the nickname
/// rather than storing a copy of the name the node already advertises.
enum ContactNameEdit {
  /// The nickname to save for `text`: empty (which clears it) when the text is blank or the
  /// advertised name, otherwise the trimmed text.
  static func nicknameToSave(text: String, advertisedName: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == advertisedName ? "" : trimmed
  }
}

/// Renames a node on this phone. The field starts with the name the page shows; the name the
/// node advertises sits under it, with a reset back to it when a nickname is set. Saving stores
/// the nickname through the same contact preference the old Nickname row used.
struct ContactNameEditSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let contact: ContactDTO
  /// Called after a save, so the page reloads the contact.
  let onSaved: () async -> Void

  @State private var text: String
  /// The free-text note kept for the node on this phone (`ContactDTO.note`).
  @State private var note: String
  @State private var isSaving = false
  @State private var errorMessage: String?
  @FocusState private var isFieldFocused: Bool

  init(contact: ContactDTO, onSaved: @escaping () async -> Void) {
    self.contact = contact
    self.onSaved = onSaved
    _text = State(initialValue: contact.displayName)
    _note = State(initialValue: contact.note ?? "")
  }

  private var nickname: String {
    ContactNameEdit.nicknameToSave(text: text, advertisedName: contact.name)
  }

  private var trimmedNote: String {
    note.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasChanges: Bool {
    nickname != (contact.nickname ?? "") || trimmedNote != (contact.note ?? "")
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(L10n.Contacts.Contacts.Detail.name, info: L10n.Contacts.Contacts.Detail.nameInfo) {
          ContentCard {
            TextField(contact.name, text: $text)
              .focused($isFieldFocused)
              .submitLabel(.done)
              .onSubmit { if hasChanges { save(nickname) } }
              .accessibilityLabel(L10n.Contacts.Contacts.Detail.name)
            Text(L10n.Contacts.Contacts.Detail.advertisedAs(contact.name))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          if contact.nickname != nil {
            ActionCard(
              L10n.Contacts.Contacts.Detail.resetToAdvertisedName,
              systemImage: "arrow.uturn.backward",
              color: .gray
            ) {
              save("")
            }
            .disabled(isSaving)
          }
        }

        // A note for this phone only: where the node is, who looks after it. Shown under the
        // header's chips on the node's pages.
        CardFormSection(L10n.RemoteNodes.RemoteNodes.Note.title, info: L10n.RemoteNodes.RemoteNodes.Note.info) {
          ContentCard {
            TextField(L10n.RemoteNodes.RemoteNodes.Note.placeholder, text: $note, axis: .vertical)
              .lineLimit(2...6)
              .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Note.title)
          }
        }
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.Detail.rename)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Contacts.Contacts.Common.save) { save(nickname) }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges || isSaving)
        }
      }
      .errorAlert($errorMessage)
      .onAppear { isFieldFocused = true }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private func save(_ nickname: String) {
    isSaving = true
    Task {
      do {
        try await appState.services?.contactService.updateContactPreferences(
          contactID: contact.id,
          nickname: nickname,
          note: trimmedNote
        )
        await onSaved()
        dismiss()
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
