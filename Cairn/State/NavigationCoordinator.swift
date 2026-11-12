import CoreLocation
import CairnServices
import SwiftUI

/// Manages tab selection, pending navigation targets, and cross-tab navigation coordination.
@Observable
@MainActor
final class NavigationCoordinator {
  /// Selected tab index (an `AppTab` raw value). Every launch starts on Home. Any tab selection
  /// closes Settings, so a cross-tab jump (a notification tap, a deep link, a Home card, ⌘1–⌘5) is
  /// never left hidden behind the Settings sheet or the iPad's Settings cover. Not
  /// while an app-started firmware update holds its page in Settings: closing it would end the
  /// upload (`holdsDevicePagesForUpdate`).
  var selectedTab: Int = NavigationCoordinator.launchTab {
    didSet {
      if !holdsDevicePagesForUpdate {
        isSettingsPresented = false
      }
    }
  }

  /// Home, or under UI tests `-uiTestTab <AppTab raw value>`: screenshot runs open each tab by
  /// relaunching.
  private static var launchTab: Int {
    #if DEBUG
      if UserDefaults.standard.object(forKey: "uiTestTab") != nil,
         let tab = AppTab(rawValue: UserDefaults.standard.integer(forKey: "uiTestTab")) {
        return tab.rawValue
      }
    #endif
    return AppTab.home.rawValue
  }

  /// Whether Settings is showing. Settings is not a tab: the gear on Home's toolbar
  /// (`settingsGearToolbarItem()`), ⌘, and every shortcut to a setting (`navigateToSetting(_:)`)
  /// set this. Compact width presents it as a sheet from `MainTabView`; regular width (iPad) covers
  /// the tabs with its hub beside its page (`SettingsTabSplit`), so the same flag drives both and
  /// survives a size-class change between them.
  var isSettingsPresented = false

  /// Settings was opened straight onto a page by a shortcut, not on its hub. The iPhone sheet then
  /// shows that page as its first, with Done and nothing to go back to: a shortcut comes back to
  /// where it was tapped, not to the hub. The iPad's Settings always keeps the hub beside it.
  private(set) var opensSettingsOnPage = false

  /// The pages pushed over the Settings hub (`SettingsStack`). Held here so any shortcut can open
  /// Settings straight onto a page (`navigateToSetting(_:)`), and a disconnect can pop the radio's
  /// pages (`SettingsDetail.popsWithoutRadio`).
  var settingsPath: [SettingsDetail] = []

  /// Device Info's sheet at regular width, which the tab view presents (`MainTabView`). Not from
  /// the title that opens it: in a list column's toolbar the sheet's Done didn't close it.
  var deviceInfoSheet = DeviceInfoSheetFlow()

  /// Which page the GPS tab shows. Set to `.map` by `navigateToMap(coordinate:)` so a chat
  /// coordinate tap lands on the map rather than the position readout; `GPSView` binds its
  /// segmented control to it.
  var gpsSegment: GPSSegment = .position

  var tabBarVisibility: Visibility = .visible

  /// Contact to navigate to
  var pendingChatContact: ContactDTO?

  /// The currently selected route in the Chats split view detail pane
  var chatsSelectedRoute: ChatRoute?

  /// Channel to navigate to
  var pendingChannel: ChannelDTO?

  /// Room session to navigate to
  var pendingRoomSession: RemoteNodeSessionDTO?

  /// Room session a notification tap wants the user to authenticate into, set
  /// when the tapped room is not currently connected. ChatsView presents
  /// RoomAuthenticationSheet, mirroring a disconnected-room list tap.
  var pendingRoomAuthentication: RemoteNodeSessionDTO?

  /// Contact to navigate to (for detail view on Contacts tab)
  var pendingContactDetail: ContactDTO?

  /// The currently selected contact in the Contacts split view detail pane. Kept in memory
  /// only and never persisted: it carries a public key and `radioID` (identity-bearing
  /// data) that must not be written outside the encrypted backup envelope.
  var selectedContact: ContactDTO?

