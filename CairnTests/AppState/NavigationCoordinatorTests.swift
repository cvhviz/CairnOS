import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Navigation Coordinator Notification Handler Tests")
@MainActor
struct NavigationCoordinatorNotificationTests {
  // MARK: - Test Helpers

  private static func makeContact(
    id: UUID = UUID(),
    radioID: UUID = UUID(),
    name: String = "TestContact"
  ) -> ContactDTO {
    ContactDTO(
      id: id,
      radioID: radioID,
      publicKey: Data(repeating: 0xAA, count: 32),
      name: name,
      typeRawValue: 0x01,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  private static func makeChannel(
    id: UUID = UUID(),
    radioID: UUID = UUID(),
    name: String = "TestChannel",
    index: UInt8 = 0
  ) -> ChannelDTO {
    ChannelDTO(
      id: id,
      radioID: radioID,
      index: index,
      name: name,
      secret: Data(),
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      notificationLevel: .all,
      isFavorite: false
    )
  }

  private static func makeDeviceDTO(manualAddContacts: Bool = false) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      publicKey: Data(repeating: 0xBB, count: 32),
      nodeName: "TestNode",
      firmwareVersion: 1,
      firmwareVersionString: "1.12.0",
      manufacturerName: "Test",
      buildDate: "2025-01-01",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      manualAddContacts: manualAddContacts,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  /// Creates an in-memory data store seeded with a contact and channel.
  private static func makeSeededDataStore(
    contact: ContactDTO,
    channel: ChannelDTO
  ) async throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let dataStore = PersistenceStore(modelContainer: container)
    try await dataStore.saveContact(contact)
    try await dataStore.saveChannel(channel)
    return dataStore
  }

  // MARK: - DM Notification Tap

  @Test
  func `DM notification tap navigates to chat with contact`() async throws {
    let contact = Self.makeContact()
    let dataStore = try await Self.makeSeededDataStore(
      contact: contact,
      channel: Self.makeChannel()
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { nil }
    )

    // Invoke the handler directly
    await notificationService.onNotificationTapped?(contact.id)

    #expect(coordinator.pendingChatContact?.id == contact.id)
    #expect(coordinator.chatsSelectedRoute == .direct(contact))
    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
  }

  // MARK: - New Contact Notification Tap

  @Test
  func `New contact notification with manualAddContacts navigates to discovery`() async throws {
    let contact = Self.makeContact()
    let dataStore = try await Self.makeSeededDataStore(
      contact: contact,
      channel: Self.makeChannel()
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()
    let device = Self.makeDeviceDTO(manualAddContacts: true)

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { device }
    )

    await notificationService.onNewContactNotificationTapped?(contact.id)

    #expect(coordinator.nodesSection == .heard)
    #expect(coordinator.selectedTab == AppTab.contacts.rawValue)
  }

  @Test
  func `New contact notification without manualAddContacts navigates to contact detail`() async throws {
    let contact = Self.makeContact()
    let dataStore = try await Self.makeSeededDataStore(
      contact: contact,
      channel: Self.makeChannel()
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()
    let device = Self.makeDeviceDTO(manualAddContacts: false)

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { device }
    )

    await notificationService.onNewContactNotificationTapped?(contact.id)

    #expect(coordinator.pendingContactDetail?.id == contact.id)
    #expect(coordinator.selectedTab == AppTab.contacts.rawValue)
  }

  // MARK: - Channel Notification Tap

  @Test
  func `Channel notification tap navigates to channel`() async throws {
    let radioID = UUID()
    let channelIndex: UInt8 = 3
    let channel = Self.makeChannel(radioID: radioID, index: channelIndex)
    let dataStore = try await Self.makeSeededDataStore(
      contact: Self.makeContact(),
      channel: channel
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { nil }
    )

    await notificationService.onChannelNotificationTapped?(radioID, channelIndex)

    #expect(coordinator.pendingChannel?.id == channel.id)
    #expect(coordinator.chatsSelectedRoute == .channel(channel))
    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
  }

  // MARK: - Reaction Notification Tap

  @Test
  func `Reaction notification on DM navigates to chat with scrollToMessageID`() async throws {
    let contact = Self.makeContact()
    let messageID = UUID()
    let dataStore = try await Self.makeSeededDataStore(
      contact: contact,
      channel: Self.makeChannel()
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { nil }
    )

    await notificationService.onReactionNotificationTapped?(contact.id, nil, nil, messageID)

    #expect(coordinator.pendingChatContact?.id == contact.id)
    #expect(coordinator.pendingScrollToMessageID == messageID)
    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
  }

  @Test
  func `Reaction notification on channel navigates to channel with scrollToMessageID`() async throws {
    let radioID = UUID()
    let channelIndex: UInt8 = 1
    let channel = Self.makeChannel(radioID: radioID, index: channelIndex)
    let messageID = UUID()
    let dataStore = try await Self.makeSeededDataStore(
      contact: Self.makeContact(),
      channel: channel
    )
    let coordinator = NavigationCoordinator()
    let notificationService = NotificationService()

    coordinator.configureNotificationHandlers(
      notificationService: notificationService,
      dataStore: dataStore,
      connectedDevice: { nil }
    )

    // contactID is nil → falls through to channel branch
    await notificationService.onReactionNotificationTapped?(nil, channelIndex, radioID, messageID)

    #expect(coordinator.pendingChannel?.id == channel.id)
    #expect(coordinator.pendingScrollToMessageID == messageID)
    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
  }
}

@Suite("NavigationCoordinator Map Navigation Tests")
@MainActor
struct NavigationCoordinatorMapTests {
  @Test
  func `navigateToMap sets pendingMapFocus and opens the GPS tab on its map`() {
    let coordinator = NavigationCoordinator()
    let coordinate = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.00902)

