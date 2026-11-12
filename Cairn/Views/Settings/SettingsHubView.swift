import CairnServices
import SwiftUI
import UserNotifications

/// Settings, behind the gear: every setting in one place, laid out as the iPhone's own Settings.
///
/// - Connections on top: which radio is linked and how, opening the manager (every saved radio,
///   profiles). The radio's own details are Device Info, which the bar's title opens.
/// - This Radio: the connected radio's own pages, dimmed until one is connected (Nodes stays open:
///   its list layout and cleanup are the app's).
/// - App: the app's preferences, one page per subject.
/// - About: the app, its support links and credits; Advanced (debug logs, Demo Mode).
///
/// Each row shows its page's current state where that is cheap to know. A search field filters
/// every setting by name (`SettingsSearchIndex`) and opens the page it is on. Shared by the iPhone
/// sheet (`SettingsStack`, which pushes the pages) and the iPad's Settings, which shows them in the
/// column beside it (`SettingsTabSplit`).
struct SettingsHubView: View {
  @Environment(\.appState) private var appState
  @State private var query = ""
  @State private var notificationsAuthorized: Bool?
  @Environment(\.appTheme) private var theme
  /// The radio's title in the bar, as on the tabs. Off in the iPhone sheet, which is named Settings
  /// and closes with Done alone; the tab beneath already shows the link.
  var showsLinkStatus = true
  /// Rows fill the pane beside the hub (iPad) rather than pushing, the open page's row marked.
  var opensPagesInPane = false

  private var device: DeviceDTO? { appState.connectedDevice }

