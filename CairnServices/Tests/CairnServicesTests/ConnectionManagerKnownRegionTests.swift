import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// `addKnownRegion` reports its outcome, so the add sheet can fail at once and say why instead of
/// waiting for a name that never reaches the list.
@Suite("ConnectionManager addKnownRegion")
@MainActor
struct ConnectionManagerKnownRegionTests {
  private static func makeServices(radioID: UUID) async throws -> ServiceContainer {
    try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: SimulatorMockTransport()),
      radioID: radioID
    )
  }

  @Test
  func `throws not connected with no radio`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()

    try await #expect {
      try await manager.addKnownRegion("socal")
    } throws: { error in
      guard let e = error as? ConnectionError, case .notConnected = e else { return false }
      return true
    }
    #expect(manager.connectedDevice == nil)
  }

  @Test
  func `adds and persists the region`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    let device = DeviceDTO.testDevice()
    let services = try await Self.makeServices(radioID: device.radioID)
    try await services.dataStore.saveDevice(device)
    manager.setTestState(services: services, connectedDevice: device)

    try await manager.addKnownRegion("socal")

    #expect(manager.connectedDevice?.knownRegions == ["socal"])
    let stored = try await services.dataStore.fetchDevice(radioID: device.radioID)
    #expect(stored?.knownRegions == ["socal"])
  }

  @Test
  func `a region already in the list is not added again`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    var device = DeviceDTO.testDevice()
    device.knownRegions = ["socal"]
    let services = try await Self.makeServices(radioID: device.radioID)
    try await services.dataStore.saveDevice(device)
    manager.setTestState(services: services, connectedDevice: device)

    try await manager.addKnownRegion("socal")

    #expect(manager.connectedDevice?.knownRegions == ["socal"])
  }

  @Test
  func `a region that cannot be saved throws and leaves the list as it was`() async throws {
    let (manager, _) = try ConnectionManager.createForTesting()
    var device = DeviceDTO.testDevice()
    device.knownRegions = ["bay"]
    // No Device row in the store: the save fails with deviceNotFound.
    let services = try await Self.makeServices(radioID: device.radioID)
    manager.setTestState(services: services, connectedDevice: device)

    await #expect(throws: PersistenceStoreError.self) {
      try await manager.addKnownRegion("socal")
    }
    #expect(manager.connectedDevice?.knownRegions == ["bay"])
  }
}
