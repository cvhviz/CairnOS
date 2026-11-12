import Foundation
@testable import CairnServices
import Testing

@Suite("SavedRadioLink")
struct SavedRadioLinkTests {
  private let peripheral = UUID()
  private let wifi = ConnectionMethod.wifi(host: "192.168.1.20", port: 5000, displayName: nil)

  private func saved(_ methods: [ConnectionMethod], id: UUID = UUID()) -> DeviceDTO {
    var device = DeviceDTO.testDevice(id: id)
    device.connectionMethods = methods
    return device
  }

  @Test
  func `WiFi reaching a radio saved over Bluetooth is news`() {
    let notice = SavedRadioLink.notice(
      existingByID: nil,
      existingByKey: saved([.bluetooth(peripheralUUID: peripheral, displayName: nil)], id: peripheral),
      newDeviceID: UUID(),
      newMethods: [wifi],
      radioName: "Basecamp"
    )

    #expect(notice?.radioName == "Basecamp")
    #expect(notice?.newTransport == .wifi)
    #expect(notice?.savedTransports == [.bluetooth])
  }

  @Test
  func `A record already known by this connection's ID is not news`() {
    let record = saved([wifi])
    #expect(SavedRadioLink.notice(
      existingByID: record, existingByKey: nil, newDeviceID: record.id, newMethods: [wifi], radioName: "A"
    ) == nil)
  }

  @Test
  func `Switching between transports the radio already has is not news`() {
    let both = saved([.bluetooth(peripheralUUID: peripheral, displayName: nil), wifi])
    #expect(SavedRadioLink.notice(
      existingByID: nil,
      existingByKey: both,
      newDeviceID: peripheral,
      newMethods: [.bluetooth(peripheralUUID: peripheral, displayName: nil)],
      radioName: "A"
    ) == nil)
  }

  @Test
  func `A backup shadow with no transport is not news`() {
    #expect(SavedRadioLink.notice(
      existingByID: nil, existingByKey: saved([]), newDeviceID: UUID(), newMethods: [wifi], radioName: "A"
    ) == nil)
  }

  @Test
  func `A new WiFi address for a WiFi radio is not news`() {
    let other = ConnectionMethod.wifi(host: "10.0.0.9", port: 5000, displayName: nil)
    #expect(SavedRadioLink.notice(
      existingByID: nil, existingByKey: saved([other]), newDeviceID: UUID(), newMethods: [wifi], radioName: "A"
    ) == nil)
  }

  @Test
  func `Transports list Bluetooth first, each once`() {
    let methods: [ConnectionMethod] = [wifi, .bluetooth(peripheralUUID: peripheral, displayName: nil), wifi]
    #expect(SavedRadioLink.orderedTransports(methods) == [.bluetooth, .wifi])
    #expect(methods[1].bluetoothPeripheralID == peripheral)
    #expect(wifi.bluetoothPeripheralID == nil)
  }
}
