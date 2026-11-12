import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Who a heard message was for")
struct RxMessageReachTests {
  /// This radio's key: its one-byte ID is 0x4A.
  private static let selfKey = Data([0x4A] + Array(repeating: 0x11, count: 31))

  private static func entry(
    type: PayloadType,
    payload: [UInt8],
    status: DecryptStatus,
    channelIndex: UInt8? = nil,
    channelName: String? = nil
  ) -> RxLogEntryDTO {
    let parsed = ParsedRxLogData(
      snr: 6.25,
      rssi: -97,
      rawPayload: Data(payload),
      routeType: .flood,
      payloadType: type,
      payloadVersion: 0,
      payloadTypeBits: type.rawValue,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data(payload)
    )
    return RxLogEntryDTO(
      radioID: UUID(),
      from: parsed,
      channelIndex: channelIndex,
      channelName: channelName,
      decryptStatus: status
    )
  }

  @Test
  func `a channel post the app read is that channel, by name`() {
    let post = Self.entry(type: .groupText, payload: [0x11, 1, 2, 3], status: .success, channelIndex: 0, channelName: "Public")
    let reach = RxMessageReach(entry: post, selfKey: Self.selfKey)
    #expect(reach == .channel(name: "Public"))
    #expect(reach?.expectsChatMessage == true)
  }

  @Test
  func `a channel post the app couldn't read is a channel you don't have, with its code`() {
    let post = Self.entry(type: .groupText, payload: [0x7A, 1, 2, 3], status: .noMatchingKey)
    #expect(RxMessageReach(entry: post, selfKey: Self.selfKey) == .channelNotJoined(hash: 0x7A))
  }

  @Test
  func `a direct message read with this radio's key is to you`() {
    let message = Self.entry(type: .textMessage, payload: [0x4A, 0x20, 9, 9], status: .success)
    #expect(RxMessageReach(entry: message, selfKey: Self.selfKey) == .toYou)
  }

  @Test
  func `an unreadable direct message to this radio's ID is flagged`() {
    let message = Self.entry(type: .textMessage, payload: [0x4A, 0x20, 9, 9], status: .dmNoMatchingKey)
    let reach = RxMessageReach(entry: message, selfKey: Self.selfKey)
    #expect(reach == .toYouUnreadable)
    #expect(reach?.expectsChatMessage == false)
  }

  @Test
  func `this radio's own direct message passed on is from you`() {
    let message = Self.entry(type: .textMessage, payload: [0x20, 0x4A, 9, 9], status: .dmNoMatchingKey)
    #expect(RxMessageReach(entry: message, selfKey: Self.selfKey) == .fromYou)
  }

  @Test
  func `a direct message between two other nodes is theirs`() {
    let message = Self.entry(type: .textMessage, payload: [0x20, 0x31, 9, 9], status: .dmNoMatchingKey)
    #expect(RxMessageReach(entry: message, selfKey: Self.selfKey) == .betweenOthers)
  }

  @Test
  func `packets that aren't messages have no reach`() {
    let advert = Self.entry(type: .advert, payload: [1, 2, 3], status: .notApplicable)
    #expect(RxMessageReach(entry: advert, selfKey: Self.selfKey) == nil)
  }
}
