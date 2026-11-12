import Foundation
@testable import MeshCore
import Testing

/// The frames as the firmware's RX_SYNC contract lays them out (its `net/RX_SYNC.md` test vectors).
@Suite("Cairn RX_SYNC parsing")
struct CairnRxSyncParserTests {
  /// A flood advert with one hop (0xAB): header 0x11, path_len 1, hop, three payload bytes.
  private static let advertRaw = "11 01 AB 01 02 03"

  @Test
  func `STATE, SUBSCRIBE and FETCH commands`() {
    #expect(PacketBuilder.cairnRxSyncState() == hex("C0 07 00"))
    #expect(PacketBuilder.cairnRxSyncSubscribe(on: true, resumeEpoch: 0xDEAD_BEEF, resumeSeq: 0x1E00, resumeMax: 512)
      == hex("C0 07 01 01 EF BE AD DE 00 1E 00 00 00 02"))
    #expect(PacketBuilder.cairnRxSyncSubscribe(on: false, resumeEpoch: 0, resumeSeq: 0, resumeMax: 0)
      == hex("C0 07 01 00 00 00 00 00 00 00 00 00 00 00"))
    #expect(PacketBuilder.cairnRxSyncFetch(sinceSeq: 0x1E00, max: 32) == hex("C0 07 02 00 1E 00 00 20"))
  }

  @Test
  func `single record parses every field`() {
    guard case let .cairnRxRecordFrame(r) = PacketParser.parse(hex("C8 00 2A 00 00 00 E8 03 00 00 F6 B5 " + Self.advertRaw))
    else {
      Issue.record("Expected cairnRxRecordFrame")
      return
    }
    #expect(r.flags.isEmpty)
    #expect(r.seq == 42)
    #expect(r.ageMs == 1000)
    #expect(r.radioAge == .milliseconds(1000))
    #expect(r.snrX4 == -10)
    #expect(r.snr == -2.5)
    #expect(r.rssi == -75)
    #expect(r.offset == 0)
    #expect(r.raw == hex(Self.advertRaw))
    #expect(r.isComplete)
  }

  @Test
  func `complete record becomes the same rxLogData a 0x88 frame does, with its position`() {
    guard case let .cairnRxRecordFrame(r) = PacketParser.parse(hex("C8 00 2A 00 00 00 E8 03 00 00 F6 B5 " + Self.advertRaw)),
          case let .rxLogData(stock) = PacketParser.parse(hex("88 F6 B5 " + Self.advertRaw)),
          let synced = r.rxLogData(epoch: 0xDEAD_BEEF) else {
      Issue.record("Expected a record and a 0x88 rxLogData")
      return
    }
    #expect(synced.seq == 42)
    #expect(synced.epoch == 0xDEAD_BEEF)
    #expect(synced.radioAge == .milliseconds(1000))
    #expect(!synced.isBackfill)
    #expect(synced.packetHash == stock.packetHash)
    #expect(synced.pathNodes == [0xAB])
    #expect(synced.payloadType == .advert)
    #expect(synced == stock.withRxSync(seq: 42, epoch: 0xDEAD_BEEF, radioAge: .milliseconds(1000), isBackfill: false))
  }

  @Test
  func `MORE and CONT join into one packet`() {
    // A flood group text of 200 raw bytes: 160 in the first frame, 40 in the continuation.
    let raw = Data([0x15, 0x00]) + Data((0..<198).map { UInt8($0 & 0xFF) })
    let firstFrame = hex("C8 02 07 00 00 00 10 00 00 00 14 A6") + raw.prefix(160)
    let contFrame = hex("C8 04 07 00 00 00 A0") + raw.suffix(40)
    guard case let .cairnRxRecordFrame(head) = PacketParser.parse(firstFrame),
          case let .cairnRxRecordFrame(tail) = PacketParser.parse(contFrame) else {
      Issue.record("Expected two cairnRxRecordFrame frames")
      return
    }
    #expect(head.flags == .more)
    #expect(!head.isComplete)
    #expect(head.rxLogData(epoch: 1) == nil)
    #expect(tail.flags == .continuation)
    #expect(tail.seq == 7)
    #expect(tail.offset == 160)
    #expect(tail.raw.count == 40)
    #expect(!tail.isComplete)

    guard let whole = head.appending(tail) else {
      Issue.record("Expected the continuation to join")
      return
    }
    #expect(whole.raw == raw)
    #expect(whole.isComplete)
    #expect(whole.snrX4 == 20)
    #expect(whole.rssi == -90)
    #expect(whole.ageMs == 16)
    let parsed = whole.rxLogData(epoch: 1)
    #expect(parsed?.payloadType == .groupText)
    #expect(parsed?.packetPayload.count == 198)
    #expect(parsed?.seq == 7)
  }

  @Test
  func `a continuation joins only its own record at its offset`() {
    let head = CairnRxRecordFrame(flags: .more, seq: 7, ageMs: 0, snrX4: 0, rssi: 0, raw: Data(repeating: 1, count: 160))
    let otherSeq = CairnRxRecordFrame(flags: .continuation, seq: 8, ageMs: 0, snrX4: 0, rssi: 0, offset: 160, raw: Data([2]))
    let wrongOffset = CairnRxRecordFrame(flags: .continuation, seq: 7, ageMs: 0, snrX4: 0, rssi: 0, offset: 150, raw: Data([2]))
    let notCont = CairnRxRecordFrame(flags: [], seq: 7, ageMs: 0, snrX4: 0, rssi: 0, raw: Data([2]))
    #expect(head.appending(otherSeq) == nil)
    #expect(head.appending(wrongOffset) == nil)
    #expect(head.appending(notCont) == nil)
  }

  @Test
  func `BACKFILL record is marked backfill`() {
    guard case let .cairnRxRecordFrame(r) = PacketParser.parse(hex("C8 01 2B 00 00 00 30 75 00 00 00 C4 " + Self.advertRaw))
    else {
      Issue.record("Expected cairnRxRecordFrame")
      return
    }
    #expect(r.flags == .backfill)
    #expect(r.seq == 43)
    #expect(r.ageMs == 30000)
    #expect(r.rxLogData(epoch: 5)?.isBackfill == true)
  }

  @Test
  func `GAP record says records before it were lost`() {
    guard case let .cairnRxRecordFrame(r) = PacketParser.parse(hex("C8 08 00 01 00 00 05 00 00 00 08 B0 " + Self.advertRaw))
    else {
      Issue.record("Expected cairnRxRecordFrame")
      return
    }
    #expect(r.flags == .gap)
    #expect(r.seq == 256)
    #expect(r.isComplete)
  }

  @Test
  func `STATE reply parses the journal`() {
    let frame = hex("C0 07 00 00 01 EF BE AD DE 10 00 00 00 00 20 00 00 00 10 00 00 01 03 00 00 00 02 00 00 00 01 04 00 00")
    guard case let .cairnRxSyncReply(.state(s)) = PacketParser.parse(frame) else {
      Issue.record("Expected a STATE reply")
      return
    }
    #expect(s.version == 1)
    #expect(s.epoch == 0xDEAD_BEEF)
    #expect(s.firstSeq == 0x10)
    #expect(s.lastSeq == 0x2000)
    #expect(s.capacityBytes == 4096)
    #expect(s.isOptedIn)
    #expect(s.overwritten == 3)
    #expect(s.pushRefused == 2)
    #expect(s.refusedMask == 0x401)
  }

  @Test
  func `SUBSCRIBE reply parses the cursor`() {
    let frame = hex("C0 07 00 01 01 01 EF BE AD DE 10 00 00 00 00 20 00 00 01 1E 00 00")
    guard case let .cairnRxSyncReply(.subscribe(s)) = PacketParser.parse(frame) else {
      Issue.record("Expected a SUBSCRIBE reply")
      return
    }
    #expect(s.isOn)
    #expect(s.resumed)
    #expect(s.epoch == 0xDEAD_BEEF)
    #expect(s.firstSeq == 0x10)
    #expect(s.lastSeq == 0x2000)
    #expect(s.cursor == 0x1E01)
  }

  @Test
  func `FETCH reply parses the range and count`() {
    guard case let .cairnRxSyncReply(.fetch(f)) = PacketParser.parse(hex("C0 07 00 02 10 00 00 00 00 20 00 00 20")) else {
      Issue.record("Expected a FETCH reply")
      return
    }
    #expect(f.firstSeq == 0x10)
    #expect(f.lastSeq == 0x2000)
    #expect(f.count == 32)
  }

  @Test
  func `BUSY and BAD_ARG are replies, not failures`() {
    #expect(PacketParser.parse(hex("C0 07 01 02")).rxSyncReply == .refused(op: .fetch, status: .busy))
    #expect(PacketParser.parse(hex("C0 07 02 02")).rxSyncReply == .refused(op: .fetch, status: .badArgument))
    #expect(PacketParser.parse(hex("C0 07 09 00")).rxSyncReply == .refused(op: .state, status: .other(9)))
  }

  @Test
  func `a refusal naming an unknown op, or none, is still a reply`() {
    // reply.bad: BAD_ARG for an op the firmware doesn't know; 0xFF: a request too short for an op
    #expect(PacketParser.parse(hex("C0 07 02 07")).rxSyncReply == .refused(op: nil, status: .badArgument))
    #expect(PacketParser.parse(hex("C0 07 02 FF")).rxSyncReply == .refused(op: nil, status: .badArgument))
    // it answers whichever request is waiting, so that request fails at once instead of timing out
    let noOp = PacketParser.parse(hex("C0 07 02 FF"))
    #expect(CairnRxSyncReply(answering: noOp, to: .state) == .refused(op: nil, status: .badArgument))
    #expect(CairnRxSyncReply(answering: noOp, to: .fetch) == .refused(op: nil, status: .badArgument))
    // a refusal naming another known op still answers only that op
    #expect(CairnRxSyncReply(answering: PacketParser.parse(hex("C0 07 01 02")), to: .state) == nil)
  }

  @Test
  func `FETCH_END parses`() {
    guard case let .cairnRxFetchEnd(end) = PacketParser.parse(hex("C9 00 EF BE AD DE 10 00 00 00 00 20 00 00 20")) else {
      Issue.record("Expected cairnRxFetchEnd")
      return
    }
    #expect(end.epoch == 0xDEAD_BEEF)
    #expect(end.firstSeq == 0x10)
    #expect(end.lastSeq == 0x2000)
    #expect(end.sent == 32)
  }

  @Test
  func `LOSS parses its refused pushes`() {
    guard case let .cairnRxLoss(loss) = PacketParser.parse(hex("C9 01 EF BE AD DE 05 00 00 00 08 00 00 80 07 00")) else {
      Issue.record("Expected cairnRxLoss")
      return
    }
    #expect(loss.epoch == 0xDEAD_BEEF)
    #expect(loss.overwritten == 5)
    #expect(loss.refusedMask == 0x8000_0008)
    #expect(loss.refusedCount == 7)
    #expect(loss.refused(.messagesWaiting))
    #expect(!loss.refused(.advertisement))
    #expect(!loss.refused(.newAdvertisement))
    #expect(!loss.refused(.ok))
    #expect(loss.refusedOther)
  }

  @Test
  func `ERR_CODE_UNSUPPORTED_CMD answers as unsupported`() {
    let error = PacketParser.parse(hex("01 01"))
    #expect(CairnRxSyncReply(answering: error, to: .state) == .unsupported)
    #expect(CairnRxSyncReply(answering: PacketParser.parse(hex("01 02")), to: .state) == nil)
    #expect(CairnRxSyncReply(answering: .ok(value: nil), to: .state) == nil)
    let fetch = PacketParser.parse(hex("C0 07 00 02 10 00 00 00 00 20 00 00 20"))
    #expect(CairnRxSyncReply(answering: fetch, to: .state) == nil)
    #expect(CairnRxSyncReply(answering: fetch, to: .fetch)?.op == .fetch)
  }

  @Test(arguments: [
    "C0 07",                                                                                  // no op
    "C0 07 00 03",                                                                            // unknown op
    "C0 07 00 00 01 EF BE AD DE 10 00 00 00 00 20 00 00 00 10 00 00 01 03 00 00 00 02 00 00 00 01 04 00", // STATE 1 short
    "C0 07 00 01 01 01 EF BE AD DE 10 00 00 00 00 20 00 00 01 1E 00",                         // SUBSCRIBE 1 short
    "C0 07 00 02 10 00 00 00 00 20 00 00",                                                    // FETCH 1 short
    "C8",                                                                                     // empty record
    "C8 00 2A 00 00 00 E8 03 00 00 F6 B5",                                                    // record, no raw
    "C8 00 2A 00 00",                                                                         // record header cut
    "C8 04 07 00 00 00 A0",                                                                   // continuation, no tail
    "C8 04 07 00",                                                                            // continuation header cut
    "C9",                                                                                     // empty status
    "C9 00 EF BE AD DE 10 00 00 00 00 20 00 00",                                              // FETCH_END 1 short
    "C9 01 EF BE AD DE 05 00 00 00 08 00 00 80 07",                                           // LOSS 1 short
    "C9 02 00 00 00 00",                                                                      // unknown kind
  ])
  func `malformed lengths are parse failures`(frame: String) {
    guard case .parseFailure = PacketParser.parse(hex(frame)) else {
      Issue.record("Expected parseFailure for \(frame)")
      return
    }
  }

  @Test
  func `stock 0x88 frames keep no RX_SYNC position`() {
    guard case let .rxLogData(stock) = PacketParser.parse(hex("88 F6 B5 " + Self.advertRaw)) else {
      Issue.record("Expected rxLogData")
      return
    }
    #expect(stock.seq == nil)
    #expect(stock.epoch == nil)
    #expect(stock.radioAge == nil)
    #expect(!stock.isBackfill)
    #expect(stock.snr == -2.5)
    #expect(stock.rssi == -75)
  }

  @Test
  func `other Cairn firmware replies still route to their own parser`() {
    guard case let .cairnSyncSentState(state) = PacketParser.parse(hex("C0 04 00 01 02")) else {
      Issue.record("Expected cairnSyncSentState")
      return
    }
    #expect(state.isOn)
    #expect(state.queued == 2)
  }

  @Test
  func `RX_SYNC pushes are push-category codes`() {
    #expect(ResponseCode.rxRecord.rawValue == 0xC8)
    #expect(ResponseCode.rxSyncStatus.rawValue == 0xC9)
    #expect(ResponseCode.rxRecord.category == .push)
    #expect(ResponseCode.rxSyncStatus.category == .push)
    #expect(CairnFirmwareSubcommand.rxSync == 0x07)
  }

  @Test
  func `filters match their RX_SYNC events`() {
    let record = PacketParser.parse(hex("C8 00 2A 00 00 00 E8 03 00 00 F6 B5 " + Self.advertRaw))
    let end = PacketParser.parse(hex("C9 00 EF BE AD DE 10 00 00 00 00 20 00 00 20"))
    let loss = PacketParser.parse(hex("C9 01 EF BE AD DE 05 00 00 00 08 00 00 80 07 00"))
    let reply = PacketParser.parse(hex("C0 07 01 02"))
    #expect(EventFilter.cairnRxRecordFrame.matches(record))
    #expect(EventFilter.cairnRxFetchEnd.matches(end))
    #expect(EventFilter.cairnRxLoss.matches(loss))
    #expect(EventFilter.cairnRxSyncReply.matches(reply))
    #expect(!EventFilter.cairnRxSyncReply.matches(record))
    #expect(EventFilter.cairnRxSyncPush.matches(record))
    #expect(EventFilter.cairnRxSyncPush.matches(end))
    #expect(EventFilter.cairnRxSyncPush.matches(loss))
    #expect(!EventFilter.cairnRxSyncPush.matches(reply))
  }

  private func hex(_ string: String) -> Data {
    Data(hexString: string.replacingOccurrences(of: " ", with: ""))!
  }
}

private extension MeshEvent {
  var rxSyncReply: CairnRxSyncReply? {
    if case let .cairnRxSyncReply(reply) = self { return reply }
    return nil
  }
}
