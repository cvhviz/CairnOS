import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// One of the "Claremont is on the flood list but not on the Traffic map" scenarios as the RX Log
/// list meets it: what this radio had heard on its channel, what the store holds (labels and
/// hints only), where this radio is, what it sent, and the packets it hears. The packets teach
/// the ledger what they prove (a verified advert's sender), as `NeighbourService` ingests them.
/// The list naming tests and the list-and-map invariant tests both run on these.
struct ClaremontListScenario: Sendable, CustomTestStringConvertible {
  typealias World = TrafficClaremontFixtures
  typealias Firmware = TrafficClaremontFixtures.Firmware

  let name: String
  /// What this radio heard on the channel before the packets.
  var observed: [NodeObservation] = World.observedWorld
  var contacts: [ContactDTO] = World.savedContacts
  var discovered: [DiscoveredNodeDTO] = World.heardNodes
  /// Where this radio is stored; (0, 0) is nowhere.
  var radioAt: (latitude: Double, longitude: Double) = World.radioPosition
  /// Commands the app wrote to the radio before the packets, and how many seconds before.
  var sends: [(command: Data, secondsBefore: TimeInterval)] = []
  /// The packets heard, oldest first; the last is the one each test looks at.
  let entries: @Sendable (Firmware) -> [RxLogEntryDTO]

  var testDescription: String { name }

  /// What this radio heard minus `key`.
  static func observed(without key: Data) -> [NodeObservation] {
    World.observedWorld.filter { $0.identity.bytes != key }
  }

  /// The list as it stands once it has read the log, on the directory the scenario's observations
  /// make, with the scenario's sends recorded in `sentLog` (the map's, in the list-and-map tests).
  @MainActor
  func list(_ firmware: Firmware, sentLog: TrafficSentLog = TrafficSentLog()) -> (model: RxLogViewModel, entries: [RxLogEntryDTO]) {
    sentLog.apply(sends.enumerated().compactMap { index, send in
      OwnTransmission.parse(command: send.command, id: UInt64(index + 1), at: World.receivedAt.addingTimeInterval(-send.secondsBefore))
    }, now: World.receivedAt)
    let heard = entries(firmware)
    let directory = World.observationDirectory(
      observed: observed + heard.flatMap(World.learned),
      contacts: contacts,
      discovered: discovered,
      anchor: radioAt.latitude == 0 && radioAt.longitude == 0 ? nil : radioAt
    )
    let model = RxLogViewModel(sentLog: sentLog, observations: directory)
    model.load(heard)
    return (model, heard)
  }

  /// The Traffic map wired as the Traffic page wires it, on the list's index and `sentLog`, with
  /// the list's packets taken in as they arrive after a first look at an empty log.
  @MainActor
  func map(_ list: RxLogViewModel, _ firmware: Firmware, sentLog: TrafficSentLog) -> TrafficMapModel {
    let map = TrafficMapModel(sentLog: sentLog)
    map.use(TrafficDirectory(
      nodes: list.nodeIndex,
      device: World.device(firmware, position: radioAt),
      contacts: list.observations.contactsByKey,
      discovered: list.observations.discoveredByKey
    ))
    map.ingest(ArraySlice(), now: World.receivedAt)
    map.ingest(list.mapEntries, now: World.receivedAt)
    return map
  }

  /// The names the row's path line gives each hop, in path order: a direct packet's route ahead
  /// without its "Ahead:" wrapper, a trace's targets.
  @MainActor
  static func hopNames(_ row: RxLogRowView, for entry: RxLogEntryDTO) -> [String] {
    var line = row.pathDisplayString
    if !entry.isFlood, entry.payloadType != .trace {
      let wrapper = L10n.Tools.Tools.RxLog.routeAhead("\u{1}").components(separatedBy: "\u{1}")
      if wrapper.count == 2, line.hasPrefix(wrapper[0]), line.hasSuffix(wrapper[1]) {
        line = String(line.dropFirst(wrapper[0].count).dropLast(wrapper[1].count))
      }
    }
    return line.components(separatedBy: " → ")
  }

  /// The row the list draws for `entry`.
  @MainActor
  static func row(for entry: RxLogEntryDTO, in model: RxLogViewModel) -> RxLogRowView {
    RxLogRowView(
      entry: entry,
      groupCount: 1,
      nodeIndex: model.nodeIndex,
      packet: model.packetNodes(for: entry),
      currentChannelKey: model.nodeIndex.channelKey,
      echo: model.echo(for: entry)
    )
  }

  // MARK: - Scenarios

