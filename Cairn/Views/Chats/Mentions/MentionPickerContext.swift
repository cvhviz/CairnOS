import Foundation
import CairnServices

/// Context passed to the mention picker `.sheet(item:)` driver on
/// `ChatConversationView`. Built by `resolveMentionTap(name:)` when the tap
/// requires user disambiguation or a "not a saved contact" / "that's you"
/// surface. Single-match resolutions never construct one — they navigate
/// directly.
struct MentionPickerContext: Identifiable {
  let id = UUID()
  let name: String
  let radioID: UUID
  let matches: [ContactDTO]
  let isSelfMention: Bool
  /// Heard-but-not-saved nodes with the name, offered beside the saved contacts.
  var discoveredMatches: [DiscoveredNodeDTO] = []
  /// What the open conversation knows about the sender, shown when no node matches.
  var activity: SenderChatActivity?

  /// Nothing on this radio has the name: the sender's advert was never heard.
  var isUnknownSender: Bool {
    !isSelfMention && matches.isEmpty && discoveredMatches.isEmpty
  }
}
