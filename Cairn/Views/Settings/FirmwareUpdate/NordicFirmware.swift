import Foundation

/// An nRF52 board the app updates over Bluetooth with Nordic DFU, and which file of a Cairn release
/// is its firmware. The board names itself ("Heltec T096": a companion's manufacturer name, a
/// repeater's `board` reply); the release names its images
/// `MeshCore-<assetKey>-Cairn<n>-<yyyy-mm-dd><suffix>.uf2`.
struct NordicFirmwareTarget: Equatable, Sendable {
  enum Role: Sendable {
    case companion
    case repeater
  }

  let assetKey: String
  /// "-ble" for a Bluetooth companion, "-repeater" for a repeater.
  let suffix: String
  let displayName: String
  /// What the firmware advertises as after `start ota` (`NRF52Board(otaname)`): a repeater has no
  /// Bluetooth of its own until then.
  let otaAdvertisingName: String

  /// Boards whose release images can be told apart from the board's own name. (The Wio Tracker L1's
  /// Pro and E-ink builds both call themselves "Seeed Wio Tracker L1", so it isn't here.)
  private static let boards: [(name: String, assetKey: String, ota: String, roles: [Role])] = [
    ("Heltec T096", "HeltecT096", "T096_OTA", [.companion, .repeater]),
    ("Heltec T114", "HeltecT114", "T114_OTA", [.repeater]),
  ]

  init?(boardName: String, role: Role) {
    let name = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let board = Self.boards.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
          board.roles.contains(role) else { return nil }
    assetKey = board.assetKey
    suffix = role == .companion ? "-ble" : "-repeater"
    displayName = board.name
    otaAdvertisingName = board.ota
  }

  /// The whole asset name, as a regular expression for `Releases.latest(assetPattern:boardName:)`.
  var assetPattern: String {
    "^MeshCore-\(assetKey)-Cairn[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}\(suffix)\\.uf2$"
  }
}

/// A Nordic legacy DFU package (`adafruit-nrfutil dfu genpkg`'s, which every Adafruit-based nRF52
/// bootloader takes) made from a release's `.uf2`: the application image and its init packet.
struct NordicFirmwarePackage: Equatable, Sendable {
  enum Problem: Error, Equatable {
    case notUF2
    /// Not an nRF52840 application image (another family, or not at the application's start).
    case wrongImage
  }

  /// The nRF52840's UF2 family.
  static let familyID: UInt32 = 0xADA5_2840
  /// Where the application starts after the S140 6.1.1 SoftDevice the boards run.
  static let applicationStart: UInt32 = 0x26000
  /// The init packet's device type (nRF52) and the SoftDevice it requires (S140 6.1.1), as
  /// PlatformIO's own packages give them.
  static let deviceType: UInt16 = 0x0052
  static let softDeviceS140v611: UInt16 = 0x00B6

  let application: Data
  let initPacket: Data

  /// From a `.uf2`: its blocks' payloads joined in address order from the application's start, then
  /// the init packet over exactly those bytes. A UF2 pads its last block to 256 bytes with zeros;
  /// they go too, the CRC counting them, which leaves them in flash past the end of the image.
  init(uf2: Data) throws {
    let blockSize = 512
    guard uf2.count >= blockSize, uf2.count % blockSize == 0 else { throw Problem.notUF2 }
    var blocks: [(address: UInt32, payload: Data)] = []
    let bytes = [UInt8](uf2)
    func word(_ offset: Int) -> UInt32 {
      UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
    }
    for start in stride(from: 0, to: bytes.count, by: blockSize) {
      guard word(start) == 0x0A32_4655, word(start + 4) == 0x9E5D_5157,
            word(start + blockSize - 4) == 0x0AB1_6F30 else { throw Problem.notUF2 }
      let flags = word(start + 8)
      let address = word(start + 12)
      let size = Int(word(start + 16))
      // 0x2000: the family ID is in the last header word.
      guard flags & 0x2000 != 0, word(start + 28) == Self.familyID, size > 0, size <= 476 else {
        throw Problem.wrongImage
      }
      blocks.append((address, Data(bytes[(start + 32)..<(start + 32 + size)])))
    }
    blocks.sort { $0.address < $1.address }
    guard blocks.first?.address == Self.applicationStart else { throw Problem.wrongImage }
    var image = Data()
    for block in blocks {
      // Contiguous, as uf2conv writes an application: a gap would need filling the bootloader
      // doesn't know about.
      guard Self.applicationStart + UInt32(image.count) == block.address else { throw Problem.wrongImage }
      image.append(block.payload)
    }
    application = image
    initPacket = Self.initPacket(for: image)
  }

  /// dfu_version 0.5's init packet: device type, revision and application version (any), the one
  /// SoftDevice required, and the image's CRC-16.
  static func initPacket(for application: Data) -> Data {
    var packet = Data()
    func append(_ value: UInt16) { packet.append(UInt8(value & 0xFF)); packet.append(UInt8(value >> 8)) }
    append(deviceType)
    append(0xFFFF)
    append(0xFFFF)
    append(0xFFFF)
    append(1)
    append(softDeviceS140v611)
    append(crc16(application))
    return packet
  }

  /// CRC-16/CCITT-FALSE, the legacy DFU's (`crc16_compute` in Nordic's SDK).
  static func crc16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
      crc = (crc >> 8) | (crc << 8)
      crc ^= UInt16(byte)
      crc ^= (crc & 0xFF) >> 4
      crc ^= crc << 12
      crc ^= (crc & 0xFF) << 5
    }
    return crc
  }
}
