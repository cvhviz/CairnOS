import Foundation
import MeshCore

/// Pure builders that turn stored DTOs into CSV tables and GPX waypoints.
/// Column names and enum values are stable English identifiers so exports
/// stay machine-readable regardless of the app language.
public enum DataExportFormatter {
  // MARK: - Messages

  /// Resolves the conversation title and sender names for message rows.
  public struct MessageContext: Sendable {
    public var contactNames: [UUID: String]
    public var channelNames: [UInt8: String]
    public var ownName: String?

    public init(contactNames: [UUID: String] = [:], channelNames: [UInt8: String] = [:], ownName: String? = nil) {
      self.contactNames = contactNames
      self.channelNames = channelNames
      self.ownName = ownName
    }
  }

  public static let messageHeaders = [
    "received_at_utc", "sent_at_utc", "conversation", "conversation_type", "sender",
    "direction", "text", "hops", "snr_db", "status", "heard_repeats", "round_trip_ms",
  ]

  /// Messages CSV, oldest first.
  public static func messagesCSV(_ messages: [MessageDTO], context: MessageContext) -> CSVTable {
    var table = CSVTable(headers: messageHeaders)
    for message in messages.sorted(by: { ($0.createdAt, $0.timestamp) < ($1.createdAt, $1.timestamp) }) {
      let isOutgoing = message.direction == .outgoing
      let conversation: String
      let conversationType: String
      if let channelIndex = message.channelIndex {
        let name = context.channelNames[channelIndex] ?? ""
        conversation = name.isEmpty ? "Channel \(channelIndex)" : name
        conversationType = "channel"
      } else {
        conversation = message.contactID.flatMap { context.contactNames[$0] } ?? ""
        conversationType = "direct"
      }

      let sender: String? = if isOutgoing {
        context.ownName ?? "me"
      } else if message.channelIndex != nil {
        message.senderNodeName
      } else {
        conversation
      }

      table.append([
        ExportFormat.timestamp(message.createdAt),
        ExportFormat.timestamp(epochSeconds: message.senderTimestamp ?? message.timestamp),
        conversation,
        conversationType,
        sender,
        isOutgoing ? "outgoing" : "incoming",
        message.text,
        isOutgoing || message.isDirectRouted ? nil : String(message.hopCount),
        isOutgoing ? nil : ExportFormat.number(message.snr, fractionDigits: 2),
        isOutgoing ? statusName(message.status) : "received",
        message.heardRepeats > 0 ? String(message.heardRepeats) : nil,
        ExportFormat.integer(message.roundTripTime),
      ])
    }
    return table
  }

  static func statusName(_ status: MessageStatus) -> String {
    switch status {
    case .pending: "pending"
    case .sending: "sending"
    case .sent: "sent"
    case .delivered: "delivered"
    case .failed: "failed"
    case .retrying: "retrying"
    }
  }

  // MARK: - Contacts

  public static let contactHeaders = [
    "name", "nickname", "type", "public_key_hex", "latitude", "longitude",
    "last_heard_utc", "last_advert_utc", "path", "favorite", "blocked",
  ]

