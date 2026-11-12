import Foundation
@testable import MeshCore
import Testing

/// The RX_SYNC contract's test vectors, byte for byte: the firmware's
/// `examples/companion_radio/ui-l2/net/RX_SYNC.md` ("Test vectors"), which its native
/// `test_l2_rxsync` checks too. Copied here exactly; a change to either side must change both.
///
/// Inputs: epoch 0xA1B2C3D4; journal first_seq 0x100, last_seq 0x130, 8192 bytes, 255 overwritten;
/// 3 pushes refused, codes 0x80 and 0x8A.
@Suite("Cairn RX_SYNC contract vectors")
struct CairnRxSyncContractVectorTests {
  private static let epoch: UInt32 = 0xA1B2_C3D4

  /// The `vectors` block of RX_SYNC.md.
  private static let vectors: [String: String] = [
    "req.state": "C0 07 00",
    "req.subscribe": "C0 07 01 01 D4 C3 B2 A1 20 01 00 00 00 02",
    "req.subscribe.off": "C0 07 01 00 00 00 00 00 00 00 00 00 00 00",
    "req.fetch": "C0 07 02 1E 01 00 00 02",
    "reply.state": "C0 07 00 00 01 D4 C3 B2 A1 00 01 00 00 30 01 00 00 00 20 00 00 01 FF 00 00 00 03 00 00 00 01 04 00 00",
    "reply.subscribe": "C0 07 00 01 01 01 D4 C3 B2 A1 00 01 00 00 30 01 00 00 21 01 00 00",
    "reply.subscribe.live": "C0 07 00 01 01 00 D4 C3 B2 A1 00 01 00 00 30 01 00 00 31 01 00 00",
    "reply.subscribe.off": "C0 07 00 01 00 00 D4 C3 B2 A1 00 01 00 00 30 01 00 00 00 00 00 00",
    "reply.fetch": "C0 07 00 02 00 01 00 00 30 01 00 00 02",
    "reply.fetch.busy": "C0 07 01 02",
    "reply.bad": "C0 07 02 07",
    "rec.single": "C8 00 21 01 00 00 DC 05 00 00 F6 A4 11 22 33 44",
    "rec.backfill": "C8 01 1F 01 00 00 60 EA 00 00 28 B5 01 02",
    "rec.gap": "C8 08 00 01 00 00 00 00 00 00 00 88 AA",
    "rec.more": "C8 02 22 01 00 00 14 00 00 00 04 C4 " + (0..<160).map { String(format: "%02X", $0) }.joined(separator: " "),
    "rec.cont": "C8 04 22 01 00 00 A0 A0 A1 A2 A3 A4 A5 A6 A7 A8 A9",
    "end.fetch": "C9 00 D4 C3 B2 A1 00 01 00 00 30 01 00 00 02",
    "loss": "C9 01 D4 C3 B2 A1 FF 00 00 00 01 04 00 00 03 00",
  ]

  @Test
  func `the contract has eighteen vectors`() {
    #expect(Self.vectors.count == 18)
  }

