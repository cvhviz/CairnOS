@testable import CairnServices
import Foundation
import Testing

@Suite("DiscoverListenWindow")
struct DiscoverListenWindowTests {
  private func window(_ preset: RadioPreset) -> TimeInterval {
    DiscoverListenWindow.seconds(
      spreadingFactor: Int(preset.spreadingFactor),
      bandwidthHz: Double(preset.bandwidthHz),
      codingRate: Int(preset.codingRate)
    )
  }

  @Test
  func `WCMesh listens for the 6 s floor`() throws {
    let wcmesh = try #require(RadioPresets.all.first { $0.id == "wcmesh" })
    #expect(window(wcmesh) == 6)
  }

  @Test
  func `reply airtime matches the LoRa formula at SF7 BW62.5 CR5`() {
    // 2.048 ms symbols; 32 + 4.25 preamble symbols and 8 + 14 · 5 payload symbols.
    let airtime = DiscoverListenWindow.replyAirtime(spreadingFactor: 7, bandwidthHz: 62500, codingRate: 5)
    #expect(abs(airtime - 0.233_984) < 0.000_01)
  }

  @Test
  func `SF11 BW250 sits between the floor and the ceiling`() {
    // A ≈ 0.600 s, so 11 · A + 1.5 s ≈ 8.1 s.
    let seconds = DiscoverListenWindow.seconds(spreadingFactor: 11, bandwidthHz: 250_000, codingRate: 5)
    #expect(seconds > 8 && seconds < 8.2)
  }

  @Test(arguments: [(11, 125_000.0), (12, 250_000.0), (12, 125_000.0)])
  func `slow presets are clamped to 15 s`(spreadingFactor: Int, bandwidthHz: Double) {
    #expect(DiscoverListenWindow.seconds(spreadingFactor: spreadingFactor, bandwidthHz: bandwidthHz, codingRate: 5) == 15)
  }

  @Test
  func `the window for a device reads its radio settings in Hz`() {
    let device = DeviceDTO.testDevice(bandwidth: 125_000, spreadingFactor: 12, codingRate: 8)
    #expect(DiscoverListenWindow.seconds(for: device) == 15)
  }

  @Test
  func `a late reply extends the window, never past 15 s`() {
    let start = Date(timeIntervalSince1970: 0)
    let end = start.addingTimeInterval(6)
    // Early reply: no change.
    #expect(DiscoverListenWindow.extendedEnd(end, start: start, reply: start.addingTimeInterval(2)) == end)
    // In the last 3 s: three more seconds.
    let extended = DiscoverListenWindow.extendedEnd(end, start: start, reply: start.addingTimeInterval(4))
    #expect(extended == start.addingTimeInterval(9))
    // Capped at the ceiling.
    let late = start.addingTimeInterval(14)
    #expect(DiscoverListenWindow.extendedEnd(late, start: start, reply: late) == start.addingTimeInterval(15))
  }
}
