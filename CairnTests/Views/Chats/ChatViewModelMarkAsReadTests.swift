import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("ChatViewModel mark as read")
@MainActor
struct ChatViewModelMarkAsReadTests {
  private func makeContact(radioID: UUID, unreadCount: Int) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Alice",
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: Date(),
      unreadCount: unreadCount
    )
  }

  private func makeChannel(radioID: UUID, unreadCount: Int) -> ChannelDTO {
    ChannelDTO(
      id: UUID(),
      radioID: radioID,
      index: 3,
      name: "General",
      secret: Data(repeating: 0xA1, count: 16),
      isEnabled: true,
      lastMessageDate: Date(),
      unreadCount: unreadCount,
      unreadMentionCount: 1
    )
  }

  private func makeViewModel(store: PersistenceStore, radioID: UUID) -> ChatViewModel {
    let viewModel = ChatViewModel()
    viewModel.configureForTesting(
      dependencies: .testDefaults(
        dataStore: { store },
        currentRadioID: { radioID }
      )
    )
    return viewModel
  }

  @Test
  func `marking a direct chat as read clears its stored unread count`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, unreadCount: 4)
    try await store.saveContact(contact)
    let viewModel = makeViewModel(store: store, radioID: radioID)
    viewModel.conversations = [contact]

    await viewModel.markAsRead(.direct(contact))

    let stored = try #require(try await store.fetchContact(id: contact.id))
    #expect(stored.unreadCount == 0)
  }

  @Test
  func `marking a channel as read clears unread and mention counts`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let radioID = UUID()
    let channel = makeChannel(radioID: radioID, unreadCount: 7)
    try await store.saveChannel(channel)
    let viewModel = makeViewModel(store: store, radioID: radioID)
    viewModel.channels = [channel]

    await viewModel.markAsRead(.channel(channel))

    let stored = try #require(try await store.fetchChannel(id: channel.id))
    #expect(stored.unreadCount == 0)
    #expect(stored.unreadMentionCount == 0)
  }

  @Test
  func `a conversation with nothing unread is left untouched`() async throws {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let radioID = UUID()
    let contact = makeContact(radioID: radioID, unreadCount: 0)
    try await store.saveContact(contact)
    let viewModel = makeViewModel(store: store, radioID: radioID)
    viewModel.conversations = [contact]

    await viewModel.markAsRead(.direct(contact))

    let stored = try #require(try await store.fetchContact(id: contact.id))
    #expect(stored.unreadCount == 0)
  }
}
