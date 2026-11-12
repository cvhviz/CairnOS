import CryptoKit
import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// Frames built byte for byte the way official MeshCore companion firmware builds them, from the
/// upstream release tags in the firmware fork's git (`git show companion-vX:path`). Every builder
/// cites the tag and line it copies. MeshCore's own tests keep the same set
/// (MeshCoreTests/Fixtures/StockFirmwareFrames.swift).
enum StockCompanionFrames {
  // MARK: - Releases

  /// An official companion release as its CMD_DEVICE_QUERY reply names it.
  struct Release: Sendable, CustomTestStringConvertible {
    let tag: String
    /// FIRMWARE_VER_CODE (examples/companion_radio/MyMesh.h).
    let verCode: UInt8
    /// FIRMWARE_VERSION.
    let version: String

    var testDescription: String {
      tag
    }

    /// The release's device-info reply: client_repeat from code 9, path_hash_mode from code 10.
    var deviceInfo: Data {
      StockCompanionFrames.deviceInfo(
        verCode: verCode,
        version: version,
        clientRepeat: verCode >= 9 ? 0 : nil,
        pathHashMode: verCode >= 10 ? 0 : nil
      )
    }
  }

  /// FIRMWARE_VER_CODE and FIRMWARE_VERSION at each companion tag from v1.7.0 to v1.18.0
  /// (`git show companion-vX:examples/companion_radio/MyMesh.h`).
  static let releases: [Release] = [
    Release(tag: "companion-v1.7.0", verCode: 5, version: "v1.7.0"),
    Release(tag: "companion-v1.7.4", verCode: 7, version: "v1.7.4"),
    Release(tag: "companion-v1.8.0", verCode: 7, version: "v1.8.0"),
    Release(tag: "companion-v1.9.0", verCode: 7, version: "v1.9.0"),
    Release(tag: "companion-v1.10.0", verCode: 8, version: "v1.10.0"),
    Release(tag: "companion-v1.11.0", verCode: 8, version: "v1.11.0"),
    Release(tag: "companion-v1.12.0", verCode: 8, version: "v1.12.0"),
    Release(tag: "companion-v1.13.0", verCode: 9, version: "v1.13.0"),
    Release(tag: "companion-v1.14.0", verCode: 10, version: "v1.14.0"),
    Release(tag: "companion-v1.14.1", verCode: 10, version: "v1.14.1"),
    Release(tag: "companion-v1.15.0", verCode: 11, version: "v1.15.0"),
    Release(tag: "companion-v1.16.0", verCode: 13, version: "v1.16.0"),
    Release(tag: "companion-v1.17.0", verCode: 13, version: "v1.17.0"),
    Release(tag: "companion-v1.17.1", verCode: 13, version: "v1.17.1"),
    Release(tag: "companion-v1.18.0", verCode: 14, version: "v1.18.0"),
  ]

  /// The release at `tag`.
  static func release(_ tag: String) -> Release {
    releases.first { $0.tag == tag }!
  }

  // MARK: - Device info (RESP_CODE_DEVICE_INFO 13)

  /// The CMD_DEVICE_QUERY reply: code, FIRMWARE_VER_CODE, MAX_CONTACTS/2, MAX_GROUP_CHANNELS,
  /// ble_pin (4), FIRMWARE_BUILD_DATE (12, zero padded), manufacturer (40), FIRMWARE_VERSION (20),
  /// then client_repeat from code 9 and path_hash_mode from code 10 (companion-v1.7.0
  /// MyMesh.cpp:639-652, v1.13.0 :918-933, v1.18.0 :1056-1075). Nothing follows on any official
  /// release; the Cairn fork appends `trailer`.
  static func deviceInfo(
    verCode: UInt8,
    version: String,
    clientRepeat: UInt8? = nil,
    pathHashMode: UInt8? = nil,
    trailer: [UInt8] = []
  ) -> Data {
    var frame: [UInt8] = [0x0D, verCode, 175, 40]
    frame += le32(123_456)
    frame += padded("13 Nov 2025", to: 12)
    frame += padded("Heltec V3", to: 40)
    frame += padded(version, to: 20)
    if let clientRepeat { frame.append(clientRepeat) }
    if let pathHashMode { frame.append(pathHashMode) }
    return Data(frame + trailer)
  }

