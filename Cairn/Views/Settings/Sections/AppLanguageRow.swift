import SwiftUI

/// The app's language, as a card on Settings → Appearance that opens the app's page in iOS
/// Settings, where iOS keeps the per-app language (as Apple's own apps do).
struct AppLanguageRow: View {
  @Environment(\.locale) private var locale
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      if let url = URL(string: UIApplication.openSettingsURLString) {
        openURL(url)
      }
    } label: {
      HStack(spacing: 8) {
        SettingCardLabel(L10n.Settings.Language.AppLanguage.title, systemImage: "globe", color: .blue)
        Spacer(minLength: 8)
        Text(appLanguageDisplayName)
          .foregroundStyle(.secondary)
        Image(systemName: "arrow.up.right")
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Settings.Language.AppLanguage.accessibilityHint)
  }

  private var appLanguageDisplayName: String {
    let code = Bundle.main.preferredLocalizations.first ?? "en"
    return locale.localizedString(forLanguageCode: code) ?? code
  }
}
