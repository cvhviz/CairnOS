import CairnServices

/// View-layer formatting flags for a message bubble.
struct MessageBubbleConfiguration {
  var showSenderName: Bool
  var showsIncomingAvatars: Bool

  static let directMessage = MessageBubbleConfiguration(
    showSenderName: false,
    showsIncomingAvatars: false
  )

  static func channel(isPublic: Bool) -> MessageBubbleConfiguration {
    MessageBubbleConfiguration(showSenderName: true, showsIncomingAvatars: true)
  }

  /// Builds a `loweredName -> nickname` lookup for channel sender matching: the one shared rule
  /// (`ChannelSenderNameResolver`) every surface uses, so the bubble, list rows, notifications,
  /// CarPlay and Siri name a channel sender alike. Only names owned by exactly one contact are
  /// included, so an ambiguous name collision never asserts a specific nickname. Keyed by
  /// locale-independent `lowercased()` because a hashable key needs a fixed fold; this
  /// intentionally diverges from `SenderContactMatcher`'s locale-aware
  /// `localizedCaseInsensitiveCompare`. Accepted for the O(1) per-message lookup.
  static func buildNicknameLookup(from contacts: [ContactDTO]) -> [String: String] {
    ChannelSenderNameResolver.nicknameTable(from: contacts)
  }

  /// Unique lowered `contact.name` → avatar identity. Unlike `buildNicknameLookup`,
  /// a nickname is not required. Colliding names are omitted.
  nonisolated static func incomingAvatarIdentities(
    from contacts: [ContactDTO]
  ) -> [String: IncomingAvatarIdentity] {
    var counts: [String: Int] = [:]
    for contact in contacts {
      counts[contact.name.lowercased(), default: 0] += 1
    }
    var lookup: [String: IncomingAvatarIdentity] = [:]
    for contact in contacts {
      let key = contact.name.lowercased()
      guard counts[key] == 1 else { continue }
      lookup[key] = IncomingAvatarIdentity(
        name: contact.name,
        matchedContactID: contact.id,
        imageRevision: IncomingAvatarIdentity.revision(of: contact.avatarImageData),
        avatarColor: contact.avatarColor
      )
    }
    return lookup
  }

  /// Resolves the display name for a message's sender from the contacts list.
  /// Baked into `MessageItem.envelope.senderResolution` upstream of the bubble.
  static func resolveSenderName(
    for message: MessageDTO,
    contacts: [ContactDTO],
    nicknamesByLoweredName: [String: String] = [:]
  ) -> NodeNameResolution {
    // First, try parsed sender name from channel message
    if let resolution = ChannelSenderNameResolver(nicknamesByLoweredName: nicknamesByLoweredName)
      .resolution(for: message.senderNodeName) {
      return resolution
    }

    // Fallback: key prefix lookup
    guard let prefix = message.senderKeyPrefix else {
      return NodeNameResolution(
        displayName: L10n.Chats.Chats.Message.Sender.unknown,
        matchKind: .unresolved
      )
    }

    // Try to find matching contact
    if let result = NeighborNameResolver.resolve(
      for: prefix,
      contacts: contacts,
      discoveredNodes: [],
      userLocation: nil
    ) {
      return result
    }

    // Fallback to hex representation
    if prefix.count >= 2 {
      return NodeNameResolution(displayName: prefix.prefix(2).uppercaseHexString(), matchKind: .unresolved)
    }
    return NodeNameResolution(
      displayName: L10n.Chats.Chats.Message.Sender.unknown,
      matchKind: .unresolved
    )
  }
}
