import Foundation
@testable import CairnServices
import Testing

/// The demo room (`MockDataProvider+Rooms`) keeps showing each way a room post names its author,
/// resolved against the demo radio's contacts as the app does when it shows a post.
@Suite("Demo room naming")
struct DemoRoomNamingTests {
  private let session = MockDataProvider.dianasRoomSession()
  private let posts = MockDataProvider.dianasRoomPosts()
  private let resolver = RoomAuthorResolver(contacts: MockDataProvider.contacts)

  private func author(_ textPrefix: String) throws -> RoomAuthorIdentity {
    let post = try #require(posts.first { $0.text.hasPrefix(textPrefix) })
    return resolver.resolve(post, roomPublicKey: session.publicKey, roomName: session.name, selfName: "You")
  }

  @Test
  func `every demo post names its author the way it should`() throws {
    #expect(try author("Welcome").kind == .room)
    #expect(try author("Welcome").displayName == "Diana's Room")

    #expect(try author("Morning all").displayName == "Alice Chen")

    let frank = try author("Heading up")
    #expect(frank.displayName == "Dad")
    #expect(frank.advertisedName == "Frank Wilson")
    #expect(frank.contactID == MockDataProvider.frankWilsonID)

    let hannah = try author("Snow above")
    #expect(hannah.displayName == "Hannah Lee")
    #expect(hannah.contactID == MockDataProvider.hannahLeeID)

    let stranger = try author("Anyone near")
    #expect(stranger.kind == .unknown)
    #expect(stranger.displayName == "DEADBEEF")
    #expect(stranger.advertisedName == nil)

    #expect(try author("On my way").kind == .me)
    #expect(try author("On my way").displayName == "You")
  }

  @Test
  func `the demo room is filed on the demo radio and its posts in the room`() {
    #expect(session.radioID == MockDataProvider.simulatorDeviceID)
    #expect(session.isRoom)
    #expect(posts.allSatisfy { $0.sessionID == session.id })
    #expect(Set(posts.map(\.deduplicationKey)).count == posts.count)
  }
}