  /// The Cairn fork's reply (fork MyMesh.cpp:2351-2380, FIRMWARE_VER_CODE 14, FIRMWARE_VERSION
  /// "v1.18.0"): the v1.18 layout, then 'C','R','N' and the build number as UInt16 LE.
  static func cairnForkDeviceInfo(build: UInt16) -> Data {
    deviceInfo(
      verCode: 14,
      version: "v1.18.0",
      clientRepeat: 0,
      pathHashMode: 1,
      trailer: Array("CRN".utf8) + withUnsafeBytes(of: build.littleEndian) { Array($0) }
    )
  }

  /// The DeviceDTO the app stores for a device-info reply (ConnectionManager copies the
  /// firmware code, version string and Cairn build from the parsed capabilities).
  static func device(fromDeviceInfo frame: Data) -> DeviceDTO? {
    guard case let .deviceInfo(capabilities) = PacketParser.parse(frame) else { return nil }
    return DeviceDTO.testDevice(
      firmwareVersion: capabilities.firmwareVersion,
      firmwareVersionString: capabilities.version
    ).copy { $0.cairnBuild = capabilities.cairnBuild }
  }

  /// The stored device for the release at `tag`.
  static func device(_ tag: String) -> DeviceDTO {
    device(fromDeviceInfo: release(tag).deviceInfo)!
  }

  // MARK: - Errors

  /// writeErrFrame: [RESP_CODE_ERR 1][err_code] (companion-v1.7.0 MyMesh.cpp:111-116, v1.18.0
  /// :158-163). An unknown command gets ERR_CODE_UNSUPPORTED_CMD (1): `CMD_GET_STATS` before
  /// companion v1.11.0 (v1.10.0 MyMesh.cpp final else).
  static func err(_ code: UInt8) -> Data {
    Data([0x01, code])
  }

  // MARK: - Stats (RESP_CODE_STATS 24, STATS_TYPE_PACKETS 2)

  /// companion-v1.11.0 MyMesh.cpp:1580-1596: recv, sent, n_sent_flood, n_sent_direct,
  /// n_recv_flood, n_recv_direct, all UInt32 LE (24 bytes after the two code bytes).
  static func statsPackets24(received: UInt32, sent: UInt32 = 10) -> Data {
    var frame: [UInt8] = [0x18, 0x02]
    for value in [received, sent, 4, 6, received / 2, received - received / 2] {
      frame += le32(value)
    }
    return Data(frame)
  }

  /// companion-v1.13.0 MyMesh.cpp:1717-1735 onwards (v1.18.0 :1943-1960): the 24 bytes, then
  /// n_recv_errors (28 bytes).
  static func statsPackets28(received: UInt32, receiveErrors: UInt32 = 3) -> Data {
    statsPackets24(received: received) + Data(le32(receiveErrors))
  }

  // MARK: - Received packets (PUSH_CODE_LOG_RX_DATA 0x88)

  /// logRxRaw: [0x88][(int8)(snr * 4)][(int8)rssi][raw packet] (companion-v1.7.0
  /// MyMesh.cpp:205-216, v1.18.0 :291-301), sent only when `len + 3 <= MAX_FRAME_SIZE`.
  static func logRx(snr: Double = 6.5, rssi: Int8 = -90, raw: [UInt8]) -> Data {
    Data([0x88, UInt8(bitPattern: Int8(snr * 4)), UInt8(bitPattern: rssi)] + raw)
  }

  /// Packet::writeTo without transport codes: header `(payload_type << 2) | route_type`,
  /// path_len, path, payload (src/Packet.h PH_TYPE_SHIFT 2).
  static func packet(payloadType: UInt8, route: UInt8, path: [UInt8] = [], payload: [UInt8]) -> [UInt8] {
    [(payloadType << 2) | route, UInt8(path.count)] + path + payload
  }

