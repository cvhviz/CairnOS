import Foundation
import SwiftData

/// Represents a channel (group) for broadcast messaging.
/// Max number of channels depends on the device, with slot 0 being the public channel.
@Model
public final class Channel {
  #Index<Channel>(
    [\.radioID],
    [\.radioID, \.index]
  )

  /// Unique identifier
  @Attribute(.unique)
  public var id: UUID

  /// The device this channel belongs to
  public var radioID: UUID

  /// Channel slot index
  public var index: UInt8

  /// Channel name
  public var name: String

  /// Channel secret (16 bytes, SHA-256 hashed from passphrase)
  public var secret: Data

  /// Whether this channel is enabled/active
  public var isEnabled: Bool

  /// Last message timestamp for this channel
  public var lastMessageDate: Date?

  /// Unread message count
  public var unreadCount: Int

  /// Unread mention count (mentions of current user not yet seen)
  public var unreadMentionCount: Int = 0

  /// Notification level for this channel (stored as raw value for SwiftData).
  public var notificationLevelRawValue: Int = NotificationLevel.all.rawValue

  /// Type-safe accessor for ``notificationLevelRawValue``.
  public var notificationLevel: NotificationLevel {
    get { NotificationLevel(rawValue: notificationLevelRawValue) ?? .all }
    set { notificationLevelRawValue = newValue.rawValue }
  }

  /// Whether this channel is marked as favorite
  public var isFavorite: Bool = false

  /// The named region override for this channel, when `floodScopeModeRawValue == .specific`.
  /// Meaningful only in `.specific` mode; otherwise should be nil.
  public var regionScope: String?

  /// Raw flood-scope-mode value ("inherit" / "allRegions" / "specific").
  /// Default "inherit" means: apply the device-level default flood scope at send time.
  /// Access through ``floodScope`` for type-safe reads/writes.
  public var floodScopeModeRawValue: String = ChannelFloodScopeStorage.Mode.inherit.rawValue

  private init(
    id: UUID,
    radioID: UUID,
    index: UInt8,
    name: String,
    secret: Data,
    isEnabled: Bool,
    lastMessageDate: Date?,
    unreadCount: Int,
    unreadMentionCount: Int,
    notificationLevelRawValue: Int,
    isFavorite: Bool,
    floodScopeModeRawValue: String,
    regionScope: String?
  ) {
    self.id = id
    self.radioID = radioID
    self.index = index
    self.name = name
    self.secret = secret
    self.isEnabled = isEnabled
    self.lastMessageDate = lastMessageDate
    self.unreadCount = unreadCount
    self.unreadMentionCount = unreadMentionCount
    self.notificationLevelRawValue = notificationLevelRawValue
    self.isFavorite = isFavorite
    self.floodScopeModeRawValue = floodScopeModeRawValue
    self.regionScope = regionScope
  }

  public convenience init(
    id: UUID = UUID(),
    radioID: UUID,
    index: UInt8,
    name: String,
    secret: Data = Data(repeating: 0, count: 16),
    isEnabled: Bool = true,
    lastMessageDate: Date? = nil,
    unreadCount: Int = 0,
    unreadMentionCount: Int = 0,
    notificationLevel: NotificationLevel = .all,
    isFavorite: Bool = false,
    floodScope: ChannelFloodScope = .inherit
  ) {
    let storage = ChannelFloodScopeStorage.decompose(floodScope)
    self.init(
      id: id,
      radioID: radioID,
      index: index,
      name: name,
      secret: secret,
      isEnabled: isEnabled,
      lastMessageDate: lastMessageDate,
      unreadCount: unreadCount,
      unreadMentionCount: unreadMentionCount,
      notificationLevelRawValue: notificationLevel.rawValue,
      isFavorite: isFavorite,
      floodScopeModeRawValue: storage.mode.rawValue,
      regionScope: storage.regionName
    )
  }

  /// Builds a model instance directly from a DTO. Shared by `saveChannel` and
  /// backup batch-insert paths so they can't drift on field coverage.
  /// Forwards raw flood-scope storage fields verbatim rather than through the
  /// normalizing ``ChannelFloodScope`` accessor.
  public convenience init(dto: ChannelDTO) {
    self.init(
      id: dto.id,
      radioID: dto.radioID,
      index: dto.index,
      name: dto.name,
      secret: dto.secret,
      isEnabled: dto.isEnabled,
      lastMessageDate: dto.lastMessageDate,
      unreadCount: dto.unreadCount,
      unreadMentionCount: dto.unreadMentionCount,
      notificationLevelRawValue: dto.notificationLevel.rawValue,
      isFavorite: dto.isFavorite,
      floodScopeModeRawValue: dto.floodScopeModeRawValue,
      regionScope: dto.regionScope
    )
  }

  /// Applies all mutable fields from a DTO to this model instance.
  /// Copies raw flood-scope storage fields verbatim; see ``init(dto:)``.
  /// `radioID` and `index` are identity and stay frozen: this runs in the
  /// id-matched `saveChannel(_:)` upsert, which owns app-side metadata. Slot
  /// changes come from the radio keyed by `(radioID, index)`, and backup
  /// relocation inserts a fresh row via ``init(dto:)``.
  func apply(_ dto: ChannelDTO) {
    name = dto.name
    secret = dto.secret
    isEnabled = dto.isEnabled
    lastMessageDate = dto.lastMessageDate
    unreadCount = dto.unreadCount
    unreadMentionCount = dto.unreadMentionCount
    notificationLevel = dto.notificationLevel
    isFavorite = dto.isFavorite
    floodScopeModeRawValue = dto.floodScopeModeRawValue
    regionScope = dto.regionScope
  }

  /// Creates a Channel from a protocol ChannelInfo
  public convenience init(radioID: UUID, from info: ChannelInfo) {
    self.init(
      radioID: radioID,
      index: info.index,
      name: info.name,
      secret: info.secret
    )
  }
}

