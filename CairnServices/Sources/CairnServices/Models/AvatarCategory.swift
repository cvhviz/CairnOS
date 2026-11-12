import Foundation

/// The avatar categories, each drawn in one fixed color (no per-entity variation) unless the user
/// picks another: companion, repeater and room-server nodes, channels in the Chats list, and the
/// user's own radio. The raw values are stored inside `NodeAvatarColor`, so they must never change.
public enum AvatarCategory: String, CaseIterable, Sendable, Hashable {
  case companion
  case repeater
  case room
  case channel
  case radio
}
