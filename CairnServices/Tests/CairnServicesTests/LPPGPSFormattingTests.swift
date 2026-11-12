import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("LPP GPS formatting")
struct LPPGPSFormattingTests {
  @Test
  func `coordinates use a dot and keep the sign`() {
    let point = LPPDataPoint(channel: 1, type: .gps, value: .gps(latitude: -37.81234, longitude: 144.96321, altitude: 12))
    #expect(point.formattedValue.hasPrefix("-37.81234, 144.96321 @ "))
  }
}
