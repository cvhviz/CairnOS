import OSLog
import SwiftUI

/// Keyboard shortcuts for Mac and iPad hardware keyboards. File: ⌘N starts a chat, ⇧⌘N adds a
/// channel, ⌥⌘N opens another window (replacing the system New Window, which would otherwise
/// claim ⌘N). Go: ⌘1–5 switch tabs (Dashboard, Nodes, Comm, GPS, Spectrum), ⌃Tab / ⌃⇧Tab step through conversations. ⌘, opens
/// Settings. Radio: ⇧⌘C Connections, ⌘I Device Info, ⇧⌘A sends a flood advert, ⇧⌘D disconnects.
/// Nodes: ⌘F finds a node (the Nodes list's search field), ⌥⌘A adds one.
/// On iPad these show in the ⌘-hold overlay.
struct AppCommands: Commands {
  /// Scene id of the main `WindowGroup`, so New Window can open another one.
  static let mainWindowID = "main"

  let navigation: NavigationCoordinator
  /// The radio's actions (advert, disconnect) and its link state, for the Radio menu.
  let appState: AppState

  @Environment(\.openWindow) private var openWindow

  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "AppCommands")

  /// ⌘1–5 in tab-bar order.
  private var tabs: [(tab: AppTab, key: KeyEquivalent)] {
    [
      (.home, "1"),
      (.contacts, "2"),
      (.chats, "3"),
      (.gps, "4"),
      (.spectrum, "5")
    ]
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(L10n.Chats.Chats.Compose.newChat) {
        navigation.requestCompose(.chat)
      }
      .keyboardShortcut("n", modifiers: .command)

      Button(L10n.Chats.Chats.Compose.newChannel) {
        navigation.requestCompose(.channel)
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Divider()

      Button(L10n.Localizable.Commands.newWindow) {
        openWindow(id: Self.mainWindowID)
      }
      .keyboardShortcut("n", modifiers: [.command, .option])

      Divider()

      // ⌥⌘A: ⌘N and its shifted and optioned forms are taken above.
      Button(L10n.Contacts.Contacts.Add.nodeTitle) {
        navigation.requestAddNode()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
    }

    // ⌘F: the Nodes list's search field, scrolled into view and focused.
    CommandGroup(after: .textEditing) {
      Button(L10n.Contacts.Contacts.Commands.search) {
        navigation.requestNodesSearch()
      }
      .keyboardShortcut("f", modifiers: .command)
    }

    CommandGroup(replacing: .appSettings) {
      Button(L10n.Localizable.Tabs.settings) {
        navigation.presentSettings()
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandMenu(L10n.Localizable.Commands.go) {
      ForEach(tabs, id: \.tab) { entry in
        Button(entry.tab.title) {
          navigation.selectedTab = entry.tab.rawValue
        }
        .keyboardShortcut(entry.key, modifiers: .command)
      }

      Divider()

      Button(L10n.Localizable.Commands.previousConversation) {
        navigation.requestConversationStep(.previous)
      }
      .keyboardShortcut(.tab, modifiers: [.control, .shift])

      Button(L10n.Localizable.Commands.nextConversation) {
        navigation.requestConversationStep(.next)
      }
      .keyboardShortcut(.tab, modifiers: .control)
    }

    // The radio: its pages in Settings, and the two actions the status menu offers.
    CommandMenu(L10n.Localizable.Commands.radio) {
      Button(SettingsDetail.connections.title) {
        navigation.navigateToSetting(.connections)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])

      Button(SettingsDetail.deviceInfo.title) {
        navigation.navigateToSetting(.deviceInfo)
      }
      .keyboardShortcut("i", modifiers: .command)

      Divider()

      Button(L10n.Settings.BleStatus.sendFloodAdvert) {
        Task {
          do {
            try await appState.sendSelfAdvert(flood: true)
          } catch {
            Self.logger.error("Send advert from the Radio menu failed: \(error.localizedDescription)")
          }
        }
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
      .disabled(appState.connectionState != .ready)

      Button(L10n.Settings.BleStatus.disconnect) {
        Task { await appState.disconnect(reason: .userInitiated) }
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(appState.connectionState == .disconnected)
    }
  }
}
