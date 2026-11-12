import Foundation
@testable import CairnServices
import Testing

@Suite("PersistenceStore message search")
struct PersistenceStoreMessageSearchTests {
  private func makeStore() async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private func saveDirect(
    _ store: PersistenceStore,
    radioID: UUID,
    contactID: UUID,
    text: String,
    at timestamp: UInt32
  ) async throws {
    try await store.saveMessage(MessageDTO.testDirectMessage(
      radioID: radioID,
      contactID: contactID,
      text: text,
      timestamp: timestamp,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
    ))
  }

  private func saveChannel(
    _ store: PersistenceStore,
    radioID: UUID,
    channelIndex: UInt8,
    text: String,
    at timestamp: UInt32
  ) async throws {
    try await store.saveMessage(MessageDTO.testChannelMessage(
      radioID: radioID,
      channelIndex: channelIndex,
      text: text,
      timestamp: timestamp,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
    ))
  }

  @Test
  func `direct search matches case-insensitively, newest first`() async throws {
    let store = try await makeStore()
    let radioID = UUID()
    let contactID = UUID()
    try await saveDirect(store, radioID: radioID, contactID: contactID, text: "Meet at the Trailhead", at: 10)
    try await saveDirect(store, radioID: radioID, contactID: contactID, text: "bring water", at: 20)
    try await saveDirect(store, radioID: radioID, contactID: contactID, text: "trailhead is closed", at: 30)

    let hits = try await store.searchMessages(contactID: contactID, query: "TRAILHEAD", limit: 50)

    #expect(hits.map(\.text) == ["trailhead is closed", "Meet at the Trailhead"])
  }

  @Test
  func `direct search ignores diacritics`() async throws {
    let store = try await makeStore()
    let contactID = UUID()
    try await saveDirect(store, radioID: UUID(), contactID: contactID, text: "Café at noon", at: 10)

    let hits = try await store.searchMessages(contactID: contactID, query: "cafe", limit: 50)

    #expect(hits.map(\.text) == ["Café at noon"])
  }

  @Test
  func `direct search stays inside its conversation`() async throws {
    let store = try await makeStore()
    let radioID = UUID()
    let alice = UUID()
    let bob = UUID()
    try await saveDirect(store, radioID: radioID, contactID: alice, text: "ridge repeater is up", at: 10)
    try await saveDirect(store, radioID: radioID, contactID: bob, text: "ridge hike saturday", at: 20)

    let hits = try await store.searchMessages(contactID: alice, query: "ridge", limit: 50)

    #expect(hits.map(\.text) == ["ridge repeater is up"])
  }

  @Test
  func `channel search is scoped to the radio and channel slot`() async throws {
    let store = try await makeStore()
    let radioID = UUID()
    try await saveChannel(store, radioID: radioID, channelIndex: 1, text: "net check at 8", at: 10)
    try await saveChannel(store, radioID: radioID, channelIndex: 2, text: "net check moved", at: 20)
    try await saveChannel(store, radioID: UUID(), channelIndex: 1, text: "net check other radio", at: 30)

    let hits = try await store.searchMessages(radioID: radioID, channelIndex: 1, query: "net check", limit: 50)

    #expect(hits.map(\.text) == ["net check at 8"])
  }

  @Test
  func `limit caps the newest hits`() async throws {
    let store = try await makeStore()
    let contactID = UUID()
    let radioID = UUID()
    for timestamp in UInt32(1)...5 {
      try await saveDirect(store, radioID: radioID, contactID: contactID, text: "ping \(timestamp)", at: timestamp)
    }

    let hits = try await store.searchMessages(contactID: contactID, query: "ping", limit: 2)

    #expect(hits.map(\.text) == ["ping 5", "ping 4"])
  }

  @Test(arguments: ["", "   "])
  func `blank query returns nothing`(query: String) async throws {
    let store = try await makeStore()
    let contactID = UUID()
    try await saveDirect(store, radioID: UUID(), contactID: contactID, text: "hello", at: 10)

    #expect(try await store.searchMessages(contactID: contactID, query: query, limit: 50).isEmpty)
  }
}
