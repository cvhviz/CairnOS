@testable import Cairn
import Testing

/// `get bootloader.ver` replies, and which bootloaders leave an nRF52 node waiting for its reset
/// button after an over-the-air update.
@Suite("Node bootloader version")
struct NodeBootloaderVersionTests {
  @Test(arguments: [
    ("> 0.9.0-2-g836c8dc-dirty", "0.9.0-2-g836c8dc-dirty"),
    ("> 0.9.2-OTAFIX2.3-BP1.4\n", "0.9.2-OTAFIX2.3-BP1.4"),
    ("0.6.1", "0.6.1"),
  ])
  func `a version reply gives the version`(reply: String, version: String) {
    #expect(NodeSettingsViewModel.bootloaderVersion(fromReply: reply) == version)
  }

  @Test(arguments: ["> unknown", "Error: unsupported", "Error: unknown config: bootloader.ver", "", ">"])
  func `no version for boards and firmware without one`(reply: String) {
    #expect(NodeSettingsViewModel.bootloaderVersion(fromReply: reply) == nil)
  }

  @Test(arguments: ["0.9.0-2-g836c8dc-dirty", "0.6.1", "0.9.2-OTAFIX1.1", "0.9.2-OTAFIX"])
  func `stock and early OTAFIX bootloaders need a reset after an update`(version: String) {
    #expect(NodeSettingsViewModel.bootloaderNeedsManualRestart(version))
  }

  @Test(arguments: ["0.9.2-OTAFIX2.3-BP1.4", "0.9.2-otafix2.0", "0.9.3-OTAFIX10.0"])
  func `OTAFIX 2 and later restart on their own`(version: String) {
    #expect(!NodeSettingsViewModel.bootloaderNeedsManualRestart(version))
  }
}