    coordinator.navigateToMap(coordinate: coordinate)

    #expect(coordinator.pendingMapFocus?.latitude == 37.3349)
    #expect(coordinator.pendingMapFocus?.longitude == -122.00902)
    #expect(coordinator.pendingMapFocus?.coordinate.latitude == 37.3349)
    #expect(coordinator.selectedTab == AppTab.gps.rawValue)
    #expect(coordinator.gpsSegment == .map)
  }

  @Test
  func `ChatViewModel.navigateToMap forwards the coordinate to the navigation sink`() {
    let coordinator = NavigationCoordinator()
    let viewModel = ChatViewModel()
    viewModel.onNavigateToMap = { coordinator.navigateToMap(coordinate: $0) }
    let coordinate = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    // The thumbnail tap path ends at ChatViewModel.navigateToMap, which forwards
    // to the same navigation sink ChatsView.handleMeshCoreLink uses for the text link.
    viewModel.navigateToMap(coordinate)

    #expect(coordinator.pendingMapFocus?.latitude == 51.5074)
    #expect(coordinator.pendingMapFocus?.longitude == -0.1278)
    #expect(coordinator.selectedTab == AppTab.gps.rawValue)
  }

  @Test
  func `clearPendingMapFocus resets the pending focus`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToMap(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2))

    coordinator.clearPendingMapFocus()

    #expect(coordinator.pendingMapFocus == nil)
  }
}

@Suite("NavigationCoordinator Settings Navigation Tests")
@MainActor
struct NavigationCoordinatorSettingsTests {
  @Test
  func `a shortcut opens Settings on its page, and the gear on the hub`() {
    let coordinator = NavigationCoordinator()

    coordinator.navigateToSetting(.connections)
    #expect(coordinator.opensSettingsOnPage)
    #expect(coordinator.settingsPath == [.connections])

    coordinator.dismissSettings()
    coordinator.presentSettings()
    #expect(!coordinator.opensSettingsOnPage)
    #expect(coordinator.settingsPath.isEmpty)
  }

  @Test
  func `a link from the hub keeps the hub beneath it`() {
    let coordinator = NavigationCoordinator()

    coordinator.presentSettings()
    coordinator.navigateToSetting(.about)

    #expect(!coordinator.opensSettingsOnPage)
    #expect(coordinator.settingsPath == [.about])
  }

