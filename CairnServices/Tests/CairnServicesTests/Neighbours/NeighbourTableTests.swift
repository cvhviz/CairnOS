@testable import CairnServices
import Foundation
import MeshCore
import Testing

@Suite("NeighbourTable")
struct NeighbourTableTests {
  // MARK: - Fixtures

  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let repeaterKey = Data([0x3A, 0x7F, 0x21] + [UInt8](repeating: 0x10, count: 29))

  private func relay(_ hash: [UInt8], packet: String, snr: Double = 4, rssi: Int = -100) -> NeighbourEvidence {
    NeighbourEvidence(identity: .hash(Data(hash)), source: .relay, snr: snr, rssi: rssi, packetHash: packet)
  }

  private func advert(_ key: Data, packet: String = "ADV", type: UInt8 = 2, name: String? = "Hilltop") -> NeighbourEvidence {
    NeighbourEvidence(identity: .fullKey(key), source: .advert, snr: 7, rssi: -90,
                      nodeTypeRaw: type, name: name, packetHash: packet)
  }

  private func reply(_ identity: NeighbourIdentity, tag: UInt32, uplink: Double = 3, packet: String = "RPL") -> NeighbourEvidence {
    NeighbourEvidence(identity: identity, source: .discoverReply, snr: 5, rssi: -95,
                      nodeTypeRaw: 2, uplinkSNR: uplink, tag: tag, packetHash: packet)
  }

  private func at(_ seconds: TimeInterval) -> Date {
    Self.t0.addingTimeInterval(seconds)
  }

  // MARK: - Dedup

  @Test
  func `a reply via 0x8E and 0x88 counts once`() throws {
    let tag: UInt32 = 0x0102_0304
    let replyPayload = [0x92, UInt8(bitPattern: -26), 0x04, 0x03, 0x02, 0x01] + [UInt8](Self.repeaterKey)
    // header: direct route, CONTROL payload; path length 0
    let raw = Data([0x02 | PayloadType.control.rawValue << 2, 0x00] + replyPayload)
    let parsed = try #require(RxLogParser.parse(snr: 6.5, rssi: -92, payload: raw))
    let fromRxLog = NeighbourEvidence.extract(RxPacketFields(parsed), selfHash: nil)
    let fromPush = NeighbourEvidence.extract(
      DiscoverResponse(nodeType: 2, snrIn: -6.5, snr: 6.5, rssi: -92, pathLength: 0,
                       tag: Data([0x04, 0x03, 0x02, 0x01]), publicKey: Self.repeaterKey),
      selfHash: nil
    )
    var table = NeighbourTable()
    table.noteProbe(tag: tag, at: at(0))

    let pushEvidence = try #require(fromPush.first)
    let rxLogEvidence = try #require(fromRxLog.first)
    #expect(table.ingest(pushEvidence, at: at(1)) == .recorded(.fullKey(Self.repeaterKey)))
    #expect(table.ingest(rxLogEvidence, at: at(1.2)) == .duplicate)

    let record = try #require(table[.fullKey(Self.repeaterKey)])
    #expect(record.heardCount == 1)
    #expect(record.sources[.replyToUs]?.count == 1)
    #expect(record.uplinkSNR == -6.5)
    #expect(record.hearsYouAt == at(1))
  }

  @Test
  func `the same packet from two relays counts for each, and a repeat after the window counts again`() {
    var table = NeighbourTable()
    table.ingest(relay([0x3A], packet: "P1"), at: at(0))
    #expect(table.ingest(relay([0x5B], packet: "P1"), at: at(0.1)) == .recorded(.hash(Data([0x5B]))))
    #expect(table.ingest(relay([0x3A], packet: "P1"), at: at(1)) == .duplicate)
    #expect(table.ingest(relay([0x3A], packet: "P1"), at: at(4)) == .recorded(.hash(Data([0x3A]))))
    #expect(table[.hash(Data([0x3A]))]?.heardCount == 2)
  }

  // MARK: - Heard from

  private func fix(_ seconds: TimeInterval, latitude: Double) -> NeighbourFix {
    NeighbourFix(latitude: latitude, longitude: -122.4, horizontalAccuracy: 10, timestamp: at(seconds))
  }

