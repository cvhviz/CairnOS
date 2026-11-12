import Foundation
@testable import MeshCore
import Testing

/// Frames built byte for byte the way official MeshCore companion firmware builds them, from the
/// upstream release tags in the firmware fork's git (`git show companion-vX:path`). Every
/// builder cites the tag and line it copies.
enum StockFirmwareFrames {
  // MARK: - Device info (RESP_CODE_DEVICE_INFO 13)

  /// The CMD_DEVICE_QUERY reply: code, FIRMWARE_VER_CODE, MAX_CONTACTS/2, MAX_GROUP_CHANNELS,
  /// ble_pin (4), FIRMWARE_BUILD_DATE (12, zero padded), manufacturer (40), FIRMWARE_VERSION (20),
  /// then client_repeat from ver 9 and path_hash_mode from ver 10. Nothing follows on any
  /// official release; the Cairn fork appends `trailer`.
  static func deviceInfo(
    verCode: UInt8,
    version: String,
    clientRepeat: UInt8? = nil,
    pathHashMode: UInt8? = nil,
    trailer: [UInt8] = []
  ) -> Data {
    var frame: [UInt8] = [0x0D, verCode, 175, 40]
    frame += withUnsafeBytes(of: UInt32(123_456).littleEndian) { Array($0) }
    frame += padded("13 Nov 2025", to: 12)
    frame += padded("Heltec V3", to: 40)
    frame += padded(version, to: 20)
    if let clientRepeat { frame.append(clientRepeat) }
    if let pathHashMode { frame.append(pathHashMode) }
    return Data(frame + trailer)
  }

  /// companion-v1.7.0 MyMesh.cpp:639-652 (FIRMWARE_VER_CODE 5, MyMesh.h:10): ends after the
  /// version string.
  static let v1_7_0DeviceInfo = deviceInfo(verCode: 5, version: "v1.7.0")
  /// companion-v1.10.0 MyMesh.cpp:815-829 (FIRMWARE_VER_CODE 8): the v1.7 layout.
  static let v1_10_0DeviceInfo = deviceInfo(verCode: 8, version: "v1.10.0")
  /// companion-v1.11.0 MyMesh.cpp:828-842: still FIRMWARE_VER_CODE 8.
  static let v1_11_0DeviceInfo = deviceInfo(verCode: 8, version: "v1.11.0")
  /// companion-v1.12.0 MyMesh.cpp:892-906: still FIRMWARE_VER_CODE 8.
  static let v1_12_0DeviceInfo = deviceInfo(verCode: 8, version: "v1.12.0")
  /// companion-v1.13.0 MyMesh.cpp:918-933 (FIRMWARE_VER_CODE 9): adds client_repeat.
  static let v1_13_0DeviceInfo = deviceInfo(verCode: 9, version: "v1.13.0", clientRepeat: 1)
  /// companion-v1.16.0 MyMesh.cpp:1009-1028 (FIRMWARE_VER_CODE 13): adds path_hash_mode.
  static let v1_16_0DeviceInfo = deviceInfo(verCode: 13, version: "v1.16.0", clientRepeat: 0, pathHashMode: 1)
  /// companion-v1.18.0 MyMesh.cpp:1056-1075 (FIRMWARE_VER_CODE 14): ends at path_hash_mode.
  static let v1_18_0DeviceInfo = deviceInfo(verCode: 14, version: "v1.18.0", clientRepeat: 1, pathHashMode: 2)

  /// The Cairn fork's reply (MyMesh.cpp:2351-2380, FIRMWARE_VER_CODE 14): the v1.18 layout, then
  /// 'C','R','N' and the build number as UInt16 LE, last in the frame. `upstreamExtra` stands
  /// for fields a future upstream release appends, which the fork's trailer then follows.
  static func cairnForkDeviceInfo(build: UInt16, upstreamExtra: [UInt8] = []) -> Data {
    deviceInfo(
      verCode: 14,
      version: "v1.18.0-cairn",
      clientRepeat: 0,
      pathHashMode: 1,
      trailer: upstreamExtra + Array("CRN".utf8) + withUnsafeBytes(of: build.littleEndian) { Array($0) }
    )
  }

