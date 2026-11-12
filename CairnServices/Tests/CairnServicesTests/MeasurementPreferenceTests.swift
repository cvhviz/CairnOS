import Foundation
@testable import CairnServices
import Testing

@Suite("MeasurementPreference")
struct MeasurementPreferenceTests {
  private let usEnglish = Locale(identifier: "en_US")
  private let ukEnglish = Locale(identifier: "en_GB")
  private let german = Locale(identifier: "de_DE")

  private func roadDistance(_ meters: Double, locale: Locale) -> String {
    Measurement(value: meters, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
  }

  @Test
  func `system leaves the locale untouched`() {
    #expect(MeasurementPreference.locale(base: usEnglish, preference: .system) == usEnglish)
  }

  @Test
  func `metric override shows kilometers for a US region and keeps the language`() {
    let locale = MeasurementPreference.locale(base: usEnglish, preference: .metric)
    #expect(locale.measurementSystem == .metric)
    #expect(locale.language.languageCode == usEnglish.language.languageCode)
    #expect(roadDistance(12400, locale: locale).contains("km"))
  }

  @Test
  func `override cache keys on the base locale and preference`() {
    let metricUS = MeasurementPreference.locale(base: usEnglish, preference: .metric)
    #expect(MeasurementPreference.locale(base: usEnglish, preference: .metric) == metricUS)
    let imperialGerman = MeasurementPreference.locale(base: german, preference: .imperial)
    #expect(imperialGerman.measurementSystem == .us)
    #expect(imperialGerman.language.languageCode == german.language.languageCode)
    let metricGerman = MeasurementPreference.locale(base: german, preference: .metric)
    #expect(metricGerman.measurementSystem == .metric)
    #expect(MeasurementPreference.locale(base: usEnglish, preference: .metric).language.languageCode
      == usEnglish.language.languageCode)
  }

  @Test
  func `imperial override shows miles for a metric region`() {
    let locale = MeasurementPreference.locale(base: german, preference: .imperial)
    #expect(locale.measurementSystem == .us)
    #expect(roadDistance(16093, locale: locale).contains("mi"))
  }

  @Test
  func `the UK drives in miles but reads telemetry in metric`() {
    #expect(MeasurementPreference.usesImperialLengths(base: ukEnglish, preference: .system))
    #expect(!MeasurementPreference.usesUSCustomaryTelemetry(base: ukEnglish, preference: .system))
  }

  @Test
  func `US customary telemetry applies to the US region and the imperial override only`() {
    #expect(MeasurementPreference.usesUSCustomaryTelemetry(base: usEnglish, preference: .system))
    #expect(MeasurementPreference.usesUSCustomaryTelemetry(base: german, preference: .imperial))
    #expect(!MeasurementPreference.usesUSCustomaryTelemetry(base: usEnglish, preference: .metric))
    #expect(!MeasurementPreference.usesUSCustomaryTelemetry(base: german, preference: .system))
  }

  @Test
  func `an unknown stored value falls back to system`() throws {
    let suiteName = "test.measurementPreference.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MeasurementPreference.current(from: defaults) == .system)
    defaults.set("furlongs", forKey: MeasurementPreference.defaultsKey)
    #expect(MeasurementPreference.current(from: defaults) == .system)
    defaults.set(MeasurementSystemPreference.metric.rawValue, forKey: MeasurementPreference.defaultsKey)
    #expect(MeasurementPreference.current(from: defaults) == .metric)
  }
}
