import CairnServices
import SwiftUI

/// The app-wide haptics switch (Settings → Appearance → Haptic Feedback), read outside SwiftUI.
enum HapticFeedbackSetting {
  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: AppStorageKey.hapticFeedbackEnabled.rawValue) as? Bool
      ?? AppStorageKey.defaultHapticFeedbackEnabled
  }
}

extension View {
  /// `sensoryFeedback(_:trigger:)` behind the app's Haptic Feedback switch: the same taps on
  /// success, error and selection, held back while the switch is off. The compass keeps its own
  /// switch (`compassHaptics`) for its bearing ticks.
  func cairnFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
    modifier(CairnFeedbackModifier(trigger: trigger) { _, _ in feedback })
  }

  /// `sensoryFeedback(_:trigger:condition:)` behind the Haptic Feedback switch.
  func cairnFeedback<T: Equatable>(
    _ feedback: SensoryFeedback,
    trigger: T,
    condition: @escaping (T, T) -> Bool
  ) -> some View {
    modifier(CairnFeedbackModifier(trigger: trigger) { old, new in condition(old, new) ? feedback : nil })
  }

  /// `sensoryFeedback(trigger:_:)` behind the Haptic Feedback switch: the closure picks the
  /// feedback for the change, or nil for none.
  func cairnFeedback<T: Equatable>(
    trigger: T,
    _ feedback: @escaping (T, T) -> SensoryFeedback?
  ) -> some View {
    modifier(CairnFeedbackModifier(trigger: trigger, feedback: feedback))
  }
}

private struct CairnFeedbackModifier<T: Equatable>: ViewModifier {
  let trigger: T
  let feedback: (T, T) -> SensoryFeedback?
  @AppStorage(AppStorageKey.hapticFeedbackEnabled.rawValue)
  private var isEnabled = AppStorageKey.defaultHapticFeedbackEnabled

  func body(content: Content) -> some View {
    content.sensoryFeedback(trigger: trigger) { old, new in
      isEnabled ? feedback(old, new) : nil
    }
  }
}
