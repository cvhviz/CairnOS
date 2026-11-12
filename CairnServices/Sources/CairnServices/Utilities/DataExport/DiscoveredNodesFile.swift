import Foundation
import MeshCore

/// The discovered-nodes exchange file: JSON that carries what adverts broadcast publicly and
/// nothing else, so a list can move between devices and people. Field names and enum values
/// are stable English identifiers, like the CSV exports.
public enum DiscoveredNodesFile {
  public static let formatIdentifier = "cairn.discovered-nodes"
  public static let currentVersion = 1
  /// A full list is a few hundred kilobytes; anything past this is not one of these files.
  public static let maxFileBytes = 5 * 1024 * 1024
  public static let filenameExtension = "json"

  /// One node as the file carries it. No radio ID, route, or hop count: those describe the
  /// exporting radio's view of the node, not the node.
  public struct Node: Sendable, Equatable {
    public let publicKey: Data
    public let name: String
    public let type: ContactType
    /// Nil when the node advertises no location. Latitude and longitude are set together.
    public let latitude: Double?
    public let longitude: Double?
    public let lastAdvertTimestamp: UInt32
    public let lastHeard: Date

    public init(
      publicKey: Data,
      name: String,
      type: ContactType,
      latitude: Double?,
      longitude: Double?,
      lastAdvertTimestamp: UInt32,
      lastHeard: Date
    ) {
      self.publicKey = publicKey
      self.name = name
      self.type = type
      self.latitude = latitude
      self.longitude = longitude
      self.lastAdvertTimestamp = lastAdvertTimestamp
      self.lastHeard = lastHeard
    }
  }