  @Test
  func `requests are built byte for byte`() {
    #expect(PacketBuilder.cairnRxSyncState() == vector("req.state"))
    #expect(PacketBuilder.cairnRxSyncSubscribe(on: true, resumeEpoch: Self.epoch, resumeSeq: 0x120, resumeMax: 512)
      == vector("req.subscribe"))
    #expect(PacketBuilder.cairnRxSyncSubscribe(on: false, resumeEpoch: 0, resumeSeq: 0, resumeMax: 0)
      == vector("req.subscribe.off"))
    #expect(PacketBuilder.cairnRxSyncFetch(sinceSeq: 0x11E, max: 2) == vector("req.fetch"))
  }

  @Test
  func `replies parse to the contract's values`() {
    #expect(reply("reply.state") == .state(CairnRxSyncState(
      version: 1, epoch: Self.epoch, firstSeq: 0x100, lastSeq: 0x130, capacityBytes: 8192,
      isOptedIn: true, overwritten: 255, pushRefused: 3, refusedMask: 0x401
    )))
    #expect(reply("reply.subscribe") == .subscribe(CairnRxSubscribeResult(
      isOn: true, resumed: true, epoch: Self.epoch, firstSeq: 0x100, lastSeq: 0x130, cursor: 0x121
    )))
    #expect(reply("reply.subscribe.live") == .subscribe(CairnRxSubscribeResult(
      isOn: true, resumed: false, epoch: Self.epoch, firstSeq: 0x100, lastSeq: 0x130, cursor: 0x131
    )))
    #expect(reply("reply.subscribe.off") == .subscribe(CairnRxSubscribeResult(
      isOn: false, resumed: false, epoch: Self.epoch, firstSeq: 0x100, lastSeq: 0x130, cursor: 0
    )))
    #expect(reply("reply.fetch") == .fetch(CairnRxFetchReply(firstSeq: 0x100, lastSeq: 0x130, count: 2)))
    #expect(reply("reply.fetch.busy") == .refused(op: .fetch, status: .busy))
    // an unknown op 7: the refusal is still a reply, naming no op this library knows
    #expect(reply("reply.bad") == .refused(op: nil, status: .badArgument))
  }

  @Test
  func `records parse to the contract's values`() {
    #expect(record("rec.single") == CairnRxRecordFrame(
      flags: [], seq: 0x121, ageMs: 1500, snrX4: -10, rssi: -92, raw: Data([0x11, 0x22, 0x33, 0x44])
    ))
    #expect(record("rec.single")?.snr == -2.5)
    #expect(record("rec.backfill") == CairnRxRecordFrame(
      flags: .backfill, seq: 0x11F, ageMs: 60000, snrX4: 40, rssi: -75, raw: Data([0x01, 0x02])
    ))
    #expect(record("rec.gap") == CairnRxRecordFrame(
      flags: .gap, seq: 0x100, ageMs: 0, snrX4: 0, rssi: -120, raw: Data([0xAA])
    ))
  }

  @Test
  func `rec.more and rec.cont join into the 170-byte packet`() throws {
    let head = try #require(record("rec.more"))
    let tail = try #require(record("rec.cont"))
    #expect(head.flags == .more)
    #expect(tail.flags == .continuation)
    #expect(tail.seq == 0x122)
    #expect(tail.offset == 160)
    let whole = try #require(head.appending(tail))
    #expect(whole == CairnRxRecordFrame(
      flags: [], seq: 0x122, ageMs: 20, snrX4: 4, rssi: -60, raw: Data((0..<170).map { UInt8($0) })
    ))
    #expect(whole.isComplete)
  }

  @Test
  func `FETCH_END and LOSS parse to the contract's values`() throws {
    guard case let .cairnRxFetchEnd(end) = PacketParser.parse(vector("end.fetch")) else {
      Issue.record("Expected cairnRxFetchEnd")
      return
    }
    #expect(end == CairnRxFetchEnd(epoch: Self.epoch, firstSeq: 0x100, lastSeq: 0x130, sent: 2))

    guard case let .cairnRxLoss(loss) = PacketParser.parse(vector("loss")) else {
      Issue.record("Expected cairnRxLoss")
      return
    }
    #expect(loss == CairnRxLoss(epoch: Self.epoch, overwritten: 255, refusedMask: 0x401, refusedCount: 3))
    #expect(loss.refused(.advertisement))
    #expect(loss.refused(.newAdvertisement))
    #expect(!loss.refused(.messagesWaiting))
    #expect(!loss.refusedOther)
  }

  // MARK: - Helpers

  private func vector(_ name: String) -> Data {
    let bytes = (Self.vectors[name] ?? "").split(separator: " ").compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
  }

  private func reply(_ name: String) -> CairnRxSyncReply? {
    if case let .cairnRxSyncReply(reply) = PacketParser.parse(vector(name)) { return reply }
    return nil
  }

  private func record(_ name: String) -> CairnRxRecordFrame? {
    if case let .cairnRxRecordFrame(record) = PacketParser.parse(vector(name)) { return record }
    return nil
  }
}