  /// The heard node open in the Nodes tab's iPad detail column (`ContactsDetailColumn`), picked
  /// from the Heard list. In memory only, like `selectedContact`; at compact width the Heard list
  /// shows the node as a sheet instead and never sets this.
  var selectedHeardNode: DiscoveredNodeDTO?

  /// The Saved list's kind filter (All, Contacts, Repeaters, Rooms). Held here rather than in the
  /// tab's views so a switch between the compact stack and the iPad columns (a rotation, Split
  /// View) keeps it, as `nodesSection` is kept.
  var nodesSegment: NodeSegment = .all

  /// The Nodes tab's search text, shared by both layouts for the same reason as `nodesSegment`.
  var nodesSearchText = ""

  /// Bumped by `requestNodesSearch()` (⌘F), so the Nodes list scrolls its search field into view
  /// and focuses it on each press.
  private(set) var nodesSearchRequestVersion = 0

  /// Bumped by `requestAddNode()`, so the Nodes tab opens its Add Node sheet on each press.
  private(set) var addNodeRequestVersion = 0

  /// Switches to Nodes and asks its list to reveal and focus the search field.
  func requestNodesSearch() {
    showTab(.contacts)
    nodesSearchRequestVersion += 1
  }

  /// Switches to Nodes and asks it to present the Add Node sheet.
  func requestAddNode() {
    showTab(.contacts)
    addNodeRequestVersion += 1
  }

  /// Which list the Nodes tab shows: the nodes saved on the radio, or the nodes heard by advert
  /// that aren't saved. Held here rather than in the tab's views so `navigateToDiscovery()` can
  /// switch it from anywhere, and the compact stack and the iPad columns agree on it. Each launch
  /// starts on the list last picked in `NodesSectionPicker`.
  var nodesSection: NodesSection = NavigationCoordinator.storedNodesSection()

  /// The Saved / Heard pick `NodesSectionPicker` stored, or Saved.
  static func storedNodesSection(in defaults: UserDefaults = .standard) -> NodesSection {
    defaults.string(forKey: AppStorageKey.nodesSection.rawValue)
      .flatMap(NodesSection.init(rawValue:)) ?? .saved
  }

  /// Whether the Nodes tab shows its Heard list. Kept as a view onto `nodesSection` for the
  /// per-radio reset and the toolbar resume probe, which predate the segment.
  var nodesShowingDiscovery: Bool {
    get { nodesSection == .heard }
    set { nodesSection = newValue ? .heard : .saved }
  }

  /// Home's navigation stack: the tools pushed over the dashboard. Held here rather than in
  /// `HomeView` so other tabs can open a tool on Home (`navigateToTool`) and the stack survives the
  /// iPad section-switch teardown. The radio's own pages are in Settings (`settingsPath`).
  var homePath: [HomeRoute] = []

  /// Set while an app-started firmware update runs. The radio drops its link on purpose to install
  /// and comes back on the new build, so its pages (Device Info, Firmware Update) stay put rather
  /// than popping under the update.
  var holdsDevicePagesForUpdate = false

  /// A route for Trace Path to start from, set by `navigateToTraceRoute(_:)` and cleared once taken.
  var pendingTraceRoute: [Data]?

  /// The section Scan & Traffic should show, set by `navigateToScan(section:)` and cleared once taken.
  var pendingScanSection: NodeDiscoverySection?

  /// The tool open on Home's stack, if any (the topmost one).
  var selectedTool: ToolSelection? {
    for route in homePath.reversed() {
      if case let .tool(tool) = route { return tool }
    }
    return nil
  }

  /// Message to scroll to after navigation (for reaction notifications)
  var pendingScrollToMessageID: UUID?

  /// Coordinate the GPS tab's map should drop a pin on and center, set by a chat coordinate tap.
  var pendingMapFocus: MapFocusRequest?

