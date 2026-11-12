import Foundation
import CairnServices

/// Resolves a chat sender's (or mention's) name to the nodes this radio knows by that name:
/// saved contacts and nodes heard advertising but not saved, matched case-insensitively the
/// way the Map and Traffic map label them. A heard node that is also saved appears once, as
/// the contact.
enum SenderNodeMatcher {
  struct Matches: Equatable {
    var contacts: [ContactDTO]
    var discovered: [DiscoveredNodeDTO]

    var count: Int { contacts.count + discovered.count }
    var isEmpty: Bool { count == 0 }
  }

  static func matches(
    name: String,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO]
  ) -> Matches {
    let savedKeys = Set(contacts.map(\.publicKey))
    let contactMatches = SenderContactMatcher.filter(contacts: contacts, senderName: name)
    let discoveredMatches = discoveredNodes
      .filter { !savedKeys.contains($0.publicKey) }
      .filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
      // A companion (chat) node is who sends to a channel; then the most recently heard.
      .sorted { lhs, rhs in
        if (lhs.nodeType == .chat) != (rhs.nodeType == .chat) { return lhs.nodeType == .chat }
        return lhs.lastHeard > rhs.lastHeard
      }
    return Matches(contacts: contactMatches, discovered: discoveredMatches)
  }
}

/// What a conversation itself knows about a sender, for a sender whose advert this radio has
/// never heard: how many of their messages are loaded here and how the latest one arrived.
struct SenderChatActivity: Equatable {
  let messageCount: Int
  let lastMessageDate: Date
  /// Hops of the latest message; nil when it came over a stored route (none recorded).
  let lastHopCount: Int?
  let lastWasDirectRoute: Bool
  let lastSNR: Double?
  /// The latest message's repeater IDs, hex, oldest first.
  let lastPathHex: [String]

  /// Nil when none of `messages` came from `name`.
  static func make(name: String, messages: [MessageDTO]) -> SenderChatActivity? {
    let fromSender = messages.filter { message in
      !message.isOutgoing
        && message.senderNodeName.map { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } == true
    }
    guard let latest = fromSender.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
    return SenderChatActivity(
      messageCount: fromSender.count,
      lastMessageDate: latest.senderDate,
      lastHopCount: latest.isDirectRouted ? nil : latest.hopCount,
      lastWasDirectRoute: latest.isDirectRouted,
      lastSNR: latest.snr,
      lastPathHex: latest.pathNodesHex
    )
  }
}
