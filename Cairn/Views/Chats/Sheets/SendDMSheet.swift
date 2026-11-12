import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SendDMSheet")

/// Picker sheet for starting a DM with a channel sender.
/// Resolves the sender's display name to matching Contacts (case-insensitive) and lets the user pick one.
struct SendDMSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let senderName: String
  let radioID: UUID
  let unverifiedNickname: String?
  let onSelect: (ContactDTO) -> Void

  @State private var matchingContacts: [ContactDTO] = []
  @State private var isLoading = true

  /// Title name mirroring the bubble's unverified-nickname presentation: nickname
  /// prominent with the raw sender name parenthesized.
  private var titleName: String {
    guard let unverifiedNickname else { return senderName }
    return "\(unverifiedNickname) \(L10n.Chats.Chats.Message.Sender.unverifiedNicknameFormat(senderName))"
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matchingContacts.isEmpty {
          // A DM needs the sender's advert (their key), which a channel message doesn't carry:
          // point at the Heard list, searched for the name, rather than ending here.
          ContentUnavailableView {
            Label(L10n.Chats.Chats.SendDM.noMatches(senderName), systemImage: "person.crop.circle.badge.questionmark")
          } description: {
            Text(L10n.Chats.Chats.SendDM.needsAdvert)
          } actions: {
            Button(L10n.Chats.Chats.SendDM.findInNodes, systemImage: "antenna.radiowaves.left.and.right") {
              dismiss()
              appState.navigation.navigateToDiscovery(searching: senderName)
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              Text(L10n.Chats.Chats.SendDM.limitation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

              Text(L10n.Chats.Chats.SendDM.matchingContacts)
                .font(.subheadline)
                .foregroundStyle(.secondary)

              ForEach(matchingContacts) { contact in
                ContactMatchRow(
                  contact: contact,
                  style: .tap,
                  userLocation: appState.bestAvailableLocation,
                  action: {
                    onSelect(contact)
                    dismiss()
                  }
                )
              }
            }
            .padding()
          }
        }
      }
      .flashingNavigationTitle(L10n.Chats.Chats.SendDM.title(titleName))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.SendDM.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task {
        await loadMatchingContacts()
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.background)
  }

  private func loadMatchingContacts() async {
    defer { isLoading = false }

    guard let store = appState.offlineDataStore else {
      logger.warning("No data store available for contact matching")
      return
    }

    do {
      let allContacts = try await store.fetchContacts(radioID: radioID)
      matchingContacts = SenderContactMatcher.filter(
        contacts: allContacts,
        senderName: senderName,
        excludeBlocked: true
      )
      logger.info("Found \(matchingContacts.count) matching contacts for sender '\(senderName)'")
    } catch {
      logger.error("Failed to fetch contacts for matching: \(error)")
    }
  }
}
