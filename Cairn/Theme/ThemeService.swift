import CairnServices
import SwiftUI
import UIKit

/// Owns the appearance settings: the color-scheme preference and the page background.
///
/// `current` is the theme injected at the scene root: the one palette (`Theme.default`) with the
/// resolved background. `defaults` and `imageStore` are injectable so the service is unit-testable
/// in isolation — matching `BackupUserDefaults`'s existing `defaults:` parameter convention.
@Observable
@MainActor
final class ThemeService {
  private(set) var colorSchemePreference: AppColorSchemePreference
  /// The persisted background settings, always normalized and never pointing at a missing photo.
  private(set) var background: AppBackground
  /// The background ready to paint; `nil` for the system background.
  private(set) var backdrop: ResolvedBackdrop?

  private let defaults: UserDefaults
  private let imageStore: BackgroundImageStore
  @ObservationIgnored private var blurTask: Task<Void, Never>?
  /// Photo and blur radius `backdrop.image` was made for, when it is exact (not an interim image
  /// shown while a render runs). Lets a dim-only change reuse the decoded image.
  @ObservationIgnored private var exactImageKey: ImageKey?
  @ObservationIgnored private var photoCache: (name: String, image: UIImage)?

  private struct ImageKey: Equatable {
    let name: String
    let radius: Int
  }

  init(defaults: UserDefaults = .standard, imageStore: BackgroundImageStore = .default) {
    self.defaults = defaults
    self.imageStore = imageStore
    colorSchemePreference = .system
    background = .system
    colorSchemePreference = resolveSchemePreferenceFromDefaults()
    // A UI-test background is saved too, so every page that reads the stored setting agrees.
    let uiTestBackground = Self.uiTestBackground()
    apply(uiTestBackground ?? storedBackground(), persist: uiTestBackground != nil)
  }

  /// Simulator UI tests start on a gradient preset with `-uiTestBackground <preset>` (e.g.
  /// `dusk`), so screenshots can check the glass cards; `system` is the untouched system look and
  /// `solid-<preset>` (e.g. `solid-midnight`) a solid color. Launch arguments can't carry the
  /// stored JSON: a value that starts with `{` is parsed as a dictionary, not a string.
  private static func uiTestBackground() -> AppBackground? {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-uiTestBackground"),
            arguments.indices.contains(index + 1) else { return nil }
      let name = arguments[index + 1]
      var background = AppBackground()
      if name == "system" {
        return .system
      } else if name.hasPrefix("solid-"), let preset = SolidBackgroundPreset(rawValue: String(name.dropFirst(6))) {
        background.kind = .solid
        background.solidColor = preset.color
      } else if let preset = GradientBackgroundPreset(rawValue: name) {
        background.kind = .gradient
        background.gradientColors = preset.colors
      } else {
        return nil
      }
      return background.normalized()
    #else
      return nil
    #endif
  }

  var current: Theme {
    Theme.default.with(backdrop: backdrop)
  }

  /// The stored photo, unblurred, for thumbnails on the Appearance page. Kept even while another
  /// kind is selected, so switching back to Photo needs no new pick.
  var backgroundPhoto: UIImage? {
    guard let name = background.imageFileName else { return nil }
    if let cached = photoCache, cached.name == name { return cached.image }
    guard let image = imageStore.image(named: name) else { return nil }
    photoCache = (name, image)
    return image
  }

  var effectiveColorScheme: ColorScheme? {
    colorSchemePreference.colorScheme
  }

  func setColorSchemePreference(_ preference: AppColorSchemePreference) {
    colorSchemePreference = preference
    defaults.set(preference.rawValue, forKey: PersistenceKeys.appColorSchemePreference)
  }

  /// Edits the background in place and persists it. Values are clamped to their ranges.
  func updateBackground(_ change: (inout AppBackground) -> Void) {
    var updated = background
    change(&updated)
    apply(updated, persist: true)
  }

  /// Saves a picked photo (downscaled, off the main actor) and makes it the background. The
  /// previous photo is deleted once the new one is in place.
  func setBackgroundImage(data: Data) async throws {
    let store = imageStore
    let saved = try await Task.detached(priority: .userInitiated) {
      try store.save(imageData: data)
    }.value
    let previous = background.imageFileName
    updateBackground {
      $0.kind = .image
      $0.imageFileName = saved.fileName
      $0.imageAverageColor = saved.averageColor
    }
    // Drops the previous photo, its blur renders and any file orphaned by an interrupted pick.
    if previous != saved.fileName {
      imageStore.removeAll(except: saved.fileName)
    }
  }

