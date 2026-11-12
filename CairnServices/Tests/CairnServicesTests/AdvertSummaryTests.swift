import Foundation
@testable import CairnServices
import Testing

@Suite("AdvertSummary")
struct AdvertSummaryTests {
  private func le32(_ v: Int32) -> [UInt8] {
    let u = UInt32(bitPattern: v)
    return [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)]
  }
  private func advert(flags: UInt8, lat: Int32? = nil, lon: Int32? = nil, name: String? = nil) -> Data {
    var b = [UInt8](repeating: 0xAB, count: 32) + [1, 2, 3, 4] + [UInt8](repeating: 0x55, count: 64) + [flags]
    if let lat, let lon { b += le32(lat) + le32(lon) }
    if let name { b += Array(name.utf8) }
    return Data(b)
  }

  @Test
  func `a repeater advert with a position and a name`() throws {
    let a = try #require(AdvertSummary.parse(advert(flags: 0x80 | 0x10 | 0x02, lat: 40_123_456, lon: -75_654_321, name: "Hilltop Rpt")))
    #expect(a.nodeType == 2)
    #expect(a.name == "Hilltop Rpt")
    #expect(a.latitude == 40.123456)
    #expect(a.longitude == -75.654321)
    #expect(a.publicKey == Data(repeating: 0xAB, count: 32))
  }

  @Test
  func `a companion advert with only a name`() throws {
    let a = try #require(AdvertSummary.parse(advert(flags: 0x80 | 0x01, name: "Alex")))
    #expect(a.nodeType == 1)
    #expect(a.name == "Alex")
    #expect(a.latitude == nil)
  }

  @Test
  func `a zero position is no position, and short payloads are no advert`() {
    #expect(AdvertSummary.parse(advert(flags: 0x10 | 0x02, lat: 0, lon: 0))?.latitude == nil)
    #expect(AdvertSummary.parse(Data(repeating: 0, count: 50)) == nil)
    #expect(AdvertSummary.parse(advert(flags: 0x10 | 0x02).prefix(104)) == nil)   // the position cut short
  }
}