  @Test
  func `a row keeps the best reception with a fix and the latest, each with when it was heard`() throws {
    var table = NeighbourTable()
    let identity = NeighbourIdentity.hash(Data([0x3A]))
    table.ingest(relay([0x3A], packet: "P1", snr: 9), at: at(0), fix: fix(-5, latitude: 37.0))
    table.ingest(relay([0x3A], packet: "P2", snr: 2), at: at(10), fix: fix(8, latitude: 37.1))
    // Heard without a fix: neither spot is removed
    table.ingest(relay([0x3A], packet: "P3", snr: 1), at: at(20))

    let record = try #require(table[identity])
    #expect(record.heardFrom == NeighbourHeardFrom(fix: fix(-5, latitude: 37.0), snr: 9, heardAt: at(0)))
    #expect(record.heardFrom?.receivedAt == at(0), "the reception's time, not the fix's")
    #expect(record.latestHeardFrom == NeighbourHeardFrom(fix: fix(8, latitude: 37.1), snr: 2, heardAt: at(10)))

    // Read back from storage, a spot has no reception time and stands at its fix's
    let stored = NeighbourHeardFrom(fix: fix(-5, latitude: 37.0), snr: 9)
    #expect(stored.receivedAt == at(-5))
  }

  @Test
  func `merging keeps the better spot and the later one`() {
    let early = NeighbourHeardFrom(fix: fix(0, latitude: 37.0), snr: 9, heardAt: at(0))
    let late = NeighbourHeardFrom(fix: fix(50, latitude: 37.2), snr: 1, heardAt: at(50))
    let identity = NeighbourIdentity.hash(Data([0x3A]))
    let first = NeighbourRecord(identity: identity, firstHeard: at(0), lastHeard: at(0), heardFrom: early, latestHeardFrom: early)
    let second = NeighbourRecord(identity: identity, firstHeard: at(50), lastHeard: at(50), heardFrom: late, latestHeardFrom: late)
    for merged in [first.merged(with: second), second.merged(with: first)] {
      #expect(merged.heardFrom == early)
      #expect(merged.latestHeardFrom == late)
    }
    #expect(NeighbourHeardFrom.latest(stored: late, reply: nil) == late)
  }

  // MARK: - Confirmation

  @Test
  func `one relay sighting is heard once; two sightings 5 s apart are confirmed`() throws {
    var table = NeighbourTable()
    let id = NeighbourIdentity.hash(Data([0x3A, 0x7F]))
    table.ingest(relay([0x3A, 0x7F], packet: "P1"), at: at(0))
    #expect(table[id]?.isConfirmed == false)

    table.ingest(relay([0x3A, 0x7F], packet: "P2"), at: at(4))
    #expect(table[id]?.isConfirmed == false)

    table.ingest(relay([0x3A, 0x7F], packet: "P3"), at: at(5))
    let record = try #require(table[id])
    #expect(record.isConfirmed)
    #expect(record.heardCount == 3)
  }

  @Test
  func `an advert, a reply or a trace confirms at once`() {
    var table = NeighbourTable()
    table.ingest(advert(Self.repeaterKey), at: at(0))
    table.ingest(reply(.keyPrefix(Data(repeating: 0x77, count: 8)), tag: 9), at: at(0))
    table.ingest(NeighbourEvidence(identity: .hash(Data([0x44])), source: .traceConfirm, snr: 2, rssi: nil,
                                   uplinkSNR: 1, tag: 5, hearsYou: true, packetHash: nil), at: at(0))
    let allConfirmed = table.records.values.allSatisfy(\.isConfirmed)
    #expect(table.count == 3)
    #expect(allConfirmed)
    #expect(table[.fullKey(Self.repeaterKey)]?.isFullKeyConfirmed(now: at(24 * 3600)) == true)
    #expect(table[.fullKey(Self.repeaterKey)]?.isFullKeyConfirmed(now: at(24 * 3600 + 1)) == false)
  }

  // MARK: - Signal

