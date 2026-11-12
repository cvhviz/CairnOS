import Foundation
import CairnServices

/// How a private channel being created or joined collides with the channels
/// already on the radio.
///
/// The same secret is the same channel, so adding it again only fills another
/// slot with a duplicate; callers open the existing channel instead. A different
/// secret under a name already in use is a distinct channel and is allowed, but
/// identically named rows can't be told apart in the chat list, so callers ask
/// for another name first.
enum PrivateChannelConflict: Equatable {
  /// A channel with this secret is already on the radio.
  case alreadyJoined(ChannelDTO)
  /// Another channel already uses this name (case-insensitive).
  case nameTaken

  /// Returns the conflict for `name` and `secret`, or nil when neither is in use.
  /// Pass a nil `secret` to check the name alone. An all-zero secret marks an
  /// unconfigured slot and never matches.
  static func check(
    name: String,
    secret: Data?,
    existingChannels: [ChannelDTO]
  ) -> PrivateChannelConflict? {
    if let secret, secret.contains(where: { $0 != 0 }),
       let joined = existingChannels.first(where: { $0.secret == secret }) {
      return .alreadyJoined(joined)
    }
    return isNameTaken(name, existingChannels: existingChannels) ? .nameTaken : nil
  }

  /// Whether another channel already uses `name`, ignoring case and
  /// surrounding whitespace. Empty names never collide.
  static func isNameTaken(_ name: String, existingChannels: [ChannelDTO]) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return existingChannels.contains {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare(trimmed) == .orderedSame
    }
  }
}
