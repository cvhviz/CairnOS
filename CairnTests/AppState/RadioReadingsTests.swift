import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

/// The title bar and Settings dashboard show battery and TX power only for a live session:
/// auto-reconnect keeps `connectedDevice`, so it alone would present the last readings as current.
@Suite("Radio Readings")
@MainActor
struct RadioReadingsTests {
  private static func makeDevice(id: UUID = UUID()) -> DeviceDTO {
    DeviceDTO(
      id: id,
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
      telemetryModeBase: 0,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }

  @Test(arguments: [DeviceConnectionState.connecting, .connected, .syncing, .disconnected])
  func `battery is hidden while the session is not ready`(_ state: DeviceConnectionState) {
    let appState = AppState()
    appState.connectionManager.setTestState(connectionState: state, connectedDevice: Self.makeDevice())
    appState.batteryMonitor.deviceBattery = BatteryInfo(level: 4000)

    #expect(!appState.isRadioReady)
    #expect(appState.radioBatteryPercent == nil)
    #expect(appState.radioBatteryVoltage == nil)
  }

  @Test
  func `battery shows once the session is ready`() {
    let appState = AppState()
    appState.connectionManager.setTestState(connectionState: .ready, connectedDevice: Self.makeDevice())
    appState.batteryMonitor.deviceBattery = BatteryInfo(level: 4000)

    #expect(appState.isRadioReady)
    #expect(appState.radioBatteryPercent != nil)
    #expect(appState.radioBatteryVoltage != nil)
  }

  @Test
  func `ending the session drops the last battery reading`() {
    let monitor = BatteryMonitor()
    monitor.deviceBattery = BatteryInfo(level: 4000)

    monitor.clearThresholds()

    #expect(monitor.deviceBattery == nil)
  }

  @Test
  func `switching radios drops the previous radio's reading, re-wiring the same one keeps it`() async throws {
    let monitor = BatteryMonitor()
    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: MockTransport())
    )
    let radioA = Self.makeDevice()
    monitor.start(services: services) { radioA }
    monitor.deviceBattery = BatteryInfo(level: 4000)

    monitor.start(services: services) { radioA }
    #expect(monitor.deviceBattery != nil)

    let radioB = Self.makeDevice()
    monitor.start(services: services) { radioB }
    #expect(monitor.deviceBattery == nil)
    monitor.stop()
  }
}

/// TX power texts: the radio chip's setting is what the radio reports and the app sends; a board with
/// a PA after the chip shows the power at the antenna first, and never "30" for a T096.
@Suite("TX power text")
@MainActor
struct TxPowerTextTests {
  @Test
  func `a T096 at its default reads at the antenna with the setting after`() {
    #expect(TxPowerText.reading(setting: 9, model: "Heltec T096")
      == L10n.Settings.Radio.TxPower.atAntennaWithSetting(TxPowerText.dBm(23), TxPowerText.dBm(9)))
  }

  @Test
  func `a T096 at its cap reads 28 dBm at the antenna`() {
    #expect(TxPowerText.reading(setting: 16, model: "Heltec T096")
      == L10n.Settings.Radio.TxPower.atAntennaWithSetting(TxPowerText.dBm(28), TxPowerText.dBm(16)))
  }

  @Test(arguments: ["Heltec V3", "RAK4631", "Seeed Wio Tracker L2", "LilyGO T-Display SF32"])
  func `a board without a PA reads plain dBm`(model: String) {
    #expect(TxPowerText.reading(setting: 22, model: model) == TxPowerText.dBm(22))
  }

  @Test
  func `a remote node's figure leads when it reports one`() {
    #expect(TxPowerText.remoteDetail(setting: 9, antenna: 23)
      == "\(L10n.Settings.Dashboard.txPower) \(L10n.Settings.Radio.TxPower.atAntennaWithSetting(TxPowerText.dBm(23), TxPowerText.dBm(9)))")
    #expect(TxPowerText.remoteDetail(setting: 22, antenna: 22) == "\(L10n.Settings.Dashboard.txPower) \(TxPowerText.dBm(22))")
  }

  @Test
  func `a remote node without antenna figures is labelled the radio setting`() {
    #expect(TxPowerText.remoteDetail(setting: 22, antenna: nil) == L10n.Settings.Radio.TxPower.detailSetting(TxPowerText.dBm(22)))
  }

  @Test
  func `the log export carries both figures on a PA board`() {
    #expect(LogExportService.txPowerLine(setting: 9, max: 16, model: "Heltec T096")
      == "9 dBm setting (23 dBm at antenna), max 16 (28 dBm at antenna)")
    #expect(LogExportService.txPowerLine(setting: 22, max: 22, model: "RAK4631") == "22 dBm (max 22)")
  }

  @Test
  func `the connected radio's maximum is read through its curve`() {
    let appState = AppState()
    var device = RadioReadingsTests.makeTestDevice()
    device.manufacturerName = "Heltec T096"
    device.txPower = 9
    device.maxTxPower = 16
    appState.connectionManager.setTestState(connectionState: .ready, connectedDevice: device)
    #expect(appState.radioTxPower == 23)
    #expect(appState.radioMaxTxPower == 28)
  }
}

extension RadioReadingsTests {
  static func makeTestDevice() -> DeviceDTO { makeDevice() }
}
