import CairnServices
import Foundation

/// What the last firmware check found, kept so the Settings hub can say "Update available" on
/// its Device Info row without a check of its own. Keyed to the radio the check was made on,
/// so another radio connecting doesn't inherit it; a check that finds nothing (or can't tell)
/// clears it.
enum FirmwareUpdateHubFlag {
  static func record(available: Bool?, deviceID: UUID?, defaults: UserDefaults = .standard) {
    let key = AppStorageKey.firmwareUpdateAvailableDeviceID.rawValue
    if available == true, let deviceID {
      defaults.set(deviceID.uuidString, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  static func isAvailable(for deviceID: UUID?, defaults: UserDefaults = .standard) -> Bool {
    guard let deviceID,
          let recorded = defaults.string(forKey: AppStorageKey.firmwareUpdateAvailableDeviceID.rawValue)
    else { return false }
    return recorded == deviceID.uuidString
  }
}

/// The Latest Release tile's caption on both update pages: whether the release is newer than the
/// board's build, and when it was published ("Update available · 3 Nov 2026"). The caption carries
/// the state for anyone who can't see the value's green.
enum FirmwareReleaseCaption {
  nonisolated static func caption(publishedAt: Date?, updateAvailable: Bool?) -> String? {
    let state: String? = switch updateAvailable {
    case true?: L10n.Settings.FirmwareUpdate.available
    case false?: L10n.Settings.FirmwareUpdate.upToDate
    case nil: nil
    }
    let published = publishedAt?.formatted(date: .abbreviated, time: .omitted)
    let parts = [state, published].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