  @Test
  func `SNR keeps the last, the best and a 0.25 moving average`() throws {
    var table = NeighbourTable()
    table.ingest(relay([0x3A], packet: "P1", snr: 8, rssi: -90), at: at(0))
    table.ingest(relay([0x3A], packet: "P2", snr: 0, rssi: -110), at: at(10))
    let record = try #require(table[.hash(Data([0x3A]))])
    #expect(record.lastSNR == 0)
    #expect(record.bestSNR == 8)
    #expect(record.snrEWMA == 6)
    #expect(record.lastRSSI == -110)
  }

  @Test
  func `a proven echo marks its relay as hearing us without counting the frame again`() throws {
    var table = NeighbourTable()
    let identity = NeighbourIdentity.hash(Data([0x3A]))
    table.ingest(relay([0x3A], packet: "ECHO"), at: at(0))
    _ = table.takeChanges()

    let noted = table.noteHearsYou(relayHash: Data([0x3A]), at: at(0))
    #expect(noted)
    var record = try #require(table[identity])
    #expect(record.hearsYouAt == at(0))
    #expect(record.heardCount == 1)
    #expect(table.takeChanges().upserted.map(\.identity) == [identity])
    // An older proof changes nothing
    let older = table.noteHearsYou(relayHash: Data([0x3A]), at: at(-10))
    #expect(!older)

    // A proof that outran its frame starts the row with no receptions, for the frame to count
    let early = table.noteHearsYou(relayHash: Data([0x5C]), at: at(5))
    #expect(early)
    #expect(table[.hash(Data([0x5C]))]?.heardCount == 0)
    table.ingest(relay([0x5C], packet: "ECHO2"), at: at(5))
    record = try #require(table[.hash(Data([0x5C]))])
    #expect(record.heardCount == 1)
    #expect(record.hearsYouAt == at(5))
  }

  @Test
  func `only our own probe's replies set uplink and hears you`() throws {
    var table = NeighbourTable()
    table.noteProbe(tag: 1, at: at(0))
    let key = NeighbourIdentity.fullKey(Self.repeaterKey)
    table.ingest(reply(key, tag: 2, packet: "R2"), at: at(1))
    var record = try #require(table[key])
    #expect(record.sources[.replyToOthers]?.count == 1)
    #expect(record.uplinkSNR == nil)
    #expect(record.hearsYouAt == nil)

    table.ingest(reply(key, tag: 1, uplink: -2.25, packet: "R1"), at: at(2))
    record = try #require(table[key])
    #expect(record.sources[.replyToUs]?.count == 1)
    #expect(record.uplinkSNR == -2.25)
    #expect(record.hearsYou(now: at(3)))
  }

  @Test
  func `weak origin evidence strengthens a row but never creates one`() {
    var table = NeighbourTable()
    let origin = NeighbourEvidence(identity: .hash(Data([0x3A])), source: .weakOrigin, snr: 3, rssi: -99, packetHash: "W1")
    #expect(table.ingest(origin, at: at(0)) == .ignored)
    #expect(table.count == 0)

    table.ingest(relay([0x3A], packet: "P1"), at: at(1))
    let again = NeighbourEvidence(identity: .hash(Data([0x3A])), source: .weakOrigin, snr: 3, rssi: -99, packetHash: "W2")
    #expect(table.ingest(again, at: at(2)) == .recorded(.hash(Data([0x3A]))))
    #expect(table[.hash(Data([0x3A]))]?.sources[.origin]?.count == 1)
  }

  // MARK: - Freshness

