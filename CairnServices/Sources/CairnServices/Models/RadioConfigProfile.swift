import Foundation

/// A named snapshot of a radio's settings, kept on this phone and applied to any radio through the
/// node-config import (`NodeConfigService.importConfig`). The snapshot is a `MeshCoreNodeConfig`,
/// the companion app's export format, so a profile shares as the same JSON file Export writes.
///
/// A profile never carries what makes one radio itself: no keys, no contacts, no position. Copied
/// onto another radio those would clone its identity or move it on the map, so they are stripped
/// on the way in (`sanitized(_:)`), whatever the source.
public struct RadioConfigProfile: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var name: String
  public var createdAt: Date
  /// The radio the profile was saved from, for the list's subtitle.
  public var sourceDeviceName: String?
  public var config: MeshCoreNodeConfig {
    didSet { config = Self.sanitized(config) }
  }

  public init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = .now,
    sourceDeviceName: String? = nil,
    config: MeshCoreNodeConfig
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.sourceDeviceName = sourceDeviceName
    self.config = Self.sanitized(config)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    sourceDeviceName = try container.decodeIfPresent(String.self, forKey: .sourceDeviceName)
    // A hand-edited store must not smuggle a key or contacts back in.
    config = Self.sanitized(try container.decode(MeshCoreNodeConfig.self, forKey: .config))
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, createdAt, sourceDeviceName, config
  }

  /// What a profile reads from the radio: the settings that can sit on any radio. The name is
  /// added from the connected device rather than read with the identity section, which would also
  /// export the private key.
  public static let captureSections = ConfigSections(radioSettings: true, otherSettings: true, channels: true)

  /// `config` without the parts that belong to one radio.
  public static func sanitized(_ config: MeshCoreNodeConfig) -> MeshCoreNodeConfig {
    var copy = config
    copy.publicKey = nil
    copy.privateKey = nil
    copy.positionSettings = nil
    copy.contacts = nil
    return copy
  }

  /// The name trimmed, or nil when nothing is left of it.
  public static func normalizedName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The profile in the export format, encoded the way Export writes it.
  public func exportData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(config)
  }
}
