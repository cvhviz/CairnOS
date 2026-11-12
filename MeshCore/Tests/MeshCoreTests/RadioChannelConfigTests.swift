import Foundation
@testable import MeshCore
import Testing

/// The channel a radio reports in a stock `RESP_CODE_SELF_INFO` (companion MyMesh.cpp
/// CMD_APP_START: `radio_freq` in kHz and `radio_bw` in Hz as uint32 LE, then `radio_sf`, `radio_cr`).
@Suite("RadioChannelConfig")
struct RadioChannelConfigTests {
  @Test
  func `a stock SELF_INFO for 910.525 MHz, 250 kHz, SF10, CR5 gives the radio's exact integers`() throws {
    let config = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 250_000, sf: 10, cr: 5)))
    #expect(config.frequencyKHz == 910_525)
    #expect(config.bandwidthHz == 250_000)
    #expect(config.spreadingFactor == 10)
    #expect(config.codingRate == 5)
    #expect(config.key.rawValue == "f910525-bw250000-sf10")
  }

  @Test(arguments: [
    (UInt32(869_618), UInt32(62_500)),
    (UInt32(433_175), UInt32(7_800)),
    (UInt32(915_000), UInt32(125_000)),
    (UInt32(906_875), UInt32(500_000)),
  ])
  func `fractional MHz and kHz readings round back to the wire integers`(frequency: UInt32, bandwidth: UInt32) throws {
    let config = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: frequency, bandwidthHz: bandwidth, sf: 7, cr: 5)))
    #expect(config.frequencyKHz == frequency)
    #expect(config.bandwidthHz == bandwidth)
  }

  @Test
  func `a coding-rate-only difference keeps the key`() throws {
    let cr5 = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 250_000, sf: 10, cr: 5)))
    let cr8 = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 250_000, sf: 10, cr: 8)))
    #expect(cr5 != cr8)
    #expect(cr5.key == cr8.key)
  }

  @Test
  func `a spreading factor, frequency or bandwidth difference changes the key`() throws {
    let base = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 250_000, sf: 10, cr: 5)))
    let otherSF = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 250_000, sf: 11, cr: 5)))
    let otherFrequency = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_526, bandwidthHz: 250_000, sf: 10, cr: 5)))
    let otherBandwidth = try #require(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 910_525, bandwidthHz: 125_000, sf: 10, cr: 5)))
    #expect(base.key != otherSF.key)
    #expect(base.key != otherFrequency.key)
    #expect(base.key != otherBandwidth.key)
  }

  @Test
  func `a SELF_INFO with no frequency gives no channel`() throws {
    #expect(RadioChannelConfig(selfInfo: try selfInfo(frequencyKHz: 0, bandwidthHz: 250_000, sf: 10, cr: 5)) == nil)
  }

  @Test
  func `the key round-trips`() throws {
    let config = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
    let parsed = try #require(RadioChannelConfig(key: config.key))
    #expect(parsed.key == config.key)
    #expect(parsed.frequencyKHz == 910_525)
    #expect(parsed.bandwidthHz == 250_000)
    #expect(parsed.spreadingFactor == 10)
  }

  @Test(arguments: ["", "f910525-bw250000", "f0-bw250000-sf10", "x910525-bw250000-sf10", "f910525-bw250000-sfX", "f910525-bw250000-sf10-cr5"])
  func `a malformed key names no channel`(raw: String) {
    #expect(RadioChannelConfig(key: ChannelKey(rawValue: raw)) == nil)
  }

  @Test
  func `config and key encode and decode`() throws {
    let config = RadioChannelConfig(frequencyKHz: 869_618, bandwidthHz: 62_500, spreadingFactor: 8, codingRate: 8)
    let decoded = try JSONDecoder().decode(RadioChannelConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded == config)
    let keyJSON = try JSONEncoder().encode(config.key)
    #expect(String(decoding: keyJSON, as: UTF8.self) == "\"f869618-bw62500-sf8\"")
    #expect(try JSONDecoder().decode(ChannelKey.self, from: keyJSON) == config.key)
  }
}

/// Parses a stock SELF_INFO frame reporting this channel.
private func selfInfo(frequencyKHz: UInt32, bandwidthHz: UInt32, sf: UInt8, cr: UInt8) throws -> SelfInfo {
  let event = PacketParser.parse(stockSelfInfoFrame(frequencyKHz: frequencyKHz, bandwidthHz: bandwidthHz, sf: sf, cr: cr))
  guard case let .selfInfo(info) = event else {
    Issue.record("Expected selfInfo, got \(event)")
    throw CancellationError()
  }
  return info
}

/// RESP_CODE_SELF_INFO as companion firmware writes it: code, adv type, tx power, max tx power,
/// pub_key (32), lat/lon (int32 LE ×1e6), multi_acks, advert_loc_policy, telemetry modes,
/// manual_add_contacts, radio_freq (kHz) and radio_bw (Hz) as uint32 LE, sf, cr, node name.
func stockSelfInfoFrame(frequencyKHz: UInt32, bandwidthHz: UInt32, sf: UInt8, cr: UInt8, name: String = "Stock") -> Data {
  var frame = Data([0x05, 0x01, 20, 22])
  frame.append(Data(repeating: 0xAA, count: 32))
  frame.append(Data(count: 8))
  frame.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
  frame.append(contentsOf: withUnsafeBytes(of: frequencyKHz.littleEndian) { Array($0) })
  frame.append(contentsOf: withUnsafeBytes(of: bandwidthHz.littleEndian) { Array($0) })
  frame.append(contentsOf: [sf, cr])
  frame.append(contentsOf: Array(name.utf8))
  return frame
}
