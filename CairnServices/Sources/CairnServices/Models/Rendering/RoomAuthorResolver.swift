import Foundation

/// Who wrote a room post, resolved when it is shown rather than when it arrived.
///
/// A room server pushes each post with the first 4 bytes of its author's public key
/// (`simple_room_server` `pushPostToClient`; the same on stock MeshCore and Cairn firmware). The
/// name saved with the post (`RoomMessage.authorName`) is only what was known at receipt, so it
/// goes stale when a nickname changes and stays a hex prefix for an author saved later. This
/// resolves the prefix against the radio's current contacts each time.
public struct RoomAuthorIdentity: Sendable, Equatable, Hashable {
  public enum Kind: Sendable, Equatable, Hashable {
    /// The user's own post.
    case me
    /// The room server itself (its own key): a system post such as a welcome or a notice.
    case room
    /// Exactly one of this radio's contacts has a key starting with the prefix.
    case contact(UUID)
    /// More than one of this radio's contacts share the prefix: not attributed to any of them.
    case ambiguous
    /// No contact on this radio matches; the name saved when the post arrived (which may come
    /// from another radio's contacts).
    case lastKnown
    /// Nothing is known about the author but the key prefix.
    case unknown
  }

  public let kind: Kind
  /// What to show as the author.
  public let displayName: String
  /// The name the author advertises on air, for an `@[mention]` other clients will recognise.
  /// Nil when it is not known for certain; a nickname or a hex prefix never goes on air.
  public let advertisedName: String?
  /// The author's key prefix in upper-case hex, e.g. "50515253".
  public let keyPrefixHex: String

  public init(kind: Kind, displayName: String, advertisedName: String?, keyPrefixHex: String) {
    self.kind = kind
    self.displayName = displayName
    self.advertisedName = advertisedName
    self.keyPrefixHex = keyPrefixHex
  }

  /// The matched contact, when the author is one of this radio's contacts.
  public var contactID: UUID? {
    if case let .contact(id) = kind { id } else { nil }
  }

  /// True when the name shown is only the author's key prefix: show it as a key, not a name.
  public var isKeyOnly: Bool {
    switch kind {
    case .ambiguous, .unknown: true
    case .me, .room, .contact, .lastKnown: false
    }
  }
}

/// Resolves room post authors against one radio's contacts. Cheap to build; rebuild it when the
/// contacts change.
public struct RoomAuthorResolver: Sendable, Equatable {
  struct Entry: Sendable, Equatable {
    let id: UUID
    let publicKey: Data
    let name: String
    let displayName: String
  }

  private let entries: [Entry]

  public static let empty = RoomAuthorResolver(contacts: [])

  public init(contacts: [ContactDTO]) {
    entries = contacts.map {
      Entry(id: $0.id, publicKey: $0.publicKey, name: $0.name, displayName: $0.displayName)
    }
  }

  /// Resolves a stored post.
  /// - Parameters:
  ///   - roomPublicKey: The room server's key, so its own system posts read as the room.
  ///   - roomName: The room's name, shown for a system post when the room isn't a contact.
  ///   - selfName: What the user's own posts are labelled ("You").
  public func resolve(
    _ message: RoomMessageDTO,
    roomPublicKey: Data?,
    roomName: String?,
    selfName: String
  ) -> RoomAuthorIdentity {
    resolve(
      keyPrefix: message.authorKeyPrefix,
      isFromSelf: message.isFromSelf,
      storedName: message.authorName,
      roomPublicKey: roomPublicKey,
      roomName: roomName,
      selfName: selfName
    )
  }

  /// Order: the user's own post; the room's own key; exactly one contact on this radio; several
  /// contacts (shown by key); the name saved at receipt; the key prefix.
  public func resolve(
    keyPrefix: Data,
    isFromSelf: Bool,
    storedName: String?,
    roomPublicKey: Data?,
    roomName: String?,
    selfName: String
  ) -> RoomAuthorIdentity {
    let hex = keyPrefix.map { String(format: "%02X", $0) }.joined()
    if isFromSelf {
      return RoomAuthorIdentity(kind: .me, displayName: selfName, advertisedName: nil, keyPrefixHex: hex)
    }
    let matches = keyPrefix.isEmpty ? [] : entries.filter { $0.publicKey.starts(with: keyPrefix) }
    if let roomPublicKey, !keyPrefix.isEmpty, roomPublicKey.starts(with: keyPrefix) {
      let roomContact = matches.first { $0.publicKey == roomPublicKey }
      let name = roomContact?.displayName ?? roomName ?? storedName ?? hex
      return RoomAuthorIdentity(kind: .room, displayName: name, advertisedName: roomContact?.name, keyPrefixHex: hex)
    }
    if matches.count == 1, let contact = matches.first {
      return RoomAuthorIdentity(
        kind: .contact(contact.id),
        displayName: contact.displayName,
        advertisedName: contact.name,
        keyPrefixHex: hex
      )
    }
    if matches.count > 1 {
      return RoomAuthorIdentity(kind: .ambiguous, displayName: hex, advertisedName: nil, keyPrefixHex: hex)
    }
    if let storedName, !storedName.isEmpty {
      return RoomAuthorIdentity(kind: .lastKnown, displayName: storedName, advertisedName: nil, keyPrefixHex: hex)
    }
    return RoomAuthorIdentity(kind: .unknown, displayName: hex, advertisedName: nil, keyPrefixHex: hex)
  }

  /// The name to save with a post as it arrives: the matched contact's name as shown then
  /// (nickname first), or nil when no single contact on this radio matches.
  public func nameAtReceipt(keyPrefix: Data) -> String? {
    guard !keyPrefix.isEmpty else { return nil }
    let matches = entries.filter { $0.publicKey.starts(with: keyPrefix) }
    return matches.count == 1 ? matches.first?.displayName : nil
  }
}

public extension RoomMessageDTO {
  /// Earliest post timestamp treated as a set room clock (2024-01-01T00:00:00Z).
  static let earliestValidPostTimestamp: UInt32 = 1_704_067_200

  /// When the post was written: its own timestamp on the room's clock, or when it arrived here
  /// if the room's clock was never set. Posts a room pushes in bulk at login all arrive "now",
  /// so arrival time is only a fallback (firmware `RoomPost.h` `postTime`).
  var postDate: Date {
    timestamp >= Self.earliestValidPostTimestamp ? date : createdAt
  }
}
