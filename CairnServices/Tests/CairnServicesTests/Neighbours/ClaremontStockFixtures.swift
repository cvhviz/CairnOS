@testable import CairnServices
import CryptoKit
import Foundation
import MeshCore
import Testing

/// The SoCal world the "Claremont is on the flood list but not on the Traffic map" scenarios run
/// in, and the packets they receive.
///
/// Every packet is a raw stock `PUSH_CODE_LOG_RX_DATA` (0x88) frame (header, path length, path,
/// payload) parsed by ``RxLogParser`` and stamped with the channel the radio reported (``channel``),
/// so epoch and seq are nil and it isn't a backfill: exactly what official MeshCore firmware
/// delivers. ``Firmware/cairn`` gives the same frame as it comes over Cairn's RX_SYNC, with its
/// journal position set; every result must be the same.
///
/// Nodes resolve only once observed on the channel: ``observedWorld`` is what this radio heard
/// (its ledger), ``savedContacts`` and ``heardNodes`` are only labels and hints. ``index(observed:)``
/// with an empty list is the world before anything was heard: every hash is unknown.
enum ClaremontStockFixtures {
  enum Firmware: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case stock
    case cairn

    var testDescription: String { rawValue }
  }

  static let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
  static let radioID = UUID(uuidString: "6B1C1D6E-0000-4000-8000-00000000C1A2")!
  /// The channel the radio reports in SoCal: 910.525 MHz, 250 kHz, SF10, CR5.
  static let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
  /// Another channel the same radio was once on.
  static let otherChannel = RadioChannelConfig(frequencyKHz: 927_875, bandwidthHz: 62500, spreadingFactor: 7, codingRate: 5)

  static func key(_ prefix: [UInt8], fill: UInt8) -> Data {
    Data(prefix + [UInt8](repeating: fill, count: 32 - prefix.count))
  }

  // MARK: - Nodes

  /// The radio "Base", in Upland.
  static let radioKey = key([0xAA, 0x01, 0x02], fill: 0x01)
  static let radio = (latitude: 34.0975, longitude: -117.6484)
  static let claremontKey = key([0xC1, 0xA2, 0x3E], fill: 0x11)
  static let claremontPosition = (latitude: 34.1064, longitude: -117.7103)
  static let mtBaldyKey = key([0xB4, 0x5D, 0x01], fill: 0x22)
  /// Heard only, nearer the radio than Claremont, and sharing its first byte.
  static let pomonaHillKey = key([0xC1, 0x77, 0x20], fill: 0x33)
  static let glendoraRoomKey = key([0x9E, 0x10, 0x02], fill: 0x44)
  static let alexKey = key([0x5A, 0x33, 0x01], fill: 0x55)
  static let claremontOpsKey = key([0x0C, 0x0F, 0x5E], fill: 0x66)
  /// A hop no store knows.
  static let unknownHop: [UInt8] = [0x7F, 0x7F, 0x7F]

  static func claremont(
    latitude: Double = claremontPosition.latitude,
    longitude: Double = claremontPosition.longitude,
    type: UInt8 = ContactType.repeater.rawValue
  ) -> ContactDTO {
    .testContact(
      radioID: radioID,
      publicKey: claremontKey,
      name: "Claremont",
      typeRawValue: type,
      latitude: latitude,
      longitude: longitude,
      lastModified: 1_799_990_000
    )
  }

  static var mtBaldy: ContactDTO {
    .testContact(
      radioID: radioID,
      publicKey: mtBaldyKey,
      name: "Mt Baldy",
      typeRawValue: ContactType.repeater.rawValue,
      latitude: 34.2364,
      longitude: -117.6589,
      lastModified: 1_799_990_000
    )
  }

  static func alex(latitude: Double = 0, longitude: Double = 0) -> ContactDTO {
    .testContact(
      radioID: radioID,
      publicKey: alexKey,
      name: "Alex",
      typeRawValue: ContactType.chat.rawValue,
      latitude: latitude,
      longitude: longitude,
      lastModified: 1_799_990_000
    )
  }

  static var claremontOps: ContactDTO {
    .testContact(
      radioID: radioID,
      publicKey: claremontOpsKey,
      name: "Claremont Ops",
      typeRawValue: ContactType.chat.rawValue,
      latitude: 34.0967,
      longitude: -117.7198,
      lastModified: 1_799_990_000
    )
  }

  static func discovered(_ key: Data, name: String, type: UInt8, latitude: Double, longitude: Double) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: key,
      name: name,
      typeRawValue: type,
      lastHeard: receivedAt.addingTimeInterval(-600),
      lastAdvertTimestamp: 1_799_999_000,
      latitude: latitude,
      longitude: longitude,
      outPathLength: 0xFF,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  static var pomonaHill: DiscoveredNodeDTO {
    discovered(pomonaHillKey, name: "Pomona Hill", type: ContactType.repeater.rawValue, latitude: 34.0900, longitude: -117.6600)
  }

  static var glendoraRoom: DiscoveredNodeDTO {
    discovered(glendoraRoomKey, name: "Glendora Room", type: ContactType.room.rawValue, latitude: 34.1361, longitude: -117.8653)
  }

  static var savedContacts: [ContactDTO] {
    [claremont(), mtBaldy, alex()]
  }

  static var heardNodes: [DiscoveredNodeDTO] {
    [pomonaHill, glendoraRoom]
  }

  // MARK: - Observations

  /// One observation of `key` on `channel`: an advert heard over `hops` relays (0: straight from
  /// the node, at the frame's SNR), carrying the node's type, name and position.
  static func observation(
    _ key: Data,
    name: String?,
    type: UInt8 = ContactType.repeater.rawValue,
    latitude: Double? = nil,
    longitude: Double? = nil,
    hops: Int = 2,
    at date: Date = receivedAt.addingTimeInterval(-3600),
    channel: RadioChannelConfig = channel
  ) -> NodeObservation {
    NodeObservation(
      identity: .fullKey(key),
      kind: hops == 0 ? .advertDirect : .advertRelayed,
      channelKey: channel.key,
      at: date,
      hops: hops,
      snr: hops == 0 ? 7.5 : nil,
      rssi: hops == 0 ? -88 : nil,
      name: name,
      nodeTypeRaw: type,
      latitude: latitude,
      longitude: longitude
    )
  }

  static var claremontObserved: NodeObservation {
    observation(claremontKey, name: "Claremont", latitude: claremontPosition.latitude, longitude: claremontPosition.longitude)
  }

  static var mtBaldyObserved: NodeObservation {
    observation(mtBaldyKey, name: "Mt Baldy", latitude: 34.2364, longitude: -117.6589)
  }

  /// Heard straight from it, nearer the radio than Claremont: the likelier of the two for C1.
  static var pomonaHillObserved: NodeObservation {
    observation(pomonaHillKey, name: "Pomona Hill", latitude: 34.0900, longitude: -117.6600, hops: 0)
  }

  static var glendoraRoomObserved: NodeObservation {
    observation(glendoraRoomKey, name: "Glendora Room", type: ContactType.room.rawValue, latitude: 34.1361, longitude: -117.8653)
  }

  static var alexObserved: NodeObservation {
    observation(alexKey, name: "Alex", type: ContactType.chat.rawValue, hops: 1)
  }

  static var claremontOpsObserved: NodeObservation {
    observation(claremontOpsKey, name: "Claremont Ops", type: ContactType.chat.rawValue, latitude: 34.0967, longitude: -117.7198)
  }

  /// What this radio heard on ``channel``: every node of the world but Pomona Hill, so the C1
  /// byte names only Claremont.
  static var observedWorld: [NodeObservation] {
    [claremontObserved, mtBaldyObserved, glendoraRoomObserved, alexObserved, claremontOpsObserved]
  }

  /// The ledger `observations` make on `channel`, taken at ``receivedAt``.
  static func ledger(
    _ observations: [NodeObservation],
    channel: RadioChannelConfig = channel,
    selfKey: Data = radioKey,
    takenAt: Date = receivedAt
  ) -> LedgerSnapshot {
    var ledger = ObservationLedger(radioID: radioID, channel: channel, selfKey: selfKey)
    ledger.ingest(observations)
    return ledger.snapshot(takenAt: takenAt)
  }

  /// The world's index: the ledger `observed` makes, the saved contacts' names as nicknames and
  /// hints, the heard nodes as hints, the radio at Base unless `anchor` says otherwise.
  static func index(
    observed: [NodeObservation] = observedWorld,
    channel: RadioChannelConfig = channel,
    contacts: [ContactDTO] = savedContacts,
    discovered: [DiscoveredNodeDTO] = heardNodes,
    anchor: (latitude: Double, longitude: Double)? = radio,
    selfKey: Data = radioKey
  ) -> PacketNodeIndex {
    PacketNodeIndex(
      ledger: ledger(observed, channel: channel, selfKey: selfKey),
      selfName: "Base",
      anchorLatitude: anchor?.latitude,
      anchorLongitude: anchor?.longitude,
      displayNames: Dictionary(contacts.map { ($0.publicKey, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
      unobserved: NeighbourKeyIndex(
        selfKey: selfKey,
        entries: contacts.map(NeighbourKeyEntry.init) + discovered.map(NeighbourKeyEntry.init)
      )
    )
  }

  // MARK: - Signed adverts

  /// A signing key whose public key starts with `byte`, the same on every run: a node a 1-byte
  /// path hash can name and whose adverts really verify.
  static func signer(startingWith byte: UInt8) -> Curve25519.Signing.PrivateKey {
    for seed in 0..<UInt16.max {
      let raw = Data([UInt8(seed & 0xFF), UInt8(seed >> 8), byte]) + Data(repeating: 0x5D, count: 29)
      // swiftlint:disable:next force_try
      let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: raw)
      if key.publicKey.rawRepresentation.first == byte { return key }
    }
    preconditionFailure("no key starts with \(byte)")
  }

  /// A local repeater whose key starts 0xC1, as Claremont's does, with adverts that verify.
  static let localC1Signer = signer(startingWith: 0xC1)

  static var localC1Key: Data {
    localC1Signer.publicKey.rawRepresentation
  }

  /// `localC1Signer`'s flood advert as "Claremont", relayed over `path` (1-byte hashes).
  static func signedClaremontAdvert(path: [UInt8] = [0xB4, 0x9E], firmware: Firmware, receivedAt: Date = receivedAt) -> RxLogEntryDTO {
    let raw = StockCompanionFrames.signedAdvert(
      name: "Claremont",
      key: localC1Signer,
      lat: claremontPosition.latitude,
      lon: claremontPosition.longitude,
      path: path
    )
    return entry(Data(raw), firmware: firmware, receivedAt: receivedAt)
  }

  // MARK: - Frames

  /// A raw over-the-air packet as a stock 0x88 push carries it after its SNR and RSSI bytes.
  static func frame(
    _ type: PayloadType,
    route: RouteType = .flood,
    pathLength: UInt8,
    path: [UInt8],
    payload: [UInt8]
  ) -> Data {
    Data([type.rawValue << 2 | route.rawValue, pathLength] + path + payload)
  }

  /// `frame` as the RX log stores it, as `firmware` delivers it, stamped with `channel` (nil: an
  /// entry stored before channels were recorded).
  static func entry(
    _ frame: Data,
    firmware: Firmware,
    receivedAt: Date = receivedAt,
    decryptStatus: DecryptStatus = .notApplicable,
    decodedText: String? = nil,
    peerPublicKey: Data? = nil,
    channel: RadioChannelConfig? = channel
  ) -> RxLogEntryDTO {
    var stock = RxLogParser.parse(snr: 6.5, rssi: -92, payload: frame)!
    stock.channel = channel
    let parsed = switch firmware {
    case .stock: stock
    case .cairn: stock.withRxSync(seq: 4242, epoch: 0xC0FFEE, radioAge: .milliseconds(120), isBackfill: false)
    }
    return RxLogEntryDTO(
      id: UUID(uuidString: "6B1C1D6E-0000-4000-8000-000000000001")!,
      radioID: radioID,
      receivedAt: receivedAt,
      from: parsed,
      decryptStatus: decryptStatus,
      decodedText: decodedText,
      peerPublicKey: peerPublicKey
    )
  }

  /// A channel message's payload: channel hash, MAC, ciphertext.
  static let groupTextPayload: [UInt8] = [0x11, 0xAB, 0xCD] + [UInt8](repeating: 0x5C, count: 16)

  /// A peer packet's payload: destination hash, source hash, MAC, ciphertext.
  static func peerPayload(destination: UInt8, source: UInt8) -> [UInt8] {
    [destination, source, 0x3E, 0x91] + [UInt8](repeating: 0x7A, count: 16)
  }

  /// An advert's payload: key, timestamp, signature, then app data (flags, position, name).
  static func advertPayload(
    key: Data,
    type: UInt8,
    name: String?,
    latitude: Double? = nil,
    longitude: Double? = nil
  ) -> [UInt8] {
    var flags = type
    var appData: [UInt8] = []
    if let latitude, let longitude {
      flags |= 0x10
      for value in [latitude, longitude] {
        let scaled = UInt32(bitPattern: Int32((value * 1e6).rounded()))
        appData += [UInt8(scaled & 0xFF), UInt8(scaled >> 8 & 0xFF), UInt8(scaled >> 16 & 0xFF), UInt8(scaled >> 24)]
      }
    }
    if let name {
      flags |= 0x80
      appData += Array(name.utf8)
    }
    return [UInt8](key) + [0x10, 0x27, 0x4B, 0x6B] + [UInt8](repeating: 0xE5, count: 64) + [flags] + appData
  }

  // MARK: - Scenarios

  /// C1: a flood channel message relayed by Mt Baldy, then Claremont (3-byte hashes).
  static func c1(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(
      frame(.groupText, pathLength: 0x82, path: [0xB4, 0x5D, 0x01, 0xC1, 0xA2, 0x3E], payload: groupTextPayload),
      firmware: firmware
    )
  }

  /// C2: Claremont, then a hop no one knows, then Mt Baldy.
  static func c2(_ firmware: Firmware, receivedAt: Date = receivedAt) -> RxLogEntryDTO {
    entry(
      frame(.groupText, pathLength: 0x83, path: [0xC1, 0xA2, 0x3E] + unknownHop + [0xB4, 0x5D, 0x01], payload: groupTextPayload),
      firmware: firmware,
      receivedAt: receivedAt
    )
  }

  /// C3: a stock client in 1-byte mode, relayed by a node starting C1.
  static func c3(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(frame(.groupText, pathLength: 0x01, path: [0xC1], payload: groupTextPayload), firmware: firmware)
  }

  /// C4: a 2-byte path through C1A2.
  static func c4(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(frame(.groupText, pathLength: 0x41, path: [0xC1, 0xA2], payload: groupTextPayload), firmware: firmware)
  }

  /// C5: Claremont's flood advert, with its position, through an unknown hop. Its signature is
  /// filler, so it verifies for no key: what a radio drops.
  static func c5(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(
      frame(.advert, pathLength: 0x81, path: unknownHop, payload: claremontAdvertPayload),
      firmware: firmware
    )
  }

  static var claremontAdvertPayload: [UInt8] {
    advertPayload(
      key: claremontKey,
      type: ContactType.repeater.rawValue,
      name: "Claremont",
      latitude: claremontPosition.latitude,
      longitude: claremontPosition.longitude
    )
  }

  /// C6: Claremont's zero-hop advert (sent direct with an empty path), heard first; unsigned.
  static func c6Advert(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(
      frame(.advert, route: .direct, pathLength: 0x00, path: [], payload: claremontAdvertPayload),
      firmware: firmware,
      receivedAt: receivedAt.addingTimeInterval(-30)
    )
  }

  /// C6 and C7: a flood direct message relayed by Claremont (one 3-byte hop).
  static func viaClaremont(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(
      frame(.textMessage, pathLength: 0x81, path: [0xC1, 0xA2, 0x3E], payload: peerPayload(destination: 0x9E, source: 0xB4)),
      firmware: firmware
    )
  }

  /// C8: a zero-hop flood request from Alex to Mt Baldy, between other nodes.
  static func c8(_ firmware: Firmware) -> RxLogEntryDTO {
    entry(
      frame(.request, pathLength: 0x00, path: [], payload: peerPayload(destination: 0xB4, source: 0x5A)),
      firmware: firmware
    )
  }

  /// C9: a decrypted channel message relayed by Mt Baldy.
  static func c9(_ firmware: Firmware, text: String = "Claremont Ops: on air") -> RxLogEntryDTO {
    entry(
      frame(.groupText, pathLength: 0x81, path: [0xB4, 0x5D, 0x01], payload: groupTextPayload),
      firmware: firmware,
      decryptStatus: .success,
      decodedText: text
    )
  }
}
