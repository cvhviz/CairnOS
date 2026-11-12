import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("PrivateChannelConflict")
struct PrivateChannelConflictTests {
  private static let radioID = UUID()
  private static let keyA = Data(repeating: 0xA1, count: 16)
  private static let keyB = Data(repeating: 0xB2, count: 16)

  private static func channel(_ name: String, index: UInt8, secret: Data) -> ChannelDTO {
    ChannelDTO(
      id: UUID(),
      radioID: radioID,
      index: index,
      name: name,
      secret: secret,
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private let existing = [
    channel("Public", index: 0, secret: Data(repeating: 0x8B, count: 16)),
    channel("Test", index: 1, secret: keyA),
    channel("", index: 2, secret: Data(count: 16)),
  ]

  @Test
  func `no conflict for a new name and key`() {
    #expect(PrivateChannelConflict.check(name: "Hiking", secret: Self.keyB, existingChannels: existing) == nil)
  }

  @Test
  func `same key is already joined regardless of name`() {
    let conflict = PrivateChannelConflict.check(name: "Renamed", secret: Self.keyA, existingChannels: existing)
    #expect(conflict == .alreadyJoined(existing[1]))
  }

  @Test
  func `same key wins over a name collision`() {
    let conflict = PrivateChannelConflict.check(name: "Public", secret: Self.keyA, existingChannels: existing)
    #expect(conflict == .alreadyJoined(existing[1]))
  }

  @Test(arguments: ["Test", "test", "TEST", "  Test  "])
  func `name in use with a different key is taken`(name: String) {
    #expect(PrivateChannelConflict.check(name: name, secret: Self.keyB, existingChannels: existing) == .nameTaken)
  }

  @Test
  func `name alone can be checked without a key`() {
    #expect(PrivateChannelConflict.check(name: "Test", secret: nil, existingChannels: existing) == .nameTaken)
    #expect(PrivateChannelConflict.check(name: "Fresh", secret: nil, existingChannels: existing) == nil)
  }

  @Test(arguments: ["", "   "])
  func `empty names never collide with empty slots`(name: String) {
    #expect(!PrivateChannelConflict.isNameTaken(name, existingChannels: existing))
  }

  @Test
  func `all-zero key never matches an unconfigured slot`() {
    #expect(PrivateChannelConflict.check(name: "Fresh", secret: Data(count: 16), existingChannels: existing) == nil)
  }

  @Test
  func `no channels means no conflict`() {
    #expect(PrivateChannelConflict.check(name: "Test", secret: Self.keyA, existingChannels: []) == nil)
  }
}
