import CairnServices
import Foundation

/// The open chat as the scene stores it: "<kind>:<conversation uuid>", nothing more. The DTO
/// is never persisted (it carries keys and a radio id, see `NavigationCoordinator.selectedContact`);
/// a restored scene looks the conversation up again in the store.
enum ChatRoutePersistence {
  private static let separator: Character = ":"

  /// "direct:<uuid>", "channel:<uuid>" or "room:<uuid>"; "" for no open chat.
  static func encode(_ route: ChatRoute?) -> String {
    guard let route else { return "" }
    return "\(kindName(route.kind))\(separator)\(route.conversationID.uuidString)"
  }

  /// The kind and conversation id a stored string names, or nil for "" and anything malformed.
  static func decode(_ string: String) -> (kind: ChatRoute.Kind, id: UUID)? {
    let parts = string.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = kind(named: String(parts[0])), let id = UUID(uuidString: String(parts[1])) else {
      return nil
    }
    return (kind, id)
  }

  /// Re-reads the stored chat from `store`. Nil when the string names nothing, the conversation
  /// is gone, it belongs to another radio than `radioID`, or it is a room (a room needs a fresh
  /// login, which the list's tap provides).
  static func resolve(_ string: String, radioID: UUID?, store: PersistenceStore) async -> ChatRoute? {
    guard let (kind, id) = decode(string) else { return nil }
    switch kind {
    case .direct:
      guard let contact = try? await store.fetchContact(id: id), contact.radioID == radioID else { return nil }
      return .direct(contact)
    case .channel:
      guard let channel = try? await store.fetchChannel(id: id), channel.radioID == radioID else { return nil }
      return .channel(channel)
    case .room:
      return nil
    }
  }

  private static func kindName(_ kind: ChatRoute.Kind) -> String {
    switch kind {
    case .direct: "direct"
    case .channel: "channel"
    case .room: "room"
    }
  }

  private static func kind(named name: String) -> ChatRoute.Kind? {
    switch name {
    case "direct": .direct
    case "channel": .channel
    case "room": .room
    default: nil
    }
  }
}
