import Foundation
@testable import Cairn
import Testing

@Suite("NodeSectionTileDetail")
struct NodeSectionTileDetailTests {
  private typealias Strings = L10n.RemoteNodes.RemoteNodes

  // MARK: - Load state

  @Test
  func `A section never read says it isn't loaded`() {
    #expect(NodeSectionTileDetail.state(isLoading: false, hasError: false, loaded: nil) == Strings.Status.Tile.notLoaded)
  }

  @Test
  func `A running request shows loading, even over an earlier reading`() {
    #expect(NodeSectionTileDetail.state(isLoading: true, hasError: false, loaded: nil) == Strings.Settings.loading)
    #expect(NodeSectionTileDetail.state(isLoading: true, hasError: true, loaded: "3") == Strings.Settings.loading)
  }

  @Test
  func `A reading wins over a later failure, and a failed first read says so`() {
    #expect(NodeSectionTileDetail.state(isLoading: false, hasError: true, loaded: "Found: 3") == "Found: 3")
    #expect(
      NodeSectionTileDetail.state(isLoading: false, hasError: true, loaded: nil)
        == L10n.Localizable.Common.Error.failedToLoad
    )
  }

  // MARK: - Contact info

  @Test
  func `Contact info shows the first non-blank line of the owner text`() {
    #expect(NodeSectionTileDetail.ownerInfo("\n  Jane Doe  \njane@example.com", firmware: "v1.9") == "Jane Doe")
  }

  @Test
  func `Empty owner text falls back to the firmware, then the empty note`() {
    #expect(NodeSectionTileDetail.ownerInfo("", firmware: "v1.9") == "v1.9")
    #expect(NodeSectionTileDetail.ownerInfo("  \n ", firmware: nil) == Strings.Status.noOwnerInfo)
    #expect(NodeSectionTileDetail.ownerInfo(nil, firmware: "") == Strings.Status.noOwnerInfo)
  }

  // MARK: - Battery

  @Test
  func `Battery shows the charge before the curve name, or the name alone`() {
    let withReading = NodeSectionTileDetail.battery(percent: 87, presetName: "LiFePO4")
    #expect(withReading == "\(BatteryLevel.formattedPercent(87)) · LiFePO4")
    #expect(NodeSectionTileDetail.battery(percent: nil, presetName: "LiFePO4") == "LiFePO4")
  }

  // MARK: - Telemetry

  @Test
  func `Telemetry counts the readings, or says there are none`() {
    #expect(NodeSectionTileDetail.telemetry(readingCount: 4) == Strings.Status.Tile.sensorCount(4))
    #expect(NodeSectionTileDetail.telemetry(readingCount: 0) == Strings.Status.noSensorData)
  }
}
