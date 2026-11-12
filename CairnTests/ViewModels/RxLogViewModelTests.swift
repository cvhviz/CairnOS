import Foundation
@testable import Cairn
@testable import CairnServices
@testable import MeshCore
import Testing

@MainActor
struct RxLogViewModelTests {
  // MARK: - RxLogEntryDTO Computed Properties

  @Test
  func `traceTargetHashes extracts 1-byte hashes when path_sz=0`() {
    // flags byte: path_sz=0 → hashSize = 1<<0 = 1
    var payload = Data(repeating: 0, count: 9) // [tag:4][auth:4][flags:1]
    payload[8] = 0x00 // path_sz = 0
    payload.append(contentsOf: [0xAA, 0xBB, 0xCC])
    let dto = makeDTO(payloadType: .trace, packetPayload: payload)

    let hashes = dto.traceTargetHashes
    #expect(hashes?.count == 3)
    #expect(hashes?[0] == Data([0xAA]))
    #expect(hashes?[1] == Data([0xBB]))
    #expect(hashes?[2] == Data([0xCC]))
  }

  @Test
  func `traceTargetHashes extracts 2-byte hashes when path_sz=1`() {
    // flags byte: path_sz=1 → hashSize = 1<<1 = 2
    var payload = Data(repeating: 0, count: 9)
    payload[8] = 0x01
    payload.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])
    let dto = makeDTO(payloadType: .trace, packetPayload: payload)

    let hashes = dto.traceTargetHashes
    #expect(hashes?.count == 2)
    #expect(hashes?[0] == Data([0xAA, 0xBB]))
    #expect(hashes?[1] == Data([0xCC, 0xDD]))
  }

  @Test
  func `traceTargetHashes returns nil for non-TRACE payload type`() {
    var payload = Data(repeating: 0, count: 12)
    payload[8] = 0x00
    let dto = makeDTO(payloadType: .textMessage, packetPayload: payload)
    #expect(dto.traceTargetHashes == nil)
  }

  @Test
  func `traceTargetHashes returns nil when payload is too short`() {
    let payload = Data(repeating: 0, count: 8) // needs > 9
    let dto = makeDTO(payloadType: .trace, packetPayload: payload)
    #expect(dto.traceTargetHashes == nil)
  }

  @Test
  func `traceTargetHashes returns nil when hash bytes don't divide evenly`() {
    // path_sz=1 → hashSize=2, but 3 remaining bytes don't divide evenly
    var payload = Data(repeating: 0, count: 9)
    payload[8] = 0x01
    payload.append(contentsOf: [0xAA, 0xBB, 0xCC])
    let dto = makeDTO(payloadType: .trace, packetPayload: payload)
    #expect(dto.traceTargetHashes == nil)
  }

  @Test
  func `senderPrefix extracts correct bytes for hashSize=1`() {
    // pathLength encodes hashSize=1: mode=0, hops=1 → 0x01
    let payload = Data([0xDD, 0xAA, 0xFF, 0xFF]) // [dest:1][src:1][rest]
    let dto = makeDTO(routeType: .direct, payloadType: .textMessage, pathLength: 0x01, packetPayload: payload)

    #expect(dto.senderPrefix == Data([0xAA]))
    #expect(dto.recipientPrefix == Data([0xDD]))
  }

  @Test
  func `senderPrefix uses fixed 1-byte payload hashes when path hashSize=2`() {
    // pathLength encodes hashSize=2: mode=1 → (1<<6)|hops = 0x41
    // DM payload hashes remain 1 byte even when routed path hashes are 2 bytes.
    let payload = Data([0xDD, 0xAA, 0xFF, 0xFF])
    let dto = makeDTO(routeType: .direct, payloadType: .textMessage, pathLength: 0x41, packetPayload: payload)

    #expect(dto.senderPrefix == Data([0xAA]))
    #expect(dto.recipientPrefix == Data([0xDD]))
  }

  @Test
  func `senderPrefix uses fixed 1-byte payload hashes when path hashSize=3`() {
    // pathLength encodes hashSize=3: mode=2 → (2<<6)|hops = 0x81
    // DM payload hashes remain 1 byte even when routed path hashes are 3 bytes.
    let payload = Data([0xDD, 0xAA, 0xFF, 0xFF])
    let dto = makeDTO(routeType: .direct, payloadType: .textMessage, pathLength: 0x81, packetPayload: payload)

    #expect(dto.senderPrefix == Data([0xAA]))
    #expect(dto.recipientPrefix == Data([0xDD]))
  }

  @Test
  func `senderPrefix is extracted for flood-routed DMs`() {
    let payload = Data([0xDD, 0xAA, 0xFF, 0xFF])
    let dto = makeDTO(routeType: .flood, payloadType: .textMessage, pathLength: 0x01, packetPayload: payload)
    #expect(dto.senderPrefix == Data([0xAA]))
    #expect(dto.recipientPrefix == Data([0xDD]))
  }

  @Test
  func `senderPrefix returns nil for non-text payload`() {
    let payload = Data([0xDD, 0xAA, 0xFF, 0xFF])
    let dto = makeDTO(routeType: .direct, payloadType: .trace, pathLength: 0x01, packetPayload: payload)
    #expect(dto.senderPrefix == nil)
  }

  @Test
  func `pathHashSize decodes TRACE using standard pathLength encoding`() {
    // pathLength=0x41 → mode=1, hashSize=2
    let dto = makeDTO(payloadType: .trace, pathLength: 0x41)
    #expect(dto.pathHashSize == 2)
  }

  @Test
  func `hopCount decodes TRACE using standard pathLength encoding`() {
    // pathLength=0x43 → mode=1, hashSize=2, hopCount=3
    let dto = makeDTO(payloadType: .trace, pathLength: 0x43)
    #expect(dto.hopCount == 3)
  }

  @Test
  func `hopCount uses decodePathLen for non-TRACE`() {
    // pathLength=0x43 → mode=1, hashSize=2, hopCount=3
    let dto = makeDTO(payloadType: .textMessage, pathLength: 0x43)
    #expect(dto.hopCount == 3)
    #expect(dto.pathHashSize == 2)
  }

  // MARK: - Incremental filtering

  @Test
  func `live entries land newest first, filtered and grouped without a rebuild`() {
    let model = RxLogViewModel()
    let first = makeDTO(routeType: .flood, packetPayload: Data([0x01]))
    let direct = makeDTO(routeType: .direct, packetPayload: Data([0x02]))
    let duplicate = makeDTO(routeType: .flood, packetPayload: Data([0x01]))
    model.load([first, direct])
    model.appendEntry(duplicate)

    #expect(model.displayEntries(groupingDuplicates: false).map(\.id) == [duplicate.id, direct.id, first.id])
    // Grouped, the packet is shown by its newest reception.
    #expect(model.displayEntries(groupingDuplicates: true).map(\.id) == [duplicate.id, direct.id])
    #expect(model.groupCounts[first.packetHash] == 2)

    model.setRouteFilter(.floodOnly)
    #expect(model.displayEntries(groupingDuplicates: false).map(\.id) == [duplicate.id, first.id])
    #expect(model.displayEntries(groupingDuplicates: true).map(\.id) == [duplicate.id])

    let liveDirect = makeDTO(routeType: .direct, packetPayload: Data([0x03]))
    model.appendEntry(liveDirect)
    #expect(model.displayEntries(groupingDuplicates: false).map(\.id) == [duplicate.id, first.id])
    #expect(model.entries.count == 4)
  }

  @Test
  func `the oldest entry is pruned from every list past the cap`() {
    let model = RxLogViewModel()
    let entries = (0..<RxLogViewModel.entryCap).map { index in
      makeDTO(packetPayload: Data([UInt8(index % 256), UInt8(index / 256)]))
    }
    model.load(entries)
    let newest = makeDTO(packetPayload: Data([0xFF, 0xFF]))
    model.appendEntry(newest)

    #expect(model.entries.count == RxLogViewModel.entryCap)
    #expect(model.entries.first?.id == entries[1].id)
    #expect(model.filteredEntries.first?.id == entries[1].id)
    #expect(model.dedupedEntries.first?.id == entries[1].id)
    #expect(model.groupCounts[entries[0].packetHash] == nil)
    #expect(model.displayEntries(groupingDuplicates: true).first?.id == newest.id)
  }

  // MARK: - Node index

  typealias World = TrafficClaremontFixtures

  @Test
  func `rows name hops from the shared directory, only nodes heard on the channel`() throws {
    let directory = World.observationDirectory()
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: directory)
    // Mt Baldy then Glendora Room, both heard here, 3-byte hashes.
    let entry = World.entry(
      World.frame(.groupText, pathLength: 0x82, path: [0xB4, 0x5D, 0x01, 0x9E, 0x10, 0x02], payload: World.groupTextPayload),
      firmware: .stock
    )
    model.load([entry])
    #expect(model.packetNodes(for: entry).hops.map(\.displayName) == ["Mt Baldy", "Glendora Room"])
    #expect(model.nodeIndex.channelKey == World.channel.key)
    #expect(model.ledgerNodeCount == World.observedWorld.count)
  }

  @Test
  func `a claimed hop that is this radio's own hash reads as You; the hop it heard never does`() throws {
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: World.observationDirectory())
    // A companion repeating can be an earlier hop of what it hears back
    let claimed = World.entry(
      World.frame(.groupText, pathLength: 0x82, path: [0xAA, 0x01, 0x02] + World.mtBaldyHash, payload: World.groupTextPayload),
      firmware: .stock
    )
    let claimedRow = RxLogRowView(entry: claimed, groupCount: 1, nodeIndex: model.nodeIndex, packet: model.packetNodes(for: claimed))
    #expect(claimedRow.pathDisplayString == "\(L10n.Tools.Tools.RxLog.pathYou) → Mt Baldy")
    // A radio never receives its own transmission: the hop it heard is another node, by hash
    let heard = World.entry(
      World.frame(.groupText, pathLength: 0x81, path: [0xAA, 0x01, 0x02], payload: World.groupTextPayload),
      firmware: .stock
    )
    let heardRow = RxLogRowView(entry: heard, groupCount: 1, nodeIndex: model.nodeIndex, packet: model.packetNodes(for: heard))
    #expect(heardRow.pathDisplayString == "AA0102")
  }

  @Test(arguments: TrafficClaremontFixtures.Firmware.allCases)
  func `a node heard later renames the rows before it, once the directory's version moves`(firmware: TrafficClaremontFixtures.Firmware) throws {
    let without = ClaremontListScenario.observed(without: World.claremontKey)
    let directory = World.observationDirectory(observed: without)
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: directory)
    let relayed = World.viaClaremont(firmware)
    model.load([relayed])
    #expect(model.packetNodes(for: relayed).hops.first?.isNamed == false)

    directory.setLedger(World.ledger(without + World.learned(from: World.c6Advert(firmware))))
    let hop = try #require(model.packetNodes(for: relayed).hops.first)
    #expect(hop.displayName == "Claremont")
    #expect(hop.hasPosition)
  }

  @Test
  func `a row received on another channel resolves against that channel's ledger`() throws {
    let directory = World.observationDirectory()
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: directory)
    let elsewhere = World.entry(
      World.frame(.groupText, pathLength: 0x01, path: [0xC1], payload: World.groupTextPayload),
      firmware: .stock,
      channel: World.otherChannel
    )
    model.load([elsewhere])
    // Not read in yet: its hash isn't named from this channel's Claremont.
    #expect(model.packetNodes(for: elsewhere).hops.first?.isNamed == false)
    let pomonaElsewhere = World.observation(World.pomonaHillKey, name: "Pomona Hill", position: World.pomonaHillPosition, channel: World.otherChannel)
    directory.store(World.ledger([pomonaElsewhere], channel: World.otherChannel), for: World.otherChannel.key)
    #expect(model.packetNodes(for: elsewhere).hops.first?.displayName == "Pomona Hill")

    let row = RxLogRowView(
      entry: elsewhere, groupCount: 1, nodeIndex: model.nodeIndex,
      packet: model.packetNodes(for: elsewhere), currentChannelKey: model.nodeIndex.channelKey
    )
    #expect(row.channelCaption == L10n.Tools.Tools.RxLog.receivedOn(RxLogRowView.channelText(World.otherChannel)))
  }

  @Test
  func `a row stored before channels were recorded shows its hops by hash`() throws {
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: World.observationDirectory())
    let unstamped = World.entry(
      World.frame(.groupText, pathLength: 0x81, path: World.mtBaldyHash, payload: World.groupTextPayload),
      firmware: .stock,
      channel: nil
    )
    model.load([unstamped])
    #expect(model.packetNodes(for: unstamped).hops.map(\.displayName) == [Data(World.mtBaldyHash).uppercaseHexString()])
    #expect(!model.packetNodes(for: unstamped).isChannelRecorded)
  }

  @Test(arguments: TrafficClaremontFixtures.Firmware.allCases)
  func `C11: the map's entries follow the route filter but not the decrypt filter`(firmware: TrafficClaremontFixtures.Firmware) throws {
    let directory = World.observationDirectory(observed: ClaremontListScenario.observed(without: World.claremontKey))
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: directory)
    let advert = World.c5(firmware)
    directory.setLedger(World.ledger(ClaremontListScenario.observed(without: World.claremontKey) + World.learned(from: advert)))
    model.load([advert])

    model.setDecryptFilter(.decrypted)
    #expect(model.filteredEntries.isEmpty)
    #expect(model.mapEntries.map(\.id) == [advert.id])

    // The map on those entries and the shared index lights Claremont.
    let map = TrafficMapModel(sentLog: TrafficSentLog())
    map.use(TrafficDirectory(nodes: model.nodeIndex, device: World.device(firmware)))
    map.ingest(ArraySlice(), now: World.receivedAt)
    map.ingest(model.mapEntries, now: World.receivedAt)
    #expect(map.activeKeys.contains(World.claremontKey))

    let decryptedText = World.c9(firmware)
    model.appendEntry(decryptedText)
    #expect(model.mapEntries.map(\.id) == [advert.id, decryptedText.id])
    #expect(model.filteredEntries.map(\.id) == [decryptedText.id])

    model.setRouteFilter(.directOnly)
    #expect(model.mapEntries.isEmpty)
    #expect(model.filteredEntries.isEmpty)
  }

  // MARK: - Helpers

  private func makeDTO(
    routeType: RouteType = .flood,
    payloadType: PayloadType = .unknown,
    pathLength: UInt8 = 0,
    pathNodes: [UInt8] = [],
    packetPayload: Data = Data()
  ) -> RxLogEntryDTO {
    let parsed = ParsedRxLogData(
      snr: nil,
      rssi: nil,
      rawPayload: Data(),
      routeType: routeType,
      payloadType: payloadType,
      payloadVersion: 0,
      payloadTypeBits: payloadType.rawValue & 0x0F,
      transportCode: nil,
      pathLength: pathLength,
      pathNodes: pathNodes,
      packetPayload: packetPayload
    )
    return RxLogEntryDTO(radioID: UUID(), from: parsed)
  }
}

