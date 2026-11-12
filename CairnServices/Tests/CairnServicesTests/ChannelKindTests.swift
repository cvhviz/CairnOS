import Foundation
import Testing
@testable import CairnServices

/// A channel is Public by its key, not by its slot (``PublicChannelKey``).
@Suite("Channel kind")
struct ChannelKindTests {
  private let radioID = UUID()
  private let privateSecret = Data((0..<16).map { UInt8($0 &* 13 &+ 7) })

  @Test
  func `a private channel another app put in slot 0 is private`() {
    let channel = ChannelDTO.testChannel(radioID: radioID, index: 0, name: "Family", secret: privateSecret)
    #expect(!channel.isPublicChannel)
    #expect(channel.isEncryptedChannel)
  }

  @Test
  func `the Public key is Public in any slot`() {
    for index: UInt8 in [0, 3] {
      let channel = ChannelDTO.testChannel(radioID: radioID, index: index, name: "Public", secret: PublicChannelKey.publicSecret)
      #expect(channel.isPublicChannel)
      #expect(!channel.isEncryptedChannel)
    }
  }

  @Test
  func `a key padded to 32 bytes still matches, a short or different one does not`() {
    #expect(PublicChannelKey.isPublic(PublicChannelKey.publicSecret + Data(repeating: 0, count: 16)))
    #expect(!PublicChannelKey.isPublic(PublicChannelKey.publicSecret.prefix(15)))
    #expect(!PublicChannelKey.isPublic(Data(repeating: 0, count: 16)))
    #expect(!PublicChannelKey.isPublic(privateSecret))
  }

  @Test
  func `a hashtag channel is not encrypted and not Public`() {
    let channel = ChannelDTO.testChannel(radioID: radioID, index: 2, name: "#general", secret: ChannelService.hashSecret("#general"))
    #expect(!channel.isPublicChannel)
    #expect(!channel.isEncryptedChannel)
  }
}
