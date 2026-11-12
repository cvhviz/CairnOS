import Foundation

/// Where the phone keeps the avatar the user picked for one of their own radios: the colour in
/// `UserDefaults` and the photo as a JPEG in Application Support, both keyed by the radio's
/// `radioID`. Never sent to the radio or over the mesh. Both are carried in app backups by
/// `BackupUserDefaults`.
public enum RadioAvatarStorage {
  /// `[radioID: NodeAvatarColor.rawValue]`.
  public static let colorsDefaultsKey = "radioAvatar.colors"

  /// `Application Support/RadioAvatars`.
  public static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("RadioAvatars", isDirectory: true)
  }

  // MARK: - Colours

  /// Every saved colour, keyed by radio ID string.
  public static func colors(from defaults: UserDefaults = .standard) -> [String: String] {
    (defaults.dictionary(forKey: colorsDefaultsKey) as? [String: String]) ?? [:]
  }

  public static func saveColors(_ colors: [String: String], to defaults: UserDefaults = .standard) {
    if colors.isEmpty {
      defaults.removeObject(forKey: colorsDefaultsKey)
    } else {
      defaults.set(colors, forKey: colorsDefaultsKey)
    }
  }

  public static func color(radioID: UUID, defaults: UserDefaults = .standard) -> NodeAvatarColor? {
    colors(from: defaults)[radioID.uuidString].flatMap(NodeAvatarColor.init(rawValue:))
  }

  /// Saves the colour, or clears it for Automatic (nil).
  public static func setColor(_ color: NodeAvatarColor?, radioID: UUID, defaults: UserDefaults = .standard) {
    var all = colors(from: defaults)
    all[radioID.uuidString] = color?.rawValue
    saveColors(all, to: defaults)
  }

  // MARK: - Photos

  public static func photoURL(radioID: UUID, directory: URL = defaultDirectory) -> URL {
    directory.appendingPathComponent("\(radioID.uuidString).jpg", isDirectory: false)
  }

  public static func photo(radioID: UUID, directory: URL = defaultDirectory) -> Data? {
    try? Data(contentsOf: photoURL(radioID: radioID, directory: directory))
  }

  /// Writes the photo atomically, or deletes it when `data` is nil.
  public static func setPhoto(_ data: Data?, radioID: UUID, directory: URL = defaultDirectory) throws {
    let url = photoURL(radioID: radioID, directory: directory)
    guard let data else {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Every saved photo, keyed by radio ID string. Files whose names are not radio IDs are skipped.
  public static func allPhotos(directory: URL = defaultDirectory) -> [String: Data] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var result: [String: Data] = [:]
    for name in names where name.hasSuffix(".jpg") {
      guard let radioID = UUID(uuidString: String(name.dropLast(4))),
            let data = photo(radioID: radioID, directory: directory) else { continue }
      result[radioID.uuidString] = data
    }
    return result
  }
}
