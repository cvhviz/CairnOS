import Foundation
import CairnServices
import SwiftUI

// MARK: - Host

/// Map surface that owns an independent filter preference.
enum MapFilterHost: String, Sendable, CaseIterable {
  case mainMap
  case tracePath
  case neighborSNR
  case nodeDiscovery
  case lineOfSight

  var capabilities: MapFilterCapabilities {
    switch self {
    case .mainMap: [.all, .recency]
    case .tracePath: [.favorites, .discovered]
    case .neighborSNR: [.favorites, .discovered]
    case .nodeDiscovery: [.favorites, .discovered]
    case .lineOfSight: [.favorites, .discovered]
    }
  }

  /// AppStorage / UserDefaults key string (must match `AppStorageKey` raw values).
  var storageKey: String {
    switch self {
    case .mainMap: AppStorageKey.mapFilterMainMap.rawValue
    case .tracePath: AppStorageKey.mapFilterTracePath.rawValue
    case .neighborSNR: AppStorageKey.mapFilterNeighborSNR.rawValue
    case .nodeDiscovery: AppStorageKey.mapFilterNodeDiscovery.rawValue
    case .lineOfSight: AppStorageKey.mapFilterLineOfSight.rawValue
    }
  }
}

// MARK: - Capabilities

struct MapFilterCapabilities: OptionSet, Sendable, Hashable {
  let rawValue: Int

  static let favorites = MapFilterCapabilities(rawValue: 1 << 0)
  static let discovered = MapFilterCapabilities(rawValue: 1 << 1)
  static let chat = MapFilterCapabilities(rawValue: 1 << 2)
  static let repeater = MapFilterCapabilities(rawValue: 1 << 3)
  static let room = MapFilterCapabilities(rawValue: 1 << 4)
  /// "Heard within" window for discovered nodes.
  static let recency = MapFilterCapabilities(rawValue: 1 << 5)

  /// Full Main Map control set (favorites, discovered, and contact types).
  static let all: MapFilterCapabilities = [.favorites, .discovered, .chat, .repeater, .room]
  static let types: MapFilterCapabilities = [.chat, .repeater, .room]

  var includesTypes: Bool {
    !intersection(.types).isEmpty
  }
}

// MARK: - Recency

/// How recently a discovered node must have been heard to appear on the map.
enum MapRecencyWindow: String, Sendable, Codable, CaseIterable {
  case day, week, month, all

  /// Window length, or nil for no limit.
  var duration: TimeInterval? {
    switch self {
    case .day: 86400
    case .week: 7 * 86400
    case .month: 30 * 86400
    case .all: nil
    }
  }

  var title: String {
    switch self {
    case .day: L10n.Map.Map.Filter.Recency.day
    case .week: L10n.Map.Map.Filter.Recency.week
    case .month: L10n.Map.Map.Filter.Recency.month
    case .all: L10n.Map.Map.Filter.Recency.all
    }
  }

  func includes(lastHeard: Date, now: Date) -> Bool {
    guard let duration else { return true }
    return now.timeIntervalSince(lastHeard) <= duration
  }

  /// Pin opacity for a discovered node: full for the first day, easing to a floor by the end of the
  /// window (a month when unlimited), so stale nodes read as background.
  func pinOpacity(lastHeard: Date, now: Date) -> Double {
    let floor = 0.45
    let fadeStart: TimeInterval = 86400
    let fadeEnd = max(duration ?? 30 * 86400, fadeStart * 2)
    let age = now.timeIntervalSince(lastHeard)
    guard age > fadeStart else { return 1 }
    let progress = min(1, (age - fadeStart) / (fadeEnd - fadeStart))
    return 1 - progress * (1 - floor)
  }
}

// MARK: - State

struct MapFilterState: Sendable, Equatable, Codable {
  private(set) var favoritesOnly: Bool
  private(set) var showDiscovered: Bool
  private(set) var showChat: Bool
  private(set) var showRepeater: Bool
  private(set) var showRoom: Bool
  private(set) var heardWithin: MapRecencyWindow

