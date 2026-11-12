import Foundation

/// Names a channel message's sender the same way on every surface: the bubble, the Chats list,
/// Home, notifications, CarPlay, Siri, search and the Live Activity.
///
/// A channel message names its sender only by the text before `": "` (the node name the sender
/// put on air), with no key, on stock MeshCore and Cairn firmware alike. That name is matched to
/// a contact by name alone, so it is never proof of identity: anyone can transmit "Frank Wilson".
/// The match is made only when exactly one of this radio's contacts has that advertised name, and
/// only that contact's nickname is offered, as an unverified extra next to the wire name.
///
/// Keyed by locale-independent `lowercased()`, because a hashable key needs a fixed fold.
public struct ChannelSenderNameResolver: Sendable, Equatable {
  /// Lowered advertised name → nickname, for names held by exactly one contact with a nickname.
  public let nicknamesByLoweredName: [String: String]

  public static let empty = ChannelSenderNameResolver(nicknamesByLoweredName: [:])

  public init(nicknamesByLoweredName: [String: String]) {
    self.nicknamesByLoweredName = nicknamesByLoweredName
  }

  /// Builds the table from one radio's contacts. A name more than one contact advertises is left
  /// out, so a collision never asserts a specific nickname.
  public init(contacts: [ContactDTO]) {
    self.init(nicknamesByLoweredName: Self.nicknameTable(from: contacts))
  }

  /// Lowered advertised name → nickname, for names owned by exactly one contact.
  public static func nicknameTable(from contacts: [ContactDTO]) -> [String: String] {
    var counts: [String: Int] = [:]
    for contact in contacts {
      counts[contact.name.lowercased(), default: 0] += 1
    }
    var lookup: [String: String] = [:]
    for contact in contacts {
      let key = contact.name.lowercased()
      guard counts[key] == 1, let nickname = contact.nickname, !nickname.isEmpty else { continue }
      lookup[key] = nickname
    }
    return lookup
  }

  /// The nickname of the one contact that advertises `wireName`, or nil.
  public func nickname(for wireName: String) -> String? {
    guard !wireName.isEmpty else { return nil }
    return nicknamesByLoweredName[wireName.lowercased()]
  }

  /// The bubble's resolution: the wire name, with the matched contact's nickname as an
  /// unverified extra. Nil when the message carries no sender name.
  public func resolution(for wireName: String?) -> NodeNameResolution? {
    guard let wireName, !wireName.isEmpty else { return nil }
    return NodeNameResolution(
      displayName: wireName,
      matchKind: .exact,
      unverifiedNickname: nickname(for: wireName)
    )
  }

  /// For short surfaces (a list row's preview, CarPlay, the Live Activity): the nickname when one
  /// contact matches, else the wire name. Nil when the message carries no sender name.
  public func shortName(for wireName: String?) -> String? {
    guard let wireName, !wireName.isEmpty else { return nil }
    return nickname(for: wireName) ?? wireName
  }

  /// For surfaces with room (notifications, Siri, search, the reactions list): the nickname with
  /// the wire name after it, e.g. "Dad (Frank Wilson)", so a spoofed name never reads as a bare
  /// trusted nickname. The wire name alone when no contact matches. Nil when there is no sender.
  /// - Parameter format: Joins nickname and wire name; the app passes its localized form.
  public func labeledName(
    for wireName: String?,
    format: (_ nickname: String, _ wireName: String) -> String = Self.defaultLabel
  ) -> String? {
    guard let wireName, !wireName.isEmpty else { return nil }
    guard let nickname = nickname(for: wireName) else { return wireName }
    return format(nickname, wireName)
  }

  /// "Nickname (Wire Name)", used when no localized form is supplied.
  public static func defaultLabel(nickname: String, wireName: String) -> String {
    "\(nickname) (\(wireName))"
  }
}
