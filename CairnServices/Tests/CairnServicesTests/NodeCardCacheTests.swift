import Foundation
@testable import CairnServices
import Testing

@Suite("NodeCardCache")
struct NodeCardCacheTests {
  private func defaults() -> UserDefaults {
    let name = "NodeCardCacheTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }
  private let key = Data([0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

  @Test
  func `a saved entry loads back for its node only`() throws {
    let d = defaults()
    NodeCardCache.save(.init(frequency: 910.525, txPower: 18, repeatEnabled: true, firmwareVersion: "v1.17.1"), publicKey: key, defaults: d)
    let e = try #require(NodeCardCache.load(publicKey: key, defaults: d))
    #expect(e.frequency == 910.525)
    #expect(e.txPower == 18)
    #expect(e.repeatEnabled == true)
    #expect(e.firmwareVersion == "v1.17.1")
    #expect(NodeCardCache.load(publicKey: Data([1, 2, 3, 4, 5, 6, 7, 8]), defaults: d) == nil)
  }

  @Test
  func `a visit that read less keeps the last values for the rest`() throws {
    let d = defaults()
    NodeCardCache.save(.init(frequency: 910.525, floodMaxHops: 64, firmwareVersion: "v1"), publicKey: key, defaults: d)
    NodeCardCache.save(.init(firmwareVersion: "v2"), publicKey: key, defaults: d)
    let e = try #require(NodeCardCache.load(publicKey: key, defaults: d))
    #expect(e.frequency == 910.525)
    #expect(e.floodMaxHops == 64)
    #expect(e.firmwareVersion == "v2")
  }

  @Test
  func `an empty entry is not saved`() {
    let d = defaults()
    NodeCardCache.save(.init(), publicKey: key, defaults: d)
    #expect(NodeCardCache.load(publicKey: key, defaults: d) == nil)
  }

  @Test
  func `the neighbour count and sensor line are kept, each replaced whole by a new reading`() throws {
    let d = defaults()
    NodeCardCache.save(
      .init(neighborCount: 4, bestNeighborSNR: 9.5, temperature: "21 °C", otherSensorCount: 2),
      publicKey: key, defaults: d
    )
    NodeCardCache.save(.init(firmwareVersion: "v2"), publicKey: key, defaults: d)
    var e = try #require(NodeCardCache.load(publicKey: key, defaults: d))
    #expect(e.neighborCount == 4)
    #expect(e.bestNeighborSNR == 9.5)
    #expect(e.temperature == "21 °C")
    #expect(e.otherSensorCount == 2)

    // No neighbours now: the old best SNR goes with the old count.
    NodeCardCache.save(.init(neighborCount: 0, otherSensorCount: 0), publicKey: key, defaults: d)
    e = try #require(NodeCardCache.load(publicKey: key, defaults: d))
    #expect(e.neighborCount == 0)
    #expect(e.bestNeighborSNR == nil)
    #expect(e.temperature == nil)
  }

  @Test
  func `an entry saved before the neighbour fields loads`() throws {
    let d = defaults()
    let old = #"{"frequency":910.525,"txPower":18,"savedAt":0}"#
    d.set(Data(old.utf8), forKey: NodeCardCache.key(for: key))
    let e = try #require(NodeCardCache.load(publicKey: key, defaults: d))
    #expect(e.frequency == 910.525)
    #expect(e.neighborCount == nil)
  }
}
