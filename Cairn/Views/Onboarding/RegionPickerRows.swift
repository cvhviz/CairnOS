import CairnServices
import SwiftUI

/// Country + state rows, plus a county row for states with county-scoped presets, laid out for
/// one card (a divider between them). Hosts apply `regionPickerSheet` on the page; a sheet
/// attached here is presented once per row.
struct RegionPickerRows: View {
  enum Sheet: Identifiable {
    case country
    case subdivision
    case county
    var id: Self {
      self
    }
  }

  @Binding var selection: RegionSelection?
  @Binding var activeSheet: Sheet?

  private var country: String? {
    selection?.countryCode
  }

  private var subdivision: String? {
    selection?.administrativeAreaCode
  }

  private var county: String? {
    selection?.countyKey
  }

  var body: some View {
    row(L10n.Onboarding.Region.country, value: countryDisplay) {
      activeSheet = .country
    }
    if RegionalAreas.showsSubdivisionPicker(for: country) {
      Divider()
      row(administrativeAreaTitle(for: country), value: subdivisionDisplay) {
        activeSheet = .subdivision
      }
    }
    // Without it a hand-picked place can never reach a county preset's county.
    if RegionalAreas.showsCountyPicker(country: country, state: subdivision) {
      Divider()
      row(L10n.Onboarding.Region.county, value: countyDisplay) {
        activeSheet = .county
      }
    }
  }

  /// A row inside a card that opens its picker sheet: title, current value, chevron.
  private func row(_ title: String, value: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        LabeledContent(title) {
          Text(value)
        }
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .frame(minHeight: 32)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  private var countryDisplay: String {
    guard let country else { return L10n.Settings.Radio.PresetLocation.notSet }
    return Locale.current.localizedString(forRegionCode: country) ?? country
  }

  private var subdivisionDisplay: String {
    guard let subdivision else { return L10n.Settings.Radio.PresetLocation.notSet }
    return RegionalAreas.subdivisionDisplayName(subdivision) ?? subdivision
  }

  private var countyDisplay: String {
    guard let county else { return L10n.Settings.Radio.PresetLocation.notSet }
    if county == RegionalAreas.otherCountyKey { return L10n.Onboarding.Region.County.other }
    return RegionalAreas.countyDisplayName(county)
  }
}

extension View {
  func regionPickerSheet(
    _ activeSheet: Binding<RegionPickerRows.Sheet?>,
    selection: Binding<RegionSelection?>
  ) -> some View {
    sheet(item: activeSheet) { sheet in
      switch sheet {
      case .country:
        CountryPickerSheet(selectedCountry: selection.wrappedValue?.countryCode) { newCountry in
          if let next = RegionSelection.afterChoosingCountry(
            newCountry,
            current: selection.wrappedValue
          ) {
            selection.wrappedValue = next
          }
        }
      case .subdivision:
        SubdivisionPickerSheet(
          country: selection.wrappedValue?.countryCode,
          selectedSubdivision: selection.wrappedValue?.administrativeAreaCode
        ) { newSubdivision in
          if let next = RegionSelection.afterChoosingSubdivision(
            newSubdivision,
            current: selection.wrappedValue
          ) {
            selection.wrappedValue = next
          }
        }
      case .county:
        CountyPickerSheet(
          country: selection.wrappedValue?.countryCode,
          state: selection.wrappedValue?.administrativeAreaCode,
          selectedCounty: selection.wrappedValue?.countyKey
        ) { newCounty in
          if let next = RegionSelection.afterChoosingCounty(
            newCounty,
            current: selection.wrappedValue
          ) {
            selection.wrappedValue = next
          }
        }
      }
    }
  }
}

private struct CountryPickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let selectedCountry: String?
  let onSelect: (String) -> Void

  @State private var search = ""

  private var filtered: [RegionalAreas.Country] {
    let all = RegionalAreas.countriesSortedByLocalizedName
    guard !search.isEmpty else { return all }
    return all.filter { $0.localizedName.localizedStandardContains(search) }
  }

  var body: some View {
    NavigationStack {
      List(filtered) { entry in
        Button {
          onSelect(entry.id)
          dismiss()
        } label: {
          HStack {
            Text(entry.localizedName)
            Spacer()
            if entry.id == selectedCountry { Image(systemName: "checkmark") }
          }
        }
        .cardListRow(theme, isSelected: entry.id == selectedCountry)
      }
      .cardListCanvas(theme)
      .searchable(text: $search)
      .flashingNavigationTitle(L10n.Onboarding.Region.country)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
  }
}

private struct SubdivisionPickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let country: String?
  let selectedSubdivision: String?
  let onSelect: (String) -> Void

  @State private var search = ""

  private var rows: [RegionalAreas.Subdivision] {
    let all = RegionalAreas.subdivisions(for: country)
    guard !search.isEmpty else { return all }
    return all.filter {
      (RegionalAreas.subdivisionDisplayName($0.id) ?? $0.englishName)
        .localizedStandardContains(search)
    }
  }

  var body: some View {
    NavigationStack {
      List(rows) { row in
        Button {
          onSelect(row.id)
          dismiss()
        } label: {
          HStack {
            Text(RegionalAreas.subdivisionDisplayName(row.id) ?? row.englishName)
            Spacer()
            if row.id == selectedSubdivision { Image(systemName: "checkmark") }
          }
        }
        .cardListRow(theme, isSelected: row.id == selectedSubdivision)
      }
      .cardListCanvas(theme)
      .searchable(text: $search)
      .flashingNavigationTitle(administrativeAreaTitle(for: country))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
  }
}

/// The state's counties with presets of their own, between "Not set" (county unknown, so the
/// state's county presets stay listed) and "Other county" (`RegionalAreas.otherCountyKey`, a
/// county not listed, which moves those presets to Other regions).
private struct CountyPickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let country: String?
  let state: String?
  let selectedCounty: String?
  let onSelect: (String?) -> Void

  private var counties: [String] {
    RegionalAreas.counties(country: country, state: state)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          countyRow(nil, title: L10n.Settings.Radio.PresetLocation.notSet)
          ForEach(counties, id: \.self) { county in
            countyRow(county, title: RegionalAreas.countyDisplayName(county))
          }
          countyRow(RegionalAreas.otherCountyKey, title: L10n.Onboarding.Region.County.other)
        } footer: {
          Text(L10n.Onboarding.Region.County.footer)
        }
      }
      .cardListCanvas(theme)
      .flashingNavigationTitle(L10n.Onboarding.Region.county)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
  }

  private func countyRow(_ county: String?, title: String) -> some View {
    Button {
      onSelect(county)
      dismiss()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if county == selectedCounty { Image(systemName: "checkmark") }
      }
    }
    .cardListRow(theme, isSelected: county == selectedCounty)
  }
}

private func administrativeAreaTitle(for country: String?) -> String {
  switch RegionalAreas.administrativeAreaKind(for: country) {
  case .province: L10n.Onboarding.Region.province
  case .state: L10n.Onboarding.Region.state
  }
}
