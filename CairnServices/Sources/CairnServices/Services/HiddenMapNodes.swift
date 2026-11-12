import Foundation
import MeshCore

/// Nodes the user has hidden from the Map tab, kept separately for each radio.
///
/// Nodes are stored by lowercase public-key hex rather than by record id, so a node stays
/// hidden when it is deleted and heard again, or moves from the discovered list onto the
/// radio's node list. Hiding is a Map tab preference only: it changes nothing about the node
/// itself, and no other map reads it.
public struct HiddenMapNodes: Codable, Sendable, Equatable {
  /// Radio id string → lowercase public-key hex strings, in the order hidden, without duplicates.
  public private(set) var keysByRadio: [String: [String]]

  public init(keysByRadio: [String: [String]] = [:]) {
    self.keysByRadio = Self.normalized(keysByRadio)
  }

  private enum CodingKeys: String, CodingKey {
    case keysByRadio
  }

  /// Decoding normalizes too, so a hand-edited backup cannot hide a node that `show` then
  /// fails to match.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(keysByRadio: container.decode([String: [String]].self, forKey: .keysByRadio))
  }

  /// The storage key used for a node's public key.
  public static func storageKey(for publicKey: Data) -> String {
    publicKey.hexString
  }

  /// Public keys hidden on `radioID`'s map.
  public func publicKeys(for radioID: UUID) -> Set<Data> {
    Set((keysByRadio[radioID.uuidString] ?? []).compactMap { Data(hexString: $0) })
  }

  public func contains(_ publicKey: Data, radioID: UUID) -> Bool {
    keysByRadio[radioID.uuidString]?.contains(Self.storageKey(for: publicKey)) ?? false
  }

  public mutating func hide(_ publicKey: Data, radioID: UUID) {
    guard !publicKey.isEmpty, !contains(publicKey, radioID: radioID) else { return }
    keysByRadio[radioID.uuidString, default: []].append(Self.storageKey(for: publicKey))
  }

  public mutating func show(_ publicKey: Data, radioID: UUID) {
    let key = Self.storageKey(for: publicKey)
    guard var keys = keysByRadio[radioID.uuidString], keys.contains(key) else { return }
    keys.removeAll { $0 == key }
    keysByRadio[radioID.uuidString] = keys.isEmpty ? nil : keys
  }

  /// Shows every node hidden on `radioID`'s map; other radios keep their hidden nodes.
  public mutating func showAll(radioID: UUID) {
    keysByRadio[radioID.uuidString] = nil
  }

  /// Canonical radio ids and lowercase keys, dropping entries that are not valid ids or hex,
  /// duplicates, and radios left with nothing hidden.
  private static func normalized(_ keysByRadio: [String: [String]]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (radio, keys) in keysByRadio {
      guard let radioID = UUID(uuidString: radio) else { continue }
      var seen = Set(result[radioID.uuidString] ?? [])
      let valid = keys.compactMap { raw -> String? in
        guard let data = Data(hexString: raw), !data.isEmpty else { return nil }
        let key = storageKey(for: data)
        return seen.insert(key).inserted ? key : nil
      }
      guard !valid.isEmpty else { continue }
      result[radioID.uuidString, default: []].append(contentsOf: valid)
    }
    return result
  }
}

/// UserDefaults persistence for hidden map nodes, stored as JSON under
/// `AppStorageKey.hiddenMapNodes` so it travels with the app-settings half of a backup.
public enum HiddenMapNodesStorage {
  public static let defaultsKey = AppStorageKey.hiddenMapNodes.rawValue

  public static func load(from defaults: UserDefaults = .standard) -> HiddenMapNodes {
    guard let data = defaults.data(forKey: defaultsKey) else { return HiddenMapNodes() }
    return decode(data)
  }

  public static func save(_ nodes: HiddenMapNodes, to defaults: UserDefaults = .standard) {
    if let data = encode(nodes) {
      defaults.set(data, forKey: defaultsKey)
    }
  }

  /// Missing or corrupt data reads as nothing hidden.
  public static func decode(_ data: Data) -> HiddenMapNodes {
    (try? JSONDecoder().decode(HiddenMapNodes.self, from: data)) ?? HiddenMapNodes()
  }

  public static func encode(_ nodes: HiddenMapNodes) -> Data? {
    try? JSONEncoder().encode(nodes)
  }
}
