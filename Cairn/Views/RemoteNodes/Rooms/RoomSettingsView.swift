import CoreLocation
import CairnServices
import SwiftUI

/// A logged-in room server's page: the Dashboard, laid out like Home, as a repeater's is. The
/// node's map heads it with the controls under it (advert, sync time, reboot, access list); then
/// its status, its sensors, its settings as cards that each open in a sheet, and the tools, the CLI
/// among them.
struct RoomSettingsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: NodeSettingsField?

  let session: RemoteNodeSessionDTO
  @State private var viewModel = RoomSettingsViewModel()
  @State private var statusViewModel = RoomStatusViewModel()
  @State private var cliViewModel = NodeCLIViewModel()
  /// The setting whose sheet is open, from its card on the Dashboard.
  @State private var openSettingsPage: NodeSettingsPage?
  @State private var showsCLI = false
  @State private var showsControls = false
  /// Post as Room: its text, while the prompt is up.
  @State private var showsRoomPost = false
  @State private var roomPostText = ""
  @State private var showRebootConfirmation = false
  @State private var showingLocationPicker = false
  @State private var telemetryConfigured = false
  @State private var lifetime = NodePageLifetime()
  /// The room's contact, for the bar menu's saved login and the reconnect after a reboot.
  @State private var contact: ContactDTO?
  /// Refresh the status every so many minutes while the page is open (the bar menu); nil is off.
  @State private var refreshMinutes: Int?
  @AppStorage(AppStorageKey.remoteNodesLoadSettingsOnOpen.rawValue)
  private var loadsSettingsOnOpen = AppStorageKey.defaultRemoteNodesLoadSettingsOnOpen
  @State private var showsCompare = false
  @State private var showsReconnect = false
  @State private var logoutError: String?

  var body: some View {
    RoomStatusContent(
      viewModel: statusViewModel,
      session: session,
      connectionState: appState.connectionState,
      connectedDeviceID: appState.connectedDevice?.radioID,
      userLocation: appState.bestAvailableLocation,
      headerActions: session.isAdmin ? AnyView(headerExtras) : nil,
      extraLinks: session.isAdmin ? AnyView(Group { controlsTile; roomPostTile; cliTile }) : nil,
      adminCards: session.isAdmin ? adminCards : [],
      onEditIdentity: session.isAdmin ? { open(.identity) } : nil,
      // Only the status by default, as on a repeater: each card reads its settings when opened.
      afterStatusLoads: session.isAdmin && loadsSettingsOnOpen ? { await loadCardSettings() } : nil
    )
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Dashboard.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showsCLI) {
      NodeCLIView(viewModel: cliViewModel)
        .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Settings.Tab.cli)
        .navigationBarTitleDisplayMode(.inline)
    }
    // The same tuning, switches and commands a repeater offers: the room server runs the same
    // CLI, and answers "??" for whatever it lacks, which the page then leaves out.
    .navigationDestination(isPresented: $showsControls) {
      RepeaterControlsPage(settings: viewModel.helper)
    }
    .alert(L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.title, isPresented: $showsRoomPost) {
      TextField(L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.placeholder, text: $roomPostText)
      Button(L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.send) {
        let text = roomPostText.trimmingCharacters(in: .whitespacesAndNewlines)
        roomPostText = ""
        guard !text.isEmpty else { return }
        Task { await postAsRoom(text) }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) { roomPostText = "" }
    } message: {
      Text(L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.detail)
    }
    .nodeAccessListDestination()
    .nodeRebootConfirmation(
      isPresented: $showRebootConfirmation,
      settings: viewModel.helper,
      title: L10n.RemoteNodes.RemoteNodes.RoomSettings.rebootConfirmTitle,
      message: L10n.RemoteNodes.RemoteNodes.RoomSettings.rebootMessage
    )
    // Advert, Sync Time and Reboot from the controls row report here; a settings sheet shows its
    // own while it's open, so this one stands aside then.
    .nodeSettingsSuccessAlert(
      settings: viewModel.helper,
      isPresented: Binding(
        get: { viewModel.helper.showSuccessAlert && openSettingsPage == nil },
        set: { if !$0 { viewModel.helper.showSuccessAlert = false } }
      )
    )
    .navigationDestination(isPresented: $showsCompare) {
      RepeaterCompareView(primaryPublicKey: session.publicKey)
    }
    .toolbar {
      if session.isAdmin {
        ToolbarItem(placement: .topBarTrailing) {
          NodeDashboardMenu(
            session: session,
            contact: contact,
            refreshMinutes: $refreshMinutes,
            onCompare: { showsCompare = true },
            onLogout: { forget in Task { await logOut(forget: forget) } }
          )
        }
      }
    }
    .sheet(isPresented: $showsReconnect) {
      if let contact {
        NodeAuthenticationSheet(contact: contact, role: .roomServer) { _ in
          viewModel.helper.markLive()
          Task { await statusViewModel.requestStatus(for: session) }
        }
        .presentationSizing(.page)
      }
    }
    .errorAlert($logoutError)
    .onChange(of: refreshMinutes) { _, minutes in
      RemoteNodePreferences.setAutoRefreshMinutes(minutes, for: session.publicKey)
    }
    .sheet(item: $openSettingsPage) { page in
      settingsSheet(page)
    }
    .task {
      refreshMinutes = RemoteNodePreferences.autoRefreshMinutes(for: session.publicKey)
      configureStatusIfNeeded()
      await viewModel.configure(
        roomAdminService: { appState.services?.roomAdminService },
        session: session
      )
      viewModel.helper.onSessionQuiet = { id in
        await appState.services?.remoteNodeService.disconnect(sessionID: id)
      }
      if let send = viewModel.makeNodeCLISendClosure(session: session) {
        cliViewModel.configure(sessionName: session.name, historyKey: session.publicKey, sendRawCommand: send)
      }
      if let dataStore = appState.services?.dataStore {
        contact = await (try? dataStore.fetchContact(radioID: session.radioID, publicKey: session.publicKey)).flatMap(\.self)
      }
    }
    .task(id: appState.servicesVersion) {
      // A reconnect rebuilds the service container; late CLI replies are delivered to a handler
      // held by the admin service, so the new one needs it registered again.
      await viewModel.registerCLIHandler()
    }
    // Hand the latest telemetry GPS fix to the settings so they can offer to apply it.
    .onChange(of: statusViewModel.helper.currentLocationFix) { _, fix in
      viewModel.helper.telemetryFix = fix
    }
    .onChange(of: openSettingsPage) { _, page in
      // Settings are cached after the first read; identity is read again on each opening so a
      // location set elsewhere shows up, unless the user has unsaved edits there.
      if page == .identity, viewModel.helper.identityLoaded, !viewModel.helper.identitySettingsModified {
        Task { await viewModel.helper.fetchIdentity() }
      }
    }
    .onAppear {
      // Teardown when the sheet closes; pushing a page over the Dashboard keeps it all running.
      lifetime.onEnd = { [statusViewModel, viewModel] in
        Task {
          await statusViewModel.clearStatusHandlers()
          await viewModel.cleanup()
        }
      }
    }
  }

  /// Configures the status view model once: its handlers populate only the status and telemetry
  /// slots, leaving the settings view model's CLI handler intact for the CLI page.
  private func configureStatusIfNeeded() {
    guard !telemetryConfigured else { return }
    telemetryConfigured = true
    statusViewModel.configure(
      roomAdminService: { appState.services?.roomAdminService },
      contactService: { appState.services?.contactService },
      nodeSnapshotService: { appState.services?.nodeSnapshotService }
    )
    Task {
      await statusViewModel.registerHandlers()
      if let radioID = appState.connectedDevice?.radioID {
        await statusViewModel.helper.loadOCVSettings(publicKey: session.publicKey, radioID: radioID)
      }
      // The dashboard asks for status as it appears; this covers it appearing before the
      // configure above took effect. A request on its way, or one that already failed, makes this
      // a no-op.
      if statusViewModel.helper.shouldBackstopAutoLoadStatus(connectionState: appState.connectionState) {
        await statusViewModel.requestStatus(for: session)
      }
    }
  }

  // MARK: - Dashboard additions

  /// Under the map: the rebooting banner while the node is quiet, the action tiles, and the
  /// invisible ticker that refreshes the status while the page is open.
  private var headerExtras: some View {
    VStack(spacing: CardStyle.spacing) {
      NodeRebootBanner(state: viewModel.helper.quietState) { showsReconnect = true }
      actionTiles
      NodeAutoRefreshTicker(
        minutes: refreshMinutes,
        isEnabled: appState.connectionState == .ready && !viewModel.helper.quietState.isQuiet
          && !statusViewModel.helper.isLoadingStatus
      ) {
        await statusViewModel.requestStatus(for: session)
      }
    }
    .animation(.default, value: viewModel.helper.quietState)
  }

  /// Logs out (the saved password stays), or logs out and forgets the room's password and
  /// session; either way the page closes.
  private func logOut(forget: Bool) async {
    guard let service = appState.services?.roomAdminService else { return }
    do {
      if forget {
        try await service.disconnect(sessionID: session.id, publicKey: session.publicKey)
        NodeAutoLogin.set(false, for: session.publicKey)
      } else {
        try await service.logout(sessionID: session.id)
      }
      dismiss()
    } catch {
      logoutError = error.userFacingMessage
    }
  }

  /// Send Advert, Sync Time, Reboot and the access list, under the map.
  private var actionTiles: some View {
    NodeSettingsActionTiles(
      settings: viewModel.helper,
      session: session,
      showRebootConfirmation: $showRebootConfirmation
    )
  }

  /// Transmit power, tuning, switches and one-tap commands, one of the Dashboard's tools.
  private var controlsTile: some View {
    Button {
      showsControls = true
    } label: {
      NavigationTile(
        L10n.RemoteNodes.RemoteNodes.Controls.title,
        systemImage: "dial.medium.fill",
        color: .orange,
        detail: viewModel.helper.originalTxPower.map {
          TxPowerText.remoteDetail(setting: $0, antenna: viewModel.helper.txAntennaPower)
        } ?? L10n.RemoteNodes.RemoteNodes.Controls.subtitle
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("room.controls")
  }

  /// A post from the room itself to every member (`room.post`), one of the Dashboard's tools.
  private var roomPostTile: some View {
    Button {
      showsRoomPost = true
    } label: {
      NavigationTile(
        L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.title,
        systemImage: "megaphone",
        color: .pink,
        detail: L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.detail
      )
    }
    .buttonStyle(.plain)
    .radioDisabled(for: appState.connectionState)
    .accessibilityIdentifier("room.post")
  }

  /// Sends the post; the room answers OK, or says why not.
  private func postAsRoom(_ text: String) async {
    do {
      let reply = try await viewModel.helper.sendAndWait("room.post \(text)")
      switch CLIResponse.parse(reply) {
      case let .error(message):
        viewModel.helper.errorMessage = message
      case .unknownCommand:
        viewModel.helper.errorMessage = reply
      default:
        viewModel.helper.successMessage = L10n.RemoteNodes.RemoteNodes.RoomSettings.Post.sent
        viewModel.helper.showSuccessAlert = true
      }
    } catch {
      viewModel.helper.errorMessage = error.userFacingMessage
    }
  }

  /// The room server's command line, one of the Dashboard's tools.
  private var cliTile: some View {
    Button {
      showsCLI = true
    } label: {
      NavigationTile(
        L10n.RemoteNodes.RemoteNodes.Settings.Tab.cli,
        systemImage: "terminal",
        color: .gray,
        detail: L10n.Tools.Tools.Subtitle.cli
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("room.cli")
  }

  // MARK: - Settings

  /// Radio, Behavior and Device: the room's settings as Dashboard cards showing their values, each
  /// opening its sheet. Identity, location and contact info open from the header's pencil.
  private var adminCards: [NodeDashboardCardItem] {
    let behavior = NodeDashboardCardItem(
      id: "behavior",
      title: L10n.RemoteNodes.RemoteNodes.Settings.behavior,
      systemImage: "slider.horizontal.3",
      tint: .indigo,
      value: viewModel.allowReadOnly.map {
        $0 ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off
      } ?? NodeStatusViewModel.emDash,
      valueTint: viewModel.allowReadOnly == nil ? .secondary : .primary,
      note: viewModel.allowReadOnly == nil ? nil : L10n.RemoteNodes.RemoteNodes.RoomSettings.allowReadOnly,
      destination: .action { open(.behavior) }
    )
    return [
      viewModel.helper.radioCard { open(.radio) },
      behavior,
      // The room server's own time, with its drift from this phone; a tap sets it.
      viewModel.helper.clockCard { Task { await viewModel.helper.syncTime() } },
      // the uptime is on the Battery card (the user, 2026-11-09)
      viewModel.helper.deviceCard(uptime: statusViewModel.helper.uptimeDisplay, showsUptime: false) { open(.deviceInfo) },
    ]
  }

  private func open(_ page: NodeSettingsPage) {
    switch page {
    case .identity:
      viewModel.helper.expand(.identity)
      viewModel.helper.expand(.contactInfo)
    case .behavior:
      viewModel.isRoomAccessExpanded = true
      viewModel.isBehaviorExpanded = true
    default:
      viewModel.helper.expand(page)
    }
    openSettingsPage = page
  }

  /// The values the Radio, Device and Behavior cards show, read once the status is in, one at a time.
  private func loadCardSettings() async {
    let helper = viewModel.helper
    if !helper.radioLoaded, !helper.isLoadingRadio { await helper.fetchRadioSettings() }
    if !helper.deviceInfoLoaded, !helper.isLoadingDeviceInfo { await helper.fetchDeviceInfo() }
    if !viewModel.roomAccessLoaded, !viewModel.isLoadingRoomAccess { await viewModel.fetchRoomAccess() }
    // The clock, set from the phone when it has drifted (as the repeater Dashboard does).
    await helper.syncTimeIfDrifted()
  }

  /// Whether a settings sheet's values are still being read from the room server.
  private func isLoading(_ page: NodeSettingsPage) -> Bool {
    let helper = viewModel.helper
    switch page {
    case .radio: return helper.isLoadingRadio
    case .identity, .contactInfo: return helper.isLoadingIdentity || helper.isLoadingContactInfo
    case .behavior, .roomAccess: return viewModel.isLoadingBehavior || viewModel.isLoadingRoomAccess
    case .deviceInfo, .security: return helper.isLoadingDeviceInfo
    case .regions: return false
    }
  }

  /// One setting in its sheet. The location picker and success alert present from inside it: a
  /// sheet can't present over itself from the page below.
  /// Edits on a settings sheet that the room hasn't been sent, so Done asks before closing.
  private func hasUnsavedChanges(_ page: NodeSettingsPage) -> Bool {
    let helper = viewModel.helper
    switch page {
    case .radio: return helper.radioSettingsModified || helper.txPowerModified
    case .identity, .contactInfo: return helper.identitySettingsModified || helper.contactInfoSettingsModified
    case .behavior, .roomAccess: return viewModel.behaviorModified || viewModel.roomAccessModified
    case .deviceInfo, .security, .regions: return false
    }
  }

  private func discardChanges(_ page: NodeSettingsPage) {
    let helper = viewModel.helper
    switch page {
    case .radio: helper.revertRadioSettings()
    case .identity, .contactInfo:
      helper.revertIdentitySettings()
      helper.revertContactInfo()
    case .behavior, .roomAccess:
      viewModel.revertBehaviorSettings()
      viewModel.revertRoomAccess()
    case .deviceInfo, .security, .regions: break
    }
  }

  private func saveChanges(_ page: NodeSettingsPage) -> (() async -> Void)? {
    let helper = viewModel.helper
    switch page {
    case .radio: return nil
    case .identity, .contactInfo:
      return {
        if helper.identitySettingsModified { await helper.applyIdentitySettings() }
        if helper.contactInfoSettingsModified, !helper.isOwnerInfoTooLong { await helper.applyContactInfoSettings() }
      }
    case .behavior, .roomAccess:
      return { [viewModel] in
        if viewModel.roomAccessModified { await viewModel.applyRoomAccess() }
        if viewModel.behaviorModified { await viewModel.applyBehaviorSettings() }
      }
    case .deviceInfo, .security, .regions: return nil
    }
  }

  private func settingsSheet(_ page: NodeSettingsPage) -> some View {
    NodeSettingsPageSheet(
      page: page,
      isLoading: isLoading(page),
      hasUnsavedChanges: hasUnsavedChanges(page),
      onDiscard: { discardChanges(page) },
      onSave: saveChanges(page),
      onDone: { openSettingsPage = nil }
    ) {
      Group {
        switch page {
        case .radio:
          NodeRadioSettingsSection(
            settings: viewModel.helper,
            focusedField: $focusedField,
            radioRestartWarning: L10n.RemoteNodes.RemoteNodes.RoomSettings.radioRestartWarning
          )
        case .identity, .contactInfo:
          RemoteNodeIdentitySection(
            settings: viewModel.helper,
            focusedField: $focusedField,
            onPickLocation: { showingLocationPicker = true }
          )
          NodeContactInfoSection(settings: viewModel.helper, focusedField: $focusedField)
        case .behavior, .roomAccess:
          RoomAccessSection(viewModel: viewModel, focusedField: $focusedField)
          RoomBehaviorSection(viewModel: viewModel, focusedField: $focusedField)
        case .deviceInfo, .security:
          NodeDeviceInfoSection(settings: viewModel.helper)
          NodeSecuritySection(settings: viewModel.helper)
        case .regions:
          EmptyView()
        }
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button(L10n.RemoteNodes.RemoteNodes.Settings.done) {
            focusedField = nil
          }
        }
      }
    }
    .nodeSettingsSuccessAlert(settings: viewModel.helper, isPresented: $viewModel.helper.showSuccessAlert)
    .sheet(isPresented: $showingLocationPicker) {
      LocationPickerView(
        initialCoordinate: CLLocationCoordinate2D(
          latitude: viewModel.helper.latitude ?? 0,
          longitude: viewModel.helper.longitude ?? 0
        )
      ) { coordinate in
        viewModel.helper.setLocationFromPicker(
          latitude: coordinate.latitude,
          longitude: coordinate.longitude
        )
      }
    }
  }
}

// MARK: - Room Access Section

private struct RoomAccessSection: View {
  @Bindable var viewModel: RoomSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.RoomSettings.roomSettingsSection,
      icon: "person.badge.key",
      color: .purple,
      info: L10n.RemoteNodes.RemoteNodes.RoomSettings.allowReadOnlyFooter,
      isExpanded: $viewModel.isRoomAccessExpanded,
      isLoaded: { viewModel.roomAccessLoaded },
      isLoading: $viewModel.isLoadingRoomAccess,
      hasError: $viewModel.roomAccessError,
      onLoad: { await viewModel.fetchRoomAccess() }
    ) {
      SecureField(L10n.RemoteNodes.RemoteNodes.RoomSettings.guestPassword, text: Binding(
        get: { viewModel.guestPassword ?? "" },
        set: { viewModel.guestPassword = $0 }
      ))
      .focused(focusedField, equals: .guestPassword)
      .disabled(viewModel.guestPassword == nil)
      .overlay(alignment: .trailing) {
        if viewModel.guestPassword == nil {
          SettingsLoadPlaceholder(isLoading: viewModel.isLoadingRoomAccess, hasError: viewModel.roomAccessError)
            .padding(.trailing, 8)
        }
      }
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["guest.password"])

      Divider()
      Toggle(isOn: Binding(
        get: { viewModel.allowReadOnly ?? false },
        set: { viewModel.allowReadOnly = $0 }
      )) {
        Text(L10n.RemoteNodes.RemoteNodes.RoomSettings.allowReadOnly)
      }
      .disabled(viewModel.allowReadOnly == nil)
      .accessibilityHint(L10n.RemoteNodes.RemoteNodes.RoomSettings.allowReadOnlyFooter)
      .accessibilityValue(
        viewModel.allowReadOnly == nil
          ? (viewModel.isLoadingRoomAccess ? L10n.RemoteNodes.RemoteNodes.Settings.loading : L10n.RemoteNodes.RemoteNodes.Settings.failedToLoad)
          : (viewModel.allowReadOnly == true ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off)
      )
      .overlay(alignment: .trailing) {
        if viewModel.allowReadOnly == nil {
          SettingsLoadPlaceholder(isLoading: viewModel.isLoadingRoomAccess, hasError: viewModel.roomAccessError)
            .padding(.trailing, 60)
            .accessibilityHidden(true)
        }
      }
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["allow.read.only"])

      Divider()
      HStack(spacing: 12) {
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.RoomSettings.applyRoomSettings,
          isLoading: viewModel.isApplyingRoomAccess,
          showSuccess: viewModel.roomAccessApplySuccess,
          isActive: viewModel.roomAccessModified,
          isDisabled: viewModel.isApplyingRoomAccess || viewModel.roomAccessApplySuccess || !viewModel.roomAccessModified
        ) {
          await viewModel.applyRoomAccess()
        }
        NodeRevertButton(isEnabled: viewModel.roomAccessModified && !viewModel.isApplyingRoomAccess) {
          viewModel.revertRoomAccess()
        }
      }
    }
  }
}

