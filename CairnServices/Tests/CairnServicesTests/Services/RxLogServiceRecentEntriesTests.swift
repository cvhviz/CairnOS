import Foundation
@testable import CairnServices
@testable import MeshCore
import Testing

@Suite("RxLogService recent entries")
struct RxLogServiceRecentEntriesTests {
  private static func parsed(rssi: Int) -> ParsedRxLogData {
    ParsedRxLogData(
      snr: 6.25,
      rssi: rssi,
      rawPayload: Data([0x01, 0x02, 0x03]),
      routeType: .flood,
      payloadType: .advert,
      payloadVersion: 0,
      payloadTypeBits: PayloadType.advert.rawValue,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0x01, 0x02, 0x03, UInt8(truncatingIfNeeded: rssi)])
    )
  }

  @Test
  func `returns only entries inside the window, newest first`() async throws {
    let radioID = UUID()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    let service = RxLogService(session: MeshCoreSession(transport: MockTransport()), dataStore: dataStore, heardRepeatsService: nil)
    await service.startEventMonitoring(radioID: radioID)
    defer { Task { await service.stopEventMonitoring() } }

    let now = Date()
    let old = RxLogEntryDTO(radioID: radioID, receivedAt: now.addingTimeInterval(-7200), from: Self.parsed(rssi: -100))
    let recent = RxLogEntryDTO(radioID: radioID, receivedAt: now.addingTimeInterval(-600), from: Self.parsed(rssi: -90))
    let newest = RxLogEntryDTO(radioID: radioID, receivedAt: now.addingTimeInterval(-5), from: Self.parsed(rssi: -80))
    let otherRadio = RxLogEntryDTO(radioID: UUID(), receivedAt: now, from: Self.parsed(rssi: -70))
    for entry in [old, recent, newest, otherRadio] {
      try await dataStore.saveRxLogEntry(entry)
    }

    let entries = await service.recentEntries(since: now.addingTimeInterval(-3600))
    #expect(entries.map(\.id) == [newest.id, recent.id])
  }

  @Test
  func `nothing comes back before monitoring names a radio`() async throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    let service = RxLogService(session: MeshCoreSession(transport: MockTransport()), dataStore: dataStore, heardRepeatsService: nil)
    #expect(await service.recentEntries(since: .distantPast).isEmpty)
  }
}
