import CairnServices
import SwiftUI

/// Settings › Chats (`SettingsDetail.chats`), also what the Comm tab's sliders open: how
/// conversations behave, as sections right on the page — General (quoting, pinning), link and map
/// previews, message details, translation, and (with a radio connected) direct message
/// acknowledgments. Each section keeps its "i". Notifications, the level new channels start with and
/// Blocked have one home each elsewhere in Settings (Notifications, Privacy & Blocking).
struct ChatSettingsView: View {
  @Environment(\.appState) private var appState
  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote
  @AppStorage(AppStorageKey.pinFavoriteChats.rawValue) private var pinFavoriteChats = AppStorageKey.defaultPinFavoriteChats

  var body: some View {
    CardForm {
      CardFormSection(
        L10n.Settings.ChatSettings.generalHeader,
        info: L10n.Settings.ReplyWithQuote.footer + "\n\n" + L10n.Settings.PinFavoriteChats.footer
      ) {
        ToggleCard(L10n.Settings.ReplyWithQuote.toggle, systemImage: "text.quote", color: .blue, isOn: $replyWithQuote)
        ToggleCard(L10n.Settings.PinFavoriteChats.toggle, systemImage: "star.fill", color: .yellow, isOn: $pinFavoriteChats)
      }

      LinkPreviewSettingsSection()
      MessagesSettingsSection()
      TranslationSettingsSection()

      // Saved on the radio, so only there while one is connected; left out rather than shown
      // disabled, since the page is otherwise all app preferences.
      if appState.connectedDevice != nil {
        DirectMessagesSettingsSection()
      }
    }
    .flashingNavigationTitle(SettingsDetail.chats.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    ChatSettingsView()
  }
  .environment(\.appState, AppState())
}
