import Foundation
import MeshCore

/// The simulator's radio (the demo radio in simulator builds, demo mode and `-screenshotMode`).
///
/// It answers the commands that read and change the radio's own settings the way companion
/// firmware does (`MyMesh.cpp`): `APP_START` with a `SELF_INFO` of its current settings,
/// `DEVICE_QUERY` with a `DEVICE_INFO`, and `SET_RADIO_PARAMS`, `SET_RADIO_TX_POWER` and
/// `SET_PATH_HASH_MODE` with OK (or ERR for values the firmware refuses), keeping what they set.
/// So picking a preset in Settings → Radio or onboarding writes, reads back and shows the new
/// settings, as on a real radio. It starts on the seeded device's settings, so a read-back before
/// any write changes nothing on screen.
///
/// It also takes a room keep-alive (`CMD_SEND_BINARY_REQ` with `REQ_TYPE_KEEP_ALIVE`) to a contact
/// it holds with `RESP_CODE_SENT`, as the firmware does once it has queued the request: that is
/// all the app waits for, so the seeded, logged-in demo room stays logged in while it is open
/// instead of dropping its login on the first keep-alive.
///
/// It sends a node discover request (`CMD_SEND_CONTROL_DATA` with the type's high bit set) and
/// answers OK, as the firmware does once it has sent it zero-hop. The demo mesh never replies, so
/// a scan or Wardrive on the demo radio listens out its window and hears nothing, rather than
/// failing as if the radio were not connected.
///
/// What happens to every other command is ``Unemulated``. The demo radio (`simulatorConnect`)
/// passes ``Unemulated/failAtOnce``: each fails at once with ``MeshTransportError/notConnected``,
/// as every command did before its session started, because the rest of the demo runs on seeded
/// data, never on the radio. That includes the other binary requests (status, telemetry,
/// neighbours), whose answers come back from the mesh, which the demo has none of; failing them at
/// once beats a wait that can only time out. By default (``Unemulated/unanswered``) a connected
/// radio takes them and never answers, as this transport always has: tests that build a session on
/// it drive the replies themselves (`dispatchForTesting`) or let the session time out.
actor SimulatorMockTransport: MeshTransport {
  /// What the radio does with a command it doesn't emulate, once connected.
  enum Unemulated: Sendable {
    /// Takes it and never answers: the session waits for a reply a test dispatches, or times out.
    case unanswered
    /// Fails it at once with ``MeshTransportError/notConnected``: the demo radio, where nothing
    /// would ever answer it.
    case failAtOnce
  }

  /// What the radio holds, as its firmware's prefs would.
  struct RadioState: Sendable, Equatable {
    var nodeName: String
    var publicKey: Data
    var txPower: Int8
    var maxTxPower: Int8
    var latitude: Double
    var longitude: Double
    var multiAcks: UInt8
    var advertLocationPolicy: UInt8
    var telemetryModes: UInt8
    var manualAddContacts: Bool
    var frequencyKHz: UInt32
    var bandwidthHz: UInt32
    var spreadingFactor: UInt8
    var codingRate: UInt8
    var clientRepeat: Bool
    var pathHashMode: UInt8
    var firmwareVersion: UInt8
    var maxContacts: UInt16
    var maxChannels: UInt8
    var blePin: UInt32
    var buildDate: String
    var model: String
    var version: String
    var cairnBuild: UInt16?

    init(device: DeviceDTO) {
      nodeName = device.nodeName
      publicKey = device.publicKey
      txPower = device.txPower
      maxTxPower = device.maxTxPower
      latitude = device.latitude
      longitude = device.longitude
      multiAcks = device.multiAcks
      advertLocationPolicy = device.advertLocationPolicy
      telemetryModes = (device.telemetryModeEnv & 0b11) << 4 | (device.telemetryModeLoc & 0b11) << 2
        | (device.telemetryModeBase & 0b11)
      manualAddContacts = device.manualAddContacts
      frequencyKHz = device.frequency
      bandwidthHz = device.bandwidth
      spreadingFactor = device.spreadingFactor
      codingRate = device.codingRate
      clientRepeat = device.clientRepeat
      pathHashMode = device.pathHashMode
      firmwareVersion = device.firmwareVersion
      maxContacts = device.maxContacts
      maxChannels = device.maxChannels
      blePin = device.blePin
      buildDate = device.buildDate
      model = device.manufacturerName
      version = device.firmwareVersionString
      cairnBuild = device.cairnBuild
    }
  }

  private let continuation: AsyncStream<Data>.Continuation
  private var _isConnected = false
  /// The radio's current settings; tests read it to see what a write left.
  private(set) var radio: RadioState
  /// Commands the radio refuses the next time they come, with "unsupported command", and then
  /// takes again: lets a test (or a UI test's `-simulatorRadioRefusesOnce`) fail one write.
  private var refusingOnce: Set<CommandCode>
  /// The contacts the radio holds, by full public key: whether each is flood-routed (no known
  /// path), which the firmware reports in `RESP_CODE_SENT`.
  private let contactsFloodRouted: [Data: Bool]
  /// The next request tag, which the firmware returns in `RESP_CODE_SENT` to match the reply.
  private var nextTag: UInt32 = 1
  private let unemulated: Unemulated

  /// The radio's replies, one frame per element.
  let receivedData: AsyncStream<Data>

  var isConnected: Bool {
    _isConnected
  }

  init(
    device: DeviceDTO = MockDataProvider.simulatorDevice,
    contacts: [ContactDTO] = MockDataProvider.contacts,
    refusingOnce: Set<CommandCode> = [],
    unemulated: Unemulated = .unanswered
  ) {
    radio = RadioState(device: device)
    self.refusingOnce = refusingOnce
    self.unemulated = unemulated
    contactsFloodRouted = Dictionary(
      contacts.map { ($0.publicKey, $0.isFloodRouted) }, uniquingKeysWith: { first, _ in first }
    )
    var cont: AsyncStream<Data>.Continuation!
    receivedData = AsyncStream { continuation in
      cont = continuation
    }
    continuation = cont
  }

  func connect() async throws {
    _isConnected = true
  }

  func disconnect() async {
    continuation.finish()
    _isConnected = false
  }

  func send(_ data: Data) async throws {
    guard _isConnected else {
      throw MeshTransportError.notConnected
    }
    guard let reply = reply(to: data) else {
      if unemulated == .failAtOnce {
        throw MeshTransportError.notConnected
      }
      return
    }
    continuation.yield(reply)
  }

  // MARK: - Firmware

  /// The frame the firmware sends back for `command`, or nil for a command this radio doesn't
  /// emulate.
  private func reply(to command: Data) -> Data? {
    guard let code = command.first.flatMap(CommandCode.init(rawValue:)) else { return nil }
    if refusingOnce.remove(code) != nil {
      return Self.error(.unsupportedCommand)
    }
    let bytes = [UInt8](command)
    switch code {
    case .appStart:
      return bytes.count >= 8 ? selfInfoFrame() : nil
    case .deviceQuery:
      return deviceInfoFrame()
    case .setRadio:
      return setRadio(bytes)
    case .setTxPower:
      guard bytes.count >= 2 else { return Self.error(.illegalArgument) }
      let power = Int8(bitPattern: bytes[1])
      guard power >= -9, power <= radio.maxTxPower else { return Self.error(.illegalArgument) }
      radio.txPower = power
      return Self.ok
    case .setPathHashMode:
      // [code, reserved 0, mode]; modes 0-2 (1- to 3-byte hashes).
      guard bytes.count >= 3, bytes[1] == 0, bytes[2] < 3 else { return Self.error(.illegalArgument) }
      radio.pathHashMode = bytes[2]
      return Self.ok
    case .setDevicePin:
      // [code, PIN UInt32 LE]; as `MyMesh::saveBLEPin`, 0 is the firmware default.
      guard bytes.count >= 5 else { return Self.error(.illegalArgument) }
      let pin = Self.uint32(bytes, at: 1)
      guard pin <= 999_999 else { return Self.error(.illegalArgument) }
      radio.blePin = pin
      return Self.ok
    case .reboot:
      // The demo radio keeps its settings and stays linked: it has nothing to restart.
      return bytes.count >= 7 ? Self.ok : Self.error(.illegalArgument)
    case .binaryRequest:
      return keepAlive(bytes)
    case .sendControlData:
      return controlData(bytes)
    default:
      return nil
    }
  }

  /// `CMD_SEND_BINARY_REQ`: [code, public key (32), request type, payload]. Only a keep-alive is
  /// taken; other request types are left unemulated (nil). As in `MyMesh.cpp`, a request to a
  /// contact the radio doesn't hold is refused with "not found", and a queued one is answered
  /// with `RESP_CODE_SENT`: route flag (1 = flood), tag (UInt32 LE), estimated timeout in ms.
  private func keepAlive(_ bytes: [UInt8]) -> Data? {
    let keySize = 32
    guard bytes.count >= 2 + keySize, bytes[1 + keySize] == BinaryRequestType.keepAlive.rawValue else {
      return nil
    }
    guard let isFlood = contactsFloodRouted[Data(bytes[1...keySize])] else {
      return Self.error(.notFound)
    }
    let tag = nextTag
    nextTag &+= 1
    var frame = Data([ResponseCode.messageSent.rawValue, isFlood ? 1 : 0])
    Self.append(tag, to: &frame)
    Self.append(UInt32(isFlood ? 10_000 : 5000), to: &frame)
    return frame
  }

  /// `CMD_SEND_CONTROL_DATA`: [code, control type, payload]. As in `MyMesh.cpp`, a type with its
  /// high bit set (a node discover request) is sent zero-hop and answered with OK; other types
  /// are left unemulated (nil).
  private func controlData(_ bytes: [UInt8]) -> Data? {
    guard bytes.count >= 2, bytes[1] & 0x80 != 0 else { return nil }
    return Self.ok
  }

  /// `CMD_SET_RADIO_PARAMS`: freq kHz and bw Hz as UInt32 LE, SF, CR, then client repeat (v9+).
  /// The same checks as the firmware, which refuses client repeat off the repeat frequencies.
  private func setRadio(_ bytes: [UInt8]) -> Data {
    guard bytes.count >= 11 else { return Self.error(.illegalArgument) }
    let frequency = Self.uint32(bytes, at: 1)
    let bandwidth = Self.uint32(bytes, at: 5)
    let spreadingFactor = bytes[9]
    let codingRate = bytes[10]
    let repeatOn = bytes.count > 11 && bytes[11] != 0
    if repeatOn, !RadioPresets.repeatPresets.contains(where: { $0.frequencyKHz == frequency }) {
      return Self.error(.illegalArgument)
    }
    guard (150_000...2_500_000).contains(frequency), (7_000...500_000).contains(bandwidth),
          (5...12).contains(spreadingFactor), (5...8).contains(codingRate) else {
      return Self.error(.illegalArgument)
    }
    radio.frequencyKHz = frequency
    radio.bandwidthHz = bandwidth
    radio.spreadingFactor = spreadingFactor
    radio.codingRate = codingRate
    radio.clientRepeat = repeatOn
    return Self.ok
  }

  /// `RESP_CODE_SELF_INFO`, laid out as `MyMesh.cpp` writes it.
  private func selfInfoFrame() -> Data {
    var frame = Data([ResponseCode.selfInfo.rawValue, 1, UInt8(bitPattern: radio.txPower), UInt8(bitPattern: radio.maxTxPower)])
    frame.append(radio.publicKey.prefix(32))
    frame.append(Data(repeating: 0, count: max(0, 32 - radio.publicKey.count)))
    Self.append(Int32((radio.latitude * 1_000_000).rounded()), to: &frame)
    Self.append(Int32((radio.longitude * 1_000_000).rounded()), to: &frame)
    frame.append(contentsOf: [radio.multiAcks, radio.advertLocationPolicy, radio.telemetryModes])
    frame.append(radio.manualAddContacts ? 1 : 0)
    Self.append(radio.frequencyKHz, to: &frame)
    Self.append(radio.bandwidthHz, to: &frame)
    frame.append(contentsOf: [radio.spreadingFactor, radio.codingRate])
    frame.append(contentsOf: Array(radio.nodeName.utf8.prefix(31)))
    return frame
  }

  /// `RESP_CODE_DEVICE_INFO` (v3+ layout, then client repeat, path hash mode and the Cairn
  /// firmware marker when the seeded device has one).
  private func deviceInfoFrame() -> Data {
    var frame = Data([ResponseCode.deviceInfo.rawValue, radio.firmwareVersion])
    frame.append(UInt8(min(Int(radio.maxContacts) / 2, 255)))
    frame.append(radio.maxChannels)
    Self.append(radio.blePin, to: &frame)
    frame.append(Self.fixed(radio.buildDate, length: 12))
    frame.append(Self.fixed(radio.model, length: 40))
    frame.append(Self.fixed(radio.version, length: 20))
    frame.append(radio.clientRepeat ? 1 : 0)
    frame.append(radio.pathHashMode)
    if let cairnBuild = radio.cairnBuild {
      frame.append(contentsOf: Array("CRN".utf8))
      Self.append(cairnBuild, to: &frame)
    }
    return frame
  }

  private static let ok = Data([ResponseCode.ok.rawValue])

  /// The commands this radio emulates, by their case names.
  private static let emulatedCommands: [String: CommandCode] = [
    "appStart": .appStart, "deviceQuery": .deviceQuery, "setRadio": .setRadio,
    "setTxPower": .setTxPower, "setPathHashMode": .setPathHashMode,
  ]

  /// The emulated commands named in a comma-separated list of their case names
  /// ("setPathHashMode,setRadio"); other names are skipped.
  static func commands(named list: String?) -> Set<CommandCode> {
    Set((list ?? "").split(separator: ",").compactMap {
      emulatedCommands[$0.trimmingCharacters(in: .whitespaces)]
    })
  }

  private static func error(_ code: ErrorCode) -> Data {
    Data([ResponseCode.error.rawValue, code.rawValue])
  }

  private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
  }

  private static func append(_ value: some FixedWidthInteger, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  /// A NUL-padded, truncated UTF-8 field of `length` bytes.
  private static func fixed(_ string: String, length: Int) -> Data {
    var bytes = Array(string.utf8.prefix(length))
    bytes.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
    return Data(bytes)
  }
}