  static let routeFlood: UInt8 = 0x01
  static let routeDirect: UInt8 = 0x02

  /// A flood group text (PAYLOAD_TYPE_GRP_TXT 5) relayed over two hops: channel hash, MAC (2),
  /// then ciphertext (16-byte blocks). `index` varies the ciphertext so packets differ.
  static func groupTextPacket(index: Int) -> [UInt8] {
    var cipher = [UInt8](repeating: 0x5C, count: 16)
    cipher[0] = UInt8(truncatingIfNeeded: index)
    cipher[1] = UInt8(truncatingIfNeeded: index >> 8)
    return packet(payloadType: 0x05, route: routeFlood, path: [0x3A, 0x7F], payload: [0x11, 0xAB, 0xCD] + cipher)
  }

  /// A zero-hop direct discover reply (PAYLOAD_TYPE_CONTROL 0x0B; simple_repeater
  /// onControlDataRecv): [0x90 | ADV_TYPE_REPEATER][snr x4][tag 4][pub_key 32].
  static func discoverReplyPacket(tag: [UInt8] = [0x11, 0x22, 0x33, 0x44], key: [UInt8]) -> [UInt8] {
    packet(payloadType: 0x0B, route: routeDirect, payload: [0x92, 0x18] + tag + key)
  }

  /// The 0x8E push for the same reply: [0x8E][snr x4][rssi][path_len][payload]
  /// (companion-v1.18.0 MyMesh.cpp onControlDataRecv).
  static func controlData(tag: [UInt8] = [0x11, 0x22, 0x33, 0x44], key: [UInt8]) -> Data {
    Data([0x8E, 26, UInt8(bitPattern: -90), 0x00, 0x92, 0x18] + tag + key)
  }

  // MARK: - Session

  /// RESP_CODE_SELF_INFO, the APP_START reply.
  static var selfInfo: Data {
    var payload = Data([0x05, 0x01, 20, 22])
    payload.append(Data(repeating: 0xAA, count: 32))
    payload.append(Data(count: 8)) // lat, lon
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // multi_acks, adv policy, telemetry, manual add
    payload.append(contentsOf: le32(910_525))
    payload.append(contentsOf: le32(62500))
    payload.append(contentsOf: [0x07, 0x05])
    payload.append(contentsOf: Array("Stock".utf8))
    return payload
  }

  private static func padded(_ text: String, to size: Int) -> [UInt8] {
    let bytes = Array(text.utf8.prefix(size))
    return bytes + [UInt8](repeating: 0, count: size - bytes.count)
  }

  private static func le32(_ value: UInt32) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
  }
}

// MARK: - Radio Model

