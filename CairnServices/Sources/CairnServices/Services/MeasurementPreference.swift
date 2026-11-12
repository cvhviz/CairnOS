import Foundation
import os

/// The user's choice of measurement units for distances, heights, and telemetry.
public enum MeasurementSystemPreference: String, CaseIterable, Sendable {
  /// Follow the device's region setting.
  case system
  /// Kilometers, meters, °C, hPa.
  case metric
  /// Miles, feet, °F, inHg.
  case imperial
}

/// Resolves the measurement preference into a `Locale` formatters can use, so an
/// app-level override changes units without touching the language or number format.
public enum MeasurementPreference {
  public static let defaultsKey = AppStorageKey.measurementSystem.rawValue

  public static func current(from defaults: UserDefaults = .standard) -> MeasurementSystemPreference {
    defaults.string(forKey: defaultsKey).flatMap(MeasurementSystemPreference.init(rawValue:)) ?? .system
  }

  /// `base` with only its measurement system replaced by the user's override.
  /// `.system` returns `base` unchanged.
  public static func locale(
    base: Locale = .current,
    preference: MeasurementSystemPreference = current()
  ) -> Locale {
    let system: Locale.MeasurementSystem
    switch preference {
    case .system: return base
    case .metric: system = .metric
    case .imperial: system = .us
    }
    let key = OverrideKey(baseIdentifier: base.identifier, system: system)
    if let cached = overrideCache.withLock({ $0?.key == key ? $0?.locale : nil }) {
      return cached
    }
    var components = Locale.Components(locale: base)
    components.measurementSystem = system
    let locale = Locale(components: components)
    overrideCache.withLock { $0 = (key, locale) }
    return locale
  }

  /// Keyed on the identifier, not the `Locale`: `Locale.current` is autoupdating and compares
  /// equal to itself after a region change, which would serve a stale override.
  private struct OverrideKey: Equatable {
    let baseIdentifier: String
    let system: Locale.MeasurementSystem
  }

  /// Last overridden locale. Formatting a distance per list row would otherwise rebuild a
  /// `Locale` from components on every render; the base and preference rarely change, so a
  /// single entry suffices.
  private static let overrideCache = OSAllocatedUnfairLock<(key: OverrideKey, locale: Locale)?>(initialState: nil)

  /// Whether lengths should show in feet and miles. The UK system measures road
  /// distance in miles but heights are still shown in feet there, so both count.
  public static func usesImperialLengths(
    base: Locale = .current,
    preference: MeasurementSystemPreference = current()
  ) -> Bool {
    locale(base: base, preference: preference).measurementSystem != .metric
  }

  /// Whether telemetry should show °F and inHg. Only the US system does; the UK
  /// drives in miles but reads temperature in °C and pressure in hPa.
  public static func usesUSCustomaryTelemetry(
    base: Locale = .current,
    preference: MeasurementSystemPreference = current()
  ) -> Bool {
    locale(base: base, preference: preference).measurementSystem == .us
  }
}
