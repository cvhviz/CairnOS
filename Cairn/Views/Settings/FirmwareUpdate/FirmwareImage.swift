import CairnUpdateKit
import Foundation

/// A firmware image ready to send to a board: the latest release, checked against its SHA256SUMS,
/// or a `…-update.bin` the person picked, checked by `FirmwareImage.check`.
struct FirmwareImage: Equatable {
  let data: Data
  let fileName: String
  /// What the confirmation names it: the release ("Cairn 112") or the file name.
  let name: String

  /// Why a picked file can't be an app image for this board.
  enum Problem: Error, Equatable {
    case tooSmall
    case notFirmware
    case fullImage
    case otherBoard
  }

  /// Smaller than any app image the touch builds produce.
  static let minimumSize = 64 * 1024
  /// The first byte of an ESP32 app image (`ESP_IMAGE_HEADER_MAGIC`).
  static let espImageMagic: UInt8 = 0xE9

  /// Checks a picked file the way the board's own upload page does before anything is sent: big
  /// enough, an ESP32 app image, not the `-full.bin` (bootloader and partitions included), and, when
  /// its name says which board it is for (`MeshCore-<board>-…`), named for this one.
  static func check(_ data: Data, fileName: String, board: Board?) -> Problem? {
    if fileName.lowercased().hasSuffix("-full.bin") { return .fullImage }
    if data.count < minimumSize { return .tooSmall }
    if data.first != espImageMagic { return .notFirmware }
    if let board, fileName.hasPrefix("MeshCore-"), !fileName.hasPrefix("MeshCore-\(board.assetKey)-") {
      return .otherBoard
    }
    return nil
  }
}