  /// Why a file as a whole was refused.
  public enum FileError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    /// Not JSON, or not shaped like a discovered-nodes file.
    case unreadable
    case wrongFormat
    case unsupportedVersion(Int?)
  }

  /// The part of a node entry that failed validation.
  public enum Field: String, Sendable, CaseIterable {
    case entry
    case publicKey
    case name
    case type
    case coordinates
    case lastAdvertTimestamp
    case lastHeard
  }

  /// An entry left out of `Contents.nodes`, by its position in the file.
  public struct Rejection: Sendable, Equatable {
    public let index: Int
    public let field: Field
  }

  public struct Contents: Sendable, Equatable {
    /// Nil when the file does not say, or says it unreadably. Shown to the user, never stored.
    public let exportedAt: Date?
    /// Valid nodes, one per public key, in file order.
    public let nodes: [Node]
    public let rejected: [Rejection]
    /// Entries dropped because an entry with the same key and a newer advert was kept.
    public let duplicateCount: Int

    /// Every entry the file listed, valid or not.
    public var entryCount: Int {
      nodes.count + rejected.count + duplicateCount
    }
  }

  // MARK: - Export

  /// Nodes the file can carry. A row with a key of the wrong size or an unknown type is left
  /// out; a name is cleaned and a location dropped when it would not pass `parse`, so an
  /// export always imports.
  public static func nodes(from discoveredNodes: [DiscoveredNodeDTO]) -> [Node] {
    discoveredNodes.compactMap { dto in
      guard dto.publicKey.count == ProtocolLimits.publicKeySize,
            let type = ContactType(rawValue: dto.typeRawValue) else { return nil }
      let hasLocation = dto.hasLocation && isValidCoordinate(latitude: dto.latitude, longitude: dto.longitude)
      return Node(
        publicKey: dto.publicKey,
        name: cleanedName(dto.name),
        type: type,
        latitude: hasLocation ? dto.latitude : nil,
        longitude: hasLocation ? dto.longitude : nil,
        lastAdvertTimestamp: dto.lastAdvertTimestamp,
        lastHeard: dto.lastHeard
      )
    }
  }

  /// The file's bytes, nodes sorted by name then key so two exports of one list are identical.
  public static func encode(_ nodes: [Node], exportedAt: Date = Date()) throws -> Data {
    let sorted = nodes.sorted { lhs, rhs in
      switch lhs.name.localizedStandardCompare(rhs.name) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: lhs.publicKey.lexicographicallyPrecedes(rhs.publicKey)
      }
    }
    let envelope = WireEnvelope(
      format: formatIdentifier,
      version: currentVersion,
      exportedAt: ExportFormat.timestamp(exportedAt) ?? "",
      nodes: sorted.map(WireNode.init(node:))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(envelope)
  }

  // MARK: - Import

  /// Reads at most `maxFileBytes` plus one byte, so an oversized file is refused without
  /// loading it. The size attribute alone is not trusted: file providers can omit it.
  public static func read(contentsOf url: URL) throws -> Data {
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
      throw FileError.tooLarge(bytes: size)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
    guard data.count <= maxFileBytes else {
      throw FileError.tooLarge(bytes: data.count)
    }
    return data
  }

  /// Validates the file and every entry in it. An invalid entry is reported in `rejected`
  /// and the rest of the file still loads; a problem with the file itself throws.
  /// - Parameter now: Caps `lastHeard`, since no device can have heard a node in the future.
  public static func parse(_ data: Data, now: Date = Date()) throws -> Contents {
    guard data.count <= maxFileBytes else {
      throw FileError.tooLarge(bytes: data.count)
    }

    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(WireHeader.self, from: data) else {
      throw FileError.unreadable
    }
    guard header.format == formatIdentifier else {
      throw FileError.wrongFormat
    }
    guard header.version == currentVersion else {
      throw FileError.unsupportedVersion(header.version)
    }
    guard let body = try? decoder.decode(WireBody.self, from: data) else {
      throw FileError.unreadable
    }

    var nodes: [Node] = []
    var indexByKey: [Data: Int] = [:]
    var rejected: [Rejection] = []
    var duplicateCount = 0

    for (index, entry) in body.nodes.enumerated() {
      switch entry.validated(now: now) {
      case let .failure(field):
        rejected.append(Rejection(index: index, field: field.field))
      case let .success(node):
        if let existingIndex = indexByKey[node.publicKey] {
          duplicateCount += 1
          if node.lastAdvertTimestamp > nodes[existingIndex].lastAdvertTimestamp {
            nodes[existingIndex] = node
          }
        } else {
          indexByKey[node.publicKey] = nodes.count
          nodes.append(node)
        }
      }
    }

    return Contents(
      exportedAt: body.exportedAt.flatMap(parseTimestamp),
      nodes: nodes,
      rejected: rejected,
      duplicateCount: duplicateCount
    )
  }

  // MARK: - Validation

  static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
    latitude.isFinite && longitude.isFinite
      && (-90...90).contains(latitude) && (-180...180).contains(longitude)
  }

  /// Within the firmware's name field and free of control characters. Format characters stay
  /// allowed: emoji sequences are joined with one.
  static func isValidName(_ name: String) -> Bool {
    name.utf8.count <= ProtocolLimits.maxUsableNameBytes
      && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  static func cleanedName(_ name: String) -> String {
    let scalars = name.unicodeScalars.filter { $0.properties.generalCategory != .control }
    return String(String.UnicodeScalarView(scalars)).utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
  }

  static func publicKey(fromHex hex: String) -> Data? {
    guard hex.utf8.count == ProtocolLimits.publicKeySize * 2,
          hex.utf8.allSatisfy({ isHexDigit($0) }) else { return nil }
    return Data(hexString: hex)
  }

  private static func isHexDigit(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"),
         UInt8(ascii: "a")...UInt8(ascii: "f"),
         UInt8(ascii: "A")...UInt8(ascii: "F"):
      true
    default:
      false
    }
  }

  static func type(named name: String) -> ContactType? {
    [ContactType.chat, .repeater, .room].first { DataExportFormatter.typeName($0) == name }
  }

  /// ISO 8601 UTC, with or without fractional seconds.
  static func parseTimestamp(_ text: String) -> Date? {
    if let date = try? Date(text, strategy: .iso8601) {
      return date
    }
    return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }
}

// MARK: - Wire Format

private struct WireEnvelope: Encodable {
  let format: String
  let version: Int
  let exportedAt: String
  let nodes: [WireNode]
}

/// Read before the body so a file of another kind or version is named as such instead of
/// failing on whatever its nodes look like.
private struct WireHeader: Decodable {
  let format: String?
  let version: Int?

  private enum CodingKeys: String, CodingKey {
    case format, version
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try? container.decodeIfPresent(String.self, forKey: .format)
    version = try? container.decodeIfPresent(Int.self, forKey: .version)
  }
}

private struct WireBody: Decodable {
  let exportedAt: String?
  let nodes: [WireNode]

