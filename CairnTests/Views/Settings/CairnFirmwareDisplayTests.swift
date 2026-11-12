import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("Cairn firmware display")
struct CairnFirmwareDisplayTests {
  private static func makeDevice(cairnBuild: UInt16?) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "Basecamp",
      firmwareVersion: 13,
      firmwareVersionString: "v1.17.1",
      manufacturerName: "LilyGO T-Display SF32",
      buildDate: "5 Oct 2026",
      maxContacts: 350,
      maxChannels: 40,
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
    ).copy { $0.cairnBuild = cairnBuild }
  }

  @Test
  func `Cairn firmware is named by its build`() {
    let device = Self.makeDevice(cairnBuild: 107)
    #expect(device.cairnFirmwareName == "Cairn 107")
    #expect(device.firmwareDisplayName == "Cairn 107")
    #expect(HomeStatusLines.modelLine(device) == "LilyGO T-Display SF32 · Cairn 107")
  }

  @Test
  func `A Cairn dev build reads as dev`() {
    #expect(Self.makeDevice(cairnBuild: 0).cairnFirmwareName == "Cairn dev")
  }

  @Test
  func `Other firmware keeps its version string`() {
    let device = Self.makeDevice(cairnBuild: nil)
    #expect(device.cairnFirmwareName == nil)
    #expect(device.firmwareDisplayName == "v1.17.1")
    #expect(HomeStatusLines.modelLine(device) == "LilyGO T-Display SF32 · v1.17.1")
  }
}

@Suite("Cairn sensor readings")
struct CairnSensorReadingTests {
  /// Self telemetry as the T-Display SF32 sends it, all on channel 1: battery, BME280
  /// temperature, humidity and pressure, then steps, tilt and motion from the IMU.
  private static let sf32Frame = Data([
    0x01, 116, 0x01, 0x9A, // voltage 4.10 V
    0x01, 103, 0x00, 0xD2, // temperature 21.0 °C
    0x01, 104, 0x5A, // humidity 45 %
    0x01, 115, 0x27, 0x94, // pressure 1013.2 hPa
    0x01, 100, 0x00, 0x00, 0x10, 0xE1, // generic sensor: 4321 steps
    0x01, 113, 0xFF, 0x52, 0x00, 0x00, 0x03, 0xDB, // gravity (-0.174, 0, 0.987): 10° nose-up
    0x01, 102, 0x01, // presence: moving
  ])

  @Test
  func `Every SF32 reading decodes`() {
    let points = LPPDecoder.decode(Self.sf32Frame)
    #expect(points.map(\.type) == [
      .voltage, .temperature, .humidity, .barometer, .genericSensor, .accelerometer, .presence,
    ])
  }

  @Test
  func `The IMU readings read as steps, tilt and motion`() throws {
    let readings = LPPDecoder.decode(Self.sf32Frame).compactMap(CairnSensorReading.init)
    #expect(readings == [.steps(4321), .tilt(pitch: 10, roll: 0), .motion(isMoving: true)])
  }

  @Test
  func `Roll comes from the sideways component`() throws {
    let point = LPPDataPoint(channel: 1, type: .accelerometer, value: .vector3(x: 0, y: 0.5, z: 0.866))
    #expect(CairnSensorReading(point) == .tilt(pitch: 0, roll: 30))
  }

  /// The RC52's GA01 sensors: tilt, still, and a magnetometer heading of 135°.
  private static let rc52Frame = Data([
    0x01, 113, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, // gravity (0, 0, 1): level
    0x01, 102, 0x00, // presence: still
    0x01, 132, 0x00, 0x87, // direction 135°
  ])

  @Test
  func `The RC52 heading reads as a compass heading`() {
    let readings = LPPDecoder.decode(Self.rc52Frame).compactMap(CairnSensorReading.init)
    #expect(readings == [.tilt(pitch: 0, roll: 0), .motion(isMoving: false), .heading(135)])
    #expect(CairnSensorReading.heading(135).value.hasPrefix("135\u{00B0} "))
  }

  @Test
  func `A plain direction reading keeps its degree sign`() {
    let point = LPPDataPoint(channel: 2, type: .direction, value: .integer(270))
    #expect(point.formattedValue == "270\u{00B0}")
  }

  @Test
  func `Readings on other channels keep their plain meaning`() {
    let point = LPPDataPoint(channel: 2, type: .genericSensor, value: .integer(12))
    #expect(CairnSensorReading(point) == nil)
  }
}

@Suite("Simulator radio readings")
@MainActor
struct SimulatorRadioReadingsTests {
  @Test
  func `The simulator radio is an SF32 on Cairn firmware`() {
    let device = MockDataProvider.simulatorDevice
    #expect(device.isCairnFirmware)
    #expect(HomeStatusLines.modelLine(device) == "LilyGO T-Display SF32 · Cairn 107")
  }

  @Test
  func `Simulator telemetry fills the sensor strip with the SF32's readings`() {
    let readings = DeviceReadingsModel()
    readings.loadSimulated(telemetry: MockDataProvider.selfTelemetryFrame)
    let chips = readings.sensorChipGroups(cairnFirmware: true).flatMap(\.chips)
    let labels = chips.map(\.label)
    #expect(labels.contains(L10n.RemoteNodes.RemoteNodes.Status.Sensor.steps))
    #expect(labels.contains(L10n.RemoteNodes.RemoteNodes.Status.Sensor.pitchRoll))
    #expect(labels.contains(L10n.RemoteNodes.RemoteNodes.Status.Sensor.motion))
    #expect(chips.contains { if case .gps = $0.kind { true } else { false } })
    #expect(chips.count == 7, "everything but the battery voltage")
    #expect(!readings.radioDidNotAnswer)
  }
}
