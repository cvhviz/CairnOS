import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("Remote node bug fixes")
@MainActor
struct RemoteNodeBugFixTests {
  // MARK: #363 neighbour ages

  @Test
  func `normal neighbour ages format by unit`() {
    #expect(NeighborRow.lastSeenText(secondsAgo: 30, maxPlausible: nil) == "30s ago")
    #expect(NeighborRow.lastSeenText(secondsAgo: 600, maxPlausible: nil) == "10m ago")
    #expect(NeighborRow.lastSeenText(secondsAgo: 7200, maxPlausible: nil) == "2h ago")
    #expect(NeighborRow.lastSeenText(secondsAgo: 3 * 86400, maxPlausible: nil) == "3d ago")
  }

  @Test
  func `a clock-jump age is reported as unknown`() {
    #expect(NeighborRow.lastSeenText(secondsAgo: 18_749 * 3600, maxPlausible: nil) == nil)
    #expect(NeighborRow.lastSeenText(secondsAgo: -5, maxPlausible: nil) == nil)
  }

  @Test
  func `an age older than the repeater's uptime is unknown`() {
    #expect(NeighborRow.lastSeenText(secondsAgo: 5000, maxPlausible: 4000) == nil)
    #expect(NeighborRow.lastSeenText(secondsAgo: 3000, maxPlausible: 4000) == "50m ago")
  }

  // MARK: #346 coordinate entry

  @Test
  func `coordinate parsing keeps southern and western signs`() {
    #expect(CoordinateTextField.parse("-37.8") == -37.8)
    #expect(CoordinateTextField.parse("\u{2212}37.8") == -37.8)
    #expect(CoordinateTextField.parse("-37,8") == -37.8)
    #expect(CoordinateTextField.parse(" 144.9 ") == 144.9)
    #expect(CoordinateTextField.parse("abc") == nil)
  }

  @Test
  func `coordinate formatting never uses grouping or a comma`() {
    #expect(CoordinateTextField.format(-37.8) == "-37.800000")
    #expect(CoordinateTextField.format(144.123456) == "144.123456")
  }

  // MARK: #386 telemetry location

  @Test
  func `telemetry fix is offered only when it differs from settings`() {
    let settings = NodeSettingsViewModel()
    #expect(!settings.telemetryFixDiffersFromSettings)
    settings.latitude = -37.8
    settings.longitude = 144.9
    settings.telemetryFix = NodeLocationFix(latitude: -37.8, longitude: 144.9, altitude: nil)
    #expect(!settings.telemetryFixDiffersFromSettings)
    settings.telemetryFix = NodeLocationFix(latitude: -37.81, longitude: 144.9, altitude: nil)
    #expect(settings.telemetryFixDiffersFromSettings)
  }
}