  private static func padded(_ text: String, to size: Int) -> [UInt8] {
    let bytes = Array(text.utf8.prefix(size))
    return bytes + [UInt8](repeating: 0, count: size - bytes.count)
  }

  // MARK: - Errors

  /// writeErrFrame: [RESP_CODE_ERR 1][err_code] (companion-v1.7.0 MyMesh.cpp:111-116,
  /// v1.18.0 :158-163). Every unknown command gets ERR_CODE_UNSUPPORTED_CMD (1).
  static func err(_ code: UInt8) -> Data {
    Data([0x01, code])
  }

  static let unsupported = err(1)

  // MARK: - Stats (RESP_CODE_STATS 24, STATS_TYPE_PACKETS 2)

  /// companion-v1.11.0 MyMesh.cpp:1580-1596: recv, sent, n_sent_flood, n_sent_direct,
  /// n_recv_flood, n_recv_direct, all UInt32 LE (24 bytes).
  static func statsPackets24(received: UInt32, sent: UInt32 = 10) -> Data {
    var frame: [UInt8] = [0x18, 0x02]
    for value in [received, sent, 4, 6, received / 2, received - received / 2] {
      frame += withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
    return Data(frame)
  }

  /// companion-v1.13.0 onwards (v1.18.0 MyMesh.cpp:1943-1960): the 24 bytes, then
  /// n_recv_errors (28 bytes).
  static func statsPackets28(received: UInt32, receiveErrors: UInt32 = 3) -> Data {
    var frame = statsPackets24(received: received)
    frame.append(contentsOf: withUnsafeBytes(of: receiveErrors.littleEndian) { Array($0) })
    return frame
  }

  // MARK: - Received packets (PUSH_CODE_LOG_RX_DATA 0x88)

  /// logRxRaw: [0x88][(int8)(snr * 4)][(int8)rssi][raw packet] (companion-v1.7.0 MyMesh.cpp:205-216,
  /// v1.18.0 :291-301), sent only when `len + 3 <= MAX_FRAME_SIZE` (172 through v1.15.0, 176 from
  /// v1.16.0).
  static func logRx(snr: Double = 6.5, rssi: Int8 = -90, raw: [UInt8]) -> Data {
    Data([0x88, UInt8(bitPattern: Int8(snr * 4)), UInt8(bitPattern: rssi)] + raw)
  }

  /// Packet::writeTo for a packet without transport codes: header
  /// `(payload_type << 2) | route_type`, path_len, path, payload (src/Packet.h PH_TYPE_SHIFT 2).
  static func packet(payloadType: UInt8, route: UInt8, path: [UInt8] = [], payload: [UInt8]) -> [UInt8] {
    [(payloadType << 2) | route, UInt8(path.count)] + path + payload
  }

  static let routeFlood: UInt8 = 0x01
  static let routeDirect: UInt8 = 0x02

  /// A plain ACK (PAYLOAD_TYPE_ACK 3, Mesh::createAck, v1.18.0 src/Mesh.cpp:560-571): the 4-byte
  /// ack CRC before companion v1.16.0 (v1.15.0 BaseChatMesh::sendAckTo takes a uint32_t).
  static func ackPacket(code: [UInt8], route: UInt8 = routeDirect, path: [UInt8] = [0x5A]) -> [UInt8] {
    packet(payloadType: 0x03, route: route, path: path, payload: code)
  }

  /// A plain ACK from companion v1.16.0 on: the CRC, the attempt byte and a random byte
  /// (v1.16.0 src/helpers/BaseChatMesh.cpp:230-234, v1.18.0 :241-247).
  static func ackPacket6(code: [UInt8], attempt: UInt8 = 0, random: UInt8 = 0xC7, path: [UInt8] = [0x5A]) -> [UInt8] {
    packet(payloadType: 0x03, route: routeDirect, path: path, payload: code + [attempt, random])
  }

  /// A multipart ACK (PAYLOAD_TYPE_MULTIPART 0x0A, Mesh::createMultiAck, v1.18.0 src/Mesh.cpp:574-585):
  /// `(remaining << 4) | PAYLOAD_TYPE_ACK`, then the ack bytes. sendAckTo sends it 300 ms before
  /// the plain ACK when multi_acks is on (BaseChatMesh.cpp:43-58).
  static func multipartAckPacket(code: [UInt8], remaining: UInt8 = 1, path: [UInt8] = [0x5A]) -> [UInt8] {
    packet(payloadType: 0x0A, route: routeDirect, path: path, payload: [(remaining << 4) | 0x03] + code)
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

  // MARK: - Messaging

  /// RESP_CODE_SENT: [6][1 = flood, 0 = direct][expected_ack 4][est_timeout 4 LE]
  /// (companion-v1.18.0 MyMesh.cpp:1167-1171).
  static func messageSent(ack: [UInt8], flood: Bool = false, timeoutMs: UInt32 = 6000) -> Data {
    Data([0x06, flood ? 1 : 0] + ack + withUnsafeBytes(of: timeoutMs.littleEndian) { Array($0) })
  }

  /// PUSH_CODE_SEND_CONFIRMED: [0x82][ack 4][trip_time 4 LE] (companion-v1.18.0 MyMesh.cpp:426-429).
  static func sendConfirmed(ack: [UInt8], tripMs: UInt32 = 1234) -> Data {
    Data([0x82] + ack + withUnsafeBytes(of: tripMs.littleEndian) { Array($0) })
  }

  /// RESP_CODE_CONTACT_MSG_RECV_V3 as queueMessage builds it for an app with target ver >= 3
  /// (companion-v1.18.0 MyMesh.cpp:440-465): code, snr x4, two reserved bytes, sender pub_key
  /// prefix (6), path_len (0xFF when direct), txt_type, sender_timestamp (4 LE), text.
  static func contactMsgV3(text: String, snr: Double = 5, pathLen: UInt8 = 0xFF) -> Data {
    var frame: [UInt8] = [0x10, UInt8(bitPattern: Int8(snr * 4)), 0, 0]
    frame += [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6]
    frame += [pathLen, 0x00]
    frame += withUnsafeBytes(of: UInt32(1_760_000_000).littleEndian) { Array($0) }
    frame += Array(text.utf8)
    return Data(frame)
  }

  /// RESP_CODE_NO_MORE_MESSAGES (companion-v1.18.0 MyMesh.cpp:1421).
  static let noMoreMessages = Data([0x0A])

  /// PUSH_CODE_MSG_WAITING, one per queued message (companion-v1.18.0 MyMesh.cpp:471).
  static let msgWaiting = Data([0x83])

  /// RESP_CODE_SELF_INFO, the APP_START reply.
  static var selfInfo: Data {
    var payload = Data([0x05, 0x01, 20, 22])
    payload.append(Data(repeating: 0xAA, count: 32))
    payload.append(Data(count: 8)) // lat, lon
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // multi_acks, adv policy, telemetry, manual add
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(910_525).littleEndian) { Array($0) })
    payload.append(contentsOf: withUnsafeBytes(of: UInt32(62500).littleEndian) { Array($0) })
    payload.append(contentsOf: [0x07, 0x05])
    payload.append(contentsOf: Array("Stock".utf8))
    return payload
  }
}

