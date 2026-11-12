import CairnServices
import Foundation

/// The photo and colour picked for one node.
struct NodeAppearance: Equatable, Sendable {
  var color: NodeAvatarColor?
  var photo: Data?
  /// Process-lifetime token for the photo bytes, cheap to compare and hash.
  var photoRevision: UInt64?
}

/// Lookup of every node's picked avatar photo and colour for the current radio, so views that know
/// only a public key or a name (channel senders, discovered nodes, remote-node headers, map pins)
/// can show the same avatar as the contact list without a database fetch per cell.
///
/// Rebuilt by `AppState.refreshNodeAppearance()` when contacts, the radio, or the radio's own
/// avatar change. A rebuild that changes nothing leaves the published state alone, so the advert
/// bursts that bump `contactsVersion` don't redraw every observer.
@Observable
@MainActor
final class NodeAppearanceIndex {
  /// Only nodes with a picked photo or colour.
  private(set) var byPublicKey: [Data: NodeAppearance] = [:]
  /// Lowered name or nickname → picked colour, for names held by exactly one contact, plus this
  /// radio's own.
  private(set) var colorByLoweredName: [String: NodeAvatarColor] = [:]
  /// Bumped whenever either table changes; feeds format caches.
  private(set) var revision = 0

  /// The current radio's contacts indexed for naming senders: channel senders by advertised name
  /// (nickname when one contact owns it), room authors by key prefix, DM reactors by contact. The
  /// same tables `SyncCoordinator` uses for notifications, so every surface names a sender alike.
  private(set) var names: ContactNameDirectory = .empty

  func appearance(for publicKey: Data?) -> NodeAppearance? {
    publicKey.flatMap { byPublicKey[$0] }
  }

  func color(forName name: String) -> NodeAvatarColor? {
    colorByLoweredName[name.lowercased()]
  }

  /// The appearance of the one picked node whose public key starts with `prefix`, as room
  /// messages name their author by key prefix. Nil when no node or more than one matches.
  func appearance(forKeyPrefix prefix: Data) -> NodeAppearance? {
    guard !prefix.isEmpty else { return nil }
    var match: NodeAppearance?
    for (key, appearance) in byPublicKey where key.starts(with: prefix) {
      if match != nil { return nil }
      match = appearance
    }
    return match
  }

  /// A room author's gutter avatar and photo: matched on the author's key prefix, else the
  /// colour picked for a contact with the author's name.
  func roomAuthor(name: String, keyPrefix: Data) -> (identity: IncomingAvatarIdentity, photo: Data?) {
    let appearance = appearance(forKeyPrefix: keyPrefix)
    let identity = IncomingAvatarIdentity(
      name: name,
      matchedContactID: nil,
      imageRevision: appearance?.photoRevision,
      avatarColor: appearance?.color ?? color(forName: name)
    )
    return (identity, appearance?.photo)
  }

  /// Rebuilds both tables. `selfName` and `selfColor` are this radio's own, so mentions of it and
  /// its name in rooms use the colour picked for it, or on Automatic the radio colour its avatar
  /// wears.
  func rebuild(contacts: [ContactDTO], selfName: String?, selfColor: NodeAvatarColor?) {
    let directory = ContactNameDirectory(contacts: contacts)
    if directory != names { names = directory }
    let tables = Self.tables(contacts: contacts, selfName: selfName, selfColor: selfColor)
    guard tables.byPublicKey != byPublicKey || tables.colorByLoweredName != colorByLoweredName else { return }
    byPublicKey = tables.byPublicKey
    colorByLoweredName = tables.colorByLoweredName
    revision += 1
  }

  /// Pure table build, shared by `rebuild` and tests.
  nonisolated static func tables(
    contacts: [ContactDTO],
    selfName: String?,
    selfColor: NodeAvatarColor?
  ) -> (byPublicKey: [Data: NodeAppearance], colorByLoweredName: [String: NodeAvatarColor]) {
    var byKey: [Data: NodeAppearance] = [:]
    // A contact answers to its advertised name and to its nickname (rooms and CarPlay show the
    // nickname); a name held by more than one contact is left out.
    var nameCounts: [String: Int] = [:]
    for contact in contacts {
      for key in names(of: contact) {
        nameCounts[key, default: 0] += 1
      }
      guard contact.avatarColor != nil || contact.avatarImageData != nil else { continue }
      byKey[contact.publicKey] = NodeAppearance(
        color: contact.avatarColor,
        photo: contact.avatarImageData,
        photoRevision: IncomingAvatarIdentity.revision(of: contact.avatarImageData)
      )
    }
    var byName: [String: NodeAvatarColor] = [:]
    for contact in contacts {
      guard let color = contact.avatarColor else { continue }
      for key in names(of: contact) where nameCounts[key] == 1 {
        byName[key] = color
      }
    }
    if let selfName {
      let key = selfName.lowercased()
      if nameCounts[key] == nil { byName[key] = selfColor ?? .category(.radio) }
    }
    return (byKey, byName)
  }

  /// The lowered names a contact answers to: its advertised name and, when set, its nickname.
  private nonisolated static func names(of contact: ContactDTO) -> Set<String> {
    Set([contact.name.lowercased(), contact.displayName.lowercased()])
  }
}