  /// Pending contact-add confirmation triggered by a `meshcore://contact/add` link tap inside any chat surface.
  var pendingContactLink: MeshCoreURLParser.ContactResult?

  /// Pending channel-join confirmation triggered by a `meshcore://channel/...` link tap inside any chat surface.
  var pendingChannelLink: MeshCoreURLParser.ChannelResult?

  /// Pending hashtag-channel join sheet triggered by a `cairn://hashtag/...` link tap inside any chat surface.
  var pendingHashtag: HashtagJoinRequest?

  /// A name for the Nodes tab's Heard list to search for on arrival, set by
  /// `navigateToDiscovery(searching:)` (the Send DM sheet's "Find in Nodes") and cleared once taken.
  var pendingNodesSearch: String?

  // MARK: - Navigation

  func navigateToChat(with contact: ContactDTO, scrollToMessageID: UUID? = nil) {
    tabBarVisibility = .hidden // Hide tab bar BEFORE switching tabs
    pendingChatContact = contact
    pendingScrollToMessageID = scrollToMessageID
    chatsSelectedRoute = .direct(contact)
    showTab(.chats)
  }

  func navigateToRoom(with session: RemoteNodeSessionDTO) {
    tabBarVisibility = .hidden // Hide tab bar BEFORE switching tabs
    pendingRoomSession = session
    chatsSelectedRoute = .room(session)
    showTab(.chats)
  }

  func navigateToChannel(with channel: ChannelDTO, scrollToMessageID: UUID? = nil) {
    tabBarVisibility = .hidden
    pendingChannel = channel
    pendingScrollToMessageID = scrollToMessageID
    chatsSelectedRoute = .channel(channel)
    showTab(.chats)
  }

  /// Opens the Nodes tab on its Heard list, in place (no push).
  func navigateToDiscovery() {
    nodesSection = .heard
    showTab(.contacts)
  }

  /// Opens the Heard list searched for `name`, so a sender known only by name can be found.
  func navigateToDiscovery(searching name: String) {
    pendingNodesSearch = name
    navigateToDiscovery()
  }

  func clearPendingNodesSearch() {
    pendingNodesSearch = nil
  }

  func navigateToContacts() {
    showTab(.contacts)
  }

  func navigateToContactDetail(_ contact: ContactDTO) {
    pendingContactDetail = contact
    showTab(.contacts)
  }

  /// A node-detail action requested from outside the detail view (the Nodes
  /// list context menu). The detail view's sheets are owned by its own state,
  /// so the list opens the detail and the detail performs the action on appear.
  enum ContactQuickAction: Equatable {
    case telemetry
    case management
    case ping
    /// Starts a path discovery for a chat contact (the row's context menu).
    case discoverPath
  }

  struct PendingContactAction: Equatable {
    let contactID: UUID
    let action: ContactQuickAction
  }

  private(set) var pendingContactAction: PendingContactAction?

  /// Opens `contact`'s detail and has it perform `action` once it appears.
  func navigateToContactDetail(_ contact: ContactDTO, performing action: ContactQuickAction) {
    pendingContactAction = PendingContactAction(contactID: contact.id, action: action)
    navigateToContactDetail(contact)
  }

  /// Hands the pending action to the detail view showing `contactID`, once.
  func consumePendingContactAction(for contactID: UUID) -> ContactQuickAction? {
    guard let pending = pendingContactAction, pending.contactID == contactID else { return nil }
    pendingContactAction = nil
    return pending.action
  }

  /// Opens Settings on `detail`, its one home, over the current tab (the iPhone sheet, or the iPad's
  /// cover with the hub beside the page, so Done comes back to it). Every shortcut to a setting comes here: a
  /// Home card, a tab's sliders, the radio button, a link on another page. With Settings already
  /// open, the page replaces whichever is pushed, over the same first page.
  func navigateToSetting(_ detail: SettingsDetail) {
    if !isSettingsPresented { opensSettingsOnPage = true }
    settingsPath = detail.settingsPath
    isSettingsPresented = true
  }

