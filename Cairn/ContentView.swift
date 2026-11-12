import CairnServices
import SwiftUI

struct ContentView: View {
  @Environment(\.appState) private var appState
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var connectionUI = appState.connectionUI

    Group {
      if appState.onboarding.hasCompletedOnboarding {
        // One navigation on every device: the iPhone's bottom tab bar. At regular width the
        // tabs with lists (Chats, Nodes) and Settings put each list beside its page.
        MainTabView()
      } else {
        OnboardingView()
      }
    }
    .animation(.default, value: appState.onboarding.hasCompletedOnboarding)
    // Opening Nodes shows what was heard, so its badge clears, however it was opened.
    .onChange(of: appState.navigation.selectedTab, initial: true) { _, tab in
      if tab == AppTab.contacts.rawValue { appState.unseenAdvertCount = 0 }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        appState.handleBecameActive()
      }
    }
    .alert(
      connectionUI.connectionFailedTitle ?? L10n.Localizable.Alert.ConnectionFailed.title,
      isPresented: $connectionUI.showingConnectionFailedAlert
    ) {
      if appState.connectionUI.failedPairingDeviceID != nil {
        switch appState.connectionUI.pairingFailureKind {
        case .authentication, .pinRejected:
          // Bond can't proceed (a dead saved bond or a rejected fresh PIN), so
          // destructive remove is the recovery. The two kinds share these
          // buttons and differ only in the message copy set by the presenter.
          Button(L10n.Localizable.Alert.ConnectionFailed.removeAndRetry, role: .destructive) {
            appState.removeFailedPairingAndRetry()
          }
          .accessibilityLabel(L10n.Localizable.Accessibility.Alert.ConnectionFailed.removeAndRetry)
          Button(L10n.Localizable.Common.cancel, role: .cancel) {
            appState.connectionUI.failedPairingDeviceID = nil
          }
        case .transient, .none:
          // Transient variant — bond is still good, prefer non-destructive retry.
          // `.none` is unreachable in practice (every pairing-failure path routes
          // through `presentPairingFailure`, which always sets the kind). Folding
          // it into the safer branch ensures a missing kind can't promote a working
          // bond into the destructive recovery.
          Button(L10n.Localizable.Common.tryAgain) {
            Task { await appState.retryFailedPairingConnect() }
          }
          Button(L10n.Localizable.Alert.ConnectionFailed.removeAndRetry, role: .destructive) {
            appState.removeFailedPairingAndRetry()
          }
          .accessibilityLabel(L10n.Localizable.Accessibility.Alert.ConnectionFailed.removeAndRetry)
          Button(L10n.Localizable.Common.cancel, role: .cancel) {
            appState.connectionUI.failedPairingDeviceID = nil
          }
        }
      } else {
        Button(L10n.Localizable.Common.ok, role: .cancel) {}
      }
    } message: {
      Text(appState.connectionUI.connectionFailedMessage ?? L10n.Localizable.Alert.ConnectionFailed.defaultMessage)
    }
    .alert(
      L10n.Localizable.Alert.CouldNotConnect.title,
      isPresented: Binding(
        get: { appState.connectionUI.otherAppWarningDeviceID != nil },
        set: { if !$0 { appState.connectionUI.otherAppWarningDeviceID = nil } }
      )
    ) {
      Button(L10n.Localizable.Common.ok) {
        appState.connectionUI.otherAppWarningDeviceID = nil
      }
    } message: {
      Text(L10n.Localizable.Alert.CouldNotConnect.otherAppMessage)
    }
    // A connection that reached a radio already saved over the other transport: it is one radio,
    // listed once on Connections with both ways in.
    .alert(
      L10n.Settings.Connections.Linked.title,
      isPresented: Binding(
        get: { appState.connectionManager.linkedRadioNotice != nil && !appState.connectionUI.showingConnectionFailedAlert },
        set: { if !$0 { appState.connectionManager.clearLinkedRadioNotice() } }
      ),
      presenting: appState.connectionManager.linkedRadioNotice
    ) { _ in
      Button(L10n.Localizable.Common.ok, role: .cancel) {}
    } message: { notice in
      Text(L10n.Settings.Connections.Linked.message(
        notice.radioName,
        NodeRouteFormat.joined(notice.savedTransports.map(\.displayName)),
        notice.newTransport.displayName
      ))
    }
    // macOS "Designed for iPad" device picker. `bluetoothScanPicker` is nil on iOS, where
    // AccessorySetupKit presents its own system picker, so this sheet never appears there.
    .sheet(isPresented: Binding(
      get: { appState.connectionManager.bluetoothScanPicker?.isPresenting ?? false },
      set: { if !$0 { appState.connectionManager.bluetoothScanPicker?.cancel() } }
    )) {
      if let scanPicker = appState.connectionManager.bluetoothScanPicker {
        DeviceScannerSheet(picker: scanPicker)
      }
    }
    .sheet(item: $connectionUI.pendingSystemPairingSetup, onDismiss: {
      appState.handleSystemPairingSetupSheetDismissed()
    }) { prompt in
      SystemPairingSetupSheet(
        prompt: prompt,
        onForget: { appState.confirmSystemPairingSetup() },
        onCancel: { appState.cancelSystemPairingSetup() }
      )
    }
    // SwiftUI does not reliably co-present a sheet and an alert from the same host,
    // so the binding yields a release only while the connection UI above is quiescent;
    // `pendingRelease` stays set and re-presents on the next render once any alert clears.
    .sheet(item: Binding(
      get: { connectionUIQuiescent ? appState.whatsNew.pendingRelease : nil },
      set: { if $0 == nil { appState.whatsNew.markShown() } }
    )) { release in
      WhatsNewSheet(release: release)
    }
  }

  /// True when no connection alert or scan picker from this host is presenting.
  private var connectionUIQuiescent: Bool {
    !appState.connectionUI.showingConnectionFailedAlert
      && appState.connectionUI.otherAppWarningDeviceID == nil
      && appState.connectionUI.pendingSystemPairingSetup == nil
      && !(appState.connectionManager.bluetoothScanPicker?.isPresenting ?? false)
      && appState.connectionManager.linkedRadioNotice == nil
  }
}

