import Foundation
import Observation

/// A user-defined, named set of nodes (contacts, repeaters, rooms) used to filter the Nodes
/// list and to address a group broadcast.
///
/// Members are stored by lowercase public-key hex rather than by `ContactDTO.id`, so a group
/// survives a contact being deleted and re-added, and one group spans every radio that knows
/// the same node.
public struct ContactGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
  public var id: UUID
  public var name: String
  /// SF Symbol name for the group's icon.
  public var symbol: String
  /// A `ContactGroup.Palette` raw value; unknown values render in the default color.
  public var color: String
  /// Lowercase public-key hex strings, in insertion order, without duplicates.
  public var memberKeys: [String]

  public init(
    id: UUID = UUID(),
    name: String,
    symbol: String = ContactGroup.defaultSymbol,
    color: String = ContactGroup.Palette.blue.rawValue,
    memberKeys: [String] = []
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.color = color
    self.memberKeys = memberKeys
  }

  public static let defaultSymbol = "person.3.fill"

  /// Longest accepted group name.
  public static let maxNameLength = 32

  /// Symbols offered by the group editor.
  public static let symbolChoices: [String] = [
    "person.3.fill", "person.2.fill", "house.fill", "briefcase.fill", "heart.fill",
    "star.fill", "flag.fill", "cross.case.fill", "car.fill", "mountain.2.fill",
    "antenna.radiowaves.left.and.right", "bolt.fill", "leaf.fill", "tent.fill",
    "shield.fill", "tag.fill",
  ]

  /// Named colors offered by the group editor. The app maps each to a SwiftUI color.
  public enum Palette: String, CaseIterable, Sendable {
    case blue, green, orange, red, purple, pink, teal, yellow, gray
  }

  /// The storage key used for a node's public key.
  public static func memberKey(for publicKey: Data) -> String {
    publicKey.map { String(format: "%02x", $0) }.joined()
  }

  public func contains(_ publicKey: Data) -> Bool {
    memberKeys.contains(Self.memberKey(for: publicKey))
  }

  /// Trims whitespace and caps the length; returns nil for a blank name.
  public static func normalizedName(_ raw: String) -> String? {
    let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// UserDefaults persistence for contact groups, stored as JSON under
/// `AppStorageKey.contactGroups` so it travels with the app-settings half of a backup.
public enum ContactGroupsStorage {
  public static let defaultsKey = AppStorageKey.contactGroups.rawValue

  public static func load(from defaults: UserDefaults = .standard) -> [ContactGroup] {
    guard let data = defaults.data(forKey: defaultsKey) else { return [] }
    return (try? JSONDecoder().decode([ContactGroup].self, from: data)) ?? []
  }

  public static func save(_ groups: [ContactGroup], to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(groups) {
      defaults.set(data, forKey: defaultsKey)
    }
  }
}

/// Observable, persisted list of contact groups. Every mutation writes through to
/// `UserDefaults` immediately; the list is small, so there is no batching.
@Observable
@MainActor
public final class ContactGroupStore {
  public static let shared = ContactGroupStore()

  public private(set) var groups: [ContactGroup]

  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    groups = ContactGroupsStorage.load(from: defaults)
  }

  /// Re-reads persisted groups, e.g. after a backup restore wrote the key.
  public func reload() {
    let loaded = ContactGroupsStorage.load(from: defaults)
    if loaded != groups {
      groups = loaded
    }
  }

  public func group(id: UUID) -> ContactGroup? {
    groups.first { $0.id == id }
  }

  /// Groups that contain the node, in list order.
  public func groups(containing publicKey: Data) -> [ContactGroup] {
    let key = ContactGroup.memberKey(for: publicKey)
    return groups.filter { $0.memberKeys.contains(key) }
  }

  /// Whether `name` is free, ignoring case, optionally excluding one group (for renames).
  public func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
    guard let normalized = ContactGroup.normalizedName(name) else { return false }
    return !groups.contains {
      $0.id != id && $0.name.caseInsensitiveCompare(normalized) == .orderedSame
    }
  }

  // MARK: - Group lifecycle

  /// Appends a new group. Returns nil when the name is blank or already used.
  @discardableResult
  public func createGroup(
    name: String,
    symbol: String = ContactGroup.defaultSymbol,
    color: String = ContactGroup.Palette.blue.rawValue,
    memberKeys: [String] = []
  ) -> ContactGroup? {
    guard let normalized = ContactGroup.normalizedName(name), isNameAvailable(normalized) else {
      return nil
    }
    var seen = Set<String>()
    let group = ContactGroup(
      name: normalized,
      symbol: symbol,
      color: color,
      memberKeys: memberKeys.filter { seen.insert($0).inserted }
    )
    groups.append(group)
    persist()
    return group
  }

  /// Renames a group. Returns false when the name is blank, taken, or the group is gone.
  @discardableResult
  public func rename(_ id: UUID, to name: String) -> Bool {
    guard let normalized = ContactGroup.normalizedName(name),
          isNameAvailable(normalized, excluding: id),
          let index = groups.firstIndex(where: { $0.id == id }) else { return false }
    groups[index].name = normalized
    persist()
    return true
  }

  public func setAppearance(_ id: UUID, symbol: String, color: String) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    groups[index].symbol = symbol
    groups[index].color = color
    persist()
  }

  public func delete(_ id: UUID) {
    groups.removeAll { $0.id == id }
    persist()
  }

  /// Moves the groups at `source` so they land before `destination`, matching
  /// SwiftUI's `onMove` semantics.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    let moving = source.sorted().filter { groups.indices.contains($0) }.map { groups[$0] }
    guard !moving.isEmpty else { return }
    let insertAt = destination - source.filter { $0 < destination }.count
    var remaining = groups
    for index in source.sorted(by: >) where remaining.indices.contains(index) {
      remaining.remove(at: index)
    }
    remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
    groups = remaining
    persist()
  }

  // MARK: - Membership

  public func isMember(_ publicKey: Data, of id: UUID) -> Bool {
    group(id: id)?.contains(publicKey) ?? false
  }

  public func add(_ publicKey: Data, to id: UUID) {
    let key = ContactGroup.memberKey(for: publicKey)
    guard let index = groups.firstIndex(where: { $0.id == id }),
          !groups[index].memberKeys.contains(key) else { return }
    groups[index].memberKeys.append(key)
    persist()
  }

  public func remove(_ publicKey: Data, from id: UUID) {
    let key = ContactGroup.memberKey(for: publicKey)
    guard let index = groups.firstIndex(where: { $0.id == id }),
          groups[index].memberKeys.contains(key) else { return }
    groups[index].memberKeys.removeAll { $0 == key }
    persist()
  }

  /// Adds each node that is not already a member, in one write. Existing members stay put, so
  /// adding a multi-selection that overlaps the group never toggles anyone out.
  public func add(_ publicKeys: [Data], to id: UUID) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    var members = groups[index].memberKeys
    var seen = Set(members)
    for key in publicKeys.map(ContactGroup.memberKey(for:)) where seen.insert(key).inserted {
      members.append(key)
    }
    guard members.count != groups[index].memberKeys.count else { return }
    groups[index].memberKeys = members
    persist()
  }

  /// Removes each of the nodes from the group, in one write.
  public func remove(_ publicKeys: [Data], from id: UUID) {
    let keys = Set(publicKeys.map(ContactGroup.memberKey(for:)))
    guard let index = groups.firstIndex(where: { $0.id == id }),
          groups[index].memberKeys.contains(where: { keys.contains($0) }) else { return }
    groups[index].memberKeys.removeAll { keys.contains($0) }
    persist()
  }

  public func toggle(_ publicKey: Data, in id: UUID) {
    if isMember(publicKey, of: id) {
      remove(publicKey, from: id)
    } else {
      add(publicKey, to: id)
    }
  }

  /// Drops member keys not in `validKeys` (lowercase hex). Pass the union of every radio's
  /// contacts, since a group spans radios. Returns how many memberships were removed.
  @discardableResult
  public func prune(keeping validKeys: Set<String>) -> Int {
    var removed = 0
    var updated = groups
    for index in updated.indices {
      let before = updated[index].memberKeys.count
      updated[index].memberKeys.removeAll { !validKeys.contains($0) }
      removed += before - updated[index].memberKeys.count
    }
    if removed > 0 {
      groups = updated
      persist()
    }
    return removed
  }

  private func persist() {
    ContactGroupsStorage.save(groups, to: defaults)
  }
}