  @Test
  func `navigateToSetting opens Settings on the page over the current tab`() {
    let coordinator = NavigationCoordinator()
    coordinator.selectedTab = AppTab.chats.rawValue

    coordinator.navigateToSetting(.about)

    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath == [.about])
    #expect(coordinator.selectedTab == AppTab.chats.rawValue)
    #expect(coordinator.homePath.isEmpty)
  }

  @Test(arguments: SettingsDetail.allCases)
  func `Every page opens in Settings, never on another tab`(detail: SettingsDetail) {
    let coordinator = NavigationCoordinator()
    coordinator.selectedTab = AppTab.gps.rawValue

    coordinator.navigateToSetting(detail)

    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath.last == detail)
    #expect(coordinator.selectedTab == AppTab.gps.rawValue)
    #expect(coordinator.homePath.isEmpty)
  }

  @Test
  func `Firmware Update opens over Device Info, so Back goes there`() {
    let coordinator = NavigationCoordinator()

    coordinator.navigateToSetting(.firmwareUpdate)

    #expect(coordinator.settingsPath == [.deviceInfo, .firmwareUpdate])
  }

  @Test
  func `A page asked for with Settings open replaces whichever page is pushed`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.radio)
    coordinator.settingsPath.append(.connections)

    coordinator.navigateToSetting(.chats)

    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath == [.chats])
  }

  @Test(arguments: [
    (AppTab.chats, SettingsDetail.chats),
    (.contacts, .nodes),
    (.gps, .gps),
    (.spectrum, .spectrum),
  ])
  func `Each tab's sliders open its page in Settings`(tab: AppTab, page: SettingsDetail) {
    #expect(tab.settingsPage == page)
  }

  @Test
  func `Home has the gear, not sliders`() {
    #expect(AppTab.home.settingsPage == nil)
  }

  @Test
  func `The gear opens the hub, dropping a page left open`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.battery)
    coordinator.dismissSettings()

    coordinator.presentSettings()

    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath.isEmpty)
  }

  @Test
  func `Done closes Settings`() {
    let coordinator = NavigationCoordinator()
    coordinator.presentSettings()

    coordinator.dismissSettings()

    #expect(!coordinator.isSettingsPresented)
  }

  @Test
  func `Selecting a tab closes Settings`() {
    let coordinator = NavigationCoordinator()
    coordinator.presentSettings()

    coordinator.selectedTab = AppTab.contacts.rawValue

    #expect(!coordinator.isSettingsPresented)
  }

  @Test
  func `A cross-tab jump from inside Settings closes it`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.appearance)

    coordinator.navigateToDiscovery()

    #expect(!coordinator.isSettingsPresented)
    #expect(coordinator.selectedTab == AppTab.contacts.rawValue)
  }

  @Test
  func `An app-started firmware update keeps Settings open and on its page`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.firmwareUpdate)
    coordinator.holdsDevicePagesForUpdate = true

    coordinator.navigateToDiscovery()
    coordinator.presentSettings()
    coordinator.clearPerDeviceSelection()

    #expect(coordinator.isSettingsPresented)
    #expect(coordinator.settingsPath == [.deviceInfo, .firmwareUpdate])
  }

  @Test
  func `The hub lists every page but Firmware Update and Connections, once`() {
    let listed = SettingsDetail.thisRadio + SettingsDetail.app + SettingsDetail.aboutSection
    #expect(Set(listed).count == listed.count)
    #expect(Set(listed) == Set(SettingsDetail.allCases).subtracting([.firmwareUpdate, .clock, .connections]))
  }

  @Test
  func `Search finds a setting by name, a page by a keyword, and nothing for nonsense`() {
    #expect(SettingsSearchIndex.results(for: "PIN").contains { $0.page == .connection })
    #expect(SettingsSearchIndex.results(for: "gif").contains { $0.page == .chats })
    #expect(SettingsSearchIndex.results(for: L10n.Settings.Units.title).contains { $0.page == .appearance })
    #expect(SettingsSearchIndex.results(for: "zzqx").isEmpty)
    #expect(SettingsSearchIndex.results(for: "  ").isEmpty)
  }
}

@Suite("NavigationCoordinator Tool Navigation Tests")
@MainActor
struct NavigationCoordinatorToolTests {
  @Test
  func `navigateToTool selects Home with the tool as the only page on its stack`() {
    let coordinator = NavigationCoordinator()
    coordinator.selectedTab = AppTab.contacts.rawValue
    coordinator.navigateToSetting(.radio)

    coordinator.navigateToTool(.nodeDiscovery)

    #expect(coordinator.selectedTab == AppTab.home.rawValue)
    #expect(coordinator.homePath == [.tool(.nodeDiscovery)])
    #expect(coordinator.selectedTool == .nodeDiscovery)
  }