  static let c1 = ClaremontListScenario(
    name: "C1 hop with no position",
    observed: observed(without: World.claremontKey) + [World.observation(World.claremontKey, name: "Claremont")],
    entries: { [World.c1($0)] }
  )
  static let c2 = ClaremontListScenario(name: "C2 beyond an unknown hop", entries: { [World.c2($0)] })
  static let c3 = ClaremontListScenario(name: "C3 one-byte hash, one node heard with it", entries: { [World.c3($0)] })
  static let c3Shared = ClaremontListScenario(
    name: "C3b one-byte hash two heard nodes share",
    observed: World.observedWorld + [World.pomonaHillObserved],
    entries: { [World.c3($0)] }
  )
  static let c3SharedClaremontDirect = ClaremontListScenario(
    name: "C3c shared, Claremont heard directly",
    observed: observed(without: World.claremontKey) + [
      World.observation(World.claremontKey, name: "Claremont", position: World.claremontPosition, hops: 0),
      World.observation(World.pomonaHillKey, name: "Pomona Hill", position: World.pomonaHillPosition, hops: 2),
    ],
    entries: { [World.c3($0)] }
  )
  static let c4 = ClaremontListScenario(
    name: "C4 companion relay",
    observed: observed(without: World.claremontKey) + [
      World.observation(World.claremontKey, name: "Claremont", type: ContactType.chat.rawValue, position: World.claremontPosition),
    ],
    entries: { [World.c4($0)] }
  )
  static let c4Unknown = ClaremontListScenario(
    name: "C4 heard node of no type",
    observed: observed(without: World.claremontKey) + [
      World.observation(World.claremontKey, name: "Claremont", type: 0, position: World.claremontPosition),
    ],
    entries: { [World.c4($0)] }
  )
  static let c5 = ClaremontListScenario(
    name: "C5 advert through an unknown hop",
    observed: observed(without: World.claremontKey),
    contacts: [World.mtBaldy, World.alex()],
    entries: { [World.c5($0)] }
  )
  static let c6 = ClaremontListScenario(
    name: "C6 learned from a live advert",
    observed: observed(without: World.claremontKey),
    contacts: [World.mtBaldy, World.alex()],
    entries: { [World.c6Advert($0), World.viaClaremont($0)] }
  )
  /// Saved as a contact, but never heard on this channel.
  static let c6Unlearned = ClaremontListScenario(
    name: "C6 saved but never heard",
    observed: observed(without: World.claremontKey),
    entries: { [World.viaClaremont($0)] }
  )
  static let c7 = ClaremontListScenario(
    name: "C7 stale radio position",
    radioAt: World.floridaPosition,
    entries: { [World.viaClaremont($0)] }
  )
  static let c8 = ClaremontListScenario(name: "C8 request between other nodes", entries: { [World.c8($0)] })
  static let c8Located = ClaremontListScenario(
    name: "C8b located sender",
    observed: observed(without: World.alexKey) + [
      World.observation(World.alexKey, name: "Alex", type: ContactType.chat.rawValue, position: (34.1000, -117.6900), hops: 1),
    ],
    entries: { [World.c8($0)] }
  )
  static let c9 = ClaremontListScenario(
    name: "C9 channel sender",
    contacts: World.savedContacts + [World.claremontOps],
    entries: { [World.c9($0)] }
  )
  static let c9b = ClaremontListScenario(
    name: "C9b unknown channel sender",
    contacts: World.savedContacts + [World.claremontOps],
    entries: { [World.c9($0, text: "Ghost: hi")] }
  )

