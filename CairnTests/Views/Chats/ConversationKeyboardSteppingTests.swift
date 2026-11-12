import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Conversation keyboard stepping")
@MainActor
struct ConversationKeyboardSteppingTests {
  private func route(_ name: String) -> ChatRoute {
    ChatRoute(conversation: .channel(ChannelDTO(
      id: UUID(),
      radioID: UUID(),
      index: 1,
      name: name,
      secret: Data(repeating: 0xA1, count: 16),
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0,
      isFavorite: false
    )))
  }

  @Test
  func `next and previous move one row`() {
    let routes = [route("A"), route("B"), route("C")]
    #expect(ConversationListContent.stepped(from: routes[1], in: routes, by: .next) == routes[2])
    #expect(ConversationListContent.stepped(from: routes[1], in: routes, by: .previous) == routes[0])
  }

  @Test
  func `stepping clamps at both ends`() {
    let routes = [route("A"), route("B")]
    #expect(ConversationListContent.stepped(from: routes[1], in: routes, by: .next) == routes[1])
    #expect(ConversationListContent.stepped(from: routes[0], in: routes, by: .previous) == routes[0])
  }

  @Test
  func `no selection starts at first for next and last for previous`() {
    let routes = [route("A"), route("B"), route("C")]
    #expect(ConversationListContent.stepped(from: nil, in: routes, by: .next) == routes[0])
    #expect(ConversationListContent.stepped(from: nil, in: routes, by: .previous) == routes[2])
    #expect(ConversationListContent.stepped(from: route("Gone"), in: routes, by: .next) == routes[0])
  }

  @Test
  func `empty list yields nil`() {
    #expect(ConversationListContent.stepped(from: nil, in: [], by: .next) == nil)
  }
}
