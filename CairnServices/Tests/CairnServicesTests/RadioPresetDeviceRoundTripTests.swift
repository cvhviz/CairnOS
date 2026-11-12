import Foundation
import MeshCore
import Testing
@testable import CairnServices

/// The radio reports its frequency in kHz and bandwidth in Hz as integers; the parser turns them
/// into MHz and kHz doubles, and the device model turns them back. That trip must give the
/// radio's own integers, or a custom frequency shows 1 kHz low.
@Suite("RadioPreset device round trip")
struct RadioPresetDeviceRoundTripTests {
  private static func selfInfo(frequencyKHz: UInt32, bandwidthHz: UInt32) -> MeshCore.SelfInfo {
    MeshCore.SelfInfo(
      advertisementType: 1,
      txPower: 20,
      maxTxPower: 22,
      publicKey: Data(repeating: 1, count: 32),
      latitude: 0,
      longitude: 0,
      multiAcks: 0,
      advertisementLocationPolicy: 0,
      telemetryModeEnvironment: 0,
      telemetryModeLocation: 0,
      telemetryModeBase: 0,
      manualAddContacts: false,
      // As the parser builds them from the firmware's integers.
      radioFrequency: Double(frequencyKHz) / 1000,
      radioBandwidth: Double(bandwidthHz) / 1000,
      radioSpreadingFactor: 9,
      radioCodingRate: 5,
      name: "Radio"
    )
  }

  @Test
  func `frequencies that truncation dropped by 1 kHz come back exact`() {
    for frequency: UInt32 in [512_002, 512_007, 512_011, 869_618, 910_525, 927_875] {
      let device = MockDataProvider.simulatorDevice.updating(from: Self.selfInfo(frequencyKHz: frequency, bandwidthHz: 62_500))
      #expect(device.frequency == frequency)
      #expect(device.bandwidth == 62_500)
    }
  }

  @Test
  func `every integer frequency from 400 to 1000 MHz round-trips`() {
    var misses: [UInt32] = []
    for frequency in UInt32(400_000)...UInt32(1_000_000) {
      let info = Self.selfInfo(frequencyKHz: frequency, bandwidthHz: 125_000)
      if info.radioFrequencyKHz != frequency { misses.append(frequency) }
    }
    #expect(misses.isEmpty, "first misses: \(misses.prefix(5))")
  }

  @Test
  func `every catalog and repeat preset round-trips through the device model`() {
    for preset in RadioPresets.all + RadioPresets.repeatPresets {
      let info = Self.selfInfo(frequencyKHz: preset.frequencyKHz, bandwidthHz: preset.bandwidthHz)
      let device = MockDataProvider.simulatorDevice.updating(from: info)
      #expect(device.frequency == preset.frequencyKHz, "\(preset.id)")
      #expect(device.bandwidth == preset.bandwidthHz, "\(preset.id)")
    }
  }
}
