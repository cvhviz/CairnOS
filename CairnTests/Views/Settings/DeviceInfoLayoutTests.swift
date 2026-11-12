import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("Device Info tile rows")
struct TileRowPlannerTests {
  @Test
  func `Rows are balanced rather than filled greedily`() {
    #expect(TileRowPlanner.rowSizes(count: 6, maxColumns: 2) == [2, 2, 2])
    #expect(TileRowPlanner.rowSizes(count: 6, maxColumns: 4) == [3, 3])
    #expect(TileRowPlanner.rowSizes(count: 6, maxColumns: 6) == [6])
    #expect(TileRowPlanner.rowSizes(count: 4, maxColumns: 3) == [2, 2])
  }

  @Test
  func `An odd count leaves one short last row, never an empty cell mid-row`() {
    #expect(TileRowPlanner.rowSizes(count: 3, maxColumns: 2) == [2, 1])
    #expect(TileRowPlanner.rowSizes(count: 5, maxColumns: 2) == [2, 2, 1])
    #expect(TileRowPlanner.rowSizes(count: 1, maxColumns: 2) == [1])
  }

  @Test
  func `One column stacks every tile and no tiles make no rows`() {
    #expect(TileRowPlanner.rowSizes(count: 3, maxColumns: 1) == [1, 1, 1])
    #expect(TileRowPlanner.rowSizes(count: 3, maxColumns: 0) == [1, 1, 1])
    #expect(TileRowPlanner.rowSizes(count: 0, maxColumns: 2).isEmpty)
  }

  @Test
  func `Columns that fit count the spacing between tiles`() {
    #expect(TileRowPlanner.columnsThatFit(width: 361, minimumTileWidth: 150, spacing: 10) == 2)
    #expect(TileRowPlanner.columnsThatFit(width: 310, minimumTileWidth: 150, spacing: 10) == 2)
    #expect(TileRowPlanner.columnsThatFit(width: 300, minimumTileWidth: 150, spacing: 10) == 1)
    #expect(TileRowPlanner.columnsThatFit(width: 100, minimumTileWidth: 150, spacing: 10) == 1)
  }

  /// iPad crash (build 14): a stack's ideal-size pass proposes an infinite width, and Int(.infinity) traps.
  @Test
  func `Columns that fit survive a width that isn't finite`() {
    #expect(TileRowPlanner.columnsThatFit(width: .infinity, minimumTileWidth: 150, spacing: 10) == 1)
    #expect(TileRowPlanner.columnsThatFit(width: .nan, minimumTileWidth: 150, spacing: 10) == 1)
    #expect(TileRowPlanner.columnsThatFit(width: 300, minimumTileWidth: .infinity, spacing: 10) == 1)
  }
}

@Suite("Device Info readings")
@MainActor
struct DeviceInfoReadingsTests {
  @Test
  func `Timeouts ask for a refresh, everything else is left out quietly`() {
    #expect(DeviceReadingIssue(MeshCoreError.timeout) == .noAnswer)
    #expect(DeviceReadingIssue(SettingsServiceError.sessionError(.timeout)) == .noAnswer)
    #expect(DeviceReadingIssue(BinaryProtocolError.timeout) == .noAnswer)
    #expect(DeviceReadingIssue(BinaryProtocolError.sessionError(.timeout)) == .noAnswer)

    #expect(DeviceReadingIssue(MeshTransportError.sendFailed("x")) == .unavailable)
    #expect(DeviceReadingIssue(SettingsServiceError.sessionError(.deviceError(code: 1))) == .unavailable)
    #expect(DeviceReadingIssue(SettingsServiceError.invalidResponse) == .unavailable)
  }

  @Test
  func `A timeout outranks other issues`() {
    #expect(DeviceReadingIssue.worst(of: []) == nil)
    #expect(DeviceReadingIssue.worst(of: [.unavailable]) == .unavailable)
    #expect(DeviceReadingIssue.worst(of: [.unavailable, .noAnswer]) == .noAnswer)
  }

  @Test
  func `Counters show as placeholders until read, then only what the radio reported`() {
    let all = DeviceLifetimeCounter.allCases
    #expect(DeviceLifetimeCounter.shown(hasCore: false, hasPackets: false, hasLoaded: false) == all)
    #expect(DeviceLifetimeCounter.shown(hasCore: true, hasPackets: true, hasLoaded: true) == all)
    #expect(DeviceLifetimeCounter.shown(hasCore: true, hasPackets: false, hasLoaded: true) == [.uptime])
    #expect(
      DeviceLifetimeCounter.shown(hasCore: false, hasPackets: true, hasLoaded: true)
        == [.received, .sent, .receiveErrors]
    )
    #expect(DeviceLifetimeCounter.shown(hasCore: false, hasPackets: false, hasLoaded: true).isEmpty)
  }

  @Test
  func `Sensors leave out the battery voltage but keep other channels' voltages`() {
    let sensors = [
      LPPDataPoint(channel: 1, type: .voltage, value: .float(4.1)),
      LPPDataPoint(channel: 1, type: .temperature, value: .float(21)),
      LPPDataPoint(channel: 2, type: .voltage, value: .float(12.3)),
    ]
    let groups = DeviceReadingsModel.displayedSensorGroups(sensors)
    #expect(groups.map(\.channel) == [1, 2])
    #expect(groups[0].dataPoints.map(\.type) == [.temperature])
    #expect(groups[1].dataPoints.map(\.type) == [.voltage])
  }

  @Test
  func `Only the battery voltage means no sensors section`() {
    let sensors = [LPPDataPoint(channel: 1, type: .voltage, value: .float(4.1))]
    #expect(DeviceReadingsModel.displayedSensorGroups(sensors).isEmpty)
  }
}

@Suite("Device Info identity")
@MainActor
struct DeviceInfoIdentityTests {
  @Test
  func `A new name must be non-blank and different`() {
    #expect(DeviceNameEditor.isValidNewName("Hilltop", current: "Base"))
    #expect(!DeviceNameEditor.isValidNewName("   ", current: "Base"))
    #expect(!DeviceNameEditor.isValidNewName(" Base ", current: "Base"))
  }

  @Test
  func `Bytes left counts UTF-8 bytes and never goes negative`() {
    let limit = ProtocolLimits.maxUsableNameBytes
    #expect(DeviceNameEditor.bytesLeft(in: "") == limit)
    #expect(DeviceNameEditor.bytesLeft(in: "é") == limit - 2)
    #expect(DeviceNameEditor.bytesLeft(in: String(repeating: "a", count: limit + 5)) == 0)
  }

  @Test
  func `Key chip shows each end of the key`() {
    let key = Data((1...32).map { UInt8($0) })
    #expect(DeviceKeyChip.shortKey(key) == "010203…1F20")
  }
}