  /// Deletes the photo and returns to the system background.
  func removeBackgroundImage() {
    let previous = background.imageFileName
    updateBackground {
      $0.kind = .system
      $0.imageFileName = nil
      $0.imageAverageColor = nil
    }
    if let previous { imageStore.delete(named: previous) }
  }

  /// Re-reads both settings so a mid-session backup import (`AppState.notifyDataRestored`)
  /// takes effect without a cold launch. A restored photo background whose file is not on this
  /// device falls back to the system background (backups carry the setting, not the photo).
  func refreshFromUserDefaults() {
    let resolvedScheme = resolveSchemePreferenceFromDefaults()
    if resolvedScheme != colorSchemePreference { colorSchemePreference = resolvedScheme }
    let stored = storedBackground()
    if stored != background { apply(stored, persist: false) }
  }

  // MARK: Resolution

  /// The settings this device can actually show: normalized, and a photo background whose file
  /// is missing (a restored backup, a cleared container) becomes the system background.
  nonisolated static func resolvedBackground(
    _ background: AppBackground,
    imageExists: (String) -> Bool
  ) -> AppBackground {
    var resolved = background.normalized()
    if resolved.kind == .image, !(resolved.imageFileName.map(imageExists) ?? false) {
      resolved.kind = .system
      resolved.imageFileName = nil
      resolved.imageAverageColor = nil
    }
    return resolved
  }

  private func storedBackground() -> AppBackground {
    AppBackground.decode(from: defaults.string(forKey: AppStorageKey.appBackground.rawValue))
  }

  private func apply(_ requested: AppBackground, persist: Bool) {
    let store = imageStore
    let resolved = Self.resolvedBackground(requested) { store.contains(named: $0) }
    let previousImage = backdrop?.settings.imageFileName == resolved.imageFileName ? backdrop?.image : nil
    if resolved.kind != .image { exactImageKey = nil }
    background = resolved

    // Persist when asked, and also when resolution corrected what was stored (a missing photo),
    // so the stale value does not resurface on the next launch.
    if persist || resolved != requested.normalized() {
      defaults.set(resolved.encodedString, forKey: AppStorageKey.appBackground.rawValue)
    }

    switch resolved.kind {
    case .system:
      blurTask?.cancel()
      backdrop = nil
    case .solid, .gradient:
      blurTask?.cancel()
      backdrop = ResolvedBackdrop(settings: resolved, image: nil)
    case .image:
      resolveImage(for: resolved, fallback: previousImage)
    }
  }

  /// Shows the photo at the requested blur. The sharp photo and cached renders load lazily and
  /// synchronously; a radius never rendered before renders off the main actor while the page
  /// keeps showing the last image, so dragging the slider never stalls.
  private func resolveImage(for settings: AppBackground, fallback: UIImage?) {
    guard let name = settings.imageFileName else { return }
    let radius = Int(settings.blur.rounded())
    let key = ImageKey(name: name, radius: radius)
    blurTask?.cancel()

    if key == exactImageKey, let image = backdrop?.image {
      backdrop = ResolvedBackdrop(settings: settings, image: image)
      return
    }
    let exact = radius == 0
      ? imageStore.image(named: name)
      : imageStore.blurRender(of: name, radius: radius)
    if let exact {
      exactImageKey = key
      backdrop = ResolvedBackdrop(settings: settings, image: exact)
      return
    }

    exactImageKey = nil
    let interim = fallback ?? imageStore.image(named: name)
    backdrop = ResolvedBackdrop(settings: settings, image: interim)
    let store = imageStore
    blurTask = Task { [weak self] in
      // Debounce: a slider drag produces a value per frame; render only where it settles.
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      let rendered = try? await Task.detached(priority: .userInitiated) {
        try store.makeBlurRender(of: name, radius: radius)
      }.value
      guard !Task.isCancelled, let self, let rendered,
            self.background.imageFileName == name,
            Int(self.background.blur.rounded()) == radius else { return }
      self.exactImageKey = key
      self.backdrop = ResolvedBackdrop(settings: self.background, image: rendered)
    }
  }

  private func resolveSchemePreferenceFromDefaults() -> AppColorSchemePreference {
    let storedScheme = defaults.string(forKey: PersistenceKeys.appColorSchemePreference)
    if let raw = storedScheme, let preference = AppColorSchemePreference(rawValue: raw) {
      return preference
    }
    if storedScheme == nil { return .system } // missing key: no write-back
    // Unknown raw value (e.g., a future-build case via backup): fall back + corrective overwrite.
    defaults.set(AppColorSchemePreference.system.rawValue,
                 forKey: PersistenceKeys.appColorSchemePreference)
    return .system
  }
}