  @Test
  func `navigateToTool for Spectrum switches to the Spectrum tab`() {
    let coordinator = NavigationCoordinator()

    coordinator.navigateToTool(.spectrum)

    #expect(coordinator.selectedTab == AppTab.spectrum.rawValue)
    #expect(coordinator.homePath.isEmpty)
  }

  @Test
  func `navigateToScan for packets opens Scan & Traffic, where the Traffic page was, on its Packets`() {
    let coordinator = NavigationCoordinator()
    coordinator.selectedTab = AppTab.chats.rawValue

    coordinator.navigateToScan(section: .packets)

    #expect(coordinator.selectedTab == AppTab.home.rawValue)
    #expect(coordinator.homePath == [.tool(.nodeDiscovery)])
    #expect(coordinator.selectedTool == .nodeDiscovery)
    #expect(coordinator.pendingScanSection == .packets)
  }

  @Test
  func `navigateToScan on an open page keeps one page and asks for the new section`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToScan(section: .packets)
    // The page took the section.
    coordinator.pendingScanSection = nil

    coordinator.navigateToScan(section: .nodes)

    #expect(coordinator.homePath == [.tool(.nodeDiscovery)])
    #expect(coordinator.pendingScanSection == .nodes)
  }
}

@Suite("NavigationCoordinator Pending Link Tests")
@MainActor
struct NavigationCoordinatorPendingLinkTests {
  @Test
  func `pendingContactLink starts nil and clears via helper`() {
    let coordinator = NavigationCoordinator()
    #expect(coordinator.pendingContactLink == nil)
    coordinator.pendingContactLink = MeshCoreURLParser.ContactResult(
      name: "Alice",
      publicKey: Data(repeating: 0xAB, count: 32),
      contactType: .chat
    )
    #expect(coordinator.pendingContactLink != nil)
    coordinator.clearPendingContactLink()
    #expect(coordinator.pendingContactLink == nil)
  }

  @Test
  func `pendingChannelLink starts nil and clears via helper`() {
    let coordinator = NavigationCoordinator()
    #expect(coordinator.pendingChannelLink == nil)
    coordinator.pendingChannelLink = MeshCoreURLParser.ChannelResult(
      name: "general",
      secret: Data(repeating: 0xCC, count: 16)
    )
    #expect(coordinator.pendingChannelLink != nil)
    coordinator.clearPendingChannelLink()
    #expect(coordinator.pendingChannelLink == nil)
  }

  @Test
  func `pendingHashtag starts nil and clears via helper`() {
    let coordinator = NavigationCoordinator()
    #expect(coordinator.pendingHashtag == nil)
    coordinator.pendingHashtag = HashtagJoinRequest(id: "#general")
    #expect(coordinator.pendingHashtag != nil)
    coordinator.clearPendingHashtag()
    #expect(coordinator.pendingHashtag == nil)
  }

  // MARK: - clearPendingLinks (per-radio teardown)

