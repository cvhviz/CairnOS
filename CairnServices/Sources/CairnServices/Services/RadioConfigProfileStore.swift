import Foundation

/// Where the phone keeps its radio config profiles (`RadioConfigProfile`): one JSON file in
/// Application Support, written atomically and protected until first unlock, like the radio
/// avatars. Profiles hold channel secrets, so they stay on this phone and leave it only when the
/// user shares one.
///
/// Small and read whole: a handful of profiles, each a few kilobytes, so every change rewrites
/// the file and returns the list as stored.
public struct RadioConfigProfileStore: Sendable {
  public let fileURL: URL

  /// `Application Support/RadioConfigProfiles.json`.
  public static var defaultFileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("RadioConfigProfiles.json", isDirectory: false)
  }

  public init(fileURL: URL = RadioConfigProfileStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// The file's envelope, versioned so a later shape can migrate this one.
  private struct Envelope: Codable {
    var version: Int
    var profiles: [RadioConfigProfile]
  }

  private static let currentVersion = 1

  /// Every saved profile, in list order. No file yet is an empty list.
  public func load() throws -> [RadioConfigProfile] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return Self.sorted(try decoder.decode(Envelope.self, from: data).profiles)
  }

  /// Replaces the stored list; an empty list removes the file.
  public func save(_ profiles: [RadioConfigProfile]) throws {
    guard !profiles.isEmpty else {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
      return
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Envelope(version: Self.currentVersion, profiles: profiles))
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Adds `profile`, or replaces the one with its ID.
  @discardableResult
  public func upsert(_ profile: RadioConfigProfile) throws -> [RadioConfigProfile] {
    var profiles = try load()
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try save(profiles)
    return Self.sorted(profiles)
  }

  /// Renames the profile; a blank name leaves it as it was.
  @discardableResult
  public func rename(id: UUID, to name: String) throws -> [RadioConfigProfile] {
    var profiles = try load()
    guard let newName = RadioConfigProfile.normalizedName(name),
          let index = profiles.firstIndex(where: { $0.id == id }) else { return profiles }
    profiles[index].name = newName
    try save(profiles)
    return Self.sorted(profiles)
  }

  @discardableResult
  public func delete(id: UUID) throws -> [RadioConfigProfile] {
    let profiles = try load().filter { $0.id != id }
    try save(profiles)
    return profiles
  }

  /// List order: by name as Finder sorts it, then the older first for equal names.
  public static func sorted(_ profiles: [RadioConfigProfile]) -> [RadioConfigProfile] {
    profiles.sorted { lhs, rhs in
      switch lhs.name.localizedStandardCompare(rhs.name) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: lhs.createdAt < rhs.createdAt
      }
    }
  }
}
