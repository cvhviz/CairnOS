import CairnServices
import SwiftUI

/// Picks the conversation a message is forwarded to. The pick doesn't send:
/// the caller drops the text into that conversation's draft and opens it, so
/// the user can review (and trim to the target's length limit) before sending.
struct ForwardMessageSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let text: String
  let sourceConversationID: UUID
  let onSelect: (ForwardTarget) -> Void

  @State private var contacts: [ContactDTO] = []
  @State private var channels: [ChannelDTO] = []
  @State private var searchText = ""
  @State private var hasLoaded = false

  private var targets: (channels: [ForwardTarget], contacts: [ForwardTarget]) {
    ForwardTarget.eligible(
      contacts: contacts,
      channels: channels,
      excluding: sourceConversationID,
      searchText: searchText
    )
  }

  var body: some View {
    NavigationStack {
      let targets = targets
      List {
        Section {
          Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .cardListRow(theme)
        }

        targetSection(L10n.Chats.Chats.Filter.channels, targets: targets.channels)
        targetSection(L10n.Chats.Chats.Filter.directMessages, targets: targets.contacts)

        if hasLoaded, targets.channels.isEmpty, targets.contacts.isEmpty {
          Section {
            ContentUnavailableView.search(text: searchText)
              .listRowBackground(Color.clear)
          }
        }
      }
      // Targets are card rows on the canvas, like the conversation list they come from.
      .cardListCanvas(theme)
      .flashingNavigationTitle(L10n.Chats.Chats.Forward.title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task { await load() }
    }
  }

  @ViewBuilder
  private func targetSection(_ title: String, targets: [ForwardTarget]) -> some View {
    if !targets.isEmpty {
      Section(title) {
        ForEach(targets) { target in
          Button {
            onSelect(target)
            dismiss()
          } label: {
            HStack(spacing: 12) {
              avatar(for: target)
              Text(target.displayName)
                .font(.headline)
              Spacer()
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .cardListRow(theme)
        }
      }
    }
  }

  @ViewBuilder
  private func avatar(for target: ForwardTarget) -> some View {
    switch target {
    case let .dm(contact): ContactAvatar(contact: contact, size: 40)
    case let .channel(channel): ChannelAvatar(channel: channel, size: 40)
    }
  }

  private func load() async {
    defer { hasLoaded = true }
    guard let radioID = appState.currentRadioID,
          let dataStore = appState.offlineDataStore else { return }
    contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
    channels = await (try? dataStore.fetchChannels(radioID: radioID)) ?? []
  }
}
