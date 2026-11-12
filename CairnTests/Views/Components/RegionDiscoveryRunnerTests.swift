import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("RegionDiscoveryRunner outcome handling")
@MainActor
struct RegionDiscoveryRunnerTests {
  @Test
  func `new regions are offered for picking`() {
    let result = RegionDiscoveryRunner.result(
      for: .completed(newRegions: ["east", "west"], allRepeatersTableFull: false)
    )
    #expect(result == .found(["east", "west"]))
  }

  @Test
  func `new regions win over a full contact table`() {
    let result = RegionDiscoveryRunner.result(
      for: .completed(newRegions: ["east"], allRepeatersTableFull: true)
    )
    #expect(result == .found(["east"]))
  }

  @Test
  func `nothing new says so`() {
    let result = RegionDiscoveryRunner.result(
      for: .completed(newRegions: [], allRepeatersTableFull: false)
    )
    #expect(result == .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.noNewRegions))
  }

  @Test
  func `nothing new with every table full blames the contact list`() {
    let result = RegionDiscoveryRunner.result(
      for: .completed(newRegions: [], allRepeatersTableFull: true)
    )
    #expect(result == .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.errRadioContactsFull))
  }

  @Test
  func `failures map to their messages`() {
    #expect(
      RegionDiscoveryRunner.result(for: .noRepeatersResponded)
        == .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.noRepeatersResponded)
    )
    #expect(
      RegionDiscoveryRunner.result(for: .errorLoadingRepeaters)
        == .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.errLoadingRepeaters)
    )
  }

  @Test
  func `a failed send stays silent`() {
    #expect(RegionDiscoveryRunner.result(for: .sendFailed) == .nothingFound(message: nil))
  }

  // MARK: - Official firmware without the commands

  @Test
  func `a radio without anonymous requests sends nothing and says it needs v1.12`() {
    // Region queries go out as CMD_SEND_ANON_REQ, first in companion-v1.12.0 (VER_CODE 8, as
    // v1.10 and v1.11 also report).
    let needsFirmware = RegionDiscoveryRunner.Result.nothingFound(message: L10n.Tools.Tools.RegionDiscovery.needsFirmware)
    #expect(RegionDiscoveryRunner.preflightResult(device: Self.device(firmwareVersion: 5, firmwareVersionString: "v1.7.0")) == needsFirmware)
    #expect(RegionDiscoveryRunner.preflightResult(device: Self.device(firmwareVersion: 7, firmwareVersionString: "v1.9.0")) == needsFirmware)
    #expect(RegionDiscoveryRunner.preflightResult(device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.11.0")) == needsFirmware)
    #expect(RegionDiscoveryRunner.preflightResult(device: Self.device(firmwareVersion: 8, firmwareVersionString: "v1.12.0")) == nil)
    #expect(RegionDiscoveryRunner.preflightResult(device: Self.device(firmwareVersion: 14, firmwareVersionString: "v1.18.0")) == nil)
  }

  @Test
  func `firmware that can't scan says so`() {
    #expect(
      RegionDiscoveryRunner.result(for: .discoverUnsupported)
        == .nothingFound(message: L10n.Tools.Tools.RegionDiscovery.scanUnsupported)
    )
  }

  @Test
  func `without a scan the repeaters heard nearby are asked, keeping the reason when none answer`() {
    let scanUnsupported = RegionDiscoveryRunner.Result.nothingFound(message: L10n.Tools.Tools.RegionDiscovery.scanUnsupported)
    #expect(RegionDiscoveryRunner.unsupportedResult(for: .completed(newRegions: ["east"], allRepeatersTableFull: false)) == .found(["east"]))
    #expect(RegionDiscoveryRunner.unsupportedResult(for: .noRepeatersResponded) == scanUnsupported)
    #expect(RegionDiscoveryRunner.unsupportedResult(for: .sendFailed) == scanUnsupported)
    #expect(
      RegionDiscoveryRunner.unsupportedResult(for: .errorLoadingRepeaters)
        == .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.errLoadingRepeaters)
    )

    // The cooldown fallback keeps its own reason.
    #expect(
      RegionDiscoveryRunner.cooldownResult(for: .noRepeatersResponded)
        == .nothingFound(message: L10n.Tools.Tools.RegionDiscovery.cooldown)
    )
  }

  /// A radio as it identifies itself: official companion firmware's FIRMWARE_VER_CODE and version string.
  private static func device(firmwareVersion: UInt8, firmwareVersionString: String) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "TestDevice",
      firmwareVersion: firmwareVersion,
      firmwareVersionString: firmwareVersionString,
      manufacturerName: "TestMfg",
      buildDate: "01 Jan 2025",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: false,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }
}
