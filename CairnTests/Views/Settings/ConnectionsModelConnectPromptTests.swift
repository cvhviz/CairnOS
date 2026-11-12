import CairnServices
import Foundation
import Testing
@testable import Cairn

@MainActor
@Suite("Connections connect prompt")
struct ConnectionsModelConnectPromptTests {
  private func row(named name: String) -> SavedRadioRow {
    let id = UUID()
    let device = DeviceDTO(
      id: id,
      radioID: UUID(),
      publicKey: Data(repeating: 0x07, count: 32),
      nodeName: name,
      firmwareVersion: 8,
      firmwareVersionString: "v1.11.0",
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
      connectionMethods: [.bluetooth(peripheralUUID: id, displayName: nil)]
    )
    return SavedRadioRow(
      device: device,
      records: [device],
      methods: device.connectionMethods,
      displayName: name,
      advertisedName: nil,
      isConnected: false,
      isDefault: false
    )
  }

  @Test
  func `a tapped radio asks before connecting`() {
    let model = ConnectionsModel()
    let radio = row(named: "Basecamp")

    model.requestConnect(radio, appState: AppState())

    #expect(model.confirmingConnect == radio, "The tap should ask, not connect")
    #expect(model.transportSwitch == nil)
  }
}