  private static func makeContact(name: String = "TestContact") -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0xAA, count: 32),
      name: name,
      typeRawValue: 0x01,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      unreadMentionCount: 0,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }

  @Test
  func `clearPendingLinks clears the hoisted Nodes selected contact`() {
    let coordinator = NavigationCoordinator()
    coordinator.selectedContact = Self.makeContact()
    #expect(coordinator.selectedContact != nil)

    coordinator.clearPendingLinks()

    #expect(coordinator.selectedContact == nil)
  }

  @Test
  func `clearPendingLinks keeps the Nodes tab's Saved or Heard choice`() {
    let coordinator = NavigationCoordinator()
    coordinator.nodesSection = .heard

    coordinator.clearPendingLinks()

    #expect(coordinator.nodesSection == .heard)
  }

  @Test
  func `the Nodes tab opens on the Saved or Heard list last picked`() throws {
    let suiteName = "NodesSectionLaunch-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(NavigationCoordinator.storedNodesSection(in: defaults) == .saved)
    defaults.set(NodesSection.heard.rawValue, forKey: AppStorageKey.nodesSection.rawValue)
    #expect(NavigationCoordinator.storedNodesSection(in: defaults) == .heard)
    defaults.set(NodesSection.saved.rawValue, forKey: AppStorageKey.nodesSection.rawValue)
    #expect(NavigationCoordinator.storedNodesSection(in: defaults) == .saved)
    defaults.set("unknown", forKey: AppStorageKey.nodesSection.rawValue)
    #expect(NavigationCoordinator.storedNodesSection(in: defaults) == .saved)
  }

  @Test
  func `clearPendingLinks clears every staged per-radio field at once`() {
    let coordinator = NavigationCoordinator()
    coordinator.pendingContactLink = MeshCoreURLParser.ContactResult(
      name: "Alice",
      publicKey: Data(repeating: 0xAB, count: 32),
      contactType: .chat
    )
    coordinator.pendingChannelLink = MeshCoreURLParser.ChannelResult(
      name: "general",
      secret: Data(repeating: 0xCC, count: 16)
    )
    coordinator.pendingHashtag = HashtagJoinRequest(id: "#general")
    coordinator.selectedContact = Self.makeContact()
    coordinator.chatsSelectedRoute = .direct(Self.makeContact())
    coordinator.navigateToSetting(.radio)

    coordinator.clearPendingLinks()

    #expect(coordinator.pendingContactLink == nil)
    #expect(coordinator.pendingChannelLink == nil)
    #expect(coordinator.pendingHashtag == nil)
    #expect(coordinator.selectedContact == nil)
    #expect(coordinator.chatsSelectedRoute == nil)
    #expect(coordinator.homePath.isEmpty)
  }

  // MARK: - clearPerRadioSelection

  @Test
  func `clearPerRadioSelection clears the hoisted Chats route`() {
    let coordinator = NavigationCoordinator()
    coordinator.chatsSelectedRoute = .direct(Self.makeContact())

    coordinator.clearPerRadioSelection()

    #expect(coordinator.chatsSelectedRoute == nil)
  }

  @Test
  func `clearPerRadioSelection keeps an open tool, which shows its own disconnected state`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToTool(.cli)

    coordinator.clearPerRadioSelection()

    #expect(coordinator.homePath == [.tool(.cli)])
    #expect(coordinator.selectedTool == .cli)
  }

  @Test
  func `clearPerRadioSelection pops a radio page off Settings and leaves Settings open`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.radio)

    coordinator.clearPerRadioSelection()

    #expect(coordinator.settingsPath.isEmpty)
    #expect(coordinator.isSettingsPresented)
  }

  @Test
  func `clearPerDeviceSelection pops Settings back to below the first radio page`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToSetting(.connections)
    coordinator.settingsPath.append(contentsOf: [.connection, .deviceInfo])

    coordinator.clearPerDeviceSelection()

    #expect(coordinator.settingsPath == [.connections])
  }

  /// Device Info shows "No Device Connected" with its way to Connections, so a disconnect or switch
  /// made on Connections over it leaves it open; the radio's pages over it still close.
  @Test(arguments: [
    ([SettingsDetail.deviceInfo], [SettingsDetail.deviceInfo]),
    ([.deviceInfo, .firmwareUpdate], [.deviceInfo]),
    ([.connections, .deviceInfo, .firmwareUpdate], [.connections, .deviceInfo]),
    ([.deviceInfo, .connections], [.deviceInfo, .connections]),
  ])
  func `clearPerDeviceSelection keeps Device Info open`(path: [SettingsDetail], expected: [SettingsDetail]) {
    let coordinator = NavigationCoordinator()
    coordinator.presentSettings()
    coordinator.settingsPath = path

    coordinator.clearPerDeviceSelection()

    #expect(coordinator.settingsPath == expected)
    #expect(coordinator.isSettingsPresented)
  }

  @Test
  func `only Device Info of the radio's pages stays open without a radio`() {
    let staying = SettingsDetail.allCases.filter { $0.isDeviceSetting && !$0.popsWithoutRadio }
    #expect(staying == [.deviceInfo])
    #expect(SettingsDetail.allCases.allSatisfy { !$0.popsWithoutRadio || $0.isDeviceSetting })
  }

  @Test
  func `clearPerDeviceSelection keeps an app page and Home's tools`() {
    let coordinator = NavigationCoordinator()
    coordinator.navigateToTool(.cli)
    coordinator.navigateToSetting(.gps)

    coordinator.clearPerDeviceSelection()

    #expect(coordinator.settingsPath == [.gps])
    #expect(coordinator.homePath == [.tool(.cli)])
  }
}