/// An official companion radio over Bluetooth, as far as delivery goes: it counts every packet it
/// hears (RadioLibWrapper n_recv) and queues that packet's 0x88 frame, unless the frame is lost
/// on the way (the radio's full send queue, the app's full receive buffer, or a packet too long
/// to forward). It answers APP_START and `CMD_GET_STATS` packets through the same first-in,
/// first-out stream, as the firmware does, and leaves every other command unanswered.
actor StockCompanionRadio: MeshTransport {
  enum StatsAnswer {
    /// companion v1.11 and v1.12: 24 bytes.
    case packets24
    /// companion v1.13 and later: 28 bytes.
    case packets28
    /// companion v1.7 to v1.10: ERR_CODE_UNSUPPORTED_CMD.
    case unsupported
    /// No reply (a dropped frame).
    case silent
  }

  let receivedData: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private var connected = false
  private var statsAnswer: StatsAnswer
  /// The radio's received-packet counter (getPacketsRecv).
  private(set) var packetsHeard: UInt32
  /// Frames the app's transport refused, as the BLE transport counts them.
  private(set) var droppedFrameCount = 0
  /// Every command the app wrote.
  private(set) var sent: [Data] = []
  private var packetIndex = 0

  init(statsAnswer: StatsAnswer = .packets28, packetsHeard: UInt32 = 1000) {
    self.statsAnswer = statsAnswer
    self.packetsHeard = packetsHeard
    (receivedData, continuation) = AsyncStream.makeStream(of: Data.self)
  }

  var isConnected: Bool {
    connected
  }

  /// `CMD_GET_STATS` packets requests the app wrote.
  var statsRequests: Int {
    sent.filter { $0 == PacketBuilder.getStatsPackets() }.count
  }

  func connect() async throws {
    connected = true
  }

  func disconnect() async {
    connected = false
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    guard connected else { throw MeshTransportError.notConnected }
    sent.append(data)
    if data.first == CommandCode.appStart.rawValue {
      continuation.yield(StockCompanionFrames.selfInfo)
    } else if data == PacketBuilder.getStatsPackets() {
      switch statsAnswer {
      case .packets24: continuation.yield(StockCompanionFrames.statsPackets24(received: packetsHeard))
      case .packets28: continuation.yield(StockCompanionFrames.statsPackets28(received: packetsHeard))
      case .unsupported: continuation.yield(StockCompanionFrames.err(1))
      case .silent: break
      }
    }
  }

  /// Hears `count` packets and passes on the 0x88 frames of the first `delivered`. The rest are
  /// lost before the session reads them; `linkDropped` of those were refused by the app's own
  /// receive buffer, which the transport counts.
  func hear(_ count: Int, delivered: Int, linkDropped: Int = 0) {
    precondition(delivered <= count && linkDropped <= count - delivered)
    for index in 0..<count {
      packetsHeard &+= 1
      packetIndex += 1
      if index < delivered {
        continuation.yield(StockCompanionFrames.logRx(raw: StockCompanionFrames.groupTextPacket(index: packetIndex)))
      }
    }
    droppedFrameCount += linkDropped
  }

  /// Pushes a frame the radio sends unasked.
  func push(_ frame: Data) {
    continuation.yield(frame)
  }

  /// Sets the radio's received-packet counter, as a reboot or a wrap would.
  func setPacketsHeard(_ value: UInt32) {
    packetsHeard = value
  }

  func setStatsAnswer(_ answer: StatsAnswer) {
    statsAnswer = answer
  }

  func setDroppedFrameCount(_ count: Int) {
    droppedFrameCount = count
  }

  /// A session over this radio, started with its APP_START answer.
  func startedSession(defaultTimeout: TimeInterval = 5) async throws -> MeshCoreSession {
    let session = MeshCoreSession(
      transport: self,
      configuration: SessionConfiguration(defaultTimeout: defaultTimeout, clientIdentifier: "StockTst")
    )
    try await session.start()
    return session
  }
}

// MARK: - Observation Fixtures

/// Packets a stock radio receives that prove (or claim) a node, signed and encrypted as official
/// firmware does: adverts per Mesh::createAdvert (src/Mesh.cpp:410-444: `public_key(32) |
/// timestamp(4) | signature(64) | app_data`, the Ed25519 signature over `public_key | timestamp |
/// app_data`) with app data per AdvertDataBuilder::encodeTo (src/helpers/AdvertDataHelpers.cpp),
/// direct messages per BaseChatMesh (`dest(1) | src(1) | MAC(2) | AES-128-ECB ciphertext`).
extension StockCompanionFrames {
  /// This radio's key in these fixtures: the one ``selfInfo`` reports (0xAA x32).
  static let selfKey = Data(repeating: 0xAA, count: 32)

