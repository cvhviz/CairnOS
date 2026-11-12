import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("RadioGPSReading")
struct RadioGPSReadingTests {
  private typealias Position = RadioGPSReading.TelemetryPosition

  private static let fixed = Position(latitude: 41.8823, longitude: -87.6232, altitude: 181.5)
  private static let noFixYet = Position(latitude: 41.8823, longitude: -87.6232, altitude: 0)

  // MARK: - Status

  @Test
  func `unread receiver state is unknown`() {
    #expect(RadioGPSReading.status(receiver: nil, telemetry: Self.fixed) == .unknown)
  }

  @Test
  func `radio without the gps var has no receiver`() {
    let state = DeviceGPSState(isSupported: false, isEnabled: false)
    #expect(RadioGPSReading.status(receiver: state, telemetry: nil) == .noReceiver)
  }

  @Test
  func `powered down receiver is off`() {
    let state = DeviceGPSState(isSupported: true, isEnabled: false)
    #expect(RadioGPSReading.status(receiver: state, telemetry: Self.fixed) == .off)
  }

  @Test
  func `receiver on reads from the telemetry point`() {
    let state = DeviceGPSState(isSupported: true, isEnabled: true)
    #expect(RadioGPSReading.status(receiver: state, telemetry: nil) == .on)
    #expect(RadioGPSReading.status(receiver: state, telemetry: Self.noFixYet) == .searching)
    #expect(RadioGPSReading.status(receiver: state, telemetry: Self.fixed) == .fix)
  }

  @Test
  func `altitude only comes from a fix`() {
    let on = DeviceGPSState(isSupported: true, isEnabled: true)
    #expect(RadioGPSReading(receiver: on, telemetry: Self.fixed).altitude == 181.5)
    #expect(RadioGPSReading(receiver: on, telemetry: Self.noFixYet).altitude == nil)
    let off = DeviceGPSState(isSupported: true, isEnabled: false)
    #expect(RadioGPSReading(receiver: off, telemetry: Self.fixed).altitude == nil)
  }

  // MARK: - Telemetry

  @Test
  func `gps point on the self channel wins`() {
    let points = [
      LPPDataPoint(channel: 1, type: .voltage, value: .float(4.1)),
      LPPDataPoint(channel: 2, type: .gps, value: .gps(latitude: 1, longitude: 2, altitude: 3)),
      LPPDataPoint(channel: 1, type: .gps, value: .gps(latitude: 41.8823, longitude: -87.6232, altitude: 181.5)),
    ]
    #expect(RadioGPSReading.telemetryPosition(in: points) == Self.fixed)
  }

  @Test
  func `gps point on another channel is used when alone`() {
    let points = [LPPDataPoint(channel: 3, type: .gps, value: .gps(latitude: 1, longitude: 2, altitude: 3))]
    #expect(RadioGPSReading.telemetryPosition(in: points) == Position(latitude: 1, longitude: 2, altitude: 3))
  }

  @Test
  func `telemetry without gps has no position`() {
    let points = [LPPDataPoint(channel: 1, type: .voltage, value: .float(4.1))]
    #expect(RadioGPSReading.telemetryPosition(in: points) == nil)
  }
}
