import Foundation

/// Typed wrapper for `@AppStorage` / `UserDefaults` key strings: user
/// preferences and lightweight UI state in `UserDefaults.standard`.
/// Connection-infrastructure keys (reverse-DNS `cvhvisuals.Cairn.*`) and the
/// theme keys live in `PersistenceKeys`; the two namespaces never share a key.
///
/// Raw values are pinned to the exact on-disk key each callsite previously
/// used as a literal, so a case rename can't silently mint a new key and
/// orphan existing user data. Keep them pinned when adding cases.
///
/// A key added here does not survive backup/restore automatically: register
/// it in `BackupUserDefaults` (a mapping row or a special-cased branch)
/// unless the value is intentionally device-local.
public enum AppStorageKey: String {
  case hasCompletedOnboarding
  case liveActivityEnabled
  case scanMapShowsTraffic
  case showIncomingPath
  case showIncomingHopCount
  case showIncomingRegion
  case showIncomingHeardCount
  case linkPreviewsEnabled
  case linkPreviewsAutoResolveDM
  case linkPreviewsAutoResolveChannels
  /// Retained for the backup wire format only; the `linkPreviewsEnabled` master
  /// now gates inline images, so this value is round-tripped but never read.
  case showInlineImages
  case autoPlayGIFs
  case replyWithQuote
  case pinFavoriteChats
  case showMapPreviewThumbnails
  case nodesSortOrder
  /// The Nodes list shows favorites only, within whichever segment is picked.
  case nodesFavoritesOnly
  /// The Manual sort's order: public keys as uppercase hex, first to last. Device-local, not in
  /// BackupUserDefaults (an array key there needs a hand-written branch).
  case nodesManualOrder
  case discoverySortOrder
  /// `NodeDisplayMode` raw value: the Nodes tab shows rows or cards.
  case nodesDisplayMode
  /// `NodeDisplayMode` raw value: the Discover list shows rows or cards.
  case discoveryDisplayMode
  case addHopSortOrder
  case measurementSystem
  case tracePathViewMode
  case mapStyleSelection
  case mapShowLabels
  case mapClusteringEnabled
  case mapNorthLocked
  /// Whether the full compass's dial shows the nodes; its list shows them either way.
  case compassShowsNodes
  /// The full compass's settings sheet (`CompassSettingsSheet`). Device-local, not backed up.
  case compassNorthUp
  case compassUsesMagneticNorth
  case compassShowsSun
  case compassShowsCourse
  case compassShowsCompanions
  case compassShowsRepeaters
  case compassShowsRooms
  case compassNodeLimit
  case compassHaptics
  case compassKeepsScreenOn
  /// Night mode: the whole interface red on black (`NightMode`). Device-local, not backed up.
  case nightMode
  /// Per-host map filter JSON (`MapFilterState.storageString`).
  /// Raw values match `BackupUserDefaults` property names so coverage tests stay aligned.
  case mapFilterMainMap
  case mapFilterTracePath
  case mapFilterNeighborSNR
  case mapFilterNodeDiscovery
  case mapFilterLineOfSight
  /// JSON-encoded `HiddenMapNodes` (see `HiddenMapNodesStorage`).
  case hiddenMapNodes
  case mapColorSchemePreference
  /// JSON-encoded `AppBackground` (the page background: kind, colors, dim, blur, photo file
  /// name). Backed up; the photo itself is not, so a restore without it shows the system
  /// background.
  case appBackground
  case hasSeenRepeaterDragHint
  /// In-bubble Translate target. `"app"` follows the app locale; `"overlay"` is
  /// the system Translate sheet; any other value is a language subtag (`da`, `zh`).
  case translationTargetLanguage
  /// When true, tap-Translate opens the system Translate sheet. Separate from
  /// `translationTargetLanguage` so the language subtag is not overwritten.
  case useDefaultTranslationApp
  /// When false, incoming messages skip language detection and show no
  /// in-bubble Translate button.
  case translationOffersEnabled
  case autoDeleteStaleNodesDays
  case lastStaleCleanupDate
  case frequentEmojis
  case recentReactionEmojis
  case blockedKeywords
  /// JSON-encoded `[ContactGroup]` (see `ContactGroupsStorage`).
  case contactGroups
  case defaultChannelNotificationLevel
  case isDemoModeUnlocked
  case isDemoModeEnabled
  /// Intentionally device-local: not registered in BackupUserDefaults so restored
  /// hardware still shows the current release's notes once. Registering it would
  /// suppress the sheet on a genuinely new device.
  case lastShownWhatsNewVersion
  /// `SpectrumWindow` raw value (Int): the time window the Spectrum chart starts with. Intentionally
  /// device-local, a view preference not registered in BackupUserDefaults (Int keys there need
  /// hand-written branches, and a restored device can pick its own).
  case spectrumDefaultWindow
  case spectrumChartStyle
  case supportPromptFirstUse
  case supportPromptConnections
  case supportPromptLastShown
  /// Seconds (Int) between the Spectrum tab's radio readings: 5 (Normal) or 2 (Live). Intentionally
  /// device-local, a battery preference not registered in BackupUserDefaults (Int keys there need
  /// hand-written branches, and the battery trade-off belongs to the device).
  case spectrumUpdateRate
  /// How many packets (Int) the Spectrum traffic table lists. Intentionally device-local, a view
  /// preference not registered in BackupUserDefaults (Int keys there need hand-written branches).
  case spectrumTrafficRows
  /// Whether the maps (Map, Trace Path, Scan for Nodes) draw live traffic: the links packets
  /// crossed lately and a laser for each as it arrives. Intentionally device-local.
  case mapShowsTraffic
  /// Whether a logged-in repeater or room Dashboard reads its settings (radio, behavior, owner
  /// info, firmware, room access) and checks its clock as soon as the status lands, or only when
  /// their cards are opened. Off: the page sends the status request alone, which spares the mesh's
  /// airtime. Intentionally device-local.
  case remoteNodesLoadSettingsOnOpen
  /// Seconds (Int) a traffic link's line and a repeater's green ring stay after their last packet,
  /// on the Traffic map and the maps' traffic layer (Settings › Maps). Intentionally device-local,
  /// a view preference not registered in BackupUserDefaults (Int keys there need hand-written
  /// branches).
  case trafficFadeSeconds
  /// Whether the Traffic map pins every located contact, quiet ones faded, or only those sending
  /// lately (Bool). Intentionally device-local, a view preference not registered in BackupUserDefaults.
  case trafficShowsAllContacts
  /// Which nodes the Scan & Traffic map pins besides the routes' (`TrafficMapNodes`).
  case trafficMapNodes
  /// How many tips (Int) this device has left in Settings › About › Support Development; above zero
  /// shows the thank-you line. Intentionally device-local, not registered in BackupUserDefaults.
  case tipJarCount
  /// Whether opening Cairn reconnects to the last radio (Bool, Settings › Connections). Off, the
  /// radio waits for a tap; once connected, a dropped link still reconnects. Intentionally
  /// device-local: whether this phone should reach for the radio is the phone's choice.
  case connectOnLaunch
  /// Whether the Nodes tab's Saved list has its Favorites group folded away (Bool). Intentionally
  /// device-local, a view preference not registered in BackupUserDefaults.
  case nodesFavoritesCollapsed
  /// Whether the Nodes tab's Saved list has the group under its Favorites, the other saved nodes,
  /// folded away (Bool). Intentionally device-local, a view preference not registered in
  /// BackupUserDefaults.
  case nodesOthersCollapsed
  /// Whether the Comm tab's conversation list has its Favorites group folded away (Bool).
  /// Intentionally device-local, a view preference not registered in BackupUserDefaults.
  case chatsFavoritesCollapsed
  /// `NodesSection` raw value: the Nodes tab's Saved / Heard pick, restored at launch. Written only
  /// by the picker itself, so a jump to Heard from elsewhere isn't remembered as a choice.
  /// Intentionally device-local, a view preference not registered in BackupUserDefaults.
  case nodesSection

