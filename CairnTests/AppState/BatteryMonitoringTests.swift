import Foundation
@testable import Cairn
@testable import CairnServices
import MeshCore
import Testing

@Suite("Battery Monitoring Tests")
@MainActor
struct BatteryMonitoringTests {
  // MARK: - Default State

  @Test
  func `deviceBattery is nil by default`() {
    let appState = AppState()
    #expect(appState.batteryMonitor.deviceBattery == nil)
  }

  @Test
  func `activeBatteryOCVArray returns liIon default when no device connected`() {
    let appState = AppState()
    #expect(appState.batteryMonitor.activeBatteryOCVArray(for: appState.connectedDevice) == OCVPreset.liIon.ocvArray)
  }

  // MARK: - fetchDeviceBattery

  @Test
  func `fetchDeviceBattery is no-op when services is nil`() async {
    let appState = AppState()

    await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)

    #expect(appState.batteryMonitor.deviceBattery == nil)
  }

  @Test
  func `fetchDeviceBattery does not crash when called on fresh state`() async {
    let appState = AppState()
    #expect(appState.services == nil)

    // Should not throw or crash
    await appState.batteryMonitor.fetchDeviceBattery(services: appState.services, device: appState.connectedDevice)
    #expect(appState.batteryMonitor.deviceBattery == nil)
  }

  @Test
  func `A failed fetch keeps the last good reading`() async throws {
    let monitor = BatteryMonitor()
    let services = try makeServices()
    let reading = BatteryInfo(level: 3700)
    monitor.deviceBattery = reading

    // The mock transport is not connected, so the read throws.
    await monitor.fetchDeviceBattery(services: services, device: nil)

    #expect(monitor.deviceBattery == reading)
  }

  @Test
  func `Ending the session drops the reading`() {
    let monitor = BatteryMonitor()
    monitor.deviceBattery = BatteryInfo(level: 3700)

    monitor.clearThresholds()

    #expect(monitor.deviceBattery == nil)
  }

  // MARK: - Battery State Observation

  @Test
  func `deviceBattery can be set directly for testing`() {
    let appState = AppState()
    let battery = BatteryInfo(level: 3700)

    appState.batteryMonitor.deviceBattery = battery

    #expect(appState.batteryMonitor.deviceBattery == battery)
    #expect(appState.batteryMonitor.deviceBattery?.level == 3700)
  }

  @Test
  func `deviceBattery can be cleared`() {
    let appState = AppState()
    appState.batteryMonitor.deviceBattery = BatteryInfo(level: 3700)

    appState.batteryMonitor.deviceBattery = nil

    #expect(appState.batteryMonitor.deviceBattery == nil)
  }

  // MARK: - Repeated start

  private func makeServices() throws -> ServiceContainer {
    try ServiceContainer(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true)),
      radioID: UUID()
    )
  }

  @Test
  func `A second start cancels the first bootstrap instead of running beside it`() throws {
    let monitor = BatteryMonitor()
    let services = try makeServices()

    monitor.start(services: services) { nil }
    let firstBootstrap = try #require(monitor.bootstrapTask)

    // Services are wired more than once per connection.
    monitor.start(services: services) { nil }
    let secondBootstrap = try #require(monitor.bootstrapTask)

    #expect(firstBootstrap.isCancelled)
    #expect(!secondBootstrap.isCancelled)
    #expect(firstBootstrap != secondBootstrap)

    monitor.stop()
    #expect(secondBootstrap.isCancelled)
    #expect(monitor.bootstrapTask == nil)
  }

  @Test
  func `start cancels a refresh loop left running by the previous start`() throws {
    let monitor = BatteryMonitor()
    let services = try makeServices()

    monitor.startRefreshLoop(services: services) { nil }
    let refreshLoop = try #require(monitor.batteryRefreshTask)

    monitor.start(services: services) { nil }

    #expect(refreshLoop.isCancelled)
    // The new bootstrap starts its own loop once it has a reading.
    #expect(monitor.batteryRefreshTask == nil)

    monitor.stop()
  }

  @Test
  func `A threshold that already alerted on this connection does not alert again`() {
    // First bootstrap at 15%: the 20% threshold is crossed and not yet notified.
    #expect(BatteryMonitor.unannouncedThresholds(crossed: [20], alreadyNotified: []) == [20])

    // Re-wiring the same connection bootstraps again at the same level.
    #expect(BatteryMonitor.unannouncedThresholds(crossed: [20], alreadyNotified: [20]).isEmpty)

    // The level has since dropped through 10%: only the new threshold alerts.
    #expect(BatteryMonitor.unannouncedThresholds(crossed: [20, 10], alreadyNotified: [20]) == [10])
  }
}