  init(
    favoritesOnly: Bool = false,
    showDiscovered: Bool = false,
    showChat: Bool = true,
    showRepeater: Bool = true,
    showRoom: Bool = true,
    heardWithin: MapRecencyWindow = .all
  ) {
    self.favoritesOnly = favoritesOnly
    self.showDiscovered = showDiscovered
    self.showChat = showChat
    self.showRepeater = showRepeater
    self.showRoom = showRoom
    self.heardWithin = heardWithin
  }

  private enum CodingKeys: String, CodingKey {
    case favoritesOnly, showDiscovered, showChat, showRepeater, showRoom, heardWithin
  }

  /// Filters saved before the recency window existed decode as `.all`, so an upgrade never hides
  /// pins the user was already seeing.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    favoritesOnly = try container.decode(Bool.self, forKey: .favoritesOnly)
    showDiscovered = try container.decode(Bool.self, forKey: .showDiscovered)
    showChat = try container.decode(Bool.self, forKey: .showChat)
    showRepeater = try container.decode(Bool.self, forKey: .showRepeater)
    showRoom = try container.decode(Bool.self, forKey: .showRoom)
    heardWithin = try container.decode(MapRecencyWindow.self, forKey: .heardWithin)
  }

  /// Every map starts out showing every node it can place: saved and heard, of every type and
  /// however long ago they were heard. Only a filter the user changes leaves any out. (`host`
  /// stays so a map can be given its own default again.)
  static func seed(for host: MapFilterHost) -> MapFilterState {
    MapFilterState(showDiscovered: true, heardWithin: .all)
  }

  /// Discovered layer for pin algebra (storage field stays frozen under Favorites).
  var effectiveShowDiscovered: Bool {
    !favoritesOnly && showDiscovered
  }

  /// True when this state differs from the host seed defaults (filter chrome active).
  func differsFromSeed(for host: MapFilterHost) -> Bool {
    let caps = host.capabilities
    let defaults = MapFilterState.seed(for: host)
    if caps.contains(.favorites), favoritesOnly != defaults.favoritesOnly { return true }
    if caps.contains(.discovered), showDiscovered != defaults.showDiscovered { return true }
    if caps.contains(.chat), showChat != defaults.showChat { return true }
    if caps.contains(.repeater), showRepeater != defaults.showRepeater { return true }
    if caps.contains(.room), showRoom != defaults.showRoom { return true }
    if caps.contains(.recency), heardWithin != defaults.heardWithin { return true }
    return false
  }

  // MARK: Mutators

  mutating func setFavoritesOnly(_ value: Bool) {
    favoritesOnly = value
  }

  /// No-op while Favorites is on (discovered toggle freezes under Favorites).
  mutating func setShowDiscovered(_ value: Bool) {
    guard !favoritesOnly else { return }
    showDiscovered = value
  }

  mutating func setHeardWithin(_ value: MapRecencyWindow) {
    heardWithin = value
  }

  mutating func setShowChat(_ value: Bool, host: MapFilterHost) {
    setType(\.showChat, value, host: host)
  }

  mutating func setShowRepeater(_ value: Bool, host: MapFilterHost) {
    setType(\.showRepeater, value, host: host)
  }

  mutating func setShowRoom(_ value: Bool, host: MapFilterHost) {
    setType(\.showRoom, value, host: host)
  }

  private mutating func setType(
    _ keyPath: WritableKeyPath<MapFilterState, Bool>,
    _ value: Bool,
    host: MapFilterHost
  ) {
    guard !favoritesOnly else { return }
    guard host.capabilities.includesTypes else { return }
    if !value {
      var probe = self
      probe[keyPath: keyPath] = false
      if !probe.hasAtLeastOneEnabledType { return }
    }
    self[keyPath: keyPath] = value
  }

  private var hasAtLeastOneEnabledType: Bool {
    showChat || showRepeater || showRoom
  }

  /// Main Map type-axis gate. Favorites bypasses type filtering.
  func allowsContactType(_ type: ContactType) -> Bool {
    if favoritesOnly { return true }
    switch type {
    case .chat: return showChat
    case .repeater: return showRepeater
    case .room: return showRoom
    }
  }

  func sanitized(for host: MapFilterHost) -> MapFilterState {
    var s = self
    if host.capabilities.includesTypes, !s.hasAtLeastOneEnabledType {
      s.showChat = true
      s.showRepeater = true
      s.showRoom = true
    }
    return s
  }

  // MARK: Storage

  var storageString: String {
    guard let data = try? JSONEncoder().encode(self),
          let string = String(data: data, encoding: .utf8) else {
      return ""
    }
    return string
  }

  init?(storageString: String) {
    guard !storageString.isEmpty,
          let data = storageString.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(MapFilterState.self, from: data) else {
      return nil
    }
    self = decoded
  }
}

