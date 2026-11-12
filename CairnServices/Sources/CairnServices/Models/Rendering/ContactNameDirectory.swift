import Foundation

/// One radio's contacts, indexed for naming message senders: channel senders by advertised name,
/// room authors by key prefix, and direct-message reactors by contact. Built once per change of the
/// contacts, by the app (`NodeAppearanceIndex`) and by `SyncCoordinator` for notifications, so both
/// name a sender the same way.
public struct ContactNameDirectory: Sendable, Equatable {
  public let channelSenders: ChannelSenderNameResolver
  public let roomAuthors: RoomAuthorResolver
  /// Contact ID → the name shown for that contact now (nickname first).
  public let displayNamesByContactID: [UUID: String]
  /// The lowered names shown for more than one contact.
  private let sharedDisplayNames: Set<String>

  public static let empty = ContactNameDirectory(contacts: [])

  public init(contacts: [ContactDTO]) {
    channelSenders = ChannelSenderNameResolver(contacts: contacts)
    roomAuthors = RoomAuthorResolver(contacts: contacts)
    var names: [UUID: String] = [:]
    for contact in contacts {
      names[contact.id] = contact.displayName
    }
    displayNamesByContactID = names
    var counts: [String: Int] = [:]
    for name in names.values {
      counts[name.lowercased(), default: 0] += 1
    }
    sharedDisplayNames = Set(counts.filter { $0.value > 1 }.keys)
  }

  /// Whether more than one contact is shown under this name.
  public func isDisplayNameShared(_ name: String) -> Bool {
    sharedDisplayNames.contains(name.lowercased())
  }
}
