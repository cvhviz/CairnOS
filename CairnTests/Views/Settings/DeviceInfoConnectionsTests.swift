@testable import Cairn
import Testing

/// Device Info's way to Connections (`DeviceInfoConnections`): where its toolbar's Connections
/// button goes inside Settings.
@Suite("Device Info connections")
struct DeviceInfoConnectionsTests {
  @Test
  func `from Device Info on the hub, Connections goes over it so Back returns there`() {
    #expect(DeviceInfoConnections.settingsPath(openingConnectionsFrom: [.deviceInfo]) == [.deviceInfo, .connections])
  }

  @Test
  func `from Device Info opened on Connections, it goes back to that Connections`() {
    #expect(DeviceInfoConnections.settingsPath(openingConnectionsFrom: [.connections, .deviceInfo]) == [.connections])
    #expect(
      DeviceInfoConnections.settingsPath(openingConnectionsFrom: [.deviceInfo, .connections, .deviceInfo])
        == [.deviceInfo, .connections]
    )
  }

  @Test
  func `pages over Device Info go`() {
    #expect(
      DeviceInfoConnections.settingsPath(openingConnectionsFrom: [.deviceInfo, .firmwareUpdate])
        == [.deviceInfo, .connections]
    )
  }

  @Test
  func `without Device Info on the path, Connections goes on top`() {
    #expect(DeviceInfoConnections.settingsPath(openingConnectionsFrom: []) == [.connections])
    #expect(DeviceInfoConnections.settingsPath(openingConnectionsFrom: [.about]) == [.about, .connections])
  }
}