  private enum CodingKeys: String, CodingKey {
    case exportedAt, nodes
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    exportedAt = try? container.decodeIfPresent(String.self, forKey: .exportedAt)
    nodes = try container.decode([WireNode].self, forKey: .nodes)
  }
}

private struct InvalidField: Error {
  let field: DiscoveredNodesFile.Field
}

/// A node entry as written. Decoding never throws for the entry's own content, so one bad
/// entry cannot take the file down with it; `validated` reports what is wrong.
private struct WireNode: Codable {
  private enum Content {
    case fields(Fields)
    case malformed
  }

  private struct Fields {
    var publicKey: String?
    var name: String?
    var type: String?
    var latitude: Double?
    var longitude: Double?
    var hasValidCoordinateTypes = true
    var lastAdvertTimestamp: UInt32?
    var lastHeard: String?
  }

  private enum CodingKeys: String, CodingKey {
    case publicKey, name, type, latitude, longitude, lastAdvertTimestamp, lastHeard
  }

  private let content: Content

  init(node: DiscoveredNodesFile.Node) {
    content = .fields(Fields(
      publicKey: ExportFormat.hex(node.publicKey),
      name: node.name,
      type: DataExportFormatter.typeName(node.type),
      latitude: node.latitude,
      longitude: node.longitude,
      lastAdvertTimestamp: node.lastAdvertTimestamp,
      lastHeard: ExportFormat.timestamp(node.lastHeard)
    ))
  }

  init(from decoder: any Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      content = .malformed
      return
    }
    var fields = Fields()
    fields.publicKey = try? container.decode(String.self, forKey: .publicKey)
    fields.name = try? container.decode(String.self, forKey: .name)
    fields.type = try? container.decode(String.self, forKey: .type)
    fields.lastAdvertTimestamp = try? container.decode(UInt32.self, forKey: .lastAdvertTimestamp)
    fields.lastHeard = try? container.decode(String.self, forKey: .lastHeard)
    do {
      fields.latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
      fields.longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    } catch {
      fields.hasValidCoordinateTypes = false
    }
    content = .fields(fields)
  }

  func encode(to encoder: any Encoder) throws {
    guard case let .fields(fields) = content else { return }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(fields.publicKey, forKey: .publicKey)
    try container.encode(fields.name, forKey: .name)
    try container.encode(fields.type, forKey: .type)
    try container.encodeIfPresent(fields.latitude, forKey: .latitude)
    try container.encodeIfPresent(fields.longitude, forKey: .longitude)
    try container.encode(fields.lastAdvertTimestamp, forKey: .lastAdvertTimestamp)
    try container.encode(fields.lastHeard, forKey: .lastHeard)
  }

  func validated(now: Date) -> Result<DiscoveredNodesFile.Node, InvalidField> {
    guard case let .fields(fields) = content else {
      return .failure(InvalidField(field: .entry))
    }
    guard let publicKey = fields.publicKey.flatMap(DiscoveredNodesFile.publicKey(fromHex:)) else {
      return .failure(InvalidField(field: .publicKey))
    }
    guard let name = fields.name, DiscoveredNodesFile.isValidName(name) else {
      return .failure(InvalidField(field: .name))
    }
    guard let type = fields.type.flatMap(DiscoveredNodesFile.type(named:)) else {
      return .failure(InvalidField(field: .type))
    }
    guard fields.hasValidCoordinateTypes,
          (fields.latitude == nil) == (fields.longitude == nil) else {
      return .failure(InvalidField(field: .coordinates))
    }
    if let latitude = fields.latitude, let longitude = fields.longitude,
       !DiscoveredNodesFile.isValidCoordinate(latitude: latitude, longitude: longitude) {
      return .failure(InvalidField(field: .coordinates))
    }
    guard let lastAdvertTimestamp = fields.lastAdvertTimestamp else {
      return .failure(InvalidField(field: .lastAdvertTimestamp))
    }
    guard let lastHeard = fields.lastHeard.flatMap(DiscoveredNodesFile.parseTimestamp) else {
      return .failure(InvalidField(field: .lastHeard))
    }
    return .success(DiscoveredNodesFile.Node(
      publicKey: publicKey,
      name: name,
      type: type,
      latitude: fields.latitude,
      longitude: fields.longitude,
      lastAdvertTimestamp: lastAdvertTimestamp,
      lastHeard: min(lastHeard, now)
    ))
  }
}
