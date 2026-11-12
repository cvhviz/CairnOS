import Foundation
@testable import CairnServices
import Testing

@Suite("CairnNodeConfig")
struct CairnNodeConfigTests {
  @Test
  func `a Cairn repeater's combined reply parses whole`() throws {
    let c = try #require(CairnNodeConfig.parse(
      "> la=40.123456|lo=-75.654321|r=910.525,62.5,7,5|tx=18|rp=on|ai=240|fai=12|fm=64|n=Hilltop Rpt"))
    #expect(c.latitude == 40.123456)
    #expect(c.longitude == -75.654321)
    #expect(c.frequency == 910.525)
    #expect(c.bandwidth == 62.5)
    #expect(c.spreadingFactor == 7)
    #expect(c.codingRate == 5)
    #expect(c.txPower == 18)
    #expect(c.repeatEnabled)
    #expect(c.advertIntervalMinutes == 240)
    #expect(c.floodAdvertIntervalHours == 12)
    #expect(c.floodMaxHops == 64)
    #expect(c.name == "Hilltop Rpt")
  }

  @Test
  func `the name keeps a bar or an equals sign`() throws {
    let c = try #require(CairnNodeConfig.parse("> la=0.0|lo=0.0|r=869.618,62.5,8,8|tx=-4|rp=off|ai=0|fai=3|fm=8|n=A|B=C"))
    #expect(c.name == "A|B=C")
    #expect(!c.repeatEnabled)
    #expect(c.txPower == -4)
  }

  @Test
  func `newer firmware reports the TX maximum and the power at the antenna`() throws {
    let c = try #require(CairnNodeConfig.parse(
      "> la=40.1|lo=-75.6|r=910.525,62.5,7,5|tx=9|txm=16|txa=23,28|rp=on|ai=240|fai=12|fm=64|n=T096 Rpt"))
    #expect(c.txPower == 9)
    #expect(c.txPowerMax == 16)
    #expect(c.txAntennaPower == 23)
    #expect(c.txAntennaMax == 28)
    #expect(c.name == "T096 Rpt")
  }

  @Test
  func `a negative setting and a bare board's equal antenna figures parse`() throws {
    let c = try #require(CairnNodeConfig.parse(
      "> la=0.0|lo=0.0|r=869.618,62.5,8,8|tx=-9|txm=22|txa=-9,22|rp=off|ai=0|fai=3|fm=8|n=V3"))
    #expect(c.txPower == -9)
    #expect(c.txPowerMax == 22)
    #expect(c.txAntennaPower == -9)
    #expect(c.txAntennaMax == 22)
  }

  @Test
  func `older firmware without the TX limits still parses`() throws {
    let c = try #require(CairnNodeConfig.parse(
      "> la=40.123456|lo=-75.654321|r=910.525,62.5,7,5|tx=18|rp=on|ai=240|fai=12|fm=64|n=Hilltop Rpt"))
    #expect(c.txPowerMax == nil)
    #expect(c.txAntennaPower == nil)
    #expect(c.txAntennaMax == nil)
  }

  /// The remote TX control's range: never the old 1...30, the node's maximum when it reports one,
  /// else the chip's 22. A stored value outside it (an old unchecked "set tx 30") doesn't stretch it.
  @Test(arguments: [
    (Int?(16), -9...16),
    (18, -9...18),
    (22, -9...22),
    (nil, -9...22),
    (-20, -9...(-9)),       // a nonsense maximum still leaves the floor
  ] as [(Int?, ClosedRange<Int>)])
  func `the remote TX range follows the node`(maximum: Int?, range: ClosedRange<Int>) {
    #expect(CairnNodeConfig.txPowerRange(maximum: maximum) == range)
  }

  /// A refused `set tx` ("Error: range -9..16") gives the node's real range.
  @Test(arguments: [
    ("Error: range -9..16", Optional(-9...16)),
    ("> Error: range -9..18", -9...18),
    ("Error: range -9 .. 22", -9...22),
    ("Error: range 5..1", nil),
    ("Error: unknown command", nil),
    ("Error: interval range is 3-168 hours", nil),
    ("OK", nil),
  ] as [(String, ClosedRange<Int>?)])
  func `a refused set tx gives the node's range`(reply: String, range: ClosedRange<Int>?) {
    #expect(CairnNodeConfig.txPowerRange(fromRefusal: reply) == range)
  }

  @Test(arguments: [
    "??: cairn.cfg", "unknown config: cairn.cfg", "Error: unknown command", "> 22", "",
    "> la=1|lo=2|r=910,62.5,7|tx=18|rp=on|ai=240|fai=12|fm=64|n=x",   // radio short a field
    "> la=1|lo=2|r=910,62.5,7,5|tx=18|rp=maybe|ai=240|fai=12|fm=64|n=x",
    "> la=1|lo=2|r=910,62.5,7,5|tx=18|rp=on|ai=240|fai=12|fm=64",       // no name
  ])
  func `a stock node's answer or a damaged reply is no config`(text: String) {
    #expect(CairnNodeConfig.parse(text) == nil)
  }
}

@Suite("CairnNodeConfigSupport")
struct CairnNodeConfigSupportTests {
  private func defaults() -> UserDefaults {
    let name = "CairnNodeConfigSupportTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  private let key = Data([0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
  private let now = Date(timeIntervalSince1970: 1_786_722_487)

  @Test
  func `a stock node's unknown-setting reply reads as unsupported, a lost or mixed reply does not`() {
    #expect(CairnNodeConfig.isUnsupportedReply("> ??: cairn.cfg"))
    #expect(CairnNodeConfig.isUnsupportedReply("Error: unknown command"))
    #expect(!CairnNodeConfig.isUnsupportedReply("> 910.525,62.5,7,5"))
    #expect(!CairnNodeConfig.isUnsupportedReply(""))
  }

  @Test
  func `an unsupported node is remembered for its key only`() {
    let d = defaults()
    #expect(!CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: "v1.17.1", now: now, defaults: d))
    CairnNodeConfigSupport.markUnsupported(publicKey: key, firmwareVersion: "v1.17.1", now: now, defaults: d)
    #expect(CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: "v1.17.1", now: now, defaults: d))
    #expect(CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: nil, now: now, defaults: d))
    #expect(!CairnNodeConfigSupport.isKnownUnsupported(
      publicKey: Data([1, 2, 3, 4, 5, 6, 7, 8]), firmwareVersion: "v1.17.1", now: now, defaults: d))
  }

  @Test
  func `a node is asked again after a firmware change or the reprobe interval`() {
    let d = defaults()
    CairnNodeConfigSupport.markUnsupported(publicKey: key, firmwareVersion: "v1.17.1", now: now, defaults: d)
    #expect(!CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: "v1.18.0", now: now, defaults: d))
    let later = now.addingTimeInterval(CairnNodeConfigSupport.reprobeInterval)
    #expect(!CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: "v1.17.1", now: later, defaults: d))
  }

  @Test
  func `a node that answers is forgotten`() {
    let d = defaults()
    CairnNodeConfigSupport.markUnsupported(publicKey: key, firmwareVersion: nil, now: now, defaults: d)
    CairnNodeConfigSupport.markSupported(publicKey: key, defaults: d)
    #expect(!CairnNodeConfigSupport.isKnownUnsupported(publicKey: key, firmwareVersion: nil, now: now, defaults: d))
  }
}