// MARK: - Row path labels

@MainActor
struct RxLogRowPathLabelTests {
  private func row(route: RouteType, payload: PayloadType, path: [UInt8], packetPayload: Data,
                   nodeIndex: PacketNodeIndex = .empty) -> RxLogRowView {
    let parsed = ParsedRxLogData(
      snr: 5, rssi: -90, rawPayload: Data(), routeType: route, payloadType: payload, payloadVersion: 0,
      payloadTypeBits: payload.rawValue & 0x0F, transportCode: nil, pathLength: UInt8(path.count),
      pathNodes: path, packetPayload: packetPayload, channel: TrafficClaremontFixtures.channel
    )
    return RxLogRowView(
      entry: RxLogEntryDTO(radioID: UUID(), from: parsed),
      groupCount: 1,
      nodeIndex: nodeIndex
    )
  }

  /// tag(4) auth(4) flags(1, one-byte hashes) then the route A3, 7F.
  private let tracePayload = Data(repeating: 0, count: 8) + Data([0x00, 0xA3, 0x7F])

  @Test
  func `a trace with no SNRs yet shows its route, not Direct`() {
    let fresh = row(route: .direct, payload: .trace, path: [], packetPayload: tracePayload)
    #expect(fresh.pathDisplayString == "A3 → 7F")
    #expect(fresh.routeStops.map(\.signal) == [nil, nil])
  }