  /// Opens Settings on `detail` pushed over its hub, so the page has Back to Settings rather than a
  /// Done of its own (the radio's title opening Device Info on a phone). With Settings already
  /// open, as `navigateToSetting(_:)`.
  func navigateToSettingOverHub(_ detail: SettingsDetail) {
    // Device Info is the exception: from anywhere it is the sheet's first page, whose Back (on the
    // left; Disconnect keeps the right) closes Settings and returns to the page it came from, the
    // Dashboard (the user, 2026-11-07: Back went to the Settings hub instead).
    if !isSettingsPresented { opensSettingsOnPage = detail == .deviceInfo }
    settingsPath = detail.settingsPath
    isSettingsPresented = true
  }

  /// Opens Settings (the toolbar gear, ⌘,) on its hub.
  func presentSettings() {
    opensSettingsOnPage = false
    if !holdsDevicePagesForUpdate {
      settingsPath = []
    }
    isSettingsPresented = true
  }

  /// Closes Settings (Done, on the iPhone sheet and the iPad's hub).
  func dismissSettings() {
    isSettingsPresented = false
  }

  /// Selects `tab` for a programmatic jump (a notification, a shortcut, a deep link, a Home card),
  /// which also closes Settings (see `selectedTab`): the conversation, node or tool the jump opens
  /// would otherwise land under it.
  func showTab(_ tab: AppTab) {
    selectedTab = tab.rawValue
  }

  func clearPendingNavigation() {
    pendingChatContact = nil
  }

  func clearPendingRoomNavigation() {
    pendingRoomSession = nil
  }

  func clearPendingRoomAuthentication() {
    pendingRoomAuthentication = nil
  }

  func clearPendingChannelNavigation() {
    pendingChannel = nil
  }

  func clearPendingScrollToMessage() {
    pendingScrollToMessageID = nil
  }

  func clearPendingContactDetailNavigation() {
    pendingContactDetail = nil
  }

  func clearPendingMapFocus() {
    pendingMapFocus = nil
  }

  func clearPendingContactLink() {
    pendingContactLink = nil
  }

  func clearPendingChannelLink() {
    pendingChannelLink = nil
  }

  // MARK: - Compose shortcuts

  /// What a keyboard shortcut asked the Chats list to start composing.
  enum ComposeRequest: Equatable {
    case chat
    case channel
  }

  /// Latest compose request and a counter bumped per request, so the Chats list
  /// reacts to each press even when the same kind is requested twice in a row.
  private(set) var composeRequest: ComposeRequest?
  private(set) var composeRequestVersion = 0

  /// Switches to Chats and asks its list to present the New Chat or New Channel sheet.
  func requestCompose(_ request: ComposeRequest) {
    showTab(.chats)
    composeRequest = request
    composeRequestVersion += 1
  }

  // MARK: - Conversation stepping

  /// Direction for the previous/next conversation keyboard shortcuts.
  enum ConversationStep: Equatable {
    case previous
    case next
  }

  /// Latest step request plus a counter bumped per press, so repeated presses in the same
  /// direction each move the selection.
  private(set) var conversationStep: ConversationStep?
  private(set) var conversationStepVersion = 0

  /// Switches to Chats and asks its list to select the previous or next conversation.
  func requestConversationStep(_ step: ConversationStep) {
    showTab(.chats)
    conversationStep = step
    conversationStepVersion += 1
  }

  func clearPendingHashtag() {
    pendingHashtag = nil
  }

  /// Clears deep-link confirmation state and every per-radio detail selection so a pending sheet
  /// cannot re-present, and a selection made on the previous radio cannot drive a detail pane,
  /// after the connection is torn down and replaced.
  func clearPendingLinks() {
    pendingContactLink = nil
    pendingChannelLink = nil
    pendingHashtag = nil
    clearPerRadioSelection()
  }

