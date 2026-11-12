import CairnUpdateKit
import Foundation
@testable import Cairn
import Testing

@Suite("Firmware image check")
struct FirmwareImageCheckTests {
  private static let validImage = Data([FirmwareImage.espImageMagic]) + Data(repeating: 0, count: FirmwareImage.minimumSize)

  @Test
  func `a release image for this board passes`() {
    let name = "MeshCore-ThinkNodeM9-Cairn112-2026-10-09-update.bin"
    #expect(FirmwareImage.check(Self.validImage, fileName: name, board: .thinkNodeM9) == nil)
  }

  @Test
  func `a file whose name doesn't say its board passes`() {
    #expect(FirmwareImage.check(Self.validImage, fileName: "firmware.bin", board: .wioL2Pro) == nil)
  }

  @Test
  func `a file named for another board is refused`() {
    let name = "MeshCore-TDeckPlus-Cairn112-2026-10-09-update.bin"
    #expect(FirmwareImage.check(Self.validImage, fileName: name, board: .heltecV4Touch) == .otherBoard)
  }

  @Test
  func `the full image is refused`() {
    let name = "MeshCore-WioL2Pro-Cairn112-2026-10-09-full.bin"
    #expect(FirmwareImage.check(Self.validImage, fileName: name, board: .wioL2Pro) == .fullImage)
  }

  @Test
  func `a small file is refused`() {
    let data = Data([FirmwareImage.espImageMagic]) + Data(repeating: 0, count: 1000)
    #expect(FirmwareImage.check(data, fileName: "update.bin", board: nil) == .tooSmall)
  }

  @Test
  func `a file without the ESP32 image header is refused`() {
    let data = Data(repeating: 0, count: FirmwareImage.minimumSize + 1)
    #expect(FirmwareImage.check(data, fileName: "update.bin", board: nil) == .notFirmware)
  }
}
