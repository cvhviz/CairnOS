import Foundation
import MeshCore

/// Role stored in the low two bits of a repeater/room ACL permissions byte
/// (`PERM_ACL_ROLE_MASK` in the firmware's `ClientACL.h`).
enum AccessListRole: UInt8, CaseIterable, Identifiable, Comparable {
  case guest = 0
  case readOnly = 1
  case readWrite = 2
  case admin = 3

  static let roleMask: UInt8 = 0x03

  /// Roles an entry can be set to. Guest is not persisted by the firmware:
  /// setting it removes the entry, so it is offered as "Remove" instead.
  static let assignable: [AccessListRole] = [.admin, .readWrite, .readOnly]

  init(permissions: UInt8) {
    // Masked to two bits, so every value maps to a case.
    self = AccessListRole(rawValue: permissions & Self.roleMask) ?? .guest
  }

  var id: UInt8 { rawValue }

  static func < (lhs: AccessListRole, rhs: AccessListRole) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var localizedName: String {
    switch self {
    case .guest: L10n.RemoteNodes.RemoteNodes.Acl.Role.guest
    case .readOnly: L10n.RemoteNodes.RemoteNodes.Acl.Role.readOnly
    case .readWrite: L10n.RemoteNodes.RemoteNodes.Acl.Role.readWrite
    case .admin: L10n.RemoteNodes.RemoteNodes.Acl.Role.admin
    }
  }

  var systemImage: String {
    switch self {
    case .guest: "person"
    case .readOnly: "eye"
    case .readWrite: "pencil"
    case .admin: "crown"
    }
  }
}

/// Builds and interprets the firmware `setperm {pubkey-hex} {permissions}` CLI command.
///
/// Firmware rules (`ClientACL::applyPermissions`): adding or changing a role needs the
/// complete 32-byte public key; removing (permissions 0) accepts a key prefix.
enum AccessListCommand {
  static let fullKeyLength = 32

  /// Command that grants `role` to the node with the given full public key.
  /// Returns nil when the key is not a complete public key or the role is guest.
  static func setRole(_ role: AccessListRole, publicKey: Data) -> String? {
    guard publicKey.count == fullKeyLength, role != .guest else { return nil }
    return "setperm \(publicKey.hexString) \(role.rawValue)"
  }

  /// Command that removes the entry matching `keyPrefix` from the ACL.
  static func remove(keyPrefix: Data) -> String? {
    guard !keyPrefix.isEmpty else { return nil }
    return "setperm \(keyPrefix.hexString) \(AccessListRole.guest.rawValue)"
  }

  /// Whether a CLI reply reports success. The firmware replies "OK" on success and
  /// "Err - ..." otherwise.
  static func isSuccess(_ reply: String) -> Bool {
    var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(">") {
      text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return text.uppercased().hasPrefix("OK")
  }
}

/// A known node that an ACL key prefix can resolve to.
struct AccessListCandidate: Equatable, Identifiable {
  let publicKey: Data
  let name: String
  /// Saved chat contacts are offered when adding an entry; other nodes only resolve names.
  var isChatContact = false

  var id: Data { publicKey }
}

/// One ACL row, with the entry's prefix resolved against known nodes where possible.
struct AccessListItem: Identifiable, Equatable {
  let keyPrefix: Data
  let role: AccessListRole
  /// Known node name, or nil when no contact or discovered node matches.
  let name: String?
  /// Complete public key of the matched node; needed to change the role.
  let fullPublicKey: Data?
  /// The entry is the connected radio's own key (the login in use).
  let isSelf: Bool

  var id: Data { keyPrefix }

  var canChangeRole: Bool {
    fullPublicKey?.count == AccessListCommand.fullKeyLength && !isSelf
  }

  var canRemove: Bool { !isSelf }
}

enum AccessListResolver {
  /// Resolves ACL entries to display items, ordered by role (admin first) then name.
  /// Candidates earlier in the array win ties, so pass contacts before discovered nodes.
  static func items(
    from entries: [ACLEntry],
    candidates: [AccessListCandidate],
    selfPublicKey: Data?
  ) -> [AccessListItem] {
    entries.map { entry in
      let match = candidates.first { $0.publicKey.starts(with: entry.keyPrefix) }
      let isSelf = selfPublicKey.map { $0.starts(with: entry.keyPrefix) } ?? false
      return AccessListItem(
        keyPrefix: entry.keyPrefix,
        role: AccessListRole(permissions: entry.permissions),
        name: match?.name,
        fullPublicKey: isSelf ? selfPublicKey : match?.publicKey,
        isSelf: isSelf
      )
    }
    .sorted { lhs, rhs in
      if lhs.role != rhs.role { return lhs.role > rhs.role }
      switch (lhs.name, rhs.name) {
      case let (left?, right?):
        return left.localizedStandardCompare(right) == .orderedAscending
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        return lhs.keyPrefix.hexString < rhs.keyPrefix.hexString
      }
    }
  }
}
