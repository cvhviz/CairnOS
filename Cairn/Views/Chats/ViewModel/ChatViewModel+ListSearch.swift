import CairnServices
import Foundation

extension ChatViewModel {
  // MARK: - Radio-wide message search

  /// Hits beyond this are not listed; the newest are the ones worth jumping to.
  static let messageSearchLimit = 50
  /// Typing pause before the store is queried.
  static let messageSearchDebounce: Duration = .milliseconds(250)

  /// Searches every stored message on `radioID` for `query`, debounced, and publishes the
  /// hits under the listed conversations (`messageSearchHits`). An empty query clears them
  /// at once. Each call replaces the search in flight, so a fast typist runs one query.
  func searchMessages(query: String, radioID: UUID?) {
    messageSearchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let radioID, let dataStore else {
      messageSearchHits = []
      messageSearchQuery = ""
      return
    }
    messageSearchTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.messageSearchDebounce)
      guard !Task.isCancelled, let self else { return }
      let messages = await (try? dataStore.searchMessages(
        radioID: radioID,
        query: trimmed,
        limit: Self.messageSearchLimit
      )) ?? []
      guard !Task.isCancelled else { return }
      messageSearchHits = MessageSearchHit.resolve(messages: messages, conversations: allConversations)
      messageSearchQuery = trimmed
    }
  }

  // MARK: - Draft previews

  /// Reads every listed direct and channel conversation's unsent draft from `store` into
  /// `draftPreviews`, so the rows show "Draft:" where one waits. Rooms have no composer draft.
  func refreshDraftPreviews(from store: DraftStore) {
    let previews = Self.draftPreviews(for: allConversations, in: store)
    if previews != draftPreviews { draftPreviews = previews }
  }

  /// The non-empty drafts of `conversations`, keyed by conversation id.
  static func draftPreviews(for conversations: [Conversation], in store: DraftStore) -> [UUID: String] {
    var previews: [UUID: String] = [:]
    for conversation in conversations {
      let draftID: ChatConversationID? = switch conversation {
      case let .direct(contact): .dm(radioID: contact.radioID, contactID: contact.id)
      case let .channel(channel): .channel(radioID: channel.radioID, channelIndex: channel.index)
      case .room: nil
      }
      guard let draftID, let draft = store.draft(for: draftID) else { continue }
      let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      previews[conversation.id] = MessagePreviewFormatter.preview(trimmed)
    }
    return previews
  }

  /// The unsent draft a row previews for `id`, if any.
  func draftPreview(id: UUID) -> String? {
    draftPreviews[id]
  }

  // MARK: - Reply quote target

  /// The message a reply's quote was taken from: the reply's stored `replyToID` when it was
  /// written here, else the newest earlier message in this conversation whose text the quote
  /// opens with, from the loaded window first and then the store. Nil when nothing matches.
  func quotedMessageID(for reply: MessageDTO) async -> UUID? {
    if let replyToID = reply.replyToID { return replyToID }
    guard let quote = ReplyQuote.parse(reply.text) else { return nil }
    if let loaded = Self.quotedMessage(matching: quote, reply: reply, in: messages) {
      return loaded.id
    }
    guard let dataStore else { return nil }
    let searchText = Self.quoteSearchText(quote.quotedText)
    let hits: [MessageDTO] = if let contact = currentContact {
      await (try? dataStore.searchMessages(contactID: contact.id, query: searchText, limit: 20)) ?? []
    } else if let channel = currentChannel {
      await (try? dataStore.searchMessages(
        radioID: channel.radioID,
        channelIndex: channel.index,
        query: searchText,
        limit: 20
      )) ?? []
    } else {
      []
    }
    return Self.quotedMessage(matching: quote, reply: reply, in: hits)?.id
  }

  /// The newest message before `reply` (not the reply itself) whose text starts with the quote,
  /// which is how MeshCore clients cut quotes. Falls back to a contains match so a quote taken
  /// mid-message still resolves.
  static func quotedMessage(matching quote: ReplyQuote, reply: MessageDTO, in candidates: [MessageDTO]) -> MessageDTO? {
    let quoted = quote.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quoted.isEmpty else { return nil }
    let earlier = candidates
      .filter { $0.id != reply.id && $0.sortDate <= reply.sortDate }
      .sorted { $0.sortDate > $1.sortDate }
    if let prefix = earlier.first(where: { $0.text.hasPrefix(quoted) }) { return prefix }
    return earlier.first { $0.text.localizedStandardContains(quoted) }
  }

  /// The first line of the quote, which is what the store's contains-search matches.
  static func quoteSearchText(_ quotedText: String) -> String {
    quotedText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
      ?? quotedText
  }
}
