import CairnServices
import CoreLocation
import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("NeighbourDirectory")
@MainActor
struct NeighbourDirectoryTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let radioID = UUID()
  /// Where the radio is: Alpha is about 1 km away, Bravo about 20 km.
  private let radio = CLLocationCoordinate2D(latitude: 45.0, longitude: -122.0)

  private static let alphaKey = Data(repeating: 0xA1, count: 32)
  private static let bravoKey = Data(repeating: 0xB2, count: 32)
  private static let sensorKey = Data(repeating: 0x5E, count: 32)
  private static let companionKey = Data(repeating: 0xC0, count: 32)
  private static let olderKey = Data(repeating: 0x0D, count: 32)
  private static let expiredKey = Data(repeating: 0xE7, count: 32)
  /// No known key starts with it, so it stays an unidentified relay.
  private static let unknownHash = Data([0xEE])

  /// The channel the radio is on, and the one it is retuned to.
  private static let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
  private static let otherChannel = RadioChannelConfig(frequencyKHz: 927_875, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)

  // MARK: - Fixtures

  private func stats(count: Int = 1, first: TimeInterval, last: TimeInterval) -> NeighbourSourceStats {
    NeighbourSourceStats(count: count, firstHeard: now.addingTimeInterval(first), lastHeard: now.addingTimeInterval(last))
  }

  private func record(
    _ identity: NeighbourIdentity,
    heard: TimeInterval,
    snr: Double?,
    sources: [NeighbourSourceKind: NeighbourSourceStats],
    type: UInt8? = nil,
    name: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil
  ) -> NeighbourRecord {
    NeighbourRecord(
      identity: identity,
      firstHeard: now.addingTimeInterval(heard - 600),
      lastHeard: now.addingTimeInterval(heard),
      heardCount: sources.values.reduce(0) { $0 + $1.count },
      lastSNR: snr,
      bestSNR: snr,
      snrEWMA: snr,
      sources: sources,
      nodeTypeRaw: type,
      name: name,
      latitude: latitude,
      longitude: longitude
    )
  }

  private var records: [NeighbourRecord] {
    [
      record(
        .fullKey(Self.alphaKey), heard: -60, snr: 5,
        sources: [.advert: stats(first: -60, last: -60), .relay: stats(count: 3, first: -300, last: -90)],
        type: ContactType.repeater.rawValue, name: "Alpha", latitude: 45.009, longitude: -122.0
      ),
      record(
        .fullKey(Self.bravoKey), heard: -120, snr: 9,
        sources: [.replyToOthers: stats(first: -120, last: -120)],
        type: ContactType.room.rawValue, name: "bravo", latitude: 45.18, longitude: -122.0
      ),
      record(
        .hash(Self.unknownHash), heard: -30, snr: 2,
        sources: [.relay: stats(count: 2, first: -40, last: -30)]
      ),
      record(
        .fullKey(Self.sensorKey), heard: -45, snr: 7,
        sources: [.advert: stats(first: -45, last: -45)],
        type: NeighbourDirectory.sensorType, name: "Soil"
      ),
      record(
        .fullKey(Self.companionKey), heard: -20, snr: 11,
        sources: [.advert: stats(first: -20, last: -20)],
        type: ContactType.chat.rawValue, name: "Phone"
      ),
      record(
        .fullKey(Self.olderKey), heard: -3 * 3600, snr: 4,
        sources: [.advert: stats(first: -3 * 3600, last: -3 * 3600)],
        type: ContactType.repeater.rawValue, name: "Older"
      ),
      record(
        .fullKey(Self.expiredKey), heard: -30 * 3600, snr: 12,
        sources: [.advert: stats(first: -30 * 3600, last: -30 * 3600)],
        type: ContactType.repeater.rawValue, name: "Expired"
      ),
    ]
  }

  private func snapshot(
    _ records: [NeighbourRecord],
    radioID: UUID? = nil,
    at date: Date? = nil,
    isWarm: Bool = true,
    channel: RadioChannelConfig? = nil
  ) -> NeighbourSnapshot {
    let date = date ?? now
    let observed = ledger(channel, radioID: radioID ?? self.radioID, at: date)
    return NeighbourSnapshot(
      radioID: radioID ?? self.radioID,
      takenAt: date,
      neighbours: NeighbourResolver.resolveAll(NeighbourTable(records: records), index: PacketNodeIndex(ledger: observed), now: date),
      isWarm: isWarm,
      ledger: observed
    )
  }

  /// What the radio observed on `channel`: nothing yet, but the channel is known. Cold with no
  /// channel, as while the radio hasn't reported one or a retune waits for it.
  private func ledger(_ channel: RadioChannelConfig?, radioID: UUID, at date: Date, version: Int = 1) -> LedgerSnapshot {
    guard let channel else { return .empty }
    return LedgerSnapshot(radioID: radioID, channelKey: channel.key, channel: channel, selfKey: nil, takenAt: date, version: version, nodes: [])
  }

  private func directory() -> NeighbourDirectory {
    NeighbourDirectory(now: { [now] in now })
  }

  private func names(_ neighbours: [ResolvedNeighbour]) -> [String] {
    neighbours.map { $0.displayName ?? $0.record.identity.bytes.map { String(format: "%02X", $0) }.joined() }
  }

  /// A stand-in for one connection's NeighbourService: its identity and its update stream.
  private final class FakeSource {
    let stream: AsyncStream<NeighbourSnapshot>
    let continuation: AsyncStream<NeighbourSnapshot>.Continuation

    init() {
      let made = AsyncStream.makeStream(of: NeighbourSnapshot.self)
      stream = made.stream
      continuation = made.continuation
    }
  }

  /// The snapshots the directory forwarded to `onSnapshot`.
  @MainActor
  private final class ForwardLog {
    var snapshots: [NeighbourSnapshot] = []
  }

  private func bind(_ directory: NeighbourDirectory, to source: FakeSource, radioID: UUID? = nil) {
    let stream = source.stream
    directory.bind(sourceID: ObjectIdentifier(source), radioID: radioID ?? self.radioID) { stream }
  }

  // MARK: - Lists

  @Test
  func `repeaters are repeater and room nodes plus unidentified relays, sorted by signal`() {
    let directory = directory()
    directory.apply(snapshot(records))
    #expect(names(NeighbourDirectory.sorted(directory.neighbours(.repeaters), by: .snr)) == ["bravo", "Alpha", "EE"])
  }

  @Test
  func `repeaters sorted by name put unnamed relays last`() {
    let directory = directory()
    directory.apply(snapshot(records))
    #expect(names(NeighbourDirectory.sorted(directory.neighbours(.repeaters), by: .name)) == ["Alpha", "bravo", "EE"])
  }

  @Test
  func `repeaters sorted by distance from the radio put rows without a position last`() {
    let directory = directory()
    directory.apply(snapshot(records))
    let sorted = NeighbourDirectory.sorted(directory.neighbours(.repeaters), by: .distance, from: radio)
    #expect(names(sorted) == ["Alpha", "bravo", "EE"])
  }

  @Test
  func `distance without a radio position falls back to the most recently heard`() {
    let directory = directory()
    directory.apply(snapshot(records))
    let sorted = NeighbourDirectory.sorted(directory.neighbours(.repeaters), by: .distance, from: nil)
    #expect(names(sorted) == ["EE", "Alpha", "bravo"])
  }

  @Test(arguments: NodeDiscoverySortOrder.allCases)
  func `sensors are only nodes that said they are sensors`(order: NodeDiscoverySortOrder) {
    let directory = directory()
    directory.apply(snapshot(records))
    #expect(names(NeighbourDirectory.sorted(directory.neighbours(.sensors), by: order, from: radio)) == ["Soil"])
  }

  @Test
  func `older rows are listed only when asked, expired ones never`() {
    let directory = directory()
    directory.apply(snapshot(records))
    let older = names(directory.neighbours(.repeaters, includeOlder: true))
    #expect(older.contains("Older"))
    #expect(!older.contains("Expired"))
    #expect(!names(directory.neighbours(.repeaters)).contains("Older"))
  }

  @Test
  func `a node is looked up by its key within the last 24 hours, whatever its kind`() {
    let directory = directory()
    directory.apply(snapshot(records))
    #expect(directory.neighbour(publicKey: Self.alphaKey)?.displayName == "Alpha")
    #expect(directory.neighbour(publicKey: Self.companionKey)?.displayName == "Phone")
    #expect(directory.neighbour(publicKey: Self.olderKey)?.displayName == "Older")
    #expect(directory.neighbour(publicKey: Self.expiredKey) == nil)
    // A relay hash names no single node, so no key finds it.
    #expect(directory.neighbour(publicKey: Data(repeating: Self.unknownHash[0], count: 32)) == nil)
  }

  // MARK: - Scan list

  /// When the scan whose list is cut started: five minutes ago.
  private var scanStart: Date { now.addingTimeInterval(-300) }

  /// Seconds relative to ``scanStart``, as a fixture offset from `now`.
  private func atScan(_ seconds: TimeInterval) -> TimeInterval { seconds - 300 }

  private func repeater(_ byte: UInt8, name: String, sources: [NeighbourSourceKind: NeighbourSourceStats], heard: TimeInterval? = nil) -> NeighbourRecord {
    let last = heard ?? sources.values.map { $0.lastHeard.timeIntervalSince(now) }.max() ?? 0
    return record(.fullKey(Data(repeating: byte, count: 32)), heard: last, snr: 5, sources: sources, type: ContactType.repeater.rawValue, name: name)
  }

  private func resolved(_ records: [NeighbourRecord]) -> [ResolvedNeighbour] {
    NeighbourResolver.resolveAll(NeighbourTable(records: records), index: .empty, now: now)
  }

  @Test
  func `a scan lists what was heard from its start on, and only with Show Older what came before`() {
    let rows = resolved([
      repeater(0x01, name: "Answered", sources: [.replyToUs: stats(first: atScan(5), last: atScan(5))]),
      repeater(0x02, name: "AtStart", sources: [.advert: stats(first: atScan(0), last: atScan(0))]),
      repeater(0x03, name: "JustBefore", sources: [.advert: stats(first: atScan(-1), last: atScan(-1))]),
      repeater(0x04, name: "HoursAgo", sources: [.advert: stats(first: -3 * 3600, last: -3 * 3600)]),
      repeater(0x05, name: "Expired", sources: [.advert: stats(first: -30 * 3600, last: -30 * 3600)]),
      repeater(0x06, name: "Relaying", sources: [.relay: stats(count: 4, first: atScan(-900), last: atScan(40))]),
    ])
    let list = NeighbourDirectory.scanList(rows, filter: .repeaters, since: scanStart, includeEarlier: false, now: now)
    #expect(Set(names(list.current)) == ["Answered", "AtStart", "Relaying"])
    #expect(list.earlier.isEmpty, "nothing heard before the scan without Show Older, however recent")

    let withOlder = NeighbourDirectory.scanList(rows, filter: .repeaters, since: scanStart, includeEarlier: true, now: now)
    #expect(withOlder.current == list.current)
    #expect(Set(names(withOlder.earlier)) == ["JustBefore", "HoursAgo"], "never the expired")
    #expect(names(withOlder.current) == names(withOlder.current.sorted { $0.record.lastHeard > $1.record.lastHeard }))
  }

  @Test
  func `before the first scan nothing is current, and Show Older lists the last 24 hours`() {
    let directory = directory()
    directory.apply(snapshot(records))
    let none = directory.scanList(.repeaters, since: nil)
    #expect(none.current.isEmpty)
    #expect(none.earlier.isEmpty)
    let older = directory.scanList(.repeaters, since: nil, includeEarlier: true)
    #expect(older.current.isEmpty)
    #expect(Set(names(older.earlier)) == Set(names(directory.neighbours(.repeaters, includeOlder: true))))
    #expect(names(older.earlier).contains("Older"))
    #expect(!names(older.earlier).contains("Expired"))
  }

  @Test
  func `a row refreshed only by relaying during the scan is current, with only that evidence`() throws {
    let row = repeater(0x07, name: "Ridge", sources: [
      .advert: stats(first: -3 * 3600, last: -3 * 3600),
      .replyToUs: stats(first: -2 * 3600, last: -2 * 3600),
      .relay: stats(count: 2, first: atScan(10), last: atScan(20)),
    ])
    let list = NeighbourDirectory.scanList(resolved([row]), filter: .repeaters, since: scanStart, includeEarlier: true, now: now)
    let current = try #require(list.current.first)
    #expect(list.earlier.isEmpty)
    #expect(current.record.sourceKinds(heardSince: scanStart) == [.relay], "an earlier scan's answer isn't this one's")
    #expect(current.record.lastReceivedAt == now.addingTimeInterval(atScan(20)))
  }

  @Test
  func `an older row merged into a newer one never makes it current, and a newer one always does`() {
    let key = Data(repeating: 0x08, count: 32)
    let keyRow = record(.fullKey(key), heard: -2 * 3600, snr: 5, sources: [.advert: stats(first: -2 * 3600, last: -2 * 3600)],
                        type: ContactType.repeater.rawValue, name: "Summit")
    let oldHash = record(.hash(Data([0x08])), heard: -3600, snr: 3, sources: [.relay: stats(count: 3, first: -4000, last: -3600)])
    let newHash = record(.hash(Data([0x08])), heard: atScan(30), snr: 3, sources: [.relay: stats(count: 2, first: atScan(20), last: atScan(30))])
    let entry = NeighbourKeyEntry(publicKey: key, nodeTypeRaw: ContactType.repeater.rawValue, name: "Summit")
    // As the resolver merges the rows that resolve to one node: the key row leads
    let before = ResolvedNeighbour(record: keyRow.merged(with: oldHash), resolution: .resolved(entry), identities: [keyRow.identity, oldHash.identity])
    let during = ResolvedNeighbour(record: keyRow.merged(with: newHash), resolution: .resolved(entry), identities: [keyRow.identity, newHash.identity])

    let quiet = NeighbourDirectory.scanList([before], filter: .repeaters, since: scanStart, includeEarlier: true, now: now)
    #expect(quiet.current.isEmpty)
    #expect(quiet.earlier.count == 1)
    let heard = NeighbourDirectory.scanList([during], filter: .repeaters, since: scanStart, includeEarlier: true, now: now)
    #expect(heard.current.count == 1)
    #expect(heard.current.first?.record.sourceKinds(heardSince: scanStart) == [.relay])
  }

  @Test
  func `a time moved by anything but a reception doesn't make a row current`() {
    // A hears-you proof stamps the row without counting a reception: on a row heard before the
    // scan, and on one whose frame hasn't arrived yet
    var proven = repeater(0x09, name: "Proven", sources: [.advert: stats(first: -3600, last: -3600)])
    proven.lastHeard = now.addingTimeInterval(atScan(30))
    let pending = record(.hash(Data([0x4F])), heard: atScan(40), snr: nil, sources: [:])
    let list = NeighbourDirectory.scanList(resolved([proven, pending]), filter: .repeaters, since: scanStart, includeEarlier: true, now: now)
    #expect(list.current.isEmpty)
    #expect(names(list.earlier) == ["Proven"], "the pending row waits for its frame")
  }

  @Test
  func `a scan's list keeps to the kind listed`() {
    let rows = resolved([
      repeater(0x0A, name: "Repeater", sources: [.relay: stats(count: 2, first: atScan(1), last: atScan(9))]),
      record(.fullKey(Self.sensorKey), heard: atScan(5), snr: 4, sources: [.replyToOthers: stats(first: atScan(5), last: atScan(5))],
             type: NeighbourDirectory.sensorType, name: "Soil"),
      record(.fullKey(Self.companionKey), heard: atScan(6), snr: 4, sources: [.advert: stats(first: atScan(6), last: atScan(6))],
             type: ContactType.chat.rawValue, name: "Phone"),
    ])
    #expect(names(NeighbourDirectory.scanList(rows, filter: .repeaters, since: scanStart, includeEarlier: true, now: now).current) == ["Repeater"])
    #expect(names(NeighbourDirectory.scanList(rows, filter: .sensors, since: scanStart, includeEarlier: true, now: now).current) == ["Soil"])
  }

  @Test
  func `nearby now counts confirmed neighbours heard in the last ten minutes`() {
    let directory = directory()
    #expect(directory.nearbyNowCount == nil)
    directory.apply(snapshot(records))
    // Alpha, bravo, the twice-heard relay, Soil and Phone; not Older or Expired
    #expect(directory.nearbyNowCount == 5)
  }

  @Test
  func `region fallback keys are confirmed repeaters with full keys heard nearby now`() {
    let directory = directory()
    directory.apply(snapshot(records))
    // Older was heard hours ago: likely out of range, so it isn't asked
    #expect(directory.nearbyRepeaterKeys() == [Self.alphaKey, Self.bravoKey])
  }

  @Test
  func `region fallback uses the recent band only when nothing was heard in the live one`() {
    let directory = directory()
    directory.apply(snapshot(records))
    // 30 minutes on, Alpha and Bravo are recent, not live; Older is past 2 hours
    #expect(directory.nearbyRepeaterKeys(now: now.addingTimeInterval(30 * 60)) == [Self.alphaKey, Self.bravoKey])
    // 3 hours on, nothing is live or recent
    #expect(directory.nearbyRepeaterKeys(now: now.addingTimeInterval(3 * 60 * 60)).isEmpty)
  }

  // MARK: - Channels

  @Test
  func `the ledger is the shown snapshot's, cold without one`() {
    let directory = directory()
    #expect(directory.ledger.isCold)
    #expect(directory.ledgerVersion == 0)
    directory.apply(snapshot(records, channel: Self.channel))
    #expect(directory.ledger.channelKey == Self.channel.key)
    #expect(directory.ledgerVersion == 1)
  }

  @Test
  func `after a retune the snapshot is empty until the new channel's rows are heard`() {
    let directory = directory()
    directory.apply(snapshot(records, channel: Self.channel))
    #expect(directory.nearbyNowCount == 5)

    // The radio was retuned: the service waits for the radio to report its channel
    directory.apply(snapshot([], at: now.addingTimeInterval(5), isWarm: false))
    #expect(directory.snapshot?.neighbours.isEmpty == true)
    #expect(directory.ledger.isCold)
    #expect(directory.nearbyNowCount == 0)
    #expect(directory.neighbours(.repeaters).isEmpty)
    #expect(directory.nearbyRepeaterKeys().isEmpty)

    // The new channel: only what was heard on it counts
    directory.apply(snapshot(Array(records.prefix(1)), at: now.addingTimeInterval(10), channel: Self.otherChannel))
    #expect(directory.ledger.channelKey == Self.otherChannel.key)
    #expect(directory.nearbyNowCount == 1)
  }

  @Test
  func `nearby now counts only the current channel's rows after a reconnect on another channel`() async throws {
    let directory = directory()
    let forwarded = ForwardLog()
    directory.onSnapshot = { forwarded.snapshots.append($0) }
    let oldSource = FakeSource()
    bind(directory, to: oldSource)
    let old = snapshot(records, channel: Self.channel)
    oldSource.continuation.yield(old)
    try await waitUntil { directory.snapshot == old }

    let newSource = FakeSource()
    bind(directory, to: newSource)
    #expect(directory.isStale)

    // Cold on the same channel, or not yet told the channel: the old rows stand in
    let sameChannel = snapshot([], at: now.addingTimeInterval(3), isWarm: false, channel: Self.channel)
    let unknownChannel = snapshot([], at: now.addingTimeInterval(4), isWarm: false)
    newSource.continuation.yield(sameChannel)
    newSource.continuation.yield(unknownChannel)
    try await waitUntil { forwarded.snapshots.contains(unknownChannel) }
    #expect(directory.snapshot == old)
    #expect(directory.isStale)

    // The radio is on another channel now: the old channel's rows go, though the service is cold
    let retuned = snapshot([], at: now.addingTimeInterval(5), isWarm: false, channel: Self.otherChannel)
    newSource.continuation.yield(retuned)
    try await waitUntil { directory.snapshot == retuned }
    #expect(directory.nearbyNowCount == 0)
    #expect(!directory.isStale)
  }

  // MARK: - Binding

  @Test
  func `a disconnect keeps the last snapshot, stale, and it ages`() async throws {
    let directory = directory()
    let source = FakeSource()
    bind(directory, to: source)
    let first = snapshot(records)
    source.continuation.yield(first)
    try await waitUntil { directory.snapshot == first }
    #expect(!directory.isStale)

    directory.markDisconnected()
    #expect(directory.isStale)
    #expect(directory.snapshot == first)
    #expect(directory.updatedAt == now)
    #expect(directory.nearbyNowCount(now: now.addingTimeInterval(11 * 60)) == 0)
  }

  @Test
  func `a rebuilt connection keeps the old snapshot until the new service is warm`() async throws {
    let directory = directory()
    let forwarded = ForwardLog()
    directory.onSnapshot = { forwarded.snapshots.append($0) }
    let oldSource = FakeSource()
    bind(directory, to: oldSource)
    let old = snapshot(records)
    oldSource.continuation.yield(old)
    try await waitUntil { directory.snapshot == old }

    let newSource = FakeSource()
    bind(directory, to: newSource)
    #expect(directory.isStale)
    #expect(directory.snapshot == old)

    // Cold: the new service hasn't read its stored rows back yet
    let cold = snapshot(Array(records.prefix(1)), at: now.addingTimeInterval(5), isWarm: false)
    newSource.continuation.yield(cold)
    try await waitUntil { forwarded.snapshots.contains(cold) }
    #expect(directory.snapshot == old)
    #expect(directory.isStale)

    // The old service's late update is no longer followed
    oldSource.continuation.yield(snapshot([], at: now.addingTimeInterval(6)))

    let warm = snapshot(records, at: now.addingTimeInterval(10))
    newSource.continuation.yield(warm)
    try await waitUntil { directory.snapshot == warm }
    #expect(!directory.isStale)
    #expect(!forwarded.snapshots.contains { $0.takenAt == now.addingTimeInterval(6) })
  }

  @Test
  func `binding the same source again changes nothing`() async throws {
    let directory = directory()
    let source = FakeSource()
    bind(directory, to: source)
    let first = snapshot(records)
    source.continuation.yield(first)
    try await waitUntil { directory.snapshot == first }

    bind(directory, to: source)
    #expect(!directory.isStale)
    #expect(directory.snapshot == first)
  }

  @Test
  func `another radio's snapshot is dropped at once and never shown`() async throws {
    let directory = directory()
    let source = FakeSource()
    bind(directory, to: source)
    source.continuation.yield(snapshot(records))
    try await waitUntil { directory.snapshot != nil }

    let otherRadio = UUID()
    let otherSource = FakeSource()
    bind(directory, to: otherSource, radioID: otherRadio)
    #expect(directory.snapshot == nil)
    #expect(!directory.isStale)

    // A straggler for the first radio is ignored
    directory.apply(snapshot(records))
    #expect(directory.snapshot == nil)

    let other = snapshot(Array(records.prefix(2)), radioID: otherRadio)
    otherSource.continuation.yield(other)
    try await waitUntil { directory.snapshot == other }
  }
}
