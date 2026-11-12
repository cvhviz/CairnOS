import Foundation

enum GPSSource: String, CaseIterable {
  case phone
  case device

  /// The source refreshed before each advert, or nil when no refresh runs: the device's advert
  /// policy keeps location out of adverts, or auto-update is off. The one gate both the advert
  /// and the GPS tab's position caption read, so the caption never claims a refresh that won't
  /// happen.
  static func advertRefresh(sharesLocationPublicly: Bool, autoUpdate: Bool, source: GPSSource) -> GPSSource? {
    guard sharesLocationPublicly, autoUpdate else { return nil }
    return source
  }
}

struct DevicePreferenceStore {
  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  // MARK: - Auto-Update Location

  func isAutoUpdateLocationEnabled(deviceID: UUID) -> Bool {
    userDefaults.bool(forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
  }

  func setAutoUpdateLocationEnabled(_ enabled: Bool, deviceID: UUID) {
    userDefaults.set(enabled, forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
  }

  // MARK: - GPS Source

  func gpsSource(deviceID: UUID) -> GPSSource {
    guard let raw = userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)),
          let source = GPSSource(rawValue: raw) else {
      return .phone
    }
    return source
  }

  func hasSetGPSSource(deviceID: UUID) -> Bool {
    userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)) != nil
  }

  func setGPSSource(_ source: GPSSource, deviceID: UUID) {
    userDefaults.set(source.rawValue, forKey: Self.gpsSourceKey(deviceID: deviceID))
  }

  // MARK: - Nickname

  /// The name the user gave a saved radio on this phone (Connections), shown in place of the
  /// name it advertises. Never written to the radio.
  func nickname(deviceID: UUID) -> String? {
    userDefaults.string(forKey: Self.nicknameKey(deviceID: deviceID))
  }

  /// Saves the nickname trimmed; a blank one clears it, so the radio's own name shows again.
  func setNickname(_ nickname: String?, deviceID: UUID) {
    let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      userDefaults.removeObject(forKey: Self.nicknameKey(deviceID: deviceID))
    } else {
      userDefaults.set(trimmed, forKey: Self.nicknameKey(deviceID: deviceID))
    }
  }

  // MARK: - Keys

  private static func nicknameKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).nickname"
  }

  private static func autoUpdateLocationKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).autoUpdateLocation"
  }

  private static func gpsSourceKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).gpsSource"
  }
}
