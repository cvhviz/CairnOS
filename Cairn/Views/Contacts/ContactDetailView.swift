import MapKit
import CairnServices
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the Map's node sheet adds when it hosts Contact Detail. The map behind the sheet already
/// shows where the node is, so the header drops its map; the sheet closes before the app moves
/// to a chat or room, and the map reloads its pins after a delete.
struct ContactDetailMapHost {
  /// Opens the conversation; the page closes the sheet first.
  let onMessage: () -> Void
  /// Called after the node is deleted and the sheet closed.
  let onDelete: () -> Void
  /// Hides the node from the Map tab; nil on maps that do not offer hiding.
  let onHide: (() -> Void)?
}

/// Detailed view for a single contact
struct ContactDetailView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.isPresented) private var isPresented
  /// `dismiss`, or on a Mac where this page is its own window, closing that window.
  @CloseDetail private var closePage

  let contact: ContactDTO
  let showFromDirectChat: Bool
  let onClearMessages: () -> Void
  /// Set when the Map's node sheet hosts this page; nil everywhere else.
  let mapHost: ContactDetailMapHost?
  /// Cards a host adds before the contact's own, such as how a repeater hears this node when the
  /// page opens from that repeater's Neighbors list.
  let extraCards: [NodeDashboardCardItem]

  /// Sheet types for the contact detail view
  private enum ActiveSheet: Identifiable, Hashable {
    case nodeAuth
    case repeaterStatus(RemoteNodeSessionDTO)
    case roomStatus(RemoteNodeSessionDTO)
    case nodeTelemetry(ContactDTO)
    case adminSettings(RemoteNodeSessionDTO)

    var id: String {
      switch self {
      case .nodeAuth: "auth"
      case let .repeaterStatus(session): "status-\(session.id)"
      case let .roomStatus(session): "room-status-\(session.id)"
      case let .nodeTelemetry(contact): "telemetry-\(contact.id)"
      case let .adminSettings(session): "admin-settings-\(session.id)"
      }
    }
  }

  @State private var currentContact: ContactDTO
  @State private var showRenameSheet = false
  @State private var showingBlockAlert = false
  @State private var showingHideMapConfirmation = false
  @State private var showingDeleteAlert = false
  /// The delete command got no answer in time; the alert offers to send it again.
  @State private var showingDeleteTimedOut = false
  @State private var showingClearMessagesAlert = false
  @State private var isClearingMessages = false
  @State private var isFavorite: Bool
  @State private var favoriteTask: Task<Void, Never>?
  @State private var errorMessage: String?
  @State private var pathViewModel = PathManagementViewModel()
  @State private var showRoomJoinSheet = false
  @State private var activeSheet: ActiveSheet?
  @State private var pendingSheet: ActiveSheet?
  // Admin access navigation state (separate from telemetry sheet flow)
  @State private var showRepeaterAdminAuth = false
  @State private var adminSession: RemoteNodeSessionDTO?
  /// QR sharing state
  @State private var showQRShareSheet = false
  // Ping state
  @State private var isPinging = false
  @State private var pingResult: PingResult?
  @State private var isSharing = false
  @State private var showShareSuccess = false
  @State private var headerHeight: CGFloat = 150
  @State private var showFullMap = false
  /// The route page (rediscover, edit, reset), opened from its tool tile, the More menu and the
  /// header's context menu now that the route is in the header rather than a Details row.
  @State private var showsRoutePage = false
  /// The avatar's photo and colour editing (pickers, crop step, colour sheet).
  @State private var avatarEditor = AvatarEditor()
  /// The last packet the RX log holds from this node, and for a repeater or room its latest
  /// stored status: read once on open from what's already saved, with no request to the node.
  @State private var heardSignal: RxLogEntryDTO?
  @State private var storedStatus: NodeStatusSnapshotDTO?
  /// The stored battery readings of the last week, for the Battery card's trend line.
  @State private var batteryTrend: [MetricChartView.DataPoint] = []
  /// The last snapshot carrying the node's telemetry (what it shared, or a repeater's sensors read
  /// at login), for the header's sensor row; nil when it never shared any.
  @State private var storedTelemetry: NodeStatusSnapshotDTO?
  /// The remote-commands switch's new value while the radio takes it; nil shows the stored flag.
  @State private var remoteCLIPending: Bool?
  @State private var showsCompanionCLI = false
  /// The telemetry switch's new value while the radio takes it (contact flags 0x0E).
  @State private var telemetryPending: Bool?

  init(
    contact: ContactDTO,
    showFromDirectChat: Bool = false,
    onClearMessages: @escaping () -> Void = {},
    mapHost: ContactDetailMapHost? = nil,
    extraCards: [NodeDashboardCardItem] = []
  ) {
    self.extraCards = extraCards
    self.contact = contact
    self.showFromDirectChat = showFromDirectChat
    self.onClearMessages = onClearMessages
    self.mapHost = mapHost
    _currentContact = State(initialValue: contact)
    _isFavorite = State(initialValue: contact.isFavorite)
  }

  /// ZephCore V-contact remove is disabled (would turn off firmware admin CLI).
  private var isVContact: Bool {
    guard let selfKey = appState.connectedDevice?.publicKey else { return false }
    return VContactIdentity.isVContact(publicKey: currentContact.publicKey, selfPublicKey: selfKey)
  }

  var body: some View {
    CardForm {
      // Who and where, then what can be done: the map header with the node's identity laid over
      // it, and the primary actions as a row of cards right under it. Over the Map tab the map
      // behind the sheet already shows where, so the header is the identity band alone.
      VStack(spacing: CardStyle.spacing) {
        NodeMapHeader(
          coordinate: currentContact.hasLocation && mapHost == nil ? currentContact.coordinate : nil,
          marker: currentContact.type.pinStyle,
          markerAvatar: MapPinAvatar(contact: currentContact),
          title: currentContact.displayName,
          subtitle: headerSubtitle,
          // the note kept for the node, under the subtitle (the chips at its end are compact)
          infoLine: currentContact.note?.trimmingCharacters(in: .whitespacesAndNewlines),
          onTapMap: mapHost == nil ? { showFullMap = true } : nil,
          onEditTitle: { showRenameSheet = true },
          // Laid out as Device Info lays out the connected radio: the position with the key (and
          // the groups menu) opposite, then the node's sensors from its last telemetry; when it was
          // last heard and its route against the band's trailing edge.
          footer: AnyView(NodeHeaderFacts(
            coordinates: currentContact.hasLocation ? RemoteNodeHeaderFormat.coordinateText(currentContact.coordinate) : nil,
            distance: currentContact.hasLocation
              ? NodeRouteFormat.distance(
                from: appState.bestAvailableLocation,
                latitude: currentContact.latitude,
                longitude: currentContact.longitude
              )
              : nil,
            sensorGroups: storedTelemetry.map { DeviceSensorChipGroup.groups(from: $0.telemetryEntries ?? []) } ?? [],
            sensorsAge: storedTelemetry.map { RelativeTimestampText.format(date: $0.timestamp, relativeTo: .now) }
          ) {
            EmptyView()
          }),
          chips: AnyView(NodeHeaderChips(publicKey: currentContact.publicKey, compact: true)),
          trailing: AnyView(NodeHeardStatus(lastHeard: lastHeardDate, route: routeSummary))
        ) {
          // Every node's avatar is a button that offers a new photo or colour.
          AvatarEditButton(
            editor: avatarEditor,
            name: currentContact.displayName,
            hasPhoto: currentContact.avatarImageData != nil,
            size: NodeMapHeader<EmptyView>.avatarSize,
            actions: avatarActions
          ) {
            ContactTypeAvatar(contact: currentContact, size: NodeMapHeader<EmptyView>.avatarSize)
          }
        }
        .scrollRevealHeaderHeight(into: $headerHeight)
        // The location lives on the map: its coordinates are in the info line, and a long press
        // copies them or opens them in Maps, as the Details card's Location row did.
        .contextMenu {
          if currentContact.hasLocation {
            Button(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc") {
              UIPasteboard.general.string = "\(currentContact.latitude), \(currentContact.longitude)"
            }
            Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
              NodeLocation.openInMaps(name: currentContact.displayName, coordinate: currentContact.coordinate)
            }
          }
          Button(L10n.Contacts.Contacts.Detail.route, systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
            showsRoutePage = true
          }
        }

        ContactActionTiles(
          currentContact: currentContact,
          showFromDirectChat: showFromDirectChat,
          isPinging: isPinging,
          onMessage: openChat,
          onJoinRoom: { showRoomJoinSheet = true },
          onShowTelemetry: {
            if currentContact.type == .chat {
              activeSheet = .nodeTelemetry(currentContact)
            } else {
              activeSheet = .nodeAuth
            }
          },
          onShowAdminAccess: {
            adminSession = nil
            showRepeaterAdminAuth = true
          },
          onPingRepeater: { Task { await pingRepeater() } },
          isDiscoveringPath: pathViewModel.isDiscovering,
          onDiscoverPath: { Task { await pathViewModel.discoverPath(for: currentContact) } },
          onShowRoute: { showsRoutePage = true },
          isSharing: isSharing,
          showShareSuccess: showShareSuccess,
          onShareQR: { showQRShareSheet = true },
          onShareViaAdvert: { Task { await shareContact() } }
        )
      }

      // Status as the Dashboard's Home-style cards, from what the app already holds and with no
      // request to the node: when it was heard and how well, for a repeater or room its last stored
      // battery and uptime, a person's messages, and the latest ping. Each opens what it sums up.
      // The header says the type, route and distance, so no card repeats them. No section title;
      // a section's gap under the action tiles, as under the cards.
      TimelineView(.everyMinute) { context in
        NodeDashboardCardGrid(items: extraCards + readings.cards(now: context.date, actions: readingActions))
      }

      if currentContact.type == .chat {
        telemetrySection
      }
      if showsRemoteCommands {
        remoteCommandsSection
      }
    }
    .onChange(of: isFavorite) { _, newValue in
      favoriteTask?.cancel()
      favoriteTask = Task { await setFavorite(newValue) }
    }
    // A flag change made elsewhere (telemetry access in Settings, a sync that read the radio)
    // reaches this page's Remote commands switch.
    .onChange(of: appState.contactsVersion) { _, _ in
      Task { await refreshContact() }
    }
    .nodeMapPresentation(isPresented: $showFullMap) { presented in
      NodeOnMapView(
        focus: .node(publicKey: currentContact.publicKey, coordinate: currentContact.coordinate),
        title: currentContact.displayName,
        isPresented: presented
      )
    }
    .navigationDestination(isPresented: $showsRoutePage) {
      ContactRoutePage(contact: $currentContact, pathViewModel: pathViewModel)
    }
    .navigationDestination(isPresented: $showsCompanionCLI) {
      CompanionCLIPage(contact: currentContact)
    }
    // The Discover Path control's result. The route page shows its own while it's open, so this
    // one waits for that page to close.
    .alert(
      L10n.Contacts.Contacts.Detail.Alert.pathDiscovery,
      isPresented: Binding(
        get: { pathViewModel.showDiscoveryResult && !showsRoutePage },
        set: { pathViewModel.showDiscoveryResult = $0 }
      )
    ) {
      if pathViewModel.canUseDiscoveredRoute {
        Button(L10n.Contacts.Contacts.PathDiscovery.useRoute) {
          Task { await pathViewModel.applyDiscoveredRoute(for: currentContact) }
        }
      }
      if pathViewModel.canUseReturnRoute {
        Button(L10n.Contacts.Contacts.PathDiscovery.useReturnRoute) {
          Task { await pathViewModel.applyReturnRoute(for: currentContact) }
        }
      }
      Button(L10n.Contacts.Contacts.Common.ok, role: .cancel) {}
    } message: {
      Text(pathViewModel.discoveryResult?.description ?? "")
    }
    .task {
      // Path discovery replies arrive as pushes; listened for while this page shows, as the route
      // page does while it's open. Only a reply from this node resolves the discovery.
      guard let advertisementService = appState.services?.advertisementService else { return }
      for await event in advertisementService.events() {
        await pathViewModel.handleAdvertisementEvent(event, for: currentContact)
      }
    }
    .errorAlert($errorMessage)
    .navigationBarTitleDisplayMode(.inline)
    .scrollRevealNavigationTitle(currentContact.displayName, revealAfter: headerHeight)
    .contentMargins(.top, 0, for: .scrollContent)
    .toolbar {
      if isPresented {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
      // Favorite lives in the bar, the system place for it; Share is a control in the row under
      // the header. Always present, so the bar keeps its item identity.
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          isFavorite.toggle()
        } label: {
          Label(
            isFavorite ? L10n.Contacts.Contacts.Action.unfavorite : L10n.Contacts.Contacts.Detail.favorite,
            systemImage: isFavorite ? "star.fill" : "star"
          )
        }
        .labelStyle(.iconOnly)

        ContactMoreMenu(
          currentContact: currentContact,
          contactTypeLabel: contactTypeLabel,
          isClearingMessages: isClearingMessages,
          isVContact: isVContact,
          onClearMessages: { showingClearMessagesAlert = true },
          onShowRoute: { showsRoutePage = true },
          onToggleBlock: {
            if currentContact.isBlocked {
              Task { await toggleBlocked() }
            } else {
              showingBlockAlert = true
            }
          },
          onHide: hideFromMapAction == nil ? nil : { showingHideMapConfirmation = true },
          onDelete: { showingDeleteAlert = true }
        )
      }
    }
    .hideFromMapConfirmation(name: currentContact.displayName, isPresented: $showingHideMapConfirmation) {
      hideFromMapAction?()
    }
    .alert(L10n.Contacts.Contacts.Detail.Alert.Block.title, isPresented: $showingBlockAlert) {
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
      Button(L10n.Contacts.Contacts.Action.block, role: .destructive) {
        Task {
          await toggleBlocked()
        }
      }
    } message: {
      Text(L10n.Contacts.Contacts.Detail.Alert.Block.message(currentContact.displayName))
    }
    .alert(L10n.Contacts.Contacts.Detail.Alert.Delete.title(contactTypeLabel), isPresented: $showingDeleteAlert) {
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
      Button(L10n.Contacts.Contacts.Common.delete, role: .destructive) {
        Task {
          await deleteContact()
        }
      }
    } message: {
      Text(L10n.Contacts.Contacts.Detail.Alert.Delete.message(currentContact.displayName))
    }
    .alert(L10n.Contacts.Contacts.ViewModel.deleteTimedOutTitle, isPresented: $showingDeleteTimedOut) {
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
      Button(L10n.Localizable.Common.tryAgain) {
        Task {
          await deleteContact()
        }
      }
    } message: {
      Text(L10n.Contacts.Contacts.ViewModel.removeTimedOut)
    }
    .alert(L10n.Contacts.Contacts.Detail.Alert.ClearMessages.title, isPresented: $showingClearMessagesAlert) {
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
      Button(L10n.Contacts.Contacts.Detail.clearMessages, role: .destructive) {
        Task {
          await clearMessages()
        }
      }
    } message: {
      Text(L10n.Contacts.Contacts.Detail.Alert.ClearMessages.message(currentContact.displayName))
    }
    // Not `.task(id:)` on the pending value: consuming it changes the id, which
    // would cancel the very task that is about to perform the action.
    .task {
      await performPendingQuickAction()
      #if DEBUG
        // UI tests: `-uiTestNodeDashboard YES` opens a repeater's or room's admin Dashboard
        // straight away, since the simulator's mock radio can't log in to one.
        if UserDefaults.standard.bool(forKey: "uiTestNodeDashboard"),
           currentContact.type == .repeater || currentContact.type == .room {
          // After the push settles: a sheet requested mid-push is dropped. Unstructured, so a
          // re-render cancelling this `.task` during the wait doesn't drop the request; retried,
          // since the mock radio may still be connecting.
          Task { @MainActor in
            for _ in 0..<8 {
              try? await Task.sleep(for: .seconds(1.5))
              guard activeSheet == nil else { return }
              guard let radioID = appState.currentRadioID else { continue }
              activeSheet = .adminSettings(RemoteNodeSessionDTO(
                radioID: radioID,
                publicKey: currentContact.publicKey,
                name: currentContact.displayName,
                role: currentContact.type == .room ? .roomServer : .repeater,
                latitude: currentContact.latitude,
                longitude: currentContact.longitude,
                isConnected: true,
                permissionLevel: .admin
              ))
              // Once: on a Mac the presenter clears `activeSheet` as it pushes the page.
              return
            }
          }
        }
      #endif
    }
    .onChange(of: appState.navigation.pendingContactAction) { _, pending in
      // Detail already on screen (iPad split view): no appear will fire.
      guard pending != nil else { return }
      Task { await performPendingQuickAction() }
    }
    .avatarEditing(
      avatarEditor,
      name: currentContact.displayName,
      category: AvatarCategory(currentContact.type),
      hasPhoto: currentContact.avatarImageData != nil,
      color: currentContact.avatarColor,
      actions: avatarActions
    ) { color in
      ContactTypeAvatar(contact: currentContact.with(avatarColorRaw: color?.rawValue), size: 56)
    }
    .task {
      pathViewModel.configure(
        dataStore: { appState.services?.dataStore },
        contactService: { appState.services?.contactService },
        connectedDevice: { appState.connectedDevice }
      ) {
        Task { @MainActor in
          await refreshContact()
        }
      }
      await pathViewModel.loadContacts(radioID: currentContact.radioID)

      // Fetch fresh contact data from device to catch external changes
      // (e.g., user modified path in official MeshCore app)
      if let freshContact = try? await appState.services?.contactService.getContact(
        radioID: currentContact.radioID,
        publicKey: currentContact.publicKey
      ) {
        currentContact = freshContact
      }
      await loadHeardReadings()
      // Nothing here logs in to a repeater or room: that waits for Management (the user,
      // 2026-11-08). A scene restored with a node page open no longer reopens it on its own.
    }
    .sheet(isPresented: $showRenameSheet) {
      ContactNameEditSheet(contact: currentContact) {
        await refreshContact()
      }
    }
    .sheet(isPresented: $showRoomJoinSheet) {
      if let role = RemoteNodeRole(contactType: currentContact.type) {
        NodeAuthenticationSheet(contact: currentContact, role: role) { session in
          // Over the Map tab, close the node sheet too: it would otherwise stay up over Chats.
          // A Mac window closes, with the main window brought forward to show the room.
          if mapHost != nil {
            showRoomJoinSheet = false
            closePage(showingMainWindow: true)
          }
          // Navigate to Chats tab with the room conversation
          appState.navigation.navigateToRoom(with: session)
        }
        .presentationSizing(.page)
      }
    }
    // On a Mac the pages push onto this page's stack (its node window, or the Nodes column), with
    // the login still a sheet; item-driven, so a graph's value push doesn't rebuild the dashboard.
    // On an iPad in a regular-width column the pages push too (over the Map's node sheet they stay sheets).
    .nodePagePresentation(
      item: $activeSheet,
      pushesOnMac: { $0 != .nodeAuth },
      pushesInRegularWidth: mapHost == nil,
      onDismiss: presentPendingSheet
    ) { sheet in
      switch sheet {
      case .nodeAuth:
        if let role = RemoteNodeRole(contactType: currentContact.type) {
          NodeAuthenticationSheet(
            contact: currentContact,
            role: role,
            customTitle: L10n.Contacts.Contacts.Detail.telemetryAccess
          ) { session in
            if currentContact.type == .room {
              pendingSheet = .roomStatus(session)
            } else {
              pendingSheet = .repeaterStatus(session)
            }
            activeSheet = nil // Triggers dismissal, then onDismiss fires
          }
          .presentationSizing(.page)
        }
      case let .repeaterStatus(session):
        RepeaterStatusView(session: session)
      case let .roomStatus(session):
        RoomStatusView(session: session)
      case let .nodeTelemetry(contact):
        NodeTelemetryView(contact: contact)
      case let .adminSettings(session):
        // A sheet with its own stack, not a push onto the value/path-based Contacts stack:
        // the telemetry tab's history graphs push value-based routes, and pushing this screen
        // there instead would rebuild it and reset the selected tab whenever a graph is tapped.
        NavigationStack {
          Group {
            if session.isRoom {
              RoomSettingsView(session: session)
            } else {
              RepeaterSettingsView(session: session)
            }
          }
          .toolbar {
            // Back where the page's reload used to be (the reload is on the page now); no Done
            ToolbarItem(placement: .cancellationAction) {
              NodePageBackButton { activeSheet = nil }
            }
          }
        }
        .presentationSizing(.page)
      }
    } pushed: { page in
      switch page {
      case .nodeAuth:
        EmptyView()
      case let .repeaterStatus(session):
        RepeaterStatusView(session: session, isPushed: true)
      case let .roomStatus(session):
        RoomStatusView(session: session, isPushed: true)
      case let .nodeTelemetry(contact):
        NodeTelemetryView(contact: contact, isPushed: true)
      case let .adminSettings(session):
        if session.isRoom {
          RoomSettingsView(session: session)
        } else {
          RepeaterSettingsView(session: session)
        }
      }
    }
    .sheet(isPresented: $showRepeaterAdminAuth, onDismiss: {
      // Trigger navigation after sheet is fully dismissed to avoid race conditions
      if let session = adminSession {
        activeSheet = Self.managementSheet(for: session)
      }
    }) {
      if let role = RemoteNodeRole(contactType: currentContact.type) {
        NodeAuthenticationSheet(contact: currentContact, role: role) { session in
          adminSession = session
          showRepeaterAdminAuth = false
          // Navigation triggers in onDismiss above
        }
        .presentationSizing(.page)
      }
    }
    .sheet(isPresented: $showQRShareSheet) {
      ContactQRShareSheet(
        contactName: currentContact.name,
        publicKey: currentContact.publicKey,
        contactType: currentContact.type
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .navigationDestination(for: ContactRoute.TelemetryHistory.self) { route in
      TelemetryHistoryOverviewView(
        publicKey: route.publicKey,
        radioID: route.radioID,
        showNeighbors: route.showNeighbors
      )
    }
  }

  // MARK: - Sheet Management

  private func presentPendingSheet() {
    if let next = pendingSheet {
      pendingSheet = nil
      activeSheet = next
    }
  }

  /// What Management opens after its login: the admin dashboard, or the status for a guest.
  private static func managementSheet(for session: RemoteNodeSessionDTO) -> ActiveSheet {
    if session.isAdmin {
      .adminSettings(session)
    } else if session.isRoom {
      .roomStatus(session)
    } else {
      .repeaterStatus(session)
    }
  }

  // MARK: - Actions

  /// The favourite write sends the radio's whole flag byte, so the page reads the contact back
  /// after it: the Remote commands switch then shows what the radio holds, not the copy the
  /// page opened with.
  private func setFavorite(_ isFavorite: Bool) async {
    do {
      try await appState.services?.contactService.setContactFavorite(
        currentContact.id,
        isFavorite: isFavorite
      )
    } catch {
      errorMessage = error.userFacingMessage
    }
    await refreshContact()
  }

  /// Lets this person's device run this radio's command line, or stops it (contact flag 0x10).
  /// The switch shows the new value while the radio takes it (`remoteCLIPending`, set by the
  /// switch before this runs), and the stored one after.
  private func setRemoteCLIAllowed(_ allowed: Bool) async {
    defer { remoteCLIPending = nil }
    do {
      try await appState.services?.contactService.setRemoteCLIAllowed(currentContact.id, allowed: allowed)
      await refreshContact()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Lets this person request this radio's telemetry, or stops it (contact flags 0x0E: base,
  /// location and environment together, as Settings' trusted contacts are set). The switch
  /// shows the new value while the radio takes it (`telemetryPending`), and the stored one after.
  private func setTelemetryShared(_ shared: Bool) async {
    defer { telemetryPending = nil }
    do {
      try await appState.services?.contactService.setTelemetryPermissions(currentContact.id, granted: shared)
      await refreshContact()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  private func toggleBlocked() async {
    do {
      try await appState.services?.contactService.updateContactPreferences(
        contactID: currentContact.id,
        isBlocked: !currentContact.isBlocked
      )
      await refreshContact()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// Bounded by the same timeout as the list's delete, so a silent radio raises the retry alert
  /// rather than leaving the page waiting.
  private func deleteContact() async {
    guard let contactService = appState.services?.contactService else { return }
    do {
      try await withTimeout(RadioCommandTimeout.delete, operationName: "removeContact") {
        try await contactService.removeContact(
          radioID: currentContact.radioID,
          publicKey: currentContact.publicKey
        )
      }
      didDelete()
    } catch is TimeoutError {
      showingDeleteTimedOut = true
    } catch ContactServiceError.contactNotFound {
      // Already gone from the radio: drop the local copy so the node doesn't linger here.
      do {
        try await contactService.removeLocalContact(
          contactID: currentContact.id,
          publicKey: currentContact.publicKey
        )
        didDelete()
      } catch {
        errorMessage = error.userFacingMessage
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  private func didDelete() {
    closePage()
    mapHost?.onDelete()
  }

  /// Hide from the Map tab, offered only when the Map's sheet hosts the page. A map preference,
  /// so it closes the sheet and works without a radio. Runs once the confirmation says Hide.
  private var hideFromMapAction: (() -> Void)? {
    guard let onHide = mapHost?.onHide else { return nil }
    return {
      closePage()
      onHide()
    }
  }

  /// Message opens the conversation; over the Map tab the sheet closes first, since it would
  /// otherwise stay up over Chats.
  private func openChat() {
    if let mapHost {
      closePage(showingMainWindow: true)
      mapHost.onMessage()
    } else {
      appState.navigation.navigateToChat(with: currentContact)
    }
  }

  private func clearMessages() async {
    guard let contactService = appState.services?.contactService else {
      errorMessage = L10n.Contacts.Contacts.Detail.Error.servicesUnavailable
      return
    }

    isClearingMessages = true
    errorMessage = nil

    do {
      try await contactService.clearContactMessages(contactID: currentContact.id)
      await appState.services?.notificationService.removeDeliveredNotifications(forContactID: currentContact.id)
      await appState.services?.notificationService.updateBadgeCount()
      onClearMessages()
      closePage()
    } catch {
      errorMessage = error.userFacingMessage
      isClearingMessages = false
    }
  }

  private func shareContact() async {
    isSharing = true
    do {
      try await appState.services?.contactService.shareContact(publicKey: currentContact.publicKey)
      isSharing = false
      withAnimation { showShareSuccess = true }
      try? await Task.sleep(for: .seconds(1.5))
      withAnimation { showShareSuccess = false }
    } catch ContactServiceError.shareContactUnavailable {
      isSharing = false
      errorMessage = L10n.Contacts.Contacts.Detail.shareContactUnavailable
    } catch {
      isSharing = false
      errorMessage = error.userFacingMessage
    }
  }

  /// Runs an action the Nodes list context menu asked for. Waits a beat first:
  /// a sheet presented while this view is still being pushed is dropped.
  private func performPendingQuickAction() async {
    guard let action = appState.navigation.consumePendingContactAction(for: currentContact.id) else { return }
    try? await Task.sleep(for: .milliseconds(450))
    guard !Task.isCancelled else { return }
    switch action {
    case .telemetry:
      activeSheet = currentContact.type == .chat ? .nodeTelemetry(currentContact) : .nodeAuth
    case .management:
      adminSession = nil
      showRepeaterAdminAuth = true
    case .ping:
      await pingRepeater()
    case .discoverPath:
      await pathViewModel.discoverPath(for: currentContact)
    }
  }

  private func pingRepeater() async {
    guard !isPinging else { return }
    isPinging = true
    pingResult = nil
    pingResult = await PingHelper.zeroHopPing(contact: currentContact, appState: appState)
    isPinging = false
  }

  private func loadHeardReadings() async {
    guard let services = appState.services else { return }
    let entries = await services.rxLogService.recentEntries(since: .distantPast)
    heardSignal = NodeHeardSignal.latest(
      in: entries,
      publicKey: currentContact.publicKey,
      selfKey: appState.connectedDevice?.publicKey
    )
    if currentContact.type != .chat {
      storedStatus = await services.nodeSnapshotService.previousStatusSnapshot(
        for: currentContact.publicKey,
        before: .now
      )
    }
    // The newest readings the node shared: a person who allows telemetry, a repeater or room whose
    // sensors were read; none for a node that never sent any.
    let snapshots = await services.nodeSnapshotService.fetchSnapshots(for: currentContact.publicKey)
    storedTelemetry = snapshots.last { $0.telemetryEntries?.isEmpty == false }
    batteryTrend = currentContact.type == .chat ? [] : NodeBatteryTrend.points(from: snapshots)
  }

  private func refreshContact() async {
    let store = appState.services?.dataStore ?? appState.offlineDataStore
    if let updated = try? await store?.fetchContact(id: currentContact.id) {
      currentContact = updated
    }
  }

  // MARK: - Avatar

  /// Saves through `ContactService` when connected, else straight to the store, so an avatar can
  /// be changed while the radio is away. Avatars stay on this phone either way.
  private var avatarActions: AvatarEditActions {
    AvatarEditActions(
      savePhoto: { data in try await updateAvatar { $0.with(avatarImageData: data) } service: { service, id in
        try await service.updateContactAvatar(contactID: id, imageData: data)
      } },
      removePhoto: { try await updateAvatar { $0.with(avatarImageData: nil) } service: { service, id in
        try await service.updateContactAvatar(contactID: id, imageData: nil)
      } },
      setColor: { color in try await updateAvatar { $0.with(avatarColorRaw: color?.rawValue) } service: { service, id in
        try await service.updateContactAvatarColor(contactID: id, color: color)
      } }
    )
  }

  private func updateAvatar(
    _ change: (ContactDTO) -> ContactDTO,
    service: (ContactService, UUID) async throws -> Void
  ) async throws {
    if let contactService = appState.services?.contactService {
      try await service(contactService, currentContact.id)
    } else if let store = appState.offlineDataStore,
              let existing = try await store.fetchContact(id: currentContact.id) {
      try await store.saveContact(change(existing))
      appState.contactsVersion += 1
    }
    await refreshContact()
  }

  // MARK: - Telemetry

  /// Whether this person may ask this radio for its telemetry: the per-contact permission the
  /// radio keeps (which Settings › Location & Sharing's trusted contacts set in bulk).
  private var telemetrySection: some View {
    // The explanation behind the title's (i), not under the card: the switch says enough on its own.
    CardFormSection(
      L10n.Contacts.Contacts.Detail.Telemetry.title,
      info: L10n.Contacts.Contacts.Detail.Telemetry.footer
    ) {
      ToggleCard(
        L10n.Contacts.Contacts.Detail.Telemetry.share,
        systemImage: "sensor.fill",
        color: .teal,
        subtitle: L10n.Contacts.Contacts.Detail.Telemetry.shareDetail,
        isOn: Binding(
          get: { telemetryPending ?? ContactService.hasTelemetryPermissions(flags: currentContact.flags) },
          set: { shared in
            // Claimed before the task runs, as the Remote commands switch is: no flash back, and
            // no second write while the first is on its way.
            guard telemetryPending == nil else { return }
            telemetryPending = shared
            Task { await setTelemetryShared(shared) }
          }
        )
      )
      .radioDisabled(for: appState.connectionState, or: telemetryPending != nil)
      .accessibilityIdentifier("contact.telemetry.share")
    }
  }

  // MARK: - Remote Commands

  /// A person's remote commands (MeshCore 1.18) on a radio that has them.
  private var showsRemoteCommands: Bool {
    currentContact.type == .chat && appState.connectedDevice?.supportsCompanionRemoteCLI == true
  }

  /// Both directions of the companion command line: whether this person may run this radio's
  /// commands, and this radio's commands to theirs (which their contact for this radio decides).
  private var remoteCommandsSection: some View {
    CardFormSection(
      L10n.Contacts.Contacts.Detail.RemoteCommands.title,
      info: L10n.Contacts.Contacts.Detail.RemoteCommands.footer
    ) {
      ToggleCard(
        L10n.Contacts.Contacts.Detail.RemoteCommands.allow,
        systemImage: "lock.open",
        color: .orange,
        subtitle: L10n.Contacts.Contacts.Detail.RemoteCommands.allowDetail,
        isOn: Binding(
          get: { remoteCLIPending ?? ContactService.allowsRemoteCLI(flags: currentContact.flags) },
          set: { allowed in
            // Claimed here, before the task runs: the switch keeps the new value with no flash
            // back, and a second flip while the radio takes the first writes nothing.
            guard remoteCLIPending == nil else { return }
            remoteCLIPending = allowed
            Task { await setRemoteCLIAllowed(allowed) }
          }
        )
      )
      .radioDisabled(for: appState.connectionState, or: remoteCLIPending != nil)
      .accessibilityIdentifier("contact.remoteCommands.allow")

      Button {
        showsCompanionCLI = true
      } label: {
        NavigationTile(
          L10n.Contacts.Contacts.Detail.RemoteCommands.open,
          systemImage: "terminal",
          color: .gray,
          detail: L10n.Contacts.Contacts.Detail.RemoteCommands.openDetail
        )
      }
      .buttonStyle(.plain)
      .radioDisabled(for: appState.connectionState)
      .accessibilityIdentifier("contact.remoteCommands.open")
    }
  }

  // MARK: - Helpers

  /// The status cards' readings, from the contact, the RX log and the stored status.
  private var readings: ContactDashboardReadings {
    ContactDashboardReadings(
      contact: currentContact,
      signal: heardSignal,
      // The relays named only by what this radio heard on the packet's channel, as the RX Log
      // list and the Traffic map name them
      heardPath: heardSignal.flatMap {
        NodeHeardSignal.heardPath(of: $0, in: appState.observationDirectory.index(for: $0))
      },
      heardPathFull: heardSignal.flatMap {
        NodeHeardSignal.heardPath(of: $0, maxShown: .max, in: appState.observationDirectory.index(for: $0))
      },
      // Both directions, as Scan & Traffic lists them, for a node this radio heard directly.
      link: NodeLinkSignal(publicKey: currentContact.publicKey, directory: appState.neighbourDirectory, now: .now),
      storedStatus: storedStatus,
      ocvValues: NodeStatusViewModel.batteryCurve(
        presetName: currentContact.ocvPreset,
        customString: currentContact.customOCVArrayString
      ).values,
      batteryTrend: batteryTrend,
      pingResult: pingResult,
      isPinging: isPinging
    )
  }

  /// Every reading opens its sheet (with the history inside); Messages opens the chat where the row
  /// offers Message, and the Ping card pings again where the node answers pings.
  private var readingActions: ContactDashboardReadings.Actions {
    var actions = ContactDashboardReadings.Actions()
    if currentContact.type == .chat, !showFromDirectChat, !currentContact.isBlocked {
      actions.openChat = { openChat() }
    }
    if currentContact.type != .chat {
      actions.ping = { Task { await pingRepeater() } }
    }
    return actions
  }

  private var contactTypeLabel: String {
    currentContact.type.localizedName
  }

  /// The node type, and Blocked when it is, which the old header said in red. The route is under
  /// the heard status at the band's trailing edge.
  /// "Repeater · Direct": the type and the route, with the last-heard capsule at the line's end.
  private var headerSubtitle: String {
    NodeRouteFormat.joined([
      contactTypeLabel,
      routeSummary,
      currentContact.isBlocked ? L10n.Contacts.Contacts.Detail.blocked : nil,
    ])
  }

  /// When the node was last heard: its last packet, else its last advert.
  private var lastHeardDate: Date? {
    currentContact.lastHeardTimestamp.flatMap(ContactReadingsFormat.date(fromTimestamp:))
      ?? ContactReadingsFormat.date(fromTimestamp: currentContact.lastAdvertTimestamp)
  }

  /// "Direct", "2 hops" or "Flood"; "Discovering…" while the route page looks for one.
  private var routeSummary: String {
    if pathViewModel.isDiscovering { return L10n.Contacts.Contacts.Detail.discoveringPath }
    if currentContact.isFloodRouted { return L10n.Contacts.Contacts.Route.flood }
    if currentContact.pathHopCount == 0 { return L10n.Contacts.Contacts.Route.direct }
    return NodeRouteFormat.hopCount(currentContact.pathHopCount)
  }

}

// MARK: - Extracted Views

/// The node's primary actions as a row of cards under the header, as on a logged-in node's
/// Dashboard. A person: Message, Telemetry, Discover Path and Share. A repeater or room: Join Room
/// (rooms), Management, Ping and Share. People get Discover Path where nodes get Ping:
/// the zero-hop ping is a trace, which only nodes that forward packets answer, while a path
/// discovery goes to the person's radio and back over the mesh. Pages that only open (history,
/// route) are tool tiles further down; Favorite and the rarer actions (block, hide, delete) sit
/// in the toolbar.
private struct ContactActionTiles: View {
  @Environment(\.appState) private var appState

  let currentContact: ContactDTO
  let showFromDirectChat: Bool
  let isPinging: Bool
  let onMessage: () -> Void
  let onJoinRoom: () -> Void
  let onShowTelemetry: () -> Void
  let onShowAdminAccess: () -> Void
  let onPingRepeater: () -> Void
  let isDiscoveringPath: Bool
  let onDiscoverPath: () -> Void
  /// The route page: how messages reach the node, and rediscover, edit or reset it.
  let onShowRoute: () -> Void
  let isSharing: Bool
  let showShareSuccess: Bool
  let onShareQR: () -> Void
  let onShareViaAdvert: () -> Void

  private var isRemoteNode: Bool { currentContact.type != .chat }
  private var showsMessage: Bool {
    currentContact.type == .chat && !showFromDirectChat && !currentContact.isBlocked
  }

  private var tileCount: Int {
    switch currentContact.type {
    case .chat: showsMessage ? 5 : 4
    case .repeater: 4
    case .room: 5
    }
  }

  /// The route page, beside Management (or Discover Path for a person): it opens a page, but
  /// it's where the node's path is changed, so it sits with the actions.
  private var routeTile: some View {
    Button(action: onShowRoute) {
      NodeActionTile(L10n.Contacts.Contacts.Detail.route, systemImage: "arrow.triangle.branch")
    }
  }

  var body: some View {
    NodeActionTileRow(count: tileCount) {
      if currentContact.type == .room {
        Button(action: onJoinRoom) {
          NodeActionTile(L10n.Contacts.Contacts.Detail.joinRoom, systemImage: "door.left.hand.open")
        }
        .radioDisabled(for: appState.connectionState)
      }

      if showsMessage {
        Button(action: onMessage) {
          NodeActionTile(
            L10n.Map.Map.Callout.message,
            systemImage: "message.fill",
            accessibilityTitle: L10n.Contacts.Contacts.Detail.sendMessage
          )
        }
        .radioDisabled(for: appState.connectionState)
      }

      // A repeater's or room's readings come with its login (Management), which opens the read-only
      // status for a guest password too; only a person shares telemetry on its own.
      if !isRemoteNode {
        Button(action: onShowTelemetry) {
          NodeActionTile(L10n.Contacts.Contacts.Detail.telemetry, systemImage: "chart.line.uptrend.xyaxis")
        }
        .radioDisabled(for: appState.connectionState)
      }

      if isRemoteNode {
        Button(action: onShowAdminAccess) {
          NodeActionTile(L10n.Contacts.Contacts.Detail.management, systemImage: "gearshape.2")
        }
        .radioDisabled(for: appState.connectionState)

        routeTile

        Button(action: onPingRepeater) {
          NodeActionTile(
            L10n.Contacts.Contacts.Detail.Action.ping,
            systemImage: "wave.3.right",
            accessibilityTitle: L10n.Contacts.Contacts.Detail.ping,
            isBusy: isPinging
          )
        }
        .disabled(isPinging)
        .radioDisabled(for: appState.connectionState)
      } else {
        // The header's subtitle reads "Discovering…" while it runs; the result comes as an alert.
        Button(action: onDiscoverPath) {
          NodeActionTile(
            L10n.Contacts.Contacts.Detail.discoverPath,
            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
            isBusy: isDiscoveringPath
          )
        }
        .disabled(isDiscoveringPath)
        .radioDisabled(for: appState.connectionState)

        routeTile
      }

      // The QR code, or an advert sent over the mesh; the glyph turns into a checkmark once the
      // advert is out.
      Menu {
        Button(action: onShareQR) {
          Label(L10n.Contacts.Contacts.Detail.shareQRCode, systemImage: "qrcode")
        }
        Button(action: onShareViaAdvert) {
          Label(L10n.Contacts.Contacts.Detail.shareViaAdvert, systemImage: "antenna.radiowaves.left.and.right")
        }
        .radioDisabled(for: appState.connectionState, or: isSharing || showShareSuccess)
      } label: {
        NodeActionTile(
          L10n.Contacts.Contacts.Detail.Action.share,
          systemImage: showShareSuccess ? "checkmark" : "square.and.arrow.up",
          accessibilityTitle: L10n.Contacts.Contacts.Detail.shareContact,
          isBusy: isSharing
        )
      }
    }
    .buttonStyle(.plain)
  }
}

/// The rare and destructive actions, out of the page and into the bar's More menu: block or
/// unblock and clear messages for a person, Hide from Map over the Map tab, and delete. Each
/// destructive one still asks first through the page's alerts. Always present, so the bar keeps
/// its item identity; disabled when nothing applies.
private struct ContactMoreMenu: View {
  @Environment(\.appState) private var appState

  let currentContact: ContactDTO
  let contactTypeLabel: String
  let isClearingMessages: Bool
  let isVContact: Bool
  let onClearMessages: () -> Void
  /// Opens the route page: rediscover, edit or reset how messages reach the node.
  let onShowRoute: () -> Void
  let onToggleBlock: () -> Void
  /// Hides the node from the Map tab; nil outside the Map's sheet.
  let onHide: (() -> Void)?
  let onDelete: () -> Void

  /// A repeater's or room's saved password and automatic login, loaded with the page; nil for a
  /// person. In this menu, as on the logged-in dashboard's, rather than a card at the page's foot
  /// (user, 2026-11-07).
  @State private var savedLogin: NodeSavedLoginModel?
  @State private var errorMessage: String?

  private var isChat: Bool { currentContact.type == .chat }
  var body: some View {
    Menu {
      Button(action: onShowRoute) {
        Label(L10n.Contacts.Contacts.Detail.route, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
      }

      if let savedLogin {
        NodeSavedLoginMenuItems(model: savedLogin, errorMessage: $errorMessage)
      }
      Divider()

      if isChat {
        Button(action: onToggleBlock) {
          Label(
            currentContact.isBlocked ? L10n.Contacts.Contacts.Detail.unblockContact : L10n.Contacts.Contacts.Detail.blockContact,
            systemImage: currentContact.isBlocked ? "hand.raised.slash" : "hand.raised"
          )
        }
        .radioDisabled(for: appState.connectionState)

        Button(role: .destructive, action: onClearMessages) {
          Label(L10n.Contacts.Contacts.Detail.clearMessages, systemImage: "xmark.circle")
        }
        .disabled(isClearingMessages)
      }

      // A map preference, so it works without a radio connection.
      if let onHide {
        Button(action: onHide) {
          Label(L10n.Map.Map.HiddenNodes.hide, systemImage: "eye.slash")
        }
      }

      if !isVContact {
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label(L10n.Contacts.Contacts.Detail.deleteType(contactTypeLabel), systemImage: "trash")
        }
        .radioDisabled(for: appState.connectionState)
      }
    } label: {
      Label(L10n.Contacts.Contacts.Detail.more, systemImage: "ellipsis.circle")
    }
    .labelStyle(.iconOnly)
    .task(id: currentContact.id) {
      guard currentContact.type != .chat else {
        savedLogin = nil
        return
      }
      let model = NodeSavedLoginModel(contact: currentContact)
      await model.load(services: appState.services)
      savedLogin = model
    }
    .errorAlert($errorMessage)
  }
}

#Preview("Default") {
  NavigationStack {
    ContactDetailView(contact: ContactDTO(from: Contact(
      radioID: UUID(),
      publicKey: Data(repeating: 0x42, count: 32),
      name: "Alice",
      latitude: 37.7749,
      longitude: -122.4194,
      lastHeardTimestamp: 0,
      isFavorite: true
    )))
  }
  .environment(\.appState, AppState())
}

#Preview("From Direct Chat") {
  NavigationStack {
    ContactDetailView(
      contact: ContactDTO(from: Contact(
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Alice",
        latitude: 37.7749,
        longitude: -122.4194,
        lastHeardTimestamp: 0,
        isFavorite: true
      )),
      showFromDirectChat: true
    )
  }
  .environment(\.appState, AppState())
}
