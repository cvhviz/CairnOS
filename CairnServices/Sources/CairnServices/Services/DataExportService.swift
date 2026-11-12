import Foundation
import MeshCore

/// Builds CSV, GPX and JSON exports of locally stored data for one radio.
/// Reads only the local store, so every export works without a connected radio.
public actor DataExportService {
  /// A conversation that the messages export can be narrowed to.
  public struct Conversation: Sendable, Hashable, Identifiable {
    public let scope: MessageScope
    public let title: String
    public var id: MessageScope { scope }
  }

  public enum MessageScope: Sendable, Hashable {
    case all
    case contact(UUID)
    case channel(UInt8)
  }

  /// Maximum RX log rows exported (the store prunes well below this).
  public static let rxLogLimit = 20000

  private let store: PersistenceStore
  /// The live observations of the radio's current channel; without it the stored ones are read.
  private let neighbourService: NeighbourService?

  public init(store: PersistenceStore, neighbourService: NeighbourService? = nil) {
    self.store = store
    self.neighbourService = neighbourService
  }

  /// Channels, then DM contacts with message history, each alphabetized.
  public func conversations(radioID: UUID) async throws -> [Conversation] {
    let channels = try await store.fetchChannels(radioID: radioID)
      .filter { !$0.name.isEmpty || $0.lastMessageDate != nil }
      .sorted { $0.index < $1.index }
      .map { Conversation(scope: .channel($0.index), title: $0.name.isEmpty ? "Channel \($0.index)" : $0.name) }
    let contacts = try await store.fetchContacts(radioID: radioID)
      .filter { $0.lastMessageDate != nil }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
      .map { Conversation(scope: .contact($0.id), title: $0.displayName) }
    return channels + contacts
  }

  public func messagesCSV(radioID: UUID, scope: MessageScope, ownName: String?) async throws -> CSVTable {
    let messages: [MessageDTO] = switch scope {
    case .all:
      try await store.fetchMessagesForExport(radioID: radioID, contactID: nil, channelIndex: nil)
    case let .contact(id):
      try await store.fetchMessagesForExport(radioID: radioID, contactID: id, channelIndex: nil)
    case let .channel(index):
      try await store.fetchMessagesForExport(radioID: radioID, contactID: nil, channelIndex: index)
    }
    let contacts = try await store.fetchContacts(radioID: radioID)
    let channels = try await store.fetchChannels(radioID: radioID)
    let context = DataExportFormatter.MessageContext(
      contactNames: Dictionary(contacts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
      channelNames: Dictionary(channels.map { ($0.index, $0.name) }, uniquingKeysWith: { first, _ in first }),
      ownName: ownName
    )
    return DataExportFormatter.messagesCSV(messages, context: context)
  }

  public func contactsCSV(radioID: UUID) async throws -> CSVTable {
    try await DataExportFormatter.contactsCSV(store.fetchContacts(radioID: radioID))
  }

  /// Status and telemetry history of every node this radio has snapshots for.
  /// Snapshots carry no radio ID, so they are scoped to the nodes this radio
  /// knows: its contacts and remote-node sessions.
  public func nodeStatusCSV(radioID: UUID) async throws -> CSVTable {
    let names = try await nodeNames(radioID: radioID)
    let snapshots = try await store.fetchAllNodeStatusSnapshots()
      .filter { names[$0.nodePublicKey] != nil }
    return DataExportFormatter.nodeStatusCSV(snapshots, nodeNames: names)
  }

  /// RX log, newest first. Channel payloads are decrypted with the stored channel keys;
  /// pass the live `RxLogService` to also decrypt DMs with the radio's key.
  ///
  /// A direct message's sender and recipient bytes are named only by the one node this radio
  /// observed with that byte on the channel the entry was received on
  /// (``PacketNodeIndex/uniqueNames()``); a saved contact never names a byte. An entry received
  /// before channels were recorded shows its bytes in hex.
  public func rxLogCSV(radioID: UUID, rxLogService: RxLogService?) async throws -> CSVTable {
    var entries = try await store.fetchRxLogEntries(radioID: radioID, limit: Self.rxLogLimit)
    if let rxLogService {
      entries = await rxLogService.decodedEntries(entries)
    } else {
      let channels = try await store.fetchChannels(radioID: radioID)
      entries = Self.decodeChannelEntries(entries, channels: channels)
    }
    var namesByChannel: [ChannelKey: [Data: String]] = [:]
    for key in Set(entries.compactMap(\.channelKey)) {
      namesByChannel[key] = try await PacketNodeIndex(ledger: ledgerSnapshot(radioID: radioID, channelKey: key)).uniqueNames()
    }
    var table = CSVTable(headers: DataExportFormatter.rxLogHeaders)
    for entry in entries {
      let names = entry.channelKey.flatMap { namesByChannel[$0] } ?? [:]
      for row in DataExportFormatter.rxLogCSV([entry], nodeNames: names).rows {
        table.append(row)
      }
    }
    return table
  }

  /// GPX waypoints of contacts and discovered nodes with known locations.
  public func waypointsGPX(radioID: UUID) async throws -> (gpx: String, count: Int) {
    let contacts = try await store.fetchContacts(radioID: radioID)
    let discovered = try await store.fetchDiscoveredNodes(radioID: radioID)
    let waypoints = DataExportFormatter.waypoints(contacts: contacts, discoveredNodes: discovered)
    return (GPXDocument.render(waypoints: waypoints, name: "Cairn Nodes"), waypoints.count)
  }

  /// Discovered-nodes exchange file for this radio's list. `count` is the number of nodes
  /// written, which leaves out rows the file cannot carry.
  public func discoveredNodesJSON(radioID: UUID, exportedAt: Date = Date()) async throws -> (data: Data, count: Int) {
    let nodes = try await DiscoveredNodesFile.nodes(from: store.fetchDiscoveredNodes(radioID: radioID))
    return try (DiscoveredNodesFile.encode(nodes, exportedAt: exportedAt), nodes.count)
  }

  // MARK: - Helpers

  /// What this radio observed on `channelKey`: live from the neighbour service when it is running,
  /// else as last stored.
  private func ledgerSnapshot(radioID: UUID, channelKey: ChannelKey) async throws -> LedgerSnapshot {
    if let neighbourService, let snapshot = await neighbourService.ledgerSnapshot(channelKey: channelKey) {
      return snapshot
    }
    return try await LedgerSnapshot(
      radioID: radioID,
      channelKey: channelKey,
      channel: RadioChannelConfig(key: channelKey),
      selfKey: nil,
      takenAt: Date(),
      version: 0,
      nodes: store.fetchObservedNodes(radioID: radioID, channelKey: channelKey).filter { !$0.isOnlyAdvertPush }
    )
  }

  private func nodeNames(radioID: UUID) async throws -> [Data: String] {
    var names: [Data: String] = [:]
    for session in try await store.fetchRemoteNodeSessions(radioID: radioID) {
      names[session.publicKey] = session.name
    }
    for contact in try await store.fetchContacts(radioID: radioID) {
      names[contact.publicKey] = contact.displayName
    }
    return names
  }

  /// Offline channel decryption for RX log entries using stored channel secrets.
  static func decodeChannelEntries(_ entries: [RxLogEntryDTO], channels: [ChannelDTO]) -> [RxLogEntryDTO] {
    let secrets = Dictionary(channels.map { ($0.index, $0.secret) }, uniquingKeysWith: { first, _ in first })
    let names = Dictionary(channels.map { ($0.index, $0.name) }, uniquingKeysWith: { first, _ in first })
    guard !secrets.isEmpty else { return entries }
    return entries.map { entry in
      guard entry.payloadType == .groupText || entry.payloadType == .groupData else { return entry }
      let outcome = RxLogService.decryptChannelPayload(
        entry.packetPayload,
        secrets: secrets,
        names: names,
        preferredIndex: entry.channelIndex
      )
      guard outcome.status == .success else { return entry }
      var decoded = entry
      decoded.channelIndex = outcome.channelIndex
      decoded.channelName = outcome.channelName
      decoded.senderTimestamp = outcome.timestamp
      decoded.decodedText = outcome.text
      decoded.decryptStatus = .success
      return decoded
    }
  }
}
