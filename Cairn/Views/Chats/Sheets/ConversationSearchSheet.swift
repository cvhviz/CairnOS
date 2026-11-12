import CairnServices
import SwiftUI

/// Searches the stored messages of one conversation. Picking a hit hands it
/// back to the conversation, which pages it in and scrolls to it.
struct ConversationSearchSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let conversationType: ChatConversationType
  let onSelect: (MessageDTO) -> Void

  @State private var searchText = ""
  @State private var results: [MessageDTO] = []
  @State private var searchedText = ""
  @State private var isSearchPresented = true

  /// Hits beyond this are not listed; the newest are the ones worth jumping to.
  static let resultLimit = 100
  private static let debounce: Duration = .milliseconds(250)

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(results) { message in
          Button {
            onSelect(message)
            dismiss()
          } label: {
            ConversationSearchRow(message: message, conversationType: conversationType)
          }
          .buttonStyle(.plain)
          .cardListRow(theme)
        }
      }
      // Each match is its own card on the canvas, like the conversation list.
      .cardListCanvas(theme)
      .overlay {
        if trimmedQuery.isEmpty {
          ContentUnavailableView(
            L10n.Chats.Chats.Search.title,
            systemImage: "magnifyingglass",
            description: Text(L10n.Chats.Chats.Search.prompt(conversationType.navigationTitle))
          )
        } else if results.isEmpty, searchedText == trimmedQuery {
          ContentUnavailableView.search(text: trimmedQuery)
        }
      }
      .flashingNavigationTitle(L10n.Chats.Chats.Search.title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $searchText,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .always)
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task(id: trimmedQuery) {
        await search(trimmedQuery)
      }
    }
  }

  private func search(_ query: String) async {
    guard !query.isEmpty else {
      results = []
      searchedText = ""
      return
    }
    // Debounce typing; `.task(id:)` cancels this run when the query changes.
    try? await Task.sleep(for: Self.debounce)
    guard !Task.isCancelled, let dataStore = appState.offlineDataStore else { return }

    let hits: [MessageDTO] = switch conversationType {
    case let .dm(contact):
      await (try? dataStore.searchMessages(
        contactID: contact.id,
        query: query,
        limit: Self.resultLimit
      )) ?? []
    case let .channel(channel):
      await (try? dataStore.searchMessages(
        radioID: channel.radioID,
        channelIndex: channel.index,
        query: query,
        limit: Self.resultLimit
      )) ?? []
    }
    guard !Task.isCancelled else { return }
    results = hits
    searchedText = query
  }
}

private struct ConversationSearchRow: View {
  @Environment(\.appState) private var appState
  let message: MessageDTO
  let conversationType: ChatConversationType

  /// You, the DM contact by their current name, or a channel sender as the bubble names them
  /// ("Dad (Frank Wilson)" when one contact owns the name), "Unknown" when the message carried none.
  private var senderName: String {
    if message.isOutgoing { return L10n.Chats.Chats.Path.Receiver.you }
    switch conversationType {
    case let .dm(contact): return contact.displayName
    case .channel:
      return appState.nodeAppearance.names.channelSenders.labeledName(for: message.senderNodeName) { nickname, wireName in
        L10n.Chats.Chats.Message.Sender.unverifiedLabel(nickname, wireName)
      } ?? L10n.Chats.Chats.Message.Sender.unknown
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(senderName)
          .font(.subheadline)
          .bold()
        Spacer()
        Text(message.date, format: .dateTime.month().day().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(message.text)
        .font(.body)
        .lineLimit(3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
  }
}