  /// The channel ``selfInfo`` reports: 910.525 MHz, 62.5 kHz, SF7, CR5.
  static let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 62500, spreadingFactor: 7, codingRate: 5)

  /// Another channel: 915 MHz, 250 kHz, SF10.
  static let otherChannel = RadioChannelConfig(frequencyKHz: 915_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)

  static let advertTypeChat: UInt8 = 1
  static let advertTypeRepeater: UInt8 = 2

  /// A signing key the same on every run, so a fixture node keeps its key and hashes.
  static func signingKey(seed: UInt8) -> Curve25519.Signing.PrivateKey {
    // swiftlint:disable:next force_try
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
  }

  /// AdvertDataBuilder::encodeTo: flags (type | 0x10 position | 0x80 name), lat and lon as
  /// int32 LE millionths, then the name (at most what fits in MAX_ADVERT_DATA_SIZE 32).
  static func advertAppData(name: String?, type: UInt8, lat: Double?, lon: Double?) -> [UInt8] {
    var flags = type & 0x0F
    var body: [UInt8] = []
    if let lat, let lon {
      flags |= 0x10
      body += le32(UInt32(bitPattern: Int32((lat * 1e6).rounded())))
      body += le32(UInt32(bitPattern: Int32((lon * 1e6).rounded())))
    }
    if let name, !name.isEmpty {
      flags |= 0x80
      body += Array(name.utf8.prefix(31 - body.count))
    }
    return [flags] + body
  }

  /// Mesh::createAdvert's payload, signed by `signer`. `claimedKey` replaces the key the payload
  /// carries (a forgery: the signature then belongs to another key).
  static func advertPayload(
    signer: Curve25519.Signing.PrivateKey,
    claimedKey: Data? = nil,
    name: String?,
    type: UInt8 = advertTypeRepeater,
    lat: Double? = nil,
    lon: Double? = nil,
    timestamp: UInt32 = 1_800_000_000
  ) -> [UInt8] {
    let signerKey = Array(signer.publicKey.rawRepresentation)
    let time = le32(timestamp)
    let appData = advertAppData(name: name, type: type, lat: lat, lon: lon)
    // swiftlint:disable:next force_try
    let signature = try! Array(signer.signature(for: Data(signerKey + time + appData)))
    return Array(claimedKey ?? Data(signerKey)) + time + signature + appData
  }

  /// A signed advert packet from `key`'s node, relayed over `path` (1-byte hashes): flood by
  /// default (an empty path is a 0-hop flood heard straight from the node), or `routeDirect`
  /// for a zero-hop direct advert (Mesh::sendZeroHop).
  static func signedAdvert(
    name: String,
    key: Curve25519.Signing.PrivateKey,
    lat: Double? = nil,
    lon: Double? = nil,
    path: [UInt8] = [],
    type: UInt8 = advertTypeRepeater,
    timestamp: UInt32 = 1_800_000_000,
    route: UInt8 = routeFlood
  ) -> [UInt8] {
    packet(
      payloadType: 0x04,
      route: route,
      path: path,
      payload: advertPayload(signer: key, name: name, type: type, lat: lat, lon: lon, timestamp: timestamp)
    )
  }

  /// An advert that carries `claimedKey` but is signed by another key: what a radio drops.
  static func forgedAdvert(
    name: String,
    claimedKey: Data,
    lat: Double? = nil,
    lon: Double? = nil,
    path: [UInt8] = []
  ) -> [UInt8] {
    packet(
      payloadType: 0x04,
      route: routeFlood,
      path: path,
      payload: advertPayload(signer: signingKey(seed: 0xEE), claimedKey: claimedKey, name: name, lat: lat, lon: lon)
    )
  }

  /// A zero-hop direct discover reply carrying the 8-byte prefix of `key` (a prefix-only request).
  static func prefixDiscoverReplyPacket(tag: [UInt8] = [0x11, 0x22, 0x33, 0x44], key: [UInt8]) -> [UInt8] {
    discoverReplyPacket(tag: tag, key: Array(key.prefix(8)))
  }

  /// PUSH_CODE_STATUS_RESPONSE (0x87): reserved(1), the responder's 6-byte key prefix, then the
  /// repeater stats block (companion MyMesh.cpp onContactResponse, RepeaterStats 52 bytes).
  static func statusResponsePush(prefix: Data) -> Data {
    Data([0x87, 0x00]) + prefix.prefix(6) + Data(count: 52)
  }

  /// PUSH_CODE_PATH_UPDATED (0x81): the contact's full key (companion MyMesh.cpp onContactPathUpdated).
  static func pathUpdatedPush(key: Data) -> Data {
    Data([0x81]) + key
  }

  /// The session event a 0x88 frame for `raw` parses to, stamped with `channel`.
  static func parsed(_ raw: [UInt8], snr: Double = 6.5, rssi: Int8 = -90, channel: RadioChannelConfig?) -> ParsedRxLogData {
    guard case var .rxLogData(parsed) = PacketParser.parse(logRx(snr: snr, rssi: rssi, raw: raw)) else {
      preconditionFailure("not an RX log frame")
    }
    parsed.channel = channel
    return parsed
  }

  /// The RX log entry `RxLogService` stores for `raw`, stamped with `channel`.
  static func entry(
    _ raw: [UInt8],
    snr: Double = 6.5,
    rssi: Int8 = -90,
    channel: RadioChannelConfig?,
    radioID: UUID = UUID(),
    receivedAt: Date = Date()
  ) -> RxLogEntryDTO {
    RxLogEntryDTO(radioID: radioID, receivedAt: receivedAt, from: parsed(raw, snr: snr, rssi: rssi, channel: channel))
  }

  // MARK: Direct messages

  /// A contact this radio shares a secret with, and the messages between them.
  enum DirectMessages {
    /// This radio's Curve25519 key for decryption. Its hashes on the air are ``selfKey``'s.
    // swiftlint:disable:next force_try
    static let radioAgreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x5A, count: 32))

    /// The contact's signing key; its first byte differs from ``selfKey``'s.
    static let contactSigner = signingKey(seed: 0x42)

    static var contactKey: Data {
      contactSigner.publicKey.rawRepresentation
    }

    /// The radio's private key as the radio exports it (`[scalar:32][nonce:32]`), for
    /// `RxLogService.updatePrivateKey`.
    static var radioPrivateKeyExport: Data {
      radioAgreementKey.rawRepresentation + Data(count: 32)
    }

    /// The secret both sides derive: X25519 of this radio's key and the contact's converted key.
    static var sharedSecret: Data {
      // swiftlint:disable:next force_unwrapping
      let contactX25519 = Ed25519ToX25519.convertPublicKey(contactKey)!
      // swiftlint:disable:next force_try
      let peer = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: contactX25519)
      // swiftlint:disable:next force_try
      return try! radioAgreementKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }

    /// A flood text message (PAYLOAD_TYPE_TXT_MSG 2) from the contact to this radio over `path`.
    static func fromContact(text: String = "hello", timestamp: UInt32 = 1_800_000_100, path: [UInt8] = []) -> [UInt8] {
      let payload = RxLogDecryptionTests.dmPayload(
        dest: selfKey[0], src: contactKey[0], timestamp: timestamp, text: text, sharedSecret: sharedSecret
      )
      return packet(payloadType: 0x02, route: routeFlood, path: path, payload: Array(payload))
    }

    /// This radio's own message to the contact, heard back from a relay over `path`.
    static func ownEcho(text: String = "hi there", timestamp: UInt32 = 1_800_000_200, path: [UInt8] = [0x3A]) -> [UInt8] {
      let payload = RxLogDecryptionTests.dmPayload(
        dest: contactKey[0], src: selfKey[0], timestamp: timestamp, text: text, sharedSecret: sharedSecret
      )
      return packet(payloadType: 0x02, route: routeFlood, path: path, payload: Array(payload))
    }

    /// The entry `RxLogService` stores once it decrypted `raw` with the contact's secret.
    static func decryptedEntry(
      _ raw: [UInt8],
      text: String,
      timestamp: UInt32,
      channel: RadioChannelConfig?,
      receivedAt: Date = Date()
    ) -> RxLogEntryDTO {
      RxLogEntryDTO(
        radioID: UUID(),
        receivedAt: receivedAt,
        from: StockCompanionFrames.parsed(raw, channel: channel),
        decryptStatus: .success,
        senderTimestamp: timestamp,
        decodedText: text,
        peerPublicKey: contactKey
      )
    }
  }
}