  @Test
  func `a trace lists the SNR each hop heard it at`() {
    // SNR bytes are quarter-dB: 24 → 6.0 dB, -10 → -2.5 dB.
    let heard = row(route: .direct, payload: .trace, path: [24, UInt8(bitPattern: -10)], packetPayload: tracePayload)
    let readings = [6.0, -2.5].map { $0.formatted(.number.precision(.fractionLength(1))) + " dB" }
    #expect(heard.routeStops.map(\.signal) == readings)
  }

  @Test
  func `a direct packet's path reads as the route ahead`() {
    let direct = row(route: .direct, payload: .textMessage, path: [0xA3, 0x7F], packetPayload: Data([1, 2, 3, 4]))
    #expect(direct.pathDisplayString == L10n.Tools.Tools.RxLog.routeAhead("A3 → 7F"))
    #expect(direct.pathDetailString.hasPrefix(L10n.Tools.Tools.RxLog.routeAhead("").trimmingCharacters(in: .whitespaces)))
    let flood = row(route: .flood, payload: .textMessage, path: [0xA3, 0x7F], packetPayload: Data([1, 2, 3, 4]))
    #expect(flood.pathDisplayString == "A3 → 7F")
  }

  /// The index of nodes this radio heard on the channel (`observed`) and saved contacts that only
  /// label (`saved`).
  private func index(observed: [(key: Data, name: String, type: ContactType)], saved: [ContactDTO] = []) -> PacketNodeIndex {
    TrafficClaremontFixtures.index(
      observed: observed.map { TrafficClaremontFixtures.observation($0.key, name: $0.name, type: $0.type.rawValue) },
      contacts: saved,
      discovered: []
    )
  }