  public static func contactsCSV(_ contacts: [ContactDTO]) -> CSVTable {
    var table = CSVTable(headers: contactHeaders)
    for contact in contacts.sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
      let path: String = if contact.isFloodRouted {
        "flood"
      } else {
        "\(decodePathLen(contact.outPathLength)?.hopCount ?? Int(contact.outPathLength)) hops"
      }
      table.append([
        contact.name,
        contact.nickname,
        typeName(contact.type),
        ExportFormat.hex(contact.publicKey),
        contact.hasLocation ? ExportFormat.number(contact.latitude) : nil,
        contact.hasLocation ? ExportFormat.number(contact.longitude) : nil,
        ExportFormat.timestamp(epochSeconds: contact.lastHeardTimestamp),
        ExportFormat.timestamp(epochSeconds: contact.lastAdvertTimestamp),
        path,
        contact.isFavorite ? "true" : "false",
        contact.isBlocked ? "true" : "false",
      ])
    }
    return table
  }

  static func typeName(_ type: ContactType) -> String {
    switch type {
    case .chat: "companion"
    case .repeater: "repeater"
    case .room: "room"
    }
  }

  // MARK: - Node status

  public static let nodeStatusHeaders = [
    "timestamp_utc", "node_name", "node_public_key_hex", "battery_mv", "last_snr_db", "last_rssi_dbm",
    "noise_floor_dbm", "uptime_s", "rx_airtime_s", "packets_sent", "packets_received", "receive_errors",
    "sent_direct", "sent_flood", "received_direct", "received_flood", "direct_duplicates", "flood_duplicates",
    "posted_count", "post_push_count", "latitude", "longitude", "altitude_m", "neighbors", "telemetry",
  ]

  /// Node status/telemetry history CSV, grouped by node then oldest first.
  public static func nodeStatusCSV(_ snapshots: [NodeStatusSnapshotDTO], nodeNames: [Data: String]) -> CSVTable {
    var table = CSVTable(headers: nodeStatusHeaders)
    let sorted = snapshots.sorted {
      let lhsName = nodeNames[$0.nodePublicKey] ?? ""
      let rhsName = nodeNames[$1.nodePublicKey] ?? ""
      if lhsName != rhsName { return lhsName < rhsName }
      if $0.nodePublicKey != $1.nodePublicKey { return $0.nodePublicKey.lexicographicallyPrecedes($1.nodePublicKey) }
      return $0.timestamp < $1.timestamp
    }
    for snapshot in sorted {
      let neighbors = snapshot.neighborSnapshots?.map { neighbor in
        "\(ExportFormat.hex(neighbor.publicKeyPrefix) ?? "")@\(ExportFormat.number(neighbor.snr, fractionDigits: 2) ?? "")"
      }.joined(separator: " ")
      let telemetry = snapshot.telemetryEntries?.map { entry in
        "ch\(entry.channel) \(entry.type)=\(ExportFormat.number(entry.value, fractionDigits: 4) ?? "")"
      }.joined(separator: "; ")
      table.append([
        ExportFormat.timestamp(snapshot.timestamp),
        nodeNames[snapshot.nodePublicKey],
        ExportFormat.hex(snapshot.nodePublicKey),
        ExportFormat.integer(snapshot.batteryMillivolts),
        ExportFormat.number(snapshot.lastSNR, fractionDigits: 2),
        ExportFormat.integer(snapshot.lastRSSI),
        ExportFormat.integer(snapshot.noiseFloor),
        ExportFormat.integer(snapshot.uptimeSeconds),
        ExportFormat.integer(snapshot.rxAirtimeSeconds),
        ExportFormat.integer(snapshot.packetsSent),
        ExportFormat.integer(snapshot.packetsReceived),
        ExportFormat.integer(snapshot.receiveErrors),
        ExportFormat.integer(snapshot.sentDirect),
        ExportFormat.integer(snapshot.sentFlood),
        ExportFormat.integer(snapshot.receivedDirect),
        ExportFormat.integer(snapshot.receivedFlood),
        ExportFormat.integer(snapshot.directDuplicates),
        ExportFormat.integer(snapshot.floodDuplicates),
        ExportFormat.integer(snapshot.postedCount),
        ExportFormat.integer(snapshot.postPushCount),
        ExportFormat.number(snapshot.latitude),
        ExportFormat.number(snapshot.longitude),
        ExportFormat.number(snapshot.altitude, fractionDigits: 1),
        neighbors,
        telemetry,
      ])
    }
    return table
  }

  // MARK: - RX log

  public static let rxLogHeaders = [
    "received_at_utc", "route", "payload_type", "payload_version", "snr_db", "rssi_dbm", "hops", "path_hex",
    "packet_hash", "decrypt_status", "channel", "from", "to", "sender_time_utc", "region", "text",
    "size_bytes", "raw_hex",
  ]

  /// RX log CSV in the order given (the log is newest first).
  public static func rxLogCSV(_ entries: [RxLogEntryDTO], nodeNames: [Data: String] = [:]) -> CSVTable {
    var table = CSVTable(headers: rxLogHeaders)
    for entry in entries {
      let from = entry.senderPrefix.map { nodeNames[$0] ?? (ExportFormat.hex($0) ?? "") } ?? entry.fromContactName
      let to = entry.recipientPrefix.map { nodeNames[$0] ?? (ExportFormat.hex($0) ?? "") } ?? entry.toContactName
      let region: String? = switch RegionScopeSemantics.coalesce(
        scope: entry.regionScope,
        matches: entry.regionScopeMatches
      ) {
      case .none: nil
      case let .unique(name): name
      case let .ambiguous(names): names.joined(separator: "|")
      }
      table.append([
        ExportFormat.timestamp(entry.receivedAt),
        entry.routeType.displayName,
        entry.payloadType.displayName,
        String(entry.payloadVersion),
        ExportFormat.number(entry.snr, fractionDigits: 2),
        ExportFormat.integer(entry.rssi),
        String(entry.hopCount),
        ExportFormat.hex(entry.pathNodes),
        entry.packetHash,
        decryptStatusName(entry.decryptStatus),
        entry.channelName,
        from,
        to,
        ExportFormat.timestamp(epochSeconds: entry.senderTimestamp),
        region,
        entry.decodedText,
        String(entry.rawPayload.count),
        ExportFormat.hex(entry.rawPayload),
      ])
    }
    return table
  }

  static func decryptStatusName(_ status: DecryptStatus) -> String {
    switch status {
    case .notApplicable: "not_applicable"
    case .noMatchingKey: "no_key"
    case .hmacFailed: "hmac_failed"
    case .decryptFailed: "decrypt_failed"
    case .success: "decrypted"
    case .dmNoMatchingKey: "no_dm_key"
    }
  }

  // MARK: - Waypoints

  /// Waypoints for contacts and discovered nodes with a known location.
  /// A discovered node already present as a contact (same public key) is skipped.
  public static func waypoints(contacts: [ContactDTO], discoveredNodes: [DiscoveredNodeDTO] = []) -> [GPXWaypoint] {
    var seenKeys = Set<Data>()
    var result: [GPXWaypoint] = []
    for contact in contacts where contact.hasLocation {
      seenKeys.insert(contact.publicKey)
      let heard = contact.lastHeardTimestamp.flatMap { $0 > 0 ? $0 : nil } ?? contact.lastAdvertTimestamp
      result.append(GPXWaypoint(
        latitude: contact.latitude,
        longitude: contact.longitude,
        name: contact.displayName,
        description: "\(typeName(contact.type)) \(ExportFormat.hex(contact.publicKey.prefix(4)) ?? "")",
        time: heard > 0 ? Date(timeIntervalSince1970: TimeInterval(heard)) : nil,
        type: typeName(contact.type)
      ))
    }
    for node in discoveredNodes
      where node.hasLocation
      && isValidCoordinate(latitude: node.latitude, longitude: node.longitude)
      && !seenKeys.contains(node.publicKey) {
      seenKeys.insert(node.publicKey)
      result.append(GPXWaypoint(
        latitude: node.latitude,
        longitude: node.longitude,
        name: node.name,
        description: "\(typeName(node.nodeType)) \(ExportFormat.hex(node.publicKey.prefix(4)) ?? "")",
        time: node.lastHeard,
        type: typeName(node.nodeType)
      ))
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// `DiscoveredNodeDTO.hasLocation` only rules out 0,0, so an advert carrying
  /// out-of-range values would otherwise produce a GPX point no reader accepts.
  private static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
    latitude.isFinite && longitude.isFinite
      && (-90...90).contains(latitude) && (-180...180).contains(longitude)
  }
}