  var body: some View {
    CardForm {
      if query.trimmingCharacters(in: .whitespaces).isEmpty {
        CardFormSection {
          pageLink(.connections) {
            SettingsConnectionsHeader()
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("settings.radio")
        }

        CardFormSection(
          L10n.Settings.Hub.thisRadio,
          footer: device == nil ? L10n.Settings.Hub.noRadioFooter : nil
        ) {
          ForEach(SettingsDetail.thisRadio, id: \.self) { detail in
            row(detail)
              .disabled(device == nil && detail.isDeviceSetting)
          }
        }

        CardFormSection(L10n.Settings.Hub.appSection) {
          ForEach(SettingsDetail.app, id: \.self) { detail in
            row(detail)
          }
        }

        CardFormSection(L10n.Settings.Hub.aboutSection) {
          ForEach(SettingsDetail.aboutSection, id: \.self) { detail in
            row(detail)
          }
        }
      } else {
        searchResults
      }
    }
    // On the iPad's column the field sits under the bar, across the column; the iPhone sheet keeps
    // the system's place for it.
    .searchable(
      text: $query,
      placement: opensPagesInPane ? .navigationBarDrawer(displayMode: .always) : .automatic,
      prompt: L10n.Settings.Hub.searchPrompt
    )
    .modifier(SettingsHubTitle(showsRadioTitle: showsLinkStatus))
    .onAppear {
      // Recount on every appearance so the rows reflect changes made on a pushed page.
      Task { await refreshDetails() }
    }
  }

  /// Opens `detail`: pushed in the iPhone sheet, in the pane beside the hub on an iPad.
  @ViewBuilder
  private func pageLink<Label: View>(_ detail: SettingsDetail, @ViewBuilder label: () -> Label) -> some View {
    if opensPagesInPane {
      Button {
        appState.navigation.settingsPath = detail.settingsPath
      } label: {
        label()
          .overlay {
            if appState.navigation.settingsPath.first == detail {
              CardStyle.shape.strokeBorder(theme.accentColor, lineWidth: 2)
            }
          }
      }
    } else {
      NavigationLink(value: detail, label: label)
    }
  }

  private func row(_ detail: SettingsDetail) -> some View {
    pageLink(detail) {
      NavigationTile(detail.title, systemImage: detail.systemImage, color: detail.color, detail: value(for: detail))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("settings.row.\(detail)")
  }

  // MARK: - Search

  @ViewBuilder
  private var searchResults: some View {
    let results = SettingsSearchIndex.results(for: query)
    if results.isEmpty {
      ContentUnavailableView.search(text: query)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    } else {
      CardFormSection {
        ForEach(results) { result in
          pageLink(result.page) {
            NavigationTile(
              result.title,
              systemImage: result.page.systemImage,
              color: result.page.color,
              detail: result.title == result.page.title ? nil : result.page.title
            )
          }
          .buttonStyle(.plain)
          .disabled(device == nil && result.page.isDeviceSetting)
        }
      }
    }
  }

  // MARK: - Row values

  /// The one line of current state on a row, where it is cheap to know.
  private func value(for detail: SettingsDetail) -> String? {
    switch detail {
    case .radio:
      device.map { HomeStatusLines.presetName($0, region: appState.regionSelection) }
    case .location:
      device?.locationSharingSummary
    case .battery:
      device == nil ? nil : appState.radioBatteryPercent.map { "\($0)%" }
    case .connection:
      device == nil ? nil
        : HomeStatusLines.transportName(isWiFi: appState.connectionManager.currentTransportType == .wifi)
    case .deviceInfo:
      // Once a check on this radio found a newer release, say so here, where the page is found.
      FirmwareUpdateHubFlag.isAvailable(for: device?.id)
        ? L10n.Settings.FirmwareUpdate.available
        : device?.firmwareDisplayName
    case .notifications:
      notificationsAuthorized.map { $0 ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off }
    case .appearance:
      schemeLabel(appState.themeService.colorSchemePreference)
    case .about:
      Bundle.main.appVersion
    case .nodes, .firmwareUpdate, .clock, .connections, .chats, .gps, .spectrum, .carPlaySiri, .privacy, .backup,
         .advanced:
      nil
    }
  }

  private func schemeLabel(_ preference: AppColorSchemePreference) -> String {
    switch preference {
    case .system: L10n.Settings.Appearance.Scheme.system
    case .light: L10n.Settings.Appearance.Scheme.light
    case .dark: L10n.Settings.Appearance.Scheme.dark
    }
  }

  private func refreshDetails() async {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    notificationsAuthorized = status != .notDetermined && status != .denied
  }
}

/// The hub's name in the iPhone sheet; on an iPad the radio's title, as on the tabs, and Settings stays
/// the navigation title for VoiceOver.
private struct SettingsHubTitle: ViewModifier {
  let showsRadioTitle: Bool

  func body(content: Content) -> some View {
    if showsRadioTitle {
      content.deviceNameTitle(pageTitle: L10n.Settings.title)
    } else {
      content
        .navigationTitle(L10n.Settings.title)
        .navigationBarTitleDisplayMode(.large)
    }
  }
}

/// The hub's first row: Connections, the manager where a radio is chosen, added or switched, with
/// the radio linked now and how ("Basecamp · Ready · Bluetooth"), or a line saying none is.
private struct SettingsConnectionsHeader: View {
  @Environment(\.appState) private var appState

  var body: some View {
    HStack(spacing: 14) {
      IconTile(systemImage: SettingsDetail.connections.systemImage, color: SettingsDetail.connections.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.Settings.Connections.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        if let device = appState.connectedDevice {
          Text("\(device.nodeName) · \(linkLine)")
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
        } else {
          Text(L10n.Settings.Hub.noRadio)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
        }
        Text(L10n.Settings.Connections.linkDetail)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color(.tertiaryLabel))
        .accessibilityHidden(true)
    }
    .cardSurface(padding: 12)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  /// "Ready · Bluetooth": the link and the transport it runs over.
  private var linkLine: String {
    let state = HomeStatusLines.linkTitle(appState.connectionState)
    let transport = HomeStatusLines.transportName(isWiFi: appState.connectionManager.currentTransportType == .wifi)
    return "\(state) · \(transport)"
  }
}

/// What the hub's search field finds: each setting by the name its page gives it, plus a few words
/// people search for (in the app's own language where a page uses them as titles, and common English
/// terms such as "PIN" or "GIF"), each opening the page the setting is on.
enum SettingsSearchIndex {
  struct Result: Identifiable, Hashable {
    let title: String
    let page: SettingsDetail
    var id: String { "\(page)-\(title)" }
  }

  /// Settings shown by name in the results.
  private static var named: [(String, SettingsDetail)] {
    [
      (L10n.Settings.Radio.Receive.lna, .radio),
      (L10n.Settings.Radio.Receive.boost, .radio),
      (L10n.Settings.Location.autoUpdate, .gps),
      (L10n.Settings.Location.DeviceGps.eco, .gps),
      (L10n.Map.Map.Gps.Control.setManually, .gps),
      (L10n.Settings.Maps.appearance, .gps),
      (L10n.Settings.Maps.trafficFade, .gps),
      (L10n.Settings.Maps.offlineHeader, .gps),
      (L10n.Map.Map.Gps.Advert.title, .location),
      (L10n.Settings.BatteryCurve.header, .battery),
      (L10n.Settings.FirmwareUpdate.title, .deviceInfo),
      (L10n.Contacts.Contacts.TabSettings.layout, .nodes),
      (L10n.Contacts.Contacts.List.sort, .nodes),
      (L10n.Settings.Nodes.AutoAdd.header, .nodes),
      (L10n.Settings.Nodes.StaleCleanup.header, .nodes),
      (L10n.Settings.Nodes.Remove.header, .nodes),
      (L10n.Settings.Nodes.Alerts.header, .notifications),
      (L10n.Settings.Notifications.ChannelDefault.header, .notifications),
      (L10n.Settings.ReplyWithQuote.toggle, .chats),
      (L10n.Settings.PinFavoriteChats.toggle, .chats),
      (L10n.Settings.LinkPreviews.header, .chats),
      (L10n.Settings.MapPreviews.toggle, .chats),
      (L10n.Settings.Messages.header, .chats),
      (L10n.Settings.ChatSettings.translationHeader, .chats),
      (L10n.Settings.DirectMessages.acknowledgments, .chats),
      (L10n.Tools.Tools.Spectrum.Settings.defaultWindow, .spectrum),
      (L10n.Tools.Tools.Spectrum.Settings.chartStyle, .spectrum),
      (L10n.Settings.Units.title, .appearance),
      (L10n.Contacts.Contacts.Blocked.title, .privacy),
      (L10n.Settings.Blocking.ChannelSenders.title, .privacy),
      (L10n.Tools.Tools.signVerify, .privacy),
      (L10n.Settings.Connections.title, .connections),
    ]
  }

  /// Words that find a page without naming one setting on it.
  private static let keywords: [SettingsDetail: [String]] = [
    .radio: ["preset", "frequency", "tx power", "power", "bandwidth", "spreading", "coding rate", "region",
             "scope", "path hash", "tuning", "airtime", "repeat", "advert", "lora", "lna",
             "rx gain", "boost", "receive", "sensitivity", "front end"],
    .location: ["location", "sharing", "telemetry", "trusted", "position"],
    .battery: ["battery", "voltage", "ocv", "curve"],
    .nodes: ["contacts", "repeaters", "rooms", "auto-add", "auto add", "remove", "cleanup", "nodes"],
    .connection: ["pin", "bluetooth", "wifi", "wi-fi", "reboot", "factory reset", "forget", "disconnect",
                  "pairing", "import key", "regenerate", "identity", "private key"],
    // The radio's name is renamed on Device Info; Connection's rename is the Bluetooth display name.
    .deviceInfo: ["key", "public key", "storage", "name", "rename", "qr", "share"],
    .clock: ["clock", "time", "time zone", "timezone", "utc", "sync"],
    // Found by its own words, straight to the page (not via Device Info).
    .firmwareUpdate: ["firmware", "update", "release", "install"],
    .connections: ["radios", "profiles", "saved", "switch", "scan", "add radio"],
    .notifications: ["notifications", "alerts", "sounds", "badge", "low battery", "new node"],
    // Channels are added and managed on the Comm tab; Chats is their settings page.
    .chats: ["gif", "link", "preview", "quote", "favorites", "hops", "path", "translate", "acks", "channel",
             "channels"],
    .gps: ["gps", "map", "offline", "download", "phone location", "eco", "traffic"],
    .spectrum: ["spectrum", "noise", "update rate", "rows"],
    .appearance: ["dark", "light", "theme", "night", "background", "photo", "units", "metric", "imperial",
                  "language"],
    .carPlaySiri: ["carplay", "siri", "live activity", "shortcuts"],
    .privacy: ["block", "blocked", "keywords", "mute", "sign", "verify", "privacy"],
    .backup: ["backup", "restore", "export", "import", "config", "data"],
    .about: ["about", "version", "support", "credits", "help"],
    .advanced: ["logs", "debug", "diagnostics", "demo"],
  ]

  /// Matches in order: pages by their own name, settings by name, then pages found by a keyword. A
  /// radio page found without a radio still shows (dimmed), so the search says where a setting is.
  static func results(for query: String) -> [Result] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return [] }
    var results: [Result] = []
    var seen = Set<Result>()
    func add(_ result: Result) {
      if seen.insert(result).inserted { results.append(result) }
    }
    for page in SettingsDetail.thisRadio + SettingsDetail.app + SettingsDetail.aboutSection + [.connections]
      where page.title.localizedStandardContains(needle) {
      add(Result(title: page.title, page: page))
    }
    for (title, page) in named where title.localizedStandardContains(needle) {
      add(Result(title: title, page: page))
    }
    for page in SettingsDetail.allCases {
      if keywords[page, default: []].contains(where: { $0.localizedStandardContains(needle) }) {
        add(Result(title: page.title, page: page))
      }
    }
    return results
  }
}

#Preview {
  NavigationStack {
    SettingsHubView()
  }
  .environment(\.appState, AppState())
  .environment(\.isInSettings, true)
}