  // Notification toggles read by NotificationPreferences and
  // NotificationPreferencesStore; all share defaultNotificationEnabled.
  case notifyContactMessages
  case notifyChannelMessages
  case notifyRoomMessages
  case notifyNewContacts
  case notifyNewContactsContact
  case notifyNewContactsRepeater
  case notifyNewContactsRoom
  case notifyReactions
  case notificationSoundEnabled
  case notificationBadgeEnabled
  case notifyLowBattery
  /// The "Cairn may not be receiving" reminder (ListeningReminder).
  case notifyNotReceiving
  /// Radio queue losses no notification reported yet (RadioQueueLossLedger). Device-local, not
  /// backed up: it describes this phone's radio, and is cleared once the user has seen it.
  case radioQueueLossUnseen
  case radioQueueLossDevice
  /// Quiet hours (NotificationPreferences): on/off, the window's start and end as minutes past
  /// midnight, and whether direct messages still come through as full alerts.
  case notificationQuietHoursEnabled
  case notificationQuietHoursStart
  case notificationQuietHoursEnd
  case notificationQuietHoursAllowDirect
  /// The app-wide haptics switch (Settings → Appearance), honoured by `cairnFeedback`.
  case hapticFeedbackEnabled
  /// The ID of the radio whose last firmware check found a newer release; empty when the last
  /// check found none. Device-local: it names this phone's radio.
  case firmwareUpdateAvailableDeviceID
  /// Wardrive's first-run note (the screen stays on, GPS runs in the background) has been shown.
  /// Device-local.
  case hasSeenWardriveNote
  /// `NodeDiscoverySortOrder` raw value: how Scan & Traffic's nodes are ordered. Device-local, a
  /// view preference.
  case scanNodesSortOrder
  /// JSON array of `CompanionCLICommand` ids pinned at the top of the CLI's command picker.
  /// Device-local.
  case pinnedCompanionCommands
  /// `NetworkHealthSort` raw value: how Network Health orders each group. Device-local.
  case networkHealthSort