// MARK: - Computed Properties

public extension Channel {
  /// Type-safe accessor for the per-channel flood scope preference.
  var floodScope: ChannelFloodScope {
    get { ChannelFloodScopeStorage.recompose(modeRawValue: floodScopeModeRawValue, regionName: regionScope) }
    set {
      let storage = ChannelFloodScopeStorage.decompose(newValue)
      floodScopeModeRawValue = storage.mode.rawValue
      regionScope = storage.regionName
    }
  }

  /// Whether this is the Public channel: the one with the well-known Public key, whichever slot
  /// it sits in. Never the slot alone: another app may put a private channel in slot 0.
  var isPublicChannel: Bool {
    PublicChannelKey.isPublic(secret)
  }

  /// Whether this channel has a non-empty secret
  var hasSecret: Bool {
    !secret.allSatisfy { $0 == 0 }
  }

  /// Whether this channel uses meaningful encryption (private channels only).
  /// The Public channel (by its key) and hashtag channels use publicly-derivable keys.
  var isEncryptedChannel: Bool {
    !isPublicChannel && !name.hasPrefix("#")
  }

  /// Updates from a protocol ChannelInfo
  func update(from info: ChannelInfo) {
    name = info.name
    secret = info.secret
  }

  /// Converts to a protocol ChannelInfo
  func toChannelInfo() -> ChannelInfo {
    ChannelInfo(index: index, name: name, secret: secret)
  }
}

// MARK: - Sendable DTO

/// A sendable snapshot of Channel for cross-actor transfers
public struct ChannelDTO: Sendable, Equatable, Identifiable, Hashable, Codable {
  public let id: UUID
  public var radioID: UUID
  public let index: UInt8
  public let name: String
  public let secret: Data
  public let isEnabled: Bool
  public let lastMessageDate: Date?
  public let unreadCount: Int
  public let unreadMentionCount: Int
  public let notificationLevel: NotificationLevel
  public let isFavorite: Bool
  public let floodScopeModeRawValue: String
  public let regionScope: String?

  /// Convenience property for checking if muted
  public var isMuted: Bool {
    notificationLevel == .muted
  }

  /// Type-safe accessor for the per-channel flood scope preference.
  public var floodScope: ChannelFloodScope {
    ChannelFloodScopeStorage.recompose(modeRawValue: floodScopeModeRawValue, regionName: regionScope)
  }