  @Test
  func `freshness changes at 10 minutes, 2 hours and 24 hours`() {
    let heard = at(0)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(600)) == .live)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(601)) == .recent)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(7200)) == .recent)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(7201)) == .older)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(86400)) == .older)
    #expect(NeighbourFreshness(lastHeard: heard, now: at(86401)) == .stale)
  }

  // MARK: - Prune

  @Test
  func `prune drops week-old rows and single prefix sightings after 2 hours`() {
    var table = NeighbourTable()
    table.ingest(relay([0x01], packet: "A"), at: at(0))                      // single sighting
    table.ingest(relay([0x02], packet: "B1"), at: at(0))
    table.ingest(relay([0x02], packet: "B2"), at: at(10))                    // two sightings
    table.ingest(advert(Self.repeaterKey), at: at(0))                        // single, but a full key
    table.ingest(relay([0x03], packet: "C1"), at: at(-8 * 86400))
    table.ingest(relay([0x03], packet: "C2"), at: at(-7 * 86400 - 1))        // a week old
    _ = table.takeChanges()

    table.prune(now: at(7200))
    #expect(table[.hash(Data([0x01]))] != nil)

    table.prune(now: at(7201))
    #expect(table[.hash(Data([0x01]))] == nil)
    #expect(table[.hash(Data([0x02]))] != nil)
    #expect(table[.fullKey(Self.repeaterKey)] != nil)
    #expect(table[.hash(Data([0x03]))] == nil)
    #expect(Set(table.takeChanges().removed) == [.hash(Data([0x01])), .hash(Data([0x03]))])
  }

  @Test
  func `prune keeps the 512 most recently heard rows`() {
    var table = NeighbourTable()
    for i in 0..<600 {
      let key = Data([UInt8(i >> 8), UInt8(i & 0xFF)] + [UInt8](repeating: 0, count: 30))
      table.ingest(advert(key, packet: "A\(i)"), at: at(TimeInterval(i)))
    }
    table.prune(now: at(600))
    #expect(table.count == NeighbourTable.maximumRows)
    let oldest = table.records.values.map(\.lastHeard).min()
    #expect(oldest == at(88))
  }

  // MARK: - Merge

  @Test
  func `a prefix row merges into the key row with counts summed`() throws {
    var table = NeighbourTable()
    let prefix = NeighbourIdentity.keyPrefix(Self.repeaterKey.prefix(8))
    table.ingest(reply(prefix, tag: 7, packet: "R1"), at: at(0))
    table.ingest(reply(prefix, tag: 8, packet: "R2"), at: at(10))
    table.ingest(relay([0x3A, 0x7F, 0x21], packet: "P1", snr: 9), at: at(20))
    _ = table.takeChanges()

    table.ingest(advert(Self.repeaterKey), at: at(30))
    #expect(table[prefix] == nil)
    var record = try #require(table[.fullKey(Self.repeaterKey)])
    #expect(record.heardCount == 3)
    #expect(record.sources[.replyToOthers]?.count == 2)
    #expect(record.firstHeard == at(0))
    #expect(record.lastHeard == at(30))
    #expect(record.name == "Hilltop")

    // A later prefix-only reply joins the key row directly
    table.ingest(reply(prefix, tag: 9, packet: "R3"), at: at(40))
    #expect(table[prefix] == nil)
    #expect(table[.fullKey(Self.repeaterKey)]?.heardCount == 4)

    // A path hash is folded only when asked
    let hashRow = NeighbourIdentity.hash(Data([0x3A, 0x7F, 0x21]))
    #expect(table[hashRow] != nil)
    table.merge(hashRow, into: Self.repeaterKey)
    record = try #require(table[.fullKey(Self.repeaterKey)])
    #expect(record.heardCount == 5)
    #expect(record.bestSNR == 9)
    #expect(record.sources[.relay]?.count == 1)

    let changes = table.takeChanges()
    #expect(Set(changes.removed) == [prefix, hashRow])
    #expect(changes.upserted.map(\.identity) == [.fullKey(Self.repeaterKey)])
  }

  // MARK: - Stored entries

  @Test
  func `a stored RX log entry gives the same packet fields as the live frame`() throws {
    let raw = Data([0x01 | PayloadType.groupText.rawValue << 2, 0x02, 0x11, 0x3A, 0xDE, 0xAD])
    let parsed = try #require(RxLogParser.parse(snr: 5.25, rssi: -97, payload: raw))
    let entry = RxLogEntryDTO(radioID: UUID(), from: parsed)
    #expect(RxPacketFields(entry) == RxPacketFields(parsed))
    #expect(NeighbourEvidence.extract(RxPacketFields(entry), selfHash: nil).first?.identity == .hash(Data([0x3A])))
  }
}