  public static let defaultShowIncomingPath: Bool = false
  /// On: how far a message travelled is worth seeing without a trip to Settings.
  public static let defaultShowIncomingHopCount: Bool = true
  public static let defaultShowIncomingRegion: Bool = false
  public static let defaultShowIncomingHeardCount: Bool = true
  public static let defaultLinkPreviewsEnabled: Bool = false
  public static let defaultLinkPreviewsAutoResolveDM: Bool = true
  public static let defaultLinkPreviewsAutoResolveChannels: Bool = true
  public static let defaultAutoPlayGIFs: Bool = true
  public static let defaultReplyWithQuote: Bool = false
  public static let defaultPinFavoriteChats: Bool = true
  public static let defaultShowMapPreviewThumbnails: Bool = true
  public static let defaultMapShowLabels: Bool = true
  public static let defaultMapClusteringEnabled: Bool = true
  public static let defaultMapNorthLocked: Bool = false
  public static let defaultShowDiscoveredNodesOnMap: Bool = false
  /// Raw value of `AppColorSchemePreference.system` — basemap only, not app chrome.
  public static let defaultMapColorSchemePreference: String = "system"
  public static let defaultHasSeenRepeaterDragHint: Bool = false
  /// Sentinel: in-bubble Translate follows the app locale.
  public static let defaultTranslationTargetLanguage: String = "app"
  public static let defaultUseDefaultTranslationApp: Bool = false
  public static let defaultTranslationOffersEnabled: Bool = true
  public static let defaultLiveActivityEnabled: Bool = true
  /// Days before a non-favorite node is auto-deleted; 0 disables cleanup.
  public static let defaultAutoDeleteStaleNodesDays: Int = 0
  /// `timeIntervalSinceReferenceDate` of the last cleanup; 0 means never ran.
  public static let defaultLastStaleCleanupDate: Double = 0
  /// `SpectrumWindow.oneMinute`'s raw value.
  public static let defaultSpectrumWindow: Int = 1
  /// `SpectrumUpdateRate.normal`: a reading every 5 seconds.
  public static let defaultSpectrumUpdateRate: Int = 5
  public static let defaultSpectrumTrafficRows: Int = 8
  /// On: the lasers are what the maps are for on a busy mesh; anyone who switched them off keeps it.
  public static let defaultMapShowsTraffic = true
  /// Off: opening a repeater asks only for its status; each setting is read when its card opens
  /// (the user, 2026-11-08, on a report of the Dashboard's airtime).
  public static let defaultRemoteNodesLoadSettingsOnOpen = false
  public static let defaultTrafficFadeSeconds = 60
  public static let defaultConnectOnLaunch = true
  public static let defaultCompassNodeLimit: Int = 12
  /// Shared default for every notification toggle case.
  public static let defaultNotificationEnabled: Bool = true
  /// Quiet hours start off; the window defaults to 22:00–07:00 once switched on.
  public static let defaultNotificationQuietHoursEnabled: Bool = false
  public static let defaultNotificationQuietHoursStart: Int = 22 * 60
  public static let defaultNotificationQuietHoursEnd: Int = 7 * 60
  public static let defaultNotificationQuietHoursAllowDirect: Bool = true
  public static let defaultHapticFeedbackEnabled: Bool = true
}
