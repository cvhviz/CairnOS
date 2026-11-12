import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Radio settings validation")
@MainActor
struct RadioSettingsValidatorTests {
  @Test
  func `a typical EU profile passes`() {
    let errors = RadioSettingsValidator.validate(frequency: 869.525, bandwidth: 250, spreadingFactor: 10, codingRate: 5)
    #expect(!errors.hasErrors)
  }

  @Test
  func `nil fields are unloaded, not wrong`() {
    let errors = RadioSettingsValidator.validate(frequency: nil, bandwidth: nil, spreadingFactor: nil, codingRate: nil)
    #expect(!errors.hasErrors)
  }

  @Test(arguments: [0.0, 100.0, 9999.0, Double.infinity, -869.5])
  func `a frequency outside the companion's range is refused`(mhz: Double) {
    let errors = RadioSettingsValidator.validate(frequency: mhz, bandwidth: 250, spreadingFactor: 10, codingRate: 5)
    #expect(errors.frequency != nil)
    #expect(errors.bandwidth == nil && errors.spreadingFactor == nil && errors.codingRate == nil)
  }

  @Test
  func `the range bounds themselves pass`() {
    let range = RadioSettingsValidator.frequencyRangeMHz
    #expect(RadioSettingsValidator.isFrequencyAllowed(range.lowerBound))
    #expect(RadioSettingsValidator.isFrequencyAllowed(range.upperBound))
  }

  @Test(arguments: [3.0, 251.0, 1000.0, -125.0])
  func `a bandwidth off the radio's list is refused`(kHz: Double) {
    let errors = RadioSettingsValidator.validate(frequency: 869.525, bandwidth: kHz, spreadingFactor: 10, codingRate: 5)
    #expect(errors.bandwidth != nil)
  }

  @Test
  func `a bandwidth the firmware reports a hair off still passes`() {
    // 7.799 kHz is the firmware's float for 7.8 kHz.
    #expect(RadioSettingsValidator.isBandwidthAllowed(7.799))
    #expect(RadioSettingsValidator.isBandwidthAllowed(250))
  }

  @Test(arguments: [4, 13, 0, 99])
  func `a spreading factor outside 5 to 12 is refused`(sf: Int) {
    let errors = RadioSettingsValidator.validate(frequency: 869.525, bandwidth: 250, spreadingFactor: sf, codingRate: 5)
    #expect(errors.spreadingFactor != nil)
  }

  @Test(arguments: [4, 9, 0])
  func `a coding rate outside 5 to 8 is refused`(cr: Int) {
    let errors = RadioSettingsValidator.validate(frequency: 869.525, bandwidth: 250, spreadingFactor: 10, codingRate: cr)
    #expect(errors.codingRate != nil)
  }

  @Test
  func `change lines name only what changes`() {
    let old = RadioSettingsValues(frequency: 869.525, bandwidth: 250, spreadingFactor: 10, codingRate: 5, txPower: 20)
    let new = RadioSettingsValues(frequency: 868.0, bandwidth: 250, spreadingFactor: 11, codingRate: 5, txPower: 20)
    let lines = old.changeLines(to: new)
    #expect(lines.count == 2)
    #expect(lines[0].contains("868"))
    #expect(lines[1].contains("SF10") && lines[1].contains("SF11"))
  }

  @Test
  func `the view model refuses to send an out-of-range frequency`() async {
    let settings = NodeSettingsViewModel()
    var sent: [String] = []
    settings.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(), publicKey: Data(repeating: 1, count: 32), name: "R", role: .repeater,
        isConnected: true, permissionLevel: .admin
      ),
      sendCommand: { _, command, _ in sent.append(command); return "OK" },
      sendRawCommand: { _, command, _ in sent.append(command); return "OK" }
    )
    settings.frequency = 12
    settings.bandwidth = 250
    settings.spreadingFactor = 10
    settings.codingRate = 5
    settings.radioSettingsModified = true

    settings.requestApplyRadioSettings()
    #expect(settings.pendingRadioChange == nil, "No confirmation for a value the node can't take")
    #expect(settings.radioValidation.frequency != nil)

    await settings.applyRadioSettings()
    #expect(sent.isEmpty, "set radio must never go out with a bad frequency")
  }

  @Test
  func `a valid change waits for confirmation, then goes out`() async {
    let settings = NodeSettingsViewModel()
    var sent: [String] = []
    settings.configure(
      session: RemoteNodeSessionDTO(
        radioID: UUID(), publicKey: Data(repeating: 1, count: 32), name: "R", role: .repeater,
        isConnected: true, permissionLevel: .admin
      ),
      sendCommand: { _, command, _ in sent.append(command); return "OK" },
      sendRawCommand: { _, command, _ in sent.append(command); return "OK" }
    )
    settings.frequency = 869.525
    settings.bandwidth = 250
    settings.spreadingFactor = 10
    settings.codingRate = 5
    settings.radioSettingsModified = true

    settings.requestApplyRadioSettings()
    #expect(settings.pendingRadioChange != nil)
    #expect(sent.isEmpty)

    await settings.applyRadioSettings()
    #expect(sent == ["set radio 869.525,250.0,10,5"])
    #expect(settings.successOffersReboot)
    #expect(!settings.radioSettingsModified)
  }
}
