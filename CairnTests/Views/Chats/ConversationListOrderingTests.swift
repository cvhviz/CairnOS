import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Conversation list ordering")
@MainActor
struct ConversationListOrderingTests {
  private func conversation(_ name: String, isFavorite: Bool, at seconds: TimeInterval) -> Conversation {
    .channel(ChannelDTO(
      id: UUID(),
      radioID: UUID(),
      index: 1,
      name: name,
      secret: Data(repeating: 0xA1, count: 16),
      isEnabled: true,
      lastMessageDate: Date(timeIntervalSince1970: seconds),
      unreadCount: 0,
      isFavorite: isFavorite
    ))
  }

  private func names(_ conversations: [Conversation]) -> [String] {
    conversations.map(\.displayName)
  }

  @Test
  func `pinning keeps favorites above newer non-favorites`() {
    let favorite = conversation("Fav", isFavorite: true, at: 100)
    let recent = conversation("Recent", isFavorite: false, at: 900)

    let sections = ConversationListSections(
      favorites: [favorite],
      others: [recent],
      pinFavorites: true,
      isFavoritesCollapsed: false,
      sort: ChatViewModel().sortedByLastMessage
    )

    #expect(names(sections.visibleRows) == ["Fav", "Recent"])
  }

  @Test
  func `with pinning off everything sorts by most recent message`() {
    let favorite = conversation("Fav", isFavorite: true, at: 100)
    let recent = conversation("Recent", isFavorite: false, at: 900)
    let middle = conversation("Middle", isFavorite: false, at: 500)

    let sections = ConversationListSections(
      favorites: [favorite],
      others: [recent, middle],
      pinFavorites: false,
      isFavoritesCollapsed: false,
      sort: ChatViewModel().sortedByLastMessage
    )

    #expect(names(sections.visibleRows) == ["Recent", "Middle", "Fav"])
    #expect(!sections.showsFavoritesGroup)
  }
}
