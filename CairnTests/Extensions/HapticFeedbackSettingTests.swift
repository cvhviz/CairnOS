import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Haptic feedback setting")
struct HapticFeedbackSettingTests {
  @Test
  func `haptics are on until switched off`() throws {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    #expect(HapticFeedbackSetting.isEnabled(in: defaults))

    defaults.set(false, forKey: AppStorageKey.hapticFeedbackEnabled.rawValue)
    #expect(!HapticFeedbackSetting.isEnabled(in: defaults))

    defaults.set(true, forKey: AppStorageKey.hapticFeedbackEnabled.rawValue)
    #expect(HapticFeedbackSetting.isEnabled(in: defaults))
  }

  @Test
  func `the key is the one the Appearance switch writes`() {
    #expect(AppStorageKey.hapticFeedbackEnabled.rawValue == "hapticFeedbackEnabled")
    #expect(AppStorageKey.defaultHapticFeedbackEnabled)
  }
}
