import Foundation
@testable import MeshCore
import Testing

/// The frames as the firmware's queue sync contract lays them out (its `net/QUEUE_SYNC.md` and
/// `test/test_l2_queuesync`, which builds the same bytes).
@Suite("Cairn queue sync parsing")
struct CairnQueueSyncParserTests {
  @Test
  func `STATE, ARM, NEXT and CLEAR_LOSS commands`() {
    #expect(PacketBuilder.cairnQueueSyncState() == hex("C0 08 00"))
    #expect(PacketBuilder.cairnQueueSyncArm(on: true) == hex("C0 08 01 01"))
    #expect(PacketBuilder.cairnQueueSyncArm(on: false) == hex("C0 08 01 00"))
    #expect(PacketBuilder.cairnQueueSyncNext(ackSeq: 0x1234_5678) == hex("C0 08 02 78 56 34 12"))
    #expect(PacketBuilder.cairnQueueSyncNext(ackSeq: 0) == hex("C0 08 02 00 00 00 00"))
    let loss = CairnQueueLoss(channelEvicted: 1, refused: 2, snapshotLost: 3, confirmationsEvicted: 4)
    #expect(PacketBuilder.cairnQueueSyncClearLoss(loss) == hex("C0 08 03 01 00 00 00 02 00 00 00 03 00 00 00 04 00 00 00"))
  }

  @Test
  func `STATE reply parses every field`() {
    // the firmware test's StateLayout vector
    let frame = hex("C0 08 00 00 01 01 02 01 00 01 DD CC BB AA 04 03 02 01 05 00 00 00 06 00 00 00 07 00 00 00")
    guard case let .cairnQueueSyncReply(.state(op, state)) = PacketParser.parse(frame) else {
      Issue.record("Expected a queue sync STATE reply")
      return
    }
    #expect(op == .state)
    #expect(state.version == 1)
    #expect(state.isArmed)
    #expect(state.depth == 0x0102)
    #expect(state.capacity == 256)
    #expect(state.nextSeq == 0xAABB_CCDD)
    #expect(state.loss == CairnQueueLoss(channelEvicted: 0x0102_0304, refused: 5, snapshotLost: 6, confirmationsEvicted: 7))
    #expect(state.loss.lostMessages == 0x0102_0304 + 11)
  }

  private func reply(_ frame: String) -> CairnQueueSyncReply? {
    if case let .cairnQueueSyncReply(reply) = PacketParser.parse(hex(frame)) { return reply }
    return nil
  }

  private func acknowledgement(_ frame: String) -> (Data, UInt32?)? {
    if case let .acknowledgement(code, tripTime) = PacketParser.parse(hex(frame)) { return (code, tripTime) }
    return nil
  }

  @Test
  func `NEXT head and refusals`() {
    #expect(reply("C0 08 00 02 44 33 22 11 03 00") == .next(seq: 0x1122_3344, remaining: 3))
    #expect(reply("C0 08 01 02") == .refused(op: .next, status: .busy))
    #expect(reply("C0 08 02 FF") == .refused(op: nil, status: .badArgument))
  }

  @Test
  func `a queued confirmation is the acknowledgement it carries, a live push stays one too`() {
    let queued = acknowledgement("CA EF BE AD DE DC 05 00 00")
    #expect(queued?.0 == hex("EF BE AD DE"))
    #expect(queued?.1 == 1500)
    let live = acknowledgement("82 EF BE AD DE DC 05 00 00")
    #expect(live?.0 == hex("EF BE AD DE"))
    #expect(live?.1 == 1500)
    // stock fetches never take a queued confirmation for their answer; NEXT does
    #expect(!MeshCoreSession.answersMessageFetch(0xCA))
    #expect(MeshCoreSession.answersQueueSyncNext(0xCA))
    #expect(MeshCoreSession.answersQueueSyncNext(ResponseCode.contactMessageReceivedV3.rawValue))
    #expect(!MeshCoreSession.answersQueueSyncNext(0x88))
  }

  @Test
  func `short replies are parse failures`() {
    guard case .parseFailure = PacketParser.parse(hex("C0 08 00 00 01")) else {
      Issue.record("Expected a parse failure for a cut STATE reply")
      return
    }
    guard case .parseFailure = PacketParser.parse(hex("CA 01 02")) else {
      Issue.record("Expected a parse failure for a cut confirmation")
      return
    }
  }

  private func hex(_ string: String) -> Data {
    Data(string.split(separator: " ").compactMap { UInt8($0, radix: 16) })
  }
}