// MARK: - Room Behavior Section

private struct RoomBehaviorSection: View {
  @Bindable var viewModel: RoomSettingsViewModel
  var focusedField: FocusState<NodeSettingsField?>.Binding

  var body: some View {
    ExpandableSettingsCard(
      title: L10n.RemoteNodes.RemoteNodes.Settings.behavior,
      icon: "slider.horizontal.3",
      color: .indigo,
      isExpanded: $viewModel.isBehaviorExpanded,
      isLoaded: { viewModel.behaviorLoaded },
      isLoading: $viewModel.isLoadingBehavior,
      hasError: $viewModel.behaviorError,
      onLoad: { await viewModel.fetchBehaviorSettings() }
    ) {
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.advertInterval0Hop,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.min,
        value: viewModel.advertIntervalMinutes,
        onChange: { viewModel.advertIntervalMinutes = $0 },
        field: .advertInterval,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.advertIntervalError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["advert.interval"])

      Divider()
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.advertIntervalFlood,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.hrs,
        value: viewModel.floodAdvertIntervalHours,
        onChange: { viewModel.floodAdvertIntervalHours = $0 },
        field: .floodAdvertInterval,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.floodAdvertIntervalError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["flood.advert.interval"])

      Divider()
      NodeIntegerFieldRow(
        title: L10n.RemoteNodes.RemoteNodes.Settings.maxFloodHops,
        unit: L10n.RemoteNodes.RemoteNodes.Settings.hops,
        value: viewModel.floodMaxHops,
        onChange: { viewModel.floodMaxHops = $0 },
        field: .floodMaxHops,
        focusedField: focusedField,
        isLoading: viewModel.isLoadingBehavior,
        hasError: viewModel.behaviorError,
        error: viewModel.floodMaxHopsError
      )
      NodeFieldResultLabel(result: viewModel.helper.fieldResults["flood.max"])

      Divider()
      HStack(spacing: 12) {
        NodeApplyButton(
          title: L10n.RemoteNodes.RemoteNodes.Settings.applyBehaviorSettings,
          isLoading: viewModel.isApplyingBehavior,
          showSuccess: viewModel.behaviorApplySuccess,
          isActive: viewModel.behaviorModified,
          isDisabled: viewModel.isApplyingBehavior || viewModel.behaviorApplySuccess || !viewModel.behaviorModified
        ) {
          await viewModel.applyBehaviorSettings()
        }
        NodeRevertButton(isEnabled: viewModel.behaviorModified && !viewModel.isApplyingBehavior) {
          viewModel.revertBehaviorSettings()
        }
      }
    }
  }
}

#Preview {
  NavigationStack {
    RoomSettingsView(
      session: RemoteNodeSessionDTO(
        id: UUID(),
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Community Room",
        role: .roomServer,
        latitude: 37.7749,
        longitude: -122.4194,
        isConnected: true,
        permissionLevel: .admin
      )
    )
    .environment(\.appState, AppState())
  }
}