// MARK: - Onboarding View

struct OnboardingView: View {
  @Environment(\.appState) private var appState

  var body: some View {
    @Bindable var onboarding = appState.onboarding

    NavigationStack(path: $onboarding.onboardingPath) {
      WelcomeView()
        .navigationDestination(for: OnboardingStep.self) { step in
          switch step {
          case .welcome:
            WelcomeView()
          case .permissions:
            PermissionsView()
          case .pair:
            DeviceScanView()
          case .region:
            RegionStepView()
          case .preset:
            PresetStepView()
          }
        }
    }
  }
}

// MARK: - Main Tab View

/// The app's one navigation, on iPhone, iPad and Mac alike: the floating bottom tab bar with
/// Dashboard, Nodes, Chats, Map and Spectrum (⌘1–⌘5, `AppCommands`). At regular width (iPad, an
/// unfolded iPhone Duo) Chats and Nodes show their list beside the open page (`ChatsTabSplit`,
/// `ContactsTabSplit`), Settings covers the tabs with its hub beside its page (`SettingsTabSplit`),
/// and the radio's name opens Device Info as a sheet over the page; at compact width (iPhone, and
/// an iPad's Split View or Slide Over) every tab is a stack and Settings is a sheet.
struct MainTabView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @AppStorage(AppStorageKey.nightMode.rawValue) private var nightMode = false
  @State private var showingDeviceSelection = false

  /// Lists beside their pages (see `TabSplitLayout`).
  private var usesSplit: Bool {
    TabSplitLayout.usesSplit(
      horizontalSizeClass: horizontalSizeClass,
      verticalSizeClass: verticalSizeClass,
      idiom: UIDevice.current.userInterfaceIdiom
    )
  }

  /// A tab's accent; the Dashboard's follows the connected radio's avatar colour.
  private func accent(_ tab: AppTab) -> Color {
    tab.accentColor(nightMode: nightMode, appState: appState, theme: theme, colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  var body: some View {
    @Bindable var navigation = appState.navigation

    TabView(selection: Binding(
      get: { navigation.selectedTab },
      set: { tab in
        // The tab bar sets the tab it's already on when that tab is tapped again.
        if tab == navigation.selectedTab { navigation.reselectTab(tab) }
        navigation.selectedTab = tab
      }
    )) {
      Tab(AppTab.home.title, image: AppTab.home.symbolName, value: AppTab.home.rawValue) {
        HomeView()
          .tint(accent(.home))
          .environment(\.horizontalSizeClass, horizontalSizeClass)
      }

      Tab(AppTab.contacts.title, systemImage: AppTab.contacts.symbolName, value: AppTab.contacts.rawValue) {
        Group {
          if usesSplit {
            ContactsTabSplit()
          } else {
            ContactsListView()
          }
        }
        .tint(AppTab.contacts.accentColor(nightMode: nightMode))
        .environment(\.horizontalSizeClass, horizontalSizeClass)
      }
      .badge(appState.unseenAdvertCount)

      Tab(AppTab.chats.title, systemImage: AppTab.chats.symbolName, value: AppTab.chats.rawValue) {
        Group {
          if usesSplit {
            ChatsTabSplit()
          } else {
            ChatsView()
          }
        }
        .tint(AppTab.chats.accentColor(nightMode: nightMode))
        .environment(\.horizontalSizeClass, horizontalSizeClass)
      }
      .badge(appState.services?.notificationService.badgeCount ?? 0)

      Tab(AppTab.gps.title, systemImage: AppTab.gps.symbolName, value: AppTab.gps.rawValue) {
        GPSView()
          .tint(AppTab.gps.accentColor(nightMode: nightMode))
          .environment(\.horizontalSizeClass, horizontalSizeClass)
      }

      Tab(AppTab.spectrum.title, systemImage: AppTab.spectrum.symbolName, value: AppTab.spectrum.rawValue) {
        SpectrumTabView()
          .tint(AppTab.spectrum.accentColor(nightMode: nightMode))
          .environment(\.horizontalSizeClass, horizontalSizeClass)
      }
    }
    // The iPhone's floating bottom bar on every device: the tab view lays out for compact width
    // (on an iPad it would otherwise move its tabs to the top bar or a sidebar), and each tab's
    // content gets the window's real size class back above.
    .environment(\.horizontalSizeClass, .compact)
    // The open tab's colour on its tab-bar icon; each tab's content carries its own.
    .tint(AppTab(rawValue: navigation.selectedTab).map(accent))
    .themedChrome(theme)
    .syncingPillOverlay(onDisconnectedTap: { showingDeviceSelection = true })
    .onChange(of: appState.connectedDevice) { _, newDevice in
      // An explicit (status-menu) disconnect skips onConnectionLost, so pop the radio's pages off
      // Home's stack here; a radio switch runs clearPerRadioSelection.
      if newDevice == nil {
        appState.navigation.clearPerDeviceSelection()
      }
    }
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    // Settings is reached through the gear on Home (and ⌘,), and every shortcut to a setting (a
    // card, a tab's sliders, the radio button) opens it on that page, rather than a tab of its own.
    // A large sheet keeps the tab underneath in place, so Done returns exactly where the user was.
    .sheet(isPresented: settingsPresented(split: false)) {
      SettingsView()
        .presentationDetents([.large])
        // An app-started firmware update runs from its page in Settings: closing the sheet would
        // end the upload, so it stays until the update lets go.
        .interactiveDismissDisabled(navigation.holdsDevicePagesForUpdate)
    }
    // At regular width Settings covers the tabs with its hub beside its page; Done (or a tab
    // switch from a shortcut) returns to the tab as it was.
    .fullScreenCover(isPresented: settingsPresented(split: true)) {
      SettingsTabSplit()
        .tint(nil)
    }
    // Device Info over the page at regular width, opened from the radio's name, so it never moves
    // Settings' page; its Firmware Update and Connections open Settings once it has gone.
    .sheet(isPresented: deviceInfoSheetIsPresented, onDismiss: {
      var flow = appState.navigation.deviceInfoSheet
      flow.dismissed(navigation: appState.navigation)
      appState.navigation.deviceInfoSheet = flow
    }) {
      DeviceInfoSheet(
        onOpenFirmwareUpdate: { appState.navigation.deviceInfoSheet.requestFirmwareUpdate() },
        onOpenConnections: { appState.navigation.deviceInfoSheet.requestConnections() },
        onOpenSetting: { appState.navigation.deviceInfoSheet.requestSetting($0) }
      )
    }
    .environment(\.opensDeviceInfoAsSheet, usesSplit)
  }

  /// Settings' presentation for one layout: the sheet at compact width, the cover at regular.
  private func settingsPresented(split: Bool) -> Binding<Bool> {
    let navigation = appState.navigation
    let applies = usesSplit == split
    return Binding(
      get: { applies && navigation.isSettingsPresented },
      set: { if applies { navigation.isSettingsPresented = $0 } }
    )
  }

  private var deviceInfoSheetIsPresented: Binding<Bool> {
    let navigation = appState.navigation
    return Binding(
      get: { navigation.deviceInfoSheet.isPresented },
      set: { navigation.deviceInfoSheet.isPresented = $0 }
    )
  }
}

#Preview("Content View - Onboarding") {
  ContentView()
    .environment(\.appState, AppState())
}

#Preview("Content View - Main App") {
  let appState = AppState()
  appState.onboarding.hasCompletedOnboarding = true
  return ContentView()
    .environment(\.appState, appState)
}
