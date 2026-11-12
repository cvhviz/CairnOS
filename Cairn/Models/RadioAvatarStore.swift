import CairnServices
import Foundation
import OSLog

/// The photo and colour picked for each of the user's own radios, keyed by `radioID`. Kept on
/// this phone only (`RadioAvatarStorage`); never sent to the radio. Loaded once and cached, so
/// views read it without touching the disk.
@Observable
@MainActor
final class RadioAvatarStore {
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RadioAvatarStore")

  private(set) var photos: [UUID: Data] = [:]
  private(set) var colors: [UUID: NodeAvatarColor] = [:]

  init(defaults: UserDefaults = .standard, directory: URL = RadioAvatarStorage.defaultDirectory) {
    self.defaults = defaults
    self.directory = directory
    reload()
  }

  func photo(for radioID: UUID?) -> Data? {
    radioID.flatMap { photos[$0] }
  }

  func color(for radioID: UUID?) -> NodeAvatarColor? {
    radioID.flatMap { colors[$0] }
  }

  /// Saves the photo, or removes it when `data` is nil.
  func setPhoto(_ data: Data?, for radioID: UUID) {
    do {
      try RadioAvatarStorage.setPhoto(data, radioID: radioID, directory: directory)
      photos[radioID] = data
    } catch {
      logger.error("Failed to save radio avatar photo: \(error.localizedDescription)")
    }
  }

  /// Saves the colour, or returns to Automatic when `color` is nil.
  func setColor(_ color: NodeAvatarColor?, for radioID: UUID) {
    RadioAvatarStorage.setColor(color, radioID: radioID, defaults: defaults)
    colors[radioID] = color
  }

  /// Re-reads everything from disk, after a backup restore.
  func reload() {
    photos = Dictionary(uniqueKeysWithValues: RadioAvatarStorage.allPhotos(directory: directory).compactMap { key, data in
      UUID(uuidString: key).map { ($0, data) }
    })
    colors = Dictionary(uniqueKeysWithValues: RadioAvatarStorage.colors(from: defaults).compactMap { key, raw in
      guard let radioID = UUID(uuidString: key), let color = NodeAvatarColor(rawValue: raw) else { return nil }
      return (radioID, color)
    })
  }
}
