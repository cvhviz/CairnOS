import CairnServices
import SwiftUI

struct TranslateIntoLanguageView: View {
  @Environment(\.locale) private var locale
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AppStorageKey.translationTargetLanguage.rawValue)
  private var translationTargetLanguage = AppStorageKey.defaultTranslationTargetLanguage
  @AppStorage(AppStorageKey.useDefaultTranslationApp.rawValue)
  private var useDefaultTranslationApp = AppStorageKey.defaultUseDefaultTranslationApp
  @State private var searchText = ""
  @State private var selectionTrigger = 0
  @State private var supportedCodes: [String] = []
  @State private var isLoadingSupportedCodes = true

  private var preference: TranslationTargetPreference {
    TranslationTargetPreference(rawValue: translationTargetLanguage)
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    CardForm {
      if isSearching {
        searchResults
      } else {
        useAppLanguageSection
        if !suggestedCodes.isEmpty {
          suggestedSection
        }
        languagesSection
      }
    }
    .searchable(text: $searchText, prompt: L10n.Settings.Language.Search.prompt)
    .flashingNavigationTitle(L10n.Settings.Language.TranslateInto.header)
    .navigationBarTitleDisplayMode(.inline)
    .cairnFeedback(.selection, trigger: selectionTrigger)
    .task {
      let codes = await TranslationLanguageAvailability.supportedCompactCodes()
      supportedCodes = codes
      isLoadingSupportedCodes = false
    }
  }

  private var onDeviceCodes: [String] {
    var codes = supportedCodes
    if !preference.isMatchAppLanguage {
      let current = MessageLanguageDetector.collapsedLanguageCode(preference.rawValue)
      if !codes.contains(where: { MessageLanguageDetector.isSameLanguage($0, current) }) {
        codes.append(current)
      }
    }
    return codes
  }

  private var suggestedCodes: [String] {
    TranslationTargetPreference.suggestedLanguageCodes(
      preferredLanguages: Locale.preferredLanguages,
      appLocale: locale,
      catalog: onDeviceCodes
    )
  }

  private var remainingOnDeviceCodes: [String] {
    let suggested = Set(suggestedCodes)
    return sorted(onDeviceCodes).filter { !suggested.contains($0) }
  }

  private var matchingOnDeviceCodes: [String] {
    sorted(onDeviceCodes).filter {
      TranslationTargetPreference.matchesSearchQuery(
        searchText,
        languageCode: $0,
        locale: locale
      )
    }
  }

  @ViewBuilder
  private var searchResults: some View {
    let matches = matchingOnDeviceCodes
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let showUseAppLanguage = L10n.Settings.Language.matchAppLanguage
      .localizedStandardContains(query)
    let unavailableCode = matches.isEmpty
      ? TranslationTargetPreference.unavailableLanguageCode(
        matchingSearchQuery: query,
        locale: locale,
        catalog: onDeviceCodes
      )
      : nil

    if matches.isEmpty, !showUseAppLanguage, unavailableCode == nil {
      ContentUnavailableView(
        L10n.Settings.Language.Search.noResults,
        systemImage: "magnifyingglass",
        description: Text(L10n.Settings.Language.Search.noResultsDescription(searchText))
      )
      .emptyStateFrame(below: CardStyle.formVerticalInset * 2)
    } else {
      if showUseAppLanguage || !matches.isEmpty {
        CardFormSection {
          ContentCard {
            if showUseAppLanguage {
              useAppLanguageRow
              if !matches.isEmpty {
                Divider()
              }
            }
            languageRows(matches)
          }
        }
      }
      if let unavailableCode {
        let name = TranslationTargetPreference.displayName(
          forLanguageCode: unavailableCode,
          in: locale
        )
        CardFormSection(footer: L10n.Settings.Language.Search.unavailable(name.localizedName)) {
          ContentCard {
            useDefaultTranslationAppRow
          }
        }
      }
    }
  }

  private var useAppLanguageSection: some View {
    CardFormSection {
      ContentCard {
        useAppLanguageRow
      }
    }
  }

  private var suggestedSection: some View {
    CardFormSection(L10n.Settings.Language.Suggested.header) {
      ContentCard {
        languageRows(suggestedCodes)
      }
    }
  }

  private var languagesSection: some View {
    // Why the list is short: only languages this device can translate in the app.
    CardFormSection(L10n.Settings.Language.All.header, info: L10n.Settings.Language.TranslateInto.listFooter) {
      ContentCard {
        if isLoadingSupportedCodes {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          languageRows(remainingOnDeviceCodes)
        }
      }
    }
  }

  /// One card's worth of language rows, separated like list rows.
  @ViewBuilder
  private func languageRows(_ codes: [String]) -> some View {
    ForEach(Array(codes.enumerated()), id: \.element) { index, code in
      if index > 0 {
        Divider()
      }
      catalogLanguageRow(code)
    }
  }

  private var useAppLanguageRow: some View {
    languageRow(
      title: L10n.Settings.Language.matchAppLanguage,
      subtitle: nil,
      selected: preference.isMatchAppLanguage
    ) {
      select(TranslationTargetPreference.matchAppLanguage.rawValue)
    }
  }

  private var useDefaultTranslationAppRow: some View {
    Button {
      useDefaultTranslationApp = true
      selectionTrigger += 1
      dismiss()
    } label: {
      Text(L10n.Settings.Language.DefaultTranslationApp.title)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
  }

  private func catalogLanguageRow(_ code: String) -> some View {
    let name = TranslationTargetPreference.displayName(forLanguageCode: code, in: locale)
    return languageRow(
      title: name.autonym,
      subtitle: name.subtitle,
      selected: !preference.isMatchAppLanguage
        && MessageLanguageDetector.isSameLanguage(preference.rawValue, code)
    ) {
      select(code)
    }
  }

  private func sorted(_ codes: [String]) -> [String] {
    codes.sorted {
      TranslationTargetPreference.displayName(forLanguageCode: $0, in: locale).autonym
        .localizedStandardCompare(
          TranslationTargetPreference.displayName(forLanguageCode: $1, in: locale).autonym
        ) == .orderedAscending
    }
  }

  private func select(_ rawValue: String) {
    translationTargetLanguage = rawValue
    useDefaultTranslationApp = false
    selectionTrigger += 1
  }

  private func languageRow(
    title: String,
    subtitle: String?,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let subtitle {
            Text(subtitle)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      // A full-size target: a title-only row would otherwise be one line of text tall.
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .modifier(OptionalAccessibilityValue(subtitle))
  }

  private struct OptionalAccessibilityValue: ViewModifier {
    let value: String?

    init(_ value: String?) {
      self.value = value
    }

    func body(content: Content) -> some View {
      if let value {
        content.accessibilityValue(value)
      } else {
        content
      }
    }
  }
}