  @Test
  func `hops a node heard on the channel names show by name, the rest by hash`() {
    let hilltop = TrafficClaremontFixtures.key([0xA3, 0x10], fill: 0x01)
    let flood = row(route: .flood, payload: .textMessage, path: [0xA3, 0x7F], packetPayload: Data([1, 2, 3, 4]),
                    nodeIndex: index(observed: [(hilltop, "Hilltop Rpt", .repeater)]))
    #expect(flood.pathDisplayString == "Hilltop Rpt → 7F")
  }

  @Test
  func `a saved contact never heard on the channel names no hop`() {
    let hilltop = TrafficClaremontFixtures.contact(
      TrafficClaremontFixtures.key([0xA3, 0x10], fill: 0x01), name: "Hilltop Rpt", type: ContactType.repeater.rawValue
    )
    let flood = row(route: .flood, payload: .textMessage, path: [0xA3, 0x7F], packetPayload: Data([1, 2, 3, 4]),
                    nodeIndex: index(observed: [], saved: [hilltop]))
    #expect(flood.pathDisplayString == "A3 → 7F")
  }

  @Test
  func `a hop two heard nodes could be shows the likelier, marked as a guess`() {
    let near = TrafficClaremontFixtures.key([0xA3, 0x10], fill: 0x01)
    let other = TrafficClaremontFixtures.key([0xA3, 0x20], fill: 0x02)
    let flood = row(route: .flood, payload: .textMessage, path: [0xA3], packetPayload: Data([1, 2, 3, 4]),
                    nodeIndex: index(observed: [(near, "Hilltop Rpt", .repeater), (other, "Ridge Rpt", .chat)]))
    // A relay ranks before a companion for a hop.
    #expect(flood.pathDisplayString == "Hilltop Rpt?")
  }

