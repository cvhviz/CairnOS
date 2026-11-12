// Cairn/Views/Chats/Reactions/ReactionDetailsSheet.swift
import CairnServices
import OSLog
import SwiftUI

/// Sheet showing who reacted with each emoji.
struct ReactionDetailsSheet: View {
  let messageID: UUID
  var initialEmoji: String?

  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appTheme) private var theme

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "ReactionDetailsSheet")

  @State private var reactions: [ReactionDTO] = []
  @State private var selectedEmoji: String?
  @State private var isLoading = true

  private var emojiGroups: [(emoji: String, reactions: [ReactionDTO])] {
    Dictionary(grouping: reactions, by: \.emoji)
      .map { (emoji: $0.key, reactions: $0.value) }
      .sorted { lhs, rhs in
        if lhs.reactions.count != rhs.reactions.count {
          return lhs.reactions.count > rhs.reactions.count
        }
        let lhsEarliest = lhs.reactions.map(\.receivedAt).min() ?? .distantPast
        let rhsEarliest = rhs.reactions.map(\.receivedAt).min() ?? .distantPast
        return lhsEarliest < rhsEarliest
      }
  }

  private var selectedReactions: [ReactionDTO] {
    emojiGroups.first { $0.emoji == selectedEmoji }?.reactions ?? []
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reactions.isEmpty {
          ContentUnavailableView(
            L10n.Chats.Reactions.EmptyState.title,
            systemImage: "face.smiling",
            description: Text(L10n.Chats.Reactions.EmptyState.description)
          )
        } else {
          emojiTabsView
          senderListView
        }
      }
      // Senders are card rows on the card canvas, with the emoji tabs above them.
      .cardCanvas(theme)
      .flashingNavigationTitle(L10n.Chats.Reactions.title)
      .navigationBarTitleDisplayMode(.inline)
      .task {
        await loadReactions()
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var emojiTabsView: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(emojiGroups, id: \.emoji) { group in
          Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
              selectedEmoji = group.emoji
            }
          } label: {
            EmojiTab(
              emoji: group.emoji,
              count: group.reactions.count,
              isSelected: selectedEmoji == group.emoji
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, CardStyle.pageInset)
      .padding(.vertical, 12)
    }
    .scrollIndicators(.hidden)
  }

  private var senderListView: some View {
    List(selectedReactions) { reaction in
      HStack {
        Text(Self.reactorName(reaction, names: appState.nodeAppearance.names))
        Spacer()
        Text(reaction.receivedAt, format: .relative(presentation: .named))
          .foregroundStyle(.secondary)
          .font(.caption)
      }
      .accessibilityElement(children: .combine)
      .cardListRow(theme)
    }
    .cardListCanvas(theme)
  }

  private func loadReactions() async {
    guard let dataStore = appState.offlineDataStore else {
      isLoading = false
      return
    }

    do {
      reactions = try await dataStore.fetchReactions(for: messageID)
      selectedEmoji = Self.resolvedSelection(
        preferred: initialEmoji,
        available: emojiGroups.map(\.emoji)
      )
    } catch {
      logger.debug("Failed to fetch reactions for message \(messageID): \(error)")
    }

    isLoading = false
  }
}

extension ReactionDetailsSheet {
  /// Who reacted, named as they are now: "You" for the user's own reaction; a DM contact by their
  /// current name (nickname first); a channel sender as the bubble names one ("Dad (Frank Wilson)"
  /// when one contact owns the name); "Unknown" in the reader's language when no name came.
  static func reactorName(_ reaction: ReactionDTO, names: ContactNameDirectory) -> String {
    reaction.displayName(
      selfName: L10n.Chats.Chats.Path.Receiver.you,
      unknownName: L10n.Chats.Chats.Message.Sender.unknown,
      contactName: { names.displayNamesByContactID[$0] },
      labelChannelSender: { wireName in
        names.channelSenders.labeledName(for: wireName) { nickname, wire in
          L10n.Chats.Chats.Message.Sender.unverifiedLabel(nickname, wire)
        }
      }
    )
  }

  /// Uses `preferred` when it is still in `available`; otherwise the first group so overflow
  /// and a vanished reaction still land on a tab.
  static func resolvedSelection(preferred: String?, available: [String]) -> String? {
    if let preferred, available.contains(preferred) {
      return preferred
    }
    return available.first
  }
}

private struct EmojiTab: View {
  @Environment(\.appTheme) private var theme

  let emoji: String
  let count: Int
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(emoji)
      Text(count, format: .number)
        .font(.caption)
        .bold()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      if isSelected {
        Capsule().fill(Color.accentColor)
      } else {
        CardBackground(shape: Capsule())
      }
    }
    .foregroundStyle(isSelected ? theme.outgoingTextColor : .primary)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview {
  ReactionDetailsSheet(messageID: UUID())
    .environment(\.appState, AppState())
}