// MARK: - Test Clock

/// A clock that moves only when a test advances it, so timeouts, quiet waits and graces run in
/// simulated time.
final class StockTestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [UUID: Sleeper] = [:]
  private var cancelledBeforeSleeping: Set<UUID> = []

  var now: Instant {
    lock.withLock { current }
  }

  var minimumResolution: Duration {
    .zero
  }

  /// Tasks sleeping on this clock now.
  var sleeperCount: Int {
    lock.withLock { sleepers.count }
  }

  /// When each sleeping task wakes, as offsets from the clock's start.
  var sleeperDeadlines: [Duration] {
    lock.withLock { sleepers.values.map(\.deadline.offset) }
  }

  func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        enum Outcome { case wake, cancel, wait }
        let outcome: Outcome = lock.withLock {
          if cancelledBeforeSleeping.remove(id) != nil { return .cancel }
          if deadline <= current { return .wake }
          sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return .wait
        }
        switch outcome {
        case .wake: continuation.resume()
        case .cancel: continuation.resume(throwing: CancellationError())
        case .wait: break
        }
      }
    } onCancel: {
      let sleeper: Sleeper? = lock.withLock {
        if let sleeper = sleepers.removeValue(forKey: id) { return sleeper }
        cancelledBeforeSleeping.insert(id)
        return nil
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Moves time on and wakes every sleeper whose deadline has come, earliest first.
  func advance(by duration: Duration) {
    let due: [Sleeper] = lock.withLock {
      current = current.advanced(by: duration)
      let ready = sleepers.filter { $0.value.deadline <= current }
      for id in ready.keys {
        sleepers.removeValue(forKey: id)
      }
      return ready.values.sorted { $0.deadline < $1.deadline }
    }
    for sleeper in due {
      sleeper.continuation.resume()
    }
  }
}

// MARK: - Test Transport

/// An in-memory transport that also reports frames it "dropped" before the session read them,
/// like the BLE transport's full notification buffer.
actor StockTestTransport: MeshTransport {
  private(set) var sentData: [Data] = []
  private(set) var isConnected = false
  private(set) var droppedFrameCount = 0
  private let stream: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(of: Data.self)
  }

  var receivedData: AsyncStream<Data> {
    stream
  }

  func connect() async throws {
    isConnected = true
  }

  func disconnect() async {
    isConnected = false
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    guard isConnected else { throw MeshTransportError.notConnected }
    sentData.append(data)
  }

  func receive(_ data: Data) {
    continuation.yield(data)
  }

  func setDroppedFrameCount(_ count: Int) {
    droppedFrameCount = count
  }

  func clearSentData() {
    sentData.removeAll()
  }

  func sent(code: UInt8) -> [Data] {
    sentData.filter { $0.first == code }
  }
}