  /// Explicit Codable: the flood-scope mode travels as its raw value next to `regionScope`.
  private enum CodingKeys: String, CodingKey {
    case id, radioID, index, name, secret, isEnabled, lastMessageDate,
         unreadCount, unreadMentionCount, notificationLevel, isFavorite,
         floodScopeModeRawValue, regionScope
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    radioID = try container.decode(UUID.self, forKey: .radioID)
    index = try container.decode(UInt8.self, forKey: .index)
    name = try container.decode(String.self, forKey: .name)
    secret = try container.decode(Data.self, forKey: .secret)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    lastMessageDate = try container.decodeIfPresent(Date.self, forKey: .lastMessageDate)
    unreadCount = try container.decode(Int.self, forKey: .unreadCount)
    unreadMentionCount = try container.decode(Int.self, forKey: .unreadMentionCount)
    notificationLevel = try container.decode(NotificationLevel.self, forKey: .notificationLevel)
    isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
    regionScope = try container.decodeIfPresent(String.self, forKey: .regionScope)
    floodScopeModeRawValue = try container.decode(String.self, forKey: .floodScopeModeRawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(radioID, forKey: .radioID)
    try container.encode(index, forKey: .index)
    try container.encode(name, forKey: .name)
    try container.encode(secret, forKey: .secret)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encodeIfPresent(lastMessageDate, forKey: .lastMessageDate)
    try container.encode(unreadCount, forKey: .unreadCount)
    try container.encode(unreadMentionCount, forKey: .unreadMentionCount)
    try container.encode(notificationLevel, forKey: .notificationLevel)
    try container.encode(isFavorite, forKey: .isFavorite)
    try container.encode(floodScopeModeRawValue, forKey: .floodScopeModeRawValue)
    try container.encodeIfPresent(regionScope, forKey: .regionScope)
  }

  public init(from channel: Channel) {
    id = channel.id
    radioID = channel.radioID
    index = channel.index
    name = channel.name
    secret = channel.secret
    isEnabled = channel.isEnabled
    lastMessageDate = channel.lastMessageDate
    unreadCount = channel.unreadCount
    unreadMentionCount = channel.unreadMentionCount
    notificationLevel = channel.notificationLevel
    isFavorite = channel.isFavorite
    floodScopeModeRawValue = channel.floodScopeModeRawValue
    regionScope = channel.regionScope
  }

  /// Memberwise initializer for creating DTOs directly
  public init(
    id: UUID,
    radioID: UUID,
    index: UInt8,
    name: String,
    secret: Data,
    isEnabled: Bool,
    lastMessageDate: Date?,
    unreadCount: Int,
    unreadMentionCount: Int = 0,
    notificationLevel: NotificationLevel = .all,
    isFavorite: Bool = false,
    floodScope: ChannelFloodScope = .inherit
  ) {
    self.id = id
    self.radioID = radioID
    self.index = index
    self.name = name
    self.secret = secret
    self.isEnabled = isEnabled
    self.lastMessageDate = lastMessageDate
    self.unreadCount = unreadCount
    self.unreadMentionCount = unreadMentionCount
    self.notificationLevel = notificationLevel
    self.isFavorite = isFavorite
    let storage = ChannelFloodScopeStorage.decompose(floodScope)
    floodScopeModeRawValue = storage.mode.rawValue
    regionScope = storage.regionName
  }

  /// Returns a copy with only `notificationLevel` changed.
  public func with(notificationLevel: NotificationLevel) -> ChannelDTO {
    ChannelDTO(
      id: id, radioID: radioID, index: index, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScope: floodScope
    )
  }

  /// Returns a copy with only `isFavorite` changed.
  public func with(isFavorite: Bool) -> ChannelDTO {
    ChannelDTO(
      id: id, radioID: radioID, index: index, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScope: floodScope
    )
  }

  /// Returns a copy with only the flood-scope preference changed.
  public func with(floodScope: ChannelFloodScope) -> ChannelDTO {
    ChannelDTO(
      id: id, radioID: radioID, index: index, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScope: floodScope
    )
  }

