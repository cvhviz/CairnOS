import Foundation
@testable import MeshCore
import Testing

@Suite("PathHops")
struct PathHopsTests {
  @Test
  func `1-byte path splits into single-byte hops`() {
    let hops = PathHops.split(pathNodes: Data([0x3A, 0x7F, 0x01]), pathLength: 0x03)
    #expect(hops == [Data([0x3A]), Data([0x7F]), Data([0x01])])
  }

  @Test
  func `2-byte path splits into two-byte hops in order`() {
    // 0b01_000010 = mode 1, 2 hops
    let hops = PathHops.split(pathNodes: Data([0x3A, 0x7F, 0x01, 0x02]), pathLength: 0x42)
    #expect(hops == [Data([0x3A, 0x7F]), Data([0x01, 0x02])])
  }

  @Test
  func `3-byte path splits into three-byte hops`() {
    // 0b10_000001 = mode 2, 1 hop
    let hops = PathHops.split(pathNodes: Data([0xAA, 0xBB, 0xCC]), pathLength: 0x81)
    #expect(hops == [Data([0xAA, 0xBB, 0xCC])])
  }

  @Test
  func `zero hops gives an empty list, at any hash size`() {
    #expect(PathHops.split(pathNodes: Data(), pathLength: 0x00) == [])
    #expect(PathHops.split(pathNodes: Data(), pathLength: 0x80) == [])
  }

  @Test
  func `reserved mode 3 gives nil`() {
    #expect(PathHops.split(pathNodes: Data([0x01]), pathLength: 0xC1) == nil)
  }

  @Test
  func `bytes that don't match the encoded length give nil`() {
    // 2 hops of 2 bytes need 4 bytes
    #expect(PathHops.split(pathNodes: Data([0x01, 0x02, 0x03]), pathLength: 0x42) == nil)
    #expect(PathHops.split(pathNodes: Data([0x01, 0x02]), pathLength: 0x01) == nil)
  }

  @Test
  func `hops are zero-based even from a sliced path`() throws {
    let raw = Data([0xFF, 0x10, 0x20, 0x30, 0x40])
    let hops = try #require(PathHops.split(pathNodes: raw.dropFirst(), pathLength: 0x42))
    #expect(hops[1].startIndex == 0)
    #expect(hops[1][0] == 0x30)
  }
}