  static let trace = ClaremontListScenario(name: "Trace part way", entries: { [World.trace($0)] })
  static let directToBase = ClaremontListScenario(
    name: "Direct to Base, hops ahead",
    entries: { [World.directVia($0, destination: 0xAA)] }
  )
  static let directPassingBy = ClaremontListScenario(
    name: "Direct passing by, hops ahead",
    entries: { [World.directVia($0, destination: 0x9E)] }
  )
  static let discoverReply = ClaremontListScenario(name: "Discover reply, 8-byte key", entries: { [World.discoverReply($0)] })
  static let anonRequest = ClaremontListScenario(
    name: "Anonymous request",
    contacts: World.savedContacts + [World.claremontOps],
    entries: { [World.anonRequest($0)] }
  )
  /// A login carrying the key of a node saved but never heard here: a claim, never named.
  static let anonRequestUnheard = ClaremontListScenario(
    name: "Anonymous request, key never heard",
    observed: observed(without: World.claremontOpsKey),
    contacts: World.savedContacts + [World.claremontOps],
    entries: { [World.anonRequest($0)] }
  )
  /// Our status request to Claremont, then a reply on the byte Pomona Hill shares.
  static let replyToRequest = ClaremontListScenario(
    name: "Reply to our request",
    observed: World.observedWorld + [World.pomonaHillObserved],
    sends: [(PacketBuilder.sendStatusRequest(to: World.claremontKey), 5)],
    entries: { [World.replyToBase($0)] }
  )
  /// Our request to Claremont passed back, from the byte Base shares with Arrow Peak.
  static let ownRequestEcho = ClaremontListScenario(
    name: "Own request echo",
    contacts: World.savedContacts + [World.contact(World.arrowPeakKey, name: "Arrow Peak", type: ContactType.chat.rawValue)],
    sends: [(PacketBuilder.sendStatusRequest(to: World.claremontKey), 5)],
    entries: { [World.ownRequestEcho($0)] }
  )
  static let ownMessagePartway = ClaremontListScenario(
    name: "Own direct message part way",
    sends: [(PacketBuilder.sendMessage(to: World.claremontOpsKey, text: "on my way", timestamp: World.receivedAt), 5)],
    entries: { [World.ownMessagePartway($0)] }
  )
  static let noRadioPosition = ClaremontListScenario(
    name: "No radio position, no phone fix",
    observed: observed(without: World.alexKey) + [
      World.observation(World.alexKey, name: "Alex", type: ContactType.chat.rawValue, position: (34.1000, -117.6900), hops: 1),
    ],
    radioAt: (0, 0),
    entries: { [World.directFromAlex($0), World.viaClaremont($0)] }
  )

  /// Claremont saved as "Claremont", advertising as "WCM-CLR-RPT", then relaying.
  static let nickname = ClaremontListScenario(
    name: "Nickname, located",
    observed: observed(without: World.claremontKey),
    contacts: [World.nicknamedClaremont(), World.mtBaldy, World.alex()],
    entries: { [World.onAirAdvert($0, withPosition: true), World.viaClaremont($0)] }
  )
  static let nicknameOffMap = ClaremontListScenario(
    name: "Nickname, no position",
    observed: observed(without: World.claremontKey),
    contacts: [World.nicknamedClaremont(), World.mtBaldy, World.alex()],
    entries: { [World.onAirAdvert($0, withPosition: false), World.viaClaremont($0)] }
  )

  /// Kona Hill and Hilo Ridge, Hawaii repeaters saved and discovered but never heard here, share
  /// first bytes with local nodes no one has heard (7F) or with Claremont (C1). We polled Kona
  /// Hill; a flood comes through 7F then C1, and a reply to us comes from a 7F node.
  static let hawaiiContacts = ClaremontListScenario(
    name: "Hawaii contacts sharing local bytes",
    contacts: World.savedContacts + TrafficHawaiiTests.hawaiiNodes().contacts,
    discovered: World.heardNodes + TrafficHawaiiTests.hawaiiNodes().discovered,
    sends: [(PacketBuilder.sendStatusRequest(to: TrafficHawaiiTests.konaHillKey), 5)],
    entries: { [TrafficHawaiiTests.flood($0), World.replyToBase($0, source: 0x7F)] }
  )

  static let all: [ClaremontListScenario] = [
    c1, c2, c3, c3Shared, c3SharedClaremontDirect, c4, c4Unknown, c5, c6, c6Unlearned, c7, c8, c8Located, c9, c9b,
    trace, directToBase, directPassingBy, discoverReply, anonRequest, anonRequestUnheard, replyToRequest, ownRequestEcho,
    ownMessagePartway, noRadioPosition, nickname, nicknameOffMap, hawaiiContacts,
  ]
}

/// What the RX Log list says for each Claremont scenario, built from raw stock 0x88 frames (and
/// the same frames as Cairn delivers them): the hops and senders by the names the shared resolver
/// gives against what this radio heard on its channel, which are the names the Traffic map draws
/// under.
@Suite("RX Log list: naming the Claremont scenarios")
@MainActor
struct RxLogClaremontNamingTests {
  typealias Scenario = ClaremontListScenario
  typealias World = TrafficClaremontFixtures
  typealias Firmware = TrafficClaremontFixtures.Firmware

  private func row(_ scenario: Scenario, _ firmware: Firmware) throws -> RxLogRowView {
    let (model, entries) = scenario.list(firmware)
    let entry = try #require(entries.last)
    return Scenario.row(for: entry, in: model)
  }

  private var claremontHex: String {
    Data(World.claremontHash).uppercaseHexString()
  }

  @Test(arguments: Firmware.allCases)
  func `C1: a hop heard without a position is still named`(firmware: Firmware) throws {
    #expect(try row(.c1, firmware).pathDisplayString == "Mt Baldy → Claremont")
  }