  /// Returns a copy placed at a different slot `index`, forwarding every other raw
  /// storage field verbatim. Used by backup import to relocate a channel whose secret
  /// has no local match onto a free slot without routing through the normalizing
  /// ``ChannelFloodScope`` accessor.
  func with(index newIndex: UInt8) -> ChannelDTO {
    ChannelDTO(
      id: id, radioID: radioID, index: newIndex, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScopeModeRawValue: floodScopeModeRawValue,
      regionScope: regionScope
    )
  }

  /// Returns a copy with a fresh surrogate `id`, forwarding every other raw storage
  /// field verbatim. Used by backup import so a relocated/non-matching channel can never
  /// upsert a live local channel that happens to share the backup's `@Attribute(.unique)`
  /// id. Channel has no inbound foreign key, so re-issuing the id breaks no linkage; it
  /// uses the raw initializer (see ``init(dto:)``).
  func with(id newID: UUID) -> ChannelDTO {
    ChannelDTO(
      id: newID, radioID: radioID, index: index, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScopeModeRawValue: floodScopeModeRawValue,
      regionScope: regionScope
    )
  }

  /// Returns a copy with only the raw `regionScope` column changed. This is the
  /// low-level bypass used for tests that must simulate malformed on-disk state;
  /// production code should go through ``with(floodScope:)``.
  func with(regionScope: String?) -> ChannelDTO {
    ChannelDTO(
      id: id, radioID: radioID, index: index, name: name,
      secret: secret, isEnabled: isEnabled, lastMessageDate: lastMessageDate,
      unreadCount: unreadCount, unreadMentionCount: unreadMentionCount,
      notificationLevel: notificationLevel, isFavorite: isFavorite,
      floodScopeModeRawValue: floodScopeModeRawValue,
      regionScope: regionScope
    )
  }

  /// Low-level init that sets both raw storage fields directly. Kept `internal`
  /// to prevent callers from constructing invalid combinations; used by
  /// ``with(regionScope:)`` and tests.
  init(
    id: UUID,
    radioID: UUID,
    index: UInt8,
    name: String,
    secret: Data,
    isEnabled: Bool,
    lastMessageDate: Date?,
    unreadCount: Int,
    unreadMentionCount: Int,
    notificationLevel: NotificationLevel,
    isFavorite: Bool,
    floodScopeModeRawValue: String,
    regionScope: String?
  ) {
    self.id = id
    self.radioID = radioID
    self.index = index
    self.name = name
    self.secret = secret
    self.isEnabled = isEnabled
    self.lastMessageDate = lastMessageDate
    self.unreadCount = unreadCount
    self.unreadMentionCount = unreadMentionCount
    self.notificationLevel = notificationLevel
    self.isFavorite = isFavorite
    self.floodScopeModeRawValue = floodScopeModeRawValue
    self.regionScope = regionScope
  }

  /// The channel with the well-known Public key, whichever slot it sits in (see ``PublicChannelKey``).
  public var isPublicChannel: Bool {
    PublicChannelKey.isPublic(secret)
  }

  public var hasSecret: Bool {
    !secret.allSatisfy { $0 == 0 }
  }

  /// Whether this channel uses meaningful encryption (private channels only).
  /// The Public channel (by its key) and hashtag channels use publicly-derivable keys.
  public var isEncryptedChannel: Bool {
    !isPublicChannel && !name.hasPrefix("#")
  }
}

/// The Public channel's key, known to everyone on the mesh.
///
/// A channel is Public because it has this key, not because of where it is stored. Cairn writes
/// Public to slot 0, but the radio lets any app put any channel there, and a private channel made
/// in another app and stored in slot 0 was shown as "Public" with the open lock.
public enum PublicChannelKey {
  public static let publicSecret = Data([
    0x8B, 0x33, 0x87, 0xE9, 0xC5, 0xCD, 0xEA, 0x6A,
    0xC9, 0xE5, 0xED, 0xBA, 0xA1, 0x15, 0xCD, 0x72
  ])

  /// Compared over the key's 16 bytes, so a secret a radio pads to 32 still matches.
  public static func isPublic(_ secret: Data) -> Bool {
    secret.count >= publicSecret.count && secret.prefix(publicSecret.count) == publicSecret
  }
}
