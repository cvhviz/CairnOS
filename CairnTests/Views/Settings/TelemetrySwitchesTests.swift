import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("TelemetrySwitches")
struct TelemetrySwitchesTests {
  private func device(base: UInt8, location: UInt8 = 0, environment: UInt8 = 0) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "Base Camp",
      firmwareVersion: 8,
      firmwareVersionString: "1.10",
      manufacturerName: "Test",
      buildDate: "",
      maxContacts: 100,
      maxChannels: 16,
      frequency: 0,
      bandwidth: 0,
      spreadingFactor: 0,
      codingRate: 0,
      txPower: 22,
      maxTxPower: 22,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      clientRepeat: false,
      pathHashMode: 0,
      manualAddContacts: false,
      autoAddConfig: 0,
      autoAddMaxHops: 0,
      multiAcks: 0,
      telemetryModeBase: base,
      telemetryModeLoc: location,
      telemetryModeEnv: environment,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }

  @Test
  func `Turning requests on opens them to everyone, unless trusted-only is in force`() {
    let off = TelemetrySwitches.modes(device(base: 0), base: true)
    #expect(off.base == 2)
    let trusted = TelemetrySwitches.modes(device(base: 1, location: 1), location: false)
    #expect(trusted.base == 1)
    #expect(trusted.location == 0)
  }

  @Test
  func `Trusted-only moves every switch that is on to the trusted level, and back`() {
    let everyone = device(base: 2, location: 2, environment: 0)
    let trusted = TelemetrySwitches.modes(everyone, trustedOnly: true)
    #expect([trusted.base, trusted.location, trusted.environment] == [1, 1, 0])
    let back = TelemetrySwitches.modes(device(base: 1, location: 1), trustedOnly: false)
    #expect([back.base, back.location, back.environment] == [2, 2, 0])
  }

  @Test
  func `Switch state reads the device's modes`() {
    #expect(TelemetrySwitches.isOn(1))
    #expect(!TelemetrySwitches.isOn(0))
    #expect(TelemetrySwitches.isTrustedOnly(device(base: 1)))
    #expect(!TelemetrySwitches.isTrustedOnly(device(base: 2)))
  }
}