  @Test
  func `a verified advert's row names its sender, kind and position`() throws {
    let payload = TrafficClaremontFixtures.advertPayload(
      signer: TrafficClaremontFixtures.claremontSigner, type: ContactType.repeater.rawValue,
      name: "Hilltop Rpt", position: (40.0, -74.0)
    )
    let advert = row(route: .flood, payload: .advert, path: [], packetPayload: Data(payload))
    let sender = try #require(advert.sender)
    #expect(sender.name == "Hilltop Rpt")
    #expect(sender.kind == .repeater)
    #expect(sender.coordinate != nil)
  }

  @Test
  func `a forged advert's key is a claim: never named or placed`() throws {
    let payload = TrafficClaremontFixtures.forgedAdvertPayload(claimedKey: TrafficClaremontFixtures.claremontKey, name: "Hilltop Rpt", position: (40.0, -74.0))
    let advert = row(route: .flood, payload: .advert, path: [], packetPayload: Data(payload))
    #expect(advert.sender?.name != "Hilltop Rpt")
    #expect(advert.sender?.coordinate == nil)
    #expect(advert.packet.sender?.isUnverified == true)
  }

  @Test
  func `a channel message's sender comes from its text`() {
    let row = row(route: .flood, payload: .groupText, path: [], packetPayload: Data([1, 2, 3]))
    #expect(row.sender == nil)   // nothing decoded: no sender to show
  }
}
