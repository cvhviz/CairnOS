import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

/// The capabilities the app reads from a device's firmware code and version string, for every
/// official companion release from v1.7.0 to v1.18.0 and the Cairn fork, each device built from
/// the release's own device-info reply.
@Suite("Stock firmware capabilities")
struct StockFirmwareCapabilityTests {
  /// What each release offers, from its tag (`git show companion-vX:examples/companion_radio/MyMesh.cpp`):
  /// CMD_SEND_CONTROL_DATA 55 from v1.10.0, CMD_GET_STATS 56 from v1.11.0, CMD_SEND_ANON_REQ 57
  /// from v1.12.0, MAX_FRAME_SIZE 176 (173 raw bytes per 0x88) from v1.16.0, 172 (169) before.
  private static let expected: [String: (discover: Bool, stats: Bool, anon: Bool, forward: Int)] = [
    "companion-v1.7.0": (false, false, false, 169),
    "companion-v1.7.4": (false, false, false, 169),
    "companion-v1.8.0": (false, false, false, 169),
    "companion-v1.9.0": (false, false, false, 169),
    "companion-v1.10.0": (true, false, false, 169),
    "companion-v1.11.0": (true, true, false, 169),
    "companion-v1.12.0": (true, true, true, 169),
    "companion-v1.13.0": (true, true, true, 169),
    "companion-v1.14.0": (true, true, true, 169),
    "companion-v1.14.1": (true, true, true, 169),
    "companion-v1.15.0": (true, true, true, 169),
    "companion-v1.16.0": (true, true, true, 173),
    "companion-v1.17.0": (true, true, true, 173),
    "companion-v1.17.1": (true, true, true, 173),
    "companion-v1.18.0": (true, true, true, 173),
  ]

  @Test(arguments: StockCompanionFrames.releases)
  func `each official release reports what its firmware offers`(release: StockCompanionFrames.Release) throws {
    let device = try #require(StockCompanionFrames.device(fromDeviceInfo: release.deviceInfo))
    let expected = try #require(Self.expected[release.tag])

    #expect(device.firmwareVersion == release.verCode)
    #expect(device.firmwareVersionString == release.version)
    #expect(!device.isCairnFirmware)
    #expect(device.supportsNodeDiscover == expected.discover)
    #expect(device.supportsStats == expected.stats)
    #expect(device.supportsAnonymousRequests == expected.anon)
    #expect(device.maxForwardedRxPacketLength == expected.forward)
  }

  @Test
  func `every release in the table is covered`() {
    #expect(Set(StockCompanionFrames.releases.map(\.tag)) == Set(Self.expected.keys))
  }

  @Test
  func `the code-8 window is told apart by the version string`() {
    let v1_10 = StockCompanionFrames.device("companion-v1.10.0")
    let v1_11 = StockCompanionFrames.device("companion-v1.11.0")
    let v1_12 = StockCompanionFrames.device("companion-v1.12.0")
    #expect([v1_10, v1_11, v1_12].allSatisfy { $0.firmwareVersion == 8 })

    #expect(v1_10.supportsNodeDiscover && !v1_10.supportsStats && !v1_10.supportsAnonymousRequests)
    #expect(v1_11.supportsNodeDiscover && v1_11.supportsStats && !v1_11.supportsAnonymousRequests)
    #expect(v1_12.supportsNodeDiscover && v1_12.supportsStats && v1_12.supportsAnonymousRequests)
  }

  @Test
  func `the Cairn fork offers everything v1.18 does`() throws {
    let device = try #require(StockCompanionFrames.device(fromDeviceInfo: StockCompanionFrames.cairnForkDeviceInfo(build: 120)))

    #expect(device.isCairnFirmware)
    #expect(device.cairnBuild == 120)
    #expect(device.supportsNodeDiscover)
    #expect(device.supportsStats)
    #expect(device.supportsAnonymousRequests)
    #expect(device.maxForwardedRxPacketLength == 173)
  }

  @Test
  func `a fork that rewrites the version string still follows its firmware code`() {
    let code9 = DeviceDTO.testDevice(firmwareVersion: 9, firmwareVersionString: "custom-build")
    #expect(code9.supportsNodeDiscover && code9.supportsStats && code9.supportsAnonymousRequests)
    #expect(code9.maxForwardedRxPacketLength == 169)

    let code13 = DeviceDTO.testDevice(firmwareVersion: 13, firmwareVersionString: "")
    #expect(code13.maxForwardedRxPacketLength == 173)

    // Code 8 without a readable version is taken as v1.10, the oldest release with that code.
    let code8 = DeviceDTO.testDevice(firmwareVersion: 8, firmwareVersionString: "custom-build")
    #expect(code8.supportsNodeDiscover && !code8.supportsStats && !code8.supportsAnonymousRequests)
  }
}