// MARK: - Session Harness

enum StockSessionHarness {
  /// A session over `transport` on `clock`, started with an APP_START answer and with the
  /// handshake cleared from the transport's record.
  static func startedSession(
    transport: StockTestTransport,
    clock: StockTestClock,
    defaultTimeout: TimeInterval = 5
  ) async throws -> MeshCoreSession {
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: defaultTimeout, clientIdentifier: "MeshCore-Tests"),
      clock: clock
    )
    let start = Task { try await session.start() }
    try await waitUntil("APP_START should be sent") {
      await !transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
    await transport.receive(StockFirmwareFrames.selfInfo)
    try await start.value
    await transport.clearSentData()
    return session
  }
}

extension MeshCoreSession {
  /// Turns RX_SYNC delivery on or off without the SUBSCRIBE exchange. For tests only.
  func setRxSyncActiveForTest(_ isActive: Bool) {
    rxSync.isActive = isActive
  }

  /// Sets the quiet wait before each message fetch; a zero `maxWait` turns the gate off. For tests only.
  func setFetchQuietWaitForTest(quiet: Duration, maxWait: Duration) {
    linkPacing.fetchQuiet = quiet
    linkPacing.fetchMaxWait = maxWait
  }
}

/// Collects the events a session dispatches, for asserting on what reached subscribers.
actor EventRecorder {
  private(set) var events: [MeshEvent] = []

  func append(_ event: MeshEvent) {
    events.append(event)
  }

  var acknowledgements: [(code: Data, tripTime: UInt32?)] {
    events.compactMap { event in
      if case let .acknowledgement(code, tripTime) = event { return (code, tripTime) }
      return nil
    }
  }

  /// Records every event `session` dispatches from now on, until the session stops.
  static func recording(_ session: MeshCoreSession) async -> (EventRecorder, Task<Void, Never>) {
    let recorder = EventRecorder()
    let stream = await session.events()
    let task = Task {
      for await event in stream {
        await recorder.append(event)
      }
    }
    return (recorder, task)
  }
}

/// Whether `error` is the radio's `deviceError` with `code`.
func isDeviceError(_ error: MeshCoreError?, _ code: UInt8) -> Bool {
  if case let .deviceError(actual) = error { return actual == code }
  return false
}

/// Whether `error` is a timeout.
func isTimeout(_ error: MeshCoreError?) -> Bool {
  if case .timeout = error { return true }
  return false
}