// MARK: - Preferences

enum MapFilterPreferences {
  /// Result of a preference resolve that may persist sanitize / migrate / corrupt repair.
  struct ResolveOutcome: Sendable, Equatable {
    let state: MapFilterState
    /// True when UserDefaults was written (sanitize rewrite or corrupt repair).
    let didWrite: Bool
  }

  /// Decode and sanitize; may write UserDefaults (sanitize rewrite or corrupt repair).
  /// Pure seed (missing key) returns without writing.
  static func resolveMigrating(
    host: MapFilterHost,
    from defaults: UserDefaults = .standard
  ) -> ResolveOutcome {
    let key = host.storageKey
    if let raw = defaults.string(forKey: key) {
      if let decoded = MapFilterState(storageString: raw) {
        let sanitized = decoded.sanitized(for: host)
        if sanitized != decoded {
          defaults.set(sanitized.storageString, forKey: key)
          return ResolveOutcome(state: sanitized, didWrite: true)
        }
        return ResolveOutcome(state: sanitized, didWrite: false)
      }
      // Present but unparseable: replace with seed so bad rows do not re-export.
      let seed = MapFilterState.seed(for: host).sanitized(for: host)
      defaults.set(seed.storageString, forKey: key)
      return ResolveOutcome(state: seed, didWrite: true)
    }

    return ResolveOutcome(state: MapFilterState.seed(for: host).sanitized(for: host), didWrite: false)
  }

  /// Decode raw AppStorage text, or host seed when empty/corrupt. Does not write UserDefaults.
  static func state(fromRaw raw: String, host: MapFilterHost) -> MapFilterState {
    if let decoded = MapFilterState(storageString: raw) {
      return decoded.sanitized(for: host)
    }
    return MapFilterState.seed(for: host).sanitized(for: host)
  }

  static func encode(_ state: MapFilterState, host: MapFilterHost) -> String {
    state.sanitized(for: host).storageString
  }

  static func binding(raw: Binding<String>, host: MapFilterHost) -> Binding<MapFilterState> {
    Binding(
      get: { state(fromRaw: raw.wrappedValue, host: host) },
      set: { raw.wrappedValue = encode($0, host: host) }
    )
  }

  /// Repair AppStorage text: sanitize present rows, repair corrupt ones via `resolveMigrating`.
  /// Pure seed (empty raw) leaves `raw` empty and does not write.
  static func ensureMigrated(
    raw: inout String,
    host: MapFilterHost,
    defaults: UserDefaults = .standard
  ) {
    if let decoded = MapFilterState(storageString: raw) {
      let sanitized = decoded.sanitized(for: host)
      if sanitized != decoded {
        let encoded = sanitized.storageString
        raw = encoded
        defaults.set(encoded, forKey: host.storageKey)
      }
      return
    }
    let outcome = resolveMigrating(host: host, from: defaults)
    if outcome.didWrite {
      raw = outcome.state.storageString
    }
  }
}
