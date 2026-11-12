import Foundation
@testable import CairnServices
import MeshCore
import Testing

@Suite("DataExportService")
struct DataExportServiceTests {
  @Test
  func `node status CSV only includes nodes this radio knows`() async throws {
    let radioID = UUID()
    let otherRadioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    try await store.saveDevice(DeviceDTO.testDevice(id: otherRadioID, radioID: otherRadioID))

    let contactKey = Data(repeating: 0xA1, count: 32)
    let sessionKey = Data(repeating: 0xB2, count: 32)
    let otherRadioKey = Data(repeating: 0xC3, count: 32)
    let orphanKey = Data(repeating: 0xD4, count: 32)
    try await store.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: contactKey, name: "Hilltop"))
    try await store.saveRemoteNodeSessionDTO(
      RemoteNodeSessionDTO.testSession(radioID: radioID, publicKey: sessionKey, name: "Room")
    )
    try await store.saveContact(
      ContactDTO.testContact(radioID: otherRadioID, publicKey: otherRadioKey, name: "Elsewhere")
    )

    for key in [contactKey, sessionKey, otherRadioKey, orphanKey] {
      _ = try await store.saveNodeStatusSnapshot(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        nodePublicKey: key,
        batteryMillivolts: 3900,
        lastSNR: nil,
        lastRSSI: nil,
        noiseFloor: nil,
        uptimeSeconds: nil,
        rxAirtimeSeconds: nil,
        packetsSent: nil,
        packetsReceived: nil,
        receiveErrors: nil
      )
    }

    let table = try await DataExportService(store: store).nodeStatusCSV(radioID: radioID)
    let keyColumn = try #require(table.headers.firstIndex(of: "node_public_key_hex"))

    #expect(Set(table.rows.map { $0[keyColumn] }) == [ExportFormat.hex(contactKey), ExportFormat.hex(sessionKey)])

    let otherTable = try await DataExportService(store: store).nodeStatusCSV(radioID: otherRadioID)
    #expect(otherTable.rows.map { $0[keyColumn] } == [ExportFormat.hex(otherRadioKey)])
  }

  @Test
  func `messages CSV labels a channel whose stored name is empty by its slot`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    try await store.saveChannel(ChannelDTO.testChannel(radioID: radioID, index: 2, name: ""))
    try await store.saveMessage(MessageDTO.testChannelMessage(
      radioID: radioID,
      channelIndex: 2,
      text: "hello",
      direction: .incoming
    ))

    let table = try await DataExportService(store: store)
      .messagesCSV(radioID: radioID, scope: .channel(2), ownName: nil)
    let conversation = try #require(table.headers.firstIndex(of: "conversation"))

    #expect(table.rows.map { $0[conversation] } == ["Channel 2"])
  }

  @Test
  func `RX log CSV names a direct message's bytes only by nodes observed on the entry's channel`() async throws {
    let radioID = UUID()
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let channel = RadioChannelConfig(frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)
    let alexKey = Data([0x5A] + [UInt8](repeating: 0x33, count: 31))
    let baldyKey = Data([0xB4] + [UInt8](repeating: 0x22, count: 31))
    // Both saved as contacts; only Mt Baldy was observed on the channel
    try await store.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: alexKey, name: "Alex"))
    try await store.saveContact(ContactDTO.testContact(radioID: radioID, publicKey: baldyKey, name: "Mt Baldy"))
    try await store.saveObservedNodes(
      radioID: radioID,
      channelKey: channel.key,
      upserting: [ObservedNode(observation: NodeObservation(
        identity: .fullKey(baldyKey),
        kind: .advertRelayed,
        channelKey: channel.key,
        at: Date(),
        hops: 2,
        name: "Mt Baldy",
        nodeTypeRaw: 2
      ))],
      removing: []
    )

    func message(channel stamp: RadioChannelConfig?, at offset: TimeInterval) -> RxLogEntryDTO {
      let payload = Data([0xB4, 0x5A, 0x3E, 0x91] + [UInt8](repeating: 0x7A, count: 16))
      var parsed = ParsedRxLogData(
        snr: 5, rssi: -90, rawPayload: payload, routeType: .flood, payloadType: .textMessage,
        payloadVersion: 0, payloadTypeBits: PayloadType.textMessage.rawValue, transportCode: nil,
        pathLength: 0, pathNodes: [], packetPayload: payload
      )
      parsed.channel = stamp
      return RxLogEntryDTO(radioID: radioID, receivedAt: Date().addingTimeInterval(offset), from: parsed)
    }
    try await store.saveRxLogEntry(message(channel: channel, at: 0))
    try await store.saveRxLogEntry(message(channel: nil, at: -60))
    try await store.flushPendingRxLogEntries()

    let table = try await DataExportService(store: store).rxLogCSV(radioID: radioID, rxLogService: nil)
    let from = try #require(table.headers.firstIndex(of: "from"))
    let to = try #require(table.headers.firstIndex(of: "to"))
    // Newest first: the stamped entry names the observed recipient, never the contact-only sender
    #expect(table.rows.map { $0[from] } == ["5a", "5a"])
    #expect(table.rows.map { $0[to] } == ["Mt Baldy", "b4"])
  }
}