  @Test(arguments: Firmware.allCases)
  func `C2: hops either side of an unknown one are named, the unknown in hex`(firmware: Firmware) throws {
    #expect(try row(.c2, firmware).pathDisplayString == "Claremont → 7F7F7F → Mt Baldy")
  }

  @Test(arguments: Firmware.allCases)
  func `C3: a one-byte hash only one heard node has names it`(firmware: Firmware) throws {
    #expect(try row(.c3, firmware).pathDisplayString == "Claremont")
  }

  @Test(arguments: Firmware.allCases)
  func `C3: a one-byte hash two heard nodes share names the likelier, as a guess`(firmware: Firmware) throws {
    // The one heard straight from it ranks first for the hop this radio heard.
    let (model, entries) = Scenario.c3Shared.list(firmware)
    let entry = try #require(entries.last)
    #expect(Scenario.row(for: entry, in: model).pathDisplayString == "Pomona Hill?")
    let hop = try #require(model.packetNodes(for: entry).hops.first)
    #expect(hop.key == World.pomonaHillKey)
    guard case let .ambiguous(_, _, total) = hop.match else {
      Issue.record("expected a guess")
      return
    }
    #expect(total == 2)

    #expect(try row(.c3SharedClaremontDirect, firmware).pathDisplayString == "Claremont?")
  }

  @Test(arguments: Firmware.allCases)
  func `C4: a companion or untyped node heard relaying is named`(firmware: Firmware) throws {
    #expect(try row(.c4, firmware).pathDisplayString == "Claremont")
    #expect(try row(.c4Unknown, firmware).pathDisplayString == "Claremont")
  }

  @Test(arguments: Firmware.allCases)
  func `C5: a verified advert names its sender, whatever hop couldn't be named`(firmware: Firmware) throws {
    let row = try row(.c5, firmware)
    let sender = try #require(row.sender)
    #expect(sender.name == "Claremont")
    #expect(sender.kind == .repeater)
    #expect(sender.coordinate != nil)
    #expect(row.pathDisplayString == "7F7F7F")
  }

  @Test(arguments: Firmware.allCases)
  func `C6: a hop is named once its node's advert has been heard here, and only then`(firmware: Firmware) throws {
    #expect(try row(.c6, firmware).pathDisplayString == "Claremont")
    // Saved as a contact all the same: never heard on this channel, so it shows by its hash.
    #expect(try row(.c6Unlearned, firmware).pathDisplayString == claremontHex)
  }

  @Test(arguments: Firmware.allCases)
  func `C6: a saved contact sharing an unknown hop's prefix is a hint only`(firmware: Firmware) throws {
    let (model, entries) = Scenario.c6Unlearned.list(firmware)
    let entry = try #require(entries.last)
    let hop = try #require(model.packetNodes(for: entry).hops.first)
    #expect(hop.match == .unknown(Data(World.claremontHash)))
    #expect(!hop.isNamed)
    #expect(hop.unobservedHint?.entry.name == "Claremont")
    #expect(hop.unobservedHint?.reason == .notHeard)
  }

  @Test(arguments: Firmware.allCases)
  func `C7: a stale radio position never hides the one node a hash can be`(firmware: Firmware) throws {
    #expect(try row(.c7, firmware).pathDisplayString == "Claremont")
  }

  @Test(arguments: Firmware.allCases)
  func `C8: a request between other nodes names its sender and who it is for`(firmware: Firmware) throws {
    let row = try row(.c8, firmware)
    let sender = try #require(row.sender)
    #expect(sender.name == "Alex")
    #expect(sender.kind == .chat)
    #expect(sender.coordinate == nil)
    #expect(row.pathDisplayString == L10n.Tools.Tools.RxLog.direct)
  }

  @Test(arguments: Firmware.allCases)
  func `C9: a channel message names the sender it typed`(firmware: Firmware) throws {
    let named = try row(.c9, firmware)
    #expect(named.sender?.name == "Claremont Ops")
    #expect(named.pathDisplayString == "Mt Baldy")

    let unknown = try row(.c9b, firmware)
    #expect(unknown.sender?.name == "Ghost")
    #expect(unknown.sender?.kind == .chat)
  }

  @Test(arguments: Firmware.allCases)
  func `an anonymous request's key never heard here is a claim, not a name`(firmware: Firmware) throws {
    let (model, entries) = Scenario.anonRequestUnheard.list(firmware)
    let entry = try #require(entries.last)
    let sender = try #require(model.packetNodes(for: entry).sender)
    #expect(!sender.isNamed)
    #expect(sender.claimedKey == World.claremontOpsKey)
    #expect(Scenario.row(for: entry, in: model).sender?.name != "Claremont Ops")
    #expect(model.nodeIndex.label(forKey: World.claremontOpsKey) == "Claremont Ops")

    #expect(try row(.anonRequest, firmware).sender?.name == "Claremont Ops")
  }

