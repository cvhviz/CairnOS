import CairnServices
import SwiftUI

/// Settings → Chats → Translation: whether incoming messages offer Translate, the language they
/// translate into, and handing off to the default translation app instead. Lives with Chats
/// because it acts on messages. Translate Into is a view-destination link, so it pushes in every
/// stack that hosts the section (the Comm tab's sheet has a `[SettingsDetail]` path, which can't
/// hold another value type).
struct TranslationSettingsSection: View {
  @Environment(\.locale) private var locale
  @AppStorage(AppStorageKey.translationTargetLanguage.rawValue)
  private var translationTargetLanguage = AppStorageKey.defaultTranslationTargetLanguage
  @AppStorage(AppStorageKey.useDefaultTranslationApp.rawValue)
  private var storedUseDefaultTranslationApp = AppStorageKey.defaultUseDefaultTranslationApp
  @AppStorage(AppStorageKey.translationOffersEnabled.rawValue)
  private var translationOffersEnabled = AppStorageKey.defaultTranslationOffersEnabled

  private var preference: TranslationTargetPreference {
    TranslationTargetPreference(rawValue: translationTargetLanguage)
  }

  private var usesSystemOverlay: Bool {
    storedUseDefaultTranslationApp
  }

  var body: some View {
    CardFormSection(L10n.Settings.ChatSettings.translationHeader, info: infoMessage) {
      ToggleCard(
        L10n.Settings.Language.TranslationOffers.title,
        systemImage: "translate",
        color: .blue,
        isOn: $translationOffersEnabled
      )

      NavigationLink {
        TranslateIntoLanguageView()
      } label: {
        NavigationTile(
          L10n.Settings.Language.TranslateInto.header,
          systemImage: "character.bubble.fill",
          color: .indigo,
          detail: translateIntoDetail
        )
      }
      .buttonStyle(.plain)
      .disabled(translateIntoDisabled)
      // The plain style doesn't dim a disabled card; do it so the state is visible.
      .opacity(translateIntoDisabled ? 0.5 : 1)

      ToggleCard(
        L10n.Settings.Language.DefaultTranslationApp.title,
        systemImage: "arrow.up.forward.app.fill",
        color: .gray,
        isOn: useDefaultTranslationApp
      )
      .disabled(!translationOffersEnabled)
    }
  }

  private var translateIntoDisabled: Bool {
    usesSystemOverlay || !translationOffersEnabled
  }

  private var useDefaultTranslationApp: Binding<Bool> {
    Binding(
      get: { usesSystemOverlay },
      set: { storedUseDefaultTranslationApp = $0 }
    )
  }

  /// Explains the switches in their current state: what Off means, or where translations go.
  private var infoMessage: String {
    if !translationOffersEnabled {
      return L10n.Settings.Language.TranslationOffers.offFooter
    }
    return usesSystemOverlay
      ? L10n.Settings.Language.DefaultTranslationApp.footer
      : L10n.Settings.Language.TranslateInto.footer + "\n\n" + L10n.Settings.Language.DefaultTranslationApp.footer
  }

  private var translateIntoDetail: String {
    preference.detailLabel(appLocale: locale, displayLocale: locale)
  }
}
