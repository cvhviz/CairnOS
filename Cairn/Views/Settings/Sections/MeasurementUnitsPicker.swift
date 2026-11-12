import CairnServices
import SwiftUI

/// Picks the units used for distances, heights, and telemetry: the device's
/// region setting, or a metric or imperial override for this app alone. A card, so Appearance can
/// keep it in one group with the color scheme rather than a section of its own; the caller
/// explains it (`L10n.Settings.Units.footer`) behind the group's "i".
struct MeasurementUnitsPicker: View {
  @AppStorage(AppStorageKey.measurementSystem.rawValue)
  private var measurementSystem: MeasurementSystemPreference = .system

  var body: some View {
    // The whole card opens the menu and reads as one button, "Units" with the current value,
    // rather than a hidden-label picker whose button would read only the value.
    Menu {
      Picker(L10n.Settings.Units.title, selection: $measurementSystem) {
        ForEach(MeasurementSystemPreference.allCases, id: \.self) { preference in
          Text(preference.localizedName).tag(preference)
        }
      }
      .pickerStyle(.inline)
    } label: {
      HStack(spacing: 8) {
        SettingCardLabel(L10n.Settings.Units.title, systemImage: "ruler", color: .orange)
        Spacer(minLength: 8)
        Text(measurementSystem.localizedName)
          .foregroundStyle(Color.accentColor)
        Image(systemName: "chevron.up.chevron.down")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.accentColor)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Settings.Units.title)
    .accessibilityValue(measurementSystem.localizedName)
  }
}

extension MeasurementSystemPreference {
  var localizedName: String {
    switch self {
    case .system: L10n.Settings.Units.system
    case .metric: L10n.Settings.Units.metric
    case .imperial: L10n.Settings.Units.imperial
    }
  }
}
