import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Forward message")
struct ForwardMessageTests {
  private static let radioID = UUID()

  private func contact(_ name: String, type: ContactType = .chat, isBlocked: Bool = false) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: Self.radioID,
      publicKey: Data(repeating: UInt8(truncatingIfNeeded: name.hashValue), count: 32),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: isBlocked,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func channel(_ name: String, index: UInt8, secret: Data = Data(repeating: 0xA1, count: 16)) -> ChannelDTO {
    ChannelDTO(
      id: UUID(),
      radioID: Self.radioID,
      index: index,
      name: name,
      secret: secret,
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  // MARK: - Draft merge

  @Test
  func `forwarding into an empty draft uses the forwarded text alone`() {
    #expect(ForwardedDraft.merged(existing: nil, forwarded: "hello") == "hello")
    #expect(ForwardedDraft.merged(existing: "  \n", forwarded: "hello") == "hello")
  }

  @Test
  func `forwarding keeps an unsent draft and appends on a new line`() {
    #expect(ForwardedDraft.merged(existing: "typed earlier", forwarded: "hello") == "typed earlier\nhello")
  }

  // MARK: - Eligible targets

  @Test
  func `only chat contacts that are not blocked are offered`() {
    let targets = ForwardTarget.eligible(
      contacts: [
        contact("Alice"),
        contact("Repeater", type: .repeater),
        contact("Room", type: .room),
        contact("Blocked", isBlocked: true)
      ],
      channels: [],
      excluding: UUID(),
      searchText: ""
    )
    #expect(targets.contacts.map(\.displayName) == ["Alice"])
  }

  @Test
  func `unconfigured channel slots are skipped`() {
    let targets = ForwardTarget.eligible(
      contacts: [],
      channels: [channel("Trail Crew", index: 1), channel("", index: 2, secret: Data(count: 16))],
      excluding: UUID(),
      searchText: ""
    )
    #expect(targets.channels.map(\.displayName) == ["Trail Crew"])
  }

  @Test
  func `the conversation the message came from is not offered`() {
    let source = channel("Trail Crew", index: 1)
    let targets = ForwardTarget.eligible(
      contacts: [],
      channels: [source, channel("Bay Area", index: 2)],
      excluding: source.id,
      searchText: ""
    )
    #expect(targets.channels.map(\.displayName) == ["Bay Area"])
  }

  @Test
  func `search narrows both groups and each group is alphabetical`() {
    let targets = ForwardTarget.eligible(
      contacts: [contact("Zed Bay"), contact("Alice"), contact("Bayard")],
      channels: [channel("Trail Crew", index: 1), channel("Bay Area", index: 2)],
      excluding: UUID(),
      searchText: "bay"
    )
    #expect(targets.channels.map(\.displayName) == ["Bay Area"])
    #expect(targets.contacts.map(\.displayName) == ["Bayard", "Zed Bay"])
  }
}