  @Test(arguments: Firmware.allCases)
  func `a saved contact keeps its nickname after it advertises under another name`(firmware: Firmware) throws {
    for scenario in [Scenario.nickname, .nicknameOffMap] {
      let (model, entries) = scenario.list(firmware)
      let advert = try #require(entries.first)
      let relayed = try #require(entries.last)
      #expect(Scenario.row(for: advert, in: model).sender?.name == "Claremont", "\(scenario.name)")
      #expect(Scenario.row(for: relayed, in: model).pathDisplayString == "Claremont", "\(scenario.name)")
      // The on-air name still finds it, for a channel message signed with it.
      #expect(model.nodeIndex.keys.entries(named: "WCM-CLR-RPT").map(\.publicKey) == [World.claremontKey])
    }
  }

  @Test(arguments: Firmware.allCases)
  func `a send recorded after a row was drawn settles its sender`(firmware: Firmware) throws {
    let sentLog = TrafficSentLog()
    let scenario = Scenario(name: "reply", observed: World.observedWorld + [World.pomonaHillObserved], entries: { [World.replyToBase($0)] })
    let (model, entries) = scenario.list(firmware, sentLog: sentLog)
    let entry = try #require(entries.last)
    #expect(model.packetNodes(for: entry).sender?.displayName == "Pomona Hill?")
    let request = try #require(OwnTransmission.parse(
      command: PacketBuilder.sendStatusRequest(to: World.claremontKey), id: 1, at: World.receivedAt.addingTimeInterval(-5)
    ))
    sentLog.apply([request], now: World.receivedAt)
    // Only its source byte ties the reply to our request: a likely answer, shown as a guess
    #expect(model.packetNodes(for: entry).sender?.displayName == "Claremont?")
    #expect(model.packetNodes(for: entry).sender?.role == .sender(.sentLog))
    #expect(model.packetNodes(for: entry).sender?.isProbable == true)
  }

  @Test(arguments: Firmware.allCases)
  func `a direct message's sender and recipient come from the same resolver`(firmware: Firmware) throws {
    // Mt Baldy's byte to Glendora Room's, through Claremont.
    let (model, entries) = Scenario.c7.list(firmware)
    let packet = model.packetNodes(for: try #require(entries.last))
    #expect(packet.sender?.displayName == "Mt Baldy")
    #expect(packet.recipient?.entry?.publicKey == World.glendoraRoomKey)
  }

  @Test(arguments: Firmware.allCases)
  func `a packet stored before channels were recorded names no hop, and says why`(firmware: Firmware) throws {
    let scenario = Scenario(name: "unstamped", entries: { [World.entry(
      World.frame(.groupText, pathLength: 0x82, path: World.mtBaldyHash + World.claremontHash, payload: World.groupTextPayload),
      firmware: $0,
      channel: nil
    )] })
    let row = try row(scenario, firmware)
    #expect(row.pathDisplayString == "\(Data(World.mtBaldyHash).uppercaseHexString()) → \(claremontHex)")
    #expect(row.channelCaption == L10n.Tools.Tools.RxLog.channelNotRecorded)
  }

  @Test(arguments: Firmware.allCases)
  func `the CSV export names a message's bytes only from the channel it was received on`(firmware: Firmware) throws {
    // Alex (5A…) was heard on this channel. The same message stamped with another channel, or
    // with none, keeps its bytes in hex, as its row does.
    let frame = World.frame(.textMessage, route: .direct, pathLength: 0x00, path: [], payload: World.peerPayload(destination: 0xAA, source: 0x5A))
    let here = World.entry(frame, firmware: firmware)
    let elsewhere = World.entry(frame, firmware: firmware, channel: World.otherChannel)
    let unstamped = World.entry(frame, firmware: firmware, channel: nil)
    let model = RxLogViewModel(sentLog: TrafficSentLog(), observations: World.observationDirectory())
    let table = model.csvTable(for: [here, elsewhere, unstamped])
    let from = try #require(DataExportFormatter.rxLogHeaders.firstIndex(of: "from"))
    let to = try #require(DataExportFormatter.rxLogHeaders.firstIndex(of: "to"))
    #expect(table.rows.map { $0[from] } == ["Alex", "5a", "5a"])
    #expect(table.rows.map { $0[to] } == ["aa", "aa", "aa"], "this radio's own byte is never a node's name")
  }
}