  /// Resets every detail selection scoped to the current radio so a stale selection cannot aim a
  /// section's detail pane at the wrong radio. Runs on disconnect and on a direct radio-to-radio
  /// switch. Line of Sight is preserved because it runs offline and is not radio-scoped.
  func clearPerRadioSelection() {
    selectedContact = nil
    selectedHeardNode = nil
    // `nodesSection` stays: Saved / Heard is a list choice rather than a detail aimed at a radio,
    // and the Heard list reloads for whichever radio connects next.
    chatsSelectedRoute = nil
    clearPerDeviceSelection()
  }

  /// Clears only device-scoped pages: Settings' stack pops back to below the first of the radio's
  /// own pages, so neither it nor anything pushed above it is left showing a radio that is gone.
  /// Device Info stays (`SettingsDetail.popsWithoutRadio`): it shows its own disconnected state and
  /// connects a saved radio from there. Home's tools stay open (each shows its own disconnected
  /// state), and so does an open Chats/Nodes detail, so a manual disconnect does not eject the user
  /// from an open conversation.
  func clearPerDeviceSelection() {
    guard !holdsDevicePagesForUpdate else { return }
    if let index = settingsPath.firstIndex(where: \.popsWithoutRadio) {
      settingsPath.removeSubrange(index...)
    }
  }

  // MARK: - Notification Handlers

  /// Configure notification tap handlers that navigate to conversations.
  /// Called from AppState.configureNotificationHandlers() when services become available.
  func configureNotificationHandlers(
    notificationService: NotificationService,
    dataStore: PersistenceStore,
    connectedDevice: @escaping @Sendable @MainActor () -> DeviceDTO?
  ) {
    // Direct message notification tap
    notificationService.onNotificationTapped = { [weak self] contactID in
      guard let self else { return }
      guard let contact = try? await dataStore.fetchContact(id: contactID) else { return }
      navigateToChat(with: contact)
    }

    // New contact notification tap
    notificationService.onNewContactNotificationTapped = { [weak self] contactID in
      guard let self else { return }
      if connectedDevice()?.manualAddContacts == true {
        navigateToDiscovery()
      } else {
        guard let contact = try? await dataStore.fetchContact(id: contactID) else {
          navigateToContacts()
          return
        }
        navigateToContactDetail(contact)
      }
    }

    // Channel notification tap
    notificationService.onChannelNotificationTapped = { [weak self] radioID, channelIndex in
      guard let self else { return }
      guard let channel = try? await dataStore.fetchChannel(radioID: radioID, index: channelIndex) else { return }
      navigateToChannel(with: channel)
    }

    // Reaction notification tap
    notificationService.onReactionNotificationTapped = { [weak self] contactID, channelIndex, radioID, messageID in
      guard let self else { return }
      if let contactID,
         let contact = try? await dataStore.fetchContact(id: contactID) {
        navigateToChat(with: contact, scrollToMessageID: messageID)
      } else if let channelIndex, let radioID,
                let channel = try? await dataStore.fetchChannel(radioID: radioID, index: channelIndex) {
        navigateToChannel(with: channel, scrollToMessageID: messageID)
      }
    }

    // Room notification tap. Resolves the full session from the stable
    // sessionID carried in the notification. A connected room opens directly;
    // a disconnected room is routed to the auth sheet, mirroring the list-row
    // gate, instead of the iPad detail pane rendering an ungated read-only room.
    notificationService.onRoomNotificationTapped = { [weak self] sessionID in
      guard let self else { return }
      guard let session = try? await dataStore.fetchRemoteNodeSession(id: sessionID) else { return }
      if session.isConnected {
        navigateToRoom(with: session)
      } else {
        showTab(.chats)
        pendingRoomAuthentication = session
      }
    }
  }
}
