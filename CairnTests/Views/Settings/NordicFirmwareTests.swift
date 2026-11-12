@testable import Cairn
import Foundation
import Testing

/// The Bluetooth update's board mapping, and the DFU package it makes from a release's `.uf2`.
@Suite("Nordic firmware package")
struct NordicFirmwareTests {
  /// A UF2 block as uf2conv writes one: header, payload, padding, end magic.
  private func block(address: UInt32, payload: [UInt8], number: Int, total: Int, family: UInt32 = 0xADA5_2840) -> Data {
    var data = Data()
    for word in [0x0A32_4655, 0x9E5D_5157, 0x2000, address, UInt32(payload.count), UInt32(number), UInt32(total), family] as [UInt32] {
      withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: payload)
    data.append(Data(count: 476 - payload.count))
    withUnsafeBytes(of: UInt32(0x0AB1_6F30).littleEndian) { data.append(contentsOf: $0) }
    return data
  }

  @Test
  func `the CRC is the legacy DFU's CRC-16 CCITT`() {
    #expect(NordicFirmwarePackage.crc16(Data("123456789".utf8)) == 0x29B1)
  }

  @Test
  func `blocks join in address order into the application and its init packet`() throws {
    let first = [UInt8](repeating: 0xA1, count: 256)
    let second = [UInt8](repeating: 0xB2, count: 256)
    // Out of order on purpose: the address decides.
    let uf2 = block(address: 0x26100, payload: second, number: 1, total: 2) + block(address: 0x26000, payload: first, number: 0, total: 2)
    let package = try NordicFirmwarePackage(uf2: uf2)
    #expect(package.application == Data(first + second))
    let crc = NordicFirmwarePackage.crc16(package.application)
    let expected: [UInt8] = [0x52, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0xB6, 0x00, UInt8(crc & 0xFF), UInt8(crc >> 8)]
    #expect(package.initPacket == Data(expected))
  }

  @Test
  func `other families, other start addresses and gaps are refused`() {
    let payload = [UInt8](repeating: 1, count: 256)
    #expect(throws: NordicFirmwarePackage.Problem.wrongImage) {
      try NordicFirmwarePackage(uf2: block(address: 0x26000, payload: payload, number: 0, total: 1, family: 0x1C5F_21B0))
    }
    #expect(throws: NordicFirmwarePackage.Problem.wrongImage) {
      try NordicFirmwarePackage(uf2: block(address: 0x1000, payload: payload, number: 0, total: 1))
    }
    #expect(throws: NordicFirmwarePackage.Problem.wrongImage) {
      try NordicFirmwarePackage(uf2: block(address: 0x26000, payload: payload, number: 0, total: 2) + block(address: 0x26200, payload: payload, number: 1, total: 2))
    }
    #expect(throws: NordicFirmwarePackage.Problem.notUF2) {
      try NordicFirmwarePackage(uf2: Data("not a uf2".utf8))
    }
  }

  @Test
  func `boards map to their release images by role`() throws {
    let companion = try #require(NordicFirmwareTarget(boardName: "Heltec T096", role: .companion))
    #expect("MeshCore-HeltecT096-Cairn127-2026-11-03-ble.uf2".range(of: companion.assetPattern, options: .regularExpression) != nil)
    #expect("MeshCore-HeltecT096-Cairn127-2026-11-03-usb.uf2".range(of: companion.assetPattern, options: .regularExpression) == nil)
    let repeater = try #require(NordicFirmwareTarget(boardName: " heltec t096 ", role: .repeater))
    #expect("MeshCore-HeltecT096-Cairn127-2026-11-03-repeater.uf2".range(of: repeater.assetPattern, options: .regularExpression) != nil)
    #expect(repeater.otaAdvertisingName == "T096_OTA")
    #expect(NordicFirmwareTarget(boardName: "Heltec T114", role: .repeater)?.otaAdvertisingName == "T114_OTA")
    #expect(NordicFirmwareTarget(boardName: "Heltec T114", role: .companion) == nil)
    #expect(NordicFirmwareTarget(boardName: "Seeed Wio Tracker L1", role: .companion) == nil)
  }
}
