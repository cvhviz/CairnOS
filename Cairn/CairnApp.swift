import AppIntents
import CairnServices
import SwiftUI

@main
struct CairnApp: App {
  /// Receives the Siri messaging intents CarPlay hands to the app; see `AppDelegate`.
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// Owns `AppState` and the launch work, so the CarPlay scene and Siri can reach them too.
  @State private var launch: AppLaunchController
  @AppStorage(AppStorageKey.nightMode.rawValue) private var nightMode = false
  @Environment(\.scenePhase) private var scenePhase

  private var appState: AppState { launch.appState }

  init() {
    let launch = AppLaunchController()
    _launch = State(initialValue: launch)
    AppLaunchController.current = launch
    // Register the bridge synchronously here: a background-launched intent
    // runs only `App.init` (no scene, no `.task`), so a deferred
    // registration could let its `@Dependency` read throw before it lands.
    // Capture into a local so the escaping autoclosure does not capture the
    // still-initializing `self`.
    let intentBridge = launch.intentBridge
    AppDependencyManager.shared.add(dependency: intentBridge)
    // Tips bought outside a purchase (Ask to Buy, an interrupted sale) arrive at any time.
    TipJarStore.shared.startObservingTransactions()
  }

  var body: some Scene {
    WindowGroup(id: AppCommands.mainWindowID) {
      windowLifecycle(ContentView().modifier(MainWindowTitle()))
        // So a detail window can bring this one forward when it moves on to a chat.
        .registersMacMainWindow()
    }
    .commands {
      AppCommands(navigation: appState.navigation, appState: appState)
    }

    // A single conversation in its own window, opened from a chat row's context menu.
    WindowGroup(for: ConversationWindowID.self) { $windowID in
      windowLifecycle(
        ConversationWindowView(windowID: windowID)
          // `ContentView` runs this hook itself for the main window.
          .modifier(BecameActiveHook())
      )
    }

    // Mac only: a node's page in its own window, one per node, where the phone and iPad show a
    // sheet (see `detailPresentation`). What the page opens pushes within that window.
    WindowGroup(for: MacDetailRoute.self) { $route in
      windowLifecycle(
        MacDetailWindowView(route: route)
          .modifier(BecameActiveHook())
      )
    }
  }

  /// Environment and lifecycle hooks shared by every window scene. The system can
  /// restore or foreground any one scene on its own, so each must be able to run
  /// launch and react to the app-level scene phase; `lifecycleGate` keeps both
  /// from repeating per window.
  private func windowLifecycle(_ content: some View) -> some View {
    Group {
      // The store would not open: the app behind this is an empty placeholder, so it stays hidden.
      if let failure = launch.storeFailure {
        StoreUnavailableView(details: failure, isRetrying: launch.isRetryingStore) {
          await launch.retryOpeningStore()
        }
      } else if launch.awaitingStore {
        // before first unlock, or the first attempts to open it: nothing of the app yet
        ProgressView()
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        content
      }
    }
      .environment(\.appState, appState)
      .environment(\.appTheme, appState.themeService.current)
      // Night mode is dark under its red filter, whatever the appearance setting.
      .preferredColorScheme(nightMode ? .dark : appState.themeService.effectiveColorScheme)
      // Under the filter colour is lost, so tinted buttons go white to stay bright.
      .tint(nightMode ? NightMode.tint : nil)
      .nightModeFilter(nightMode)
      .task {
        await launch.launchOnce()
      }
      .onOpenURL { url in
        launch.pendingExternalURL.submit(url, appState: appState)
      }
      .onChange(of: scenePhase) { oldPhase, newPhase in
        handleScenePhaseChange(from: oldPhase, to: newPhase)
      }
      // Mac only: no App Nap while a radio is connected or being reconnected.
      .onChange(of: appState.connectionManager.isConnectionWanted || appState.connectionState != .disconnected, initial: true) { _, isWanted in
        MacRadioActivity.update(isWanted: isWanted)
      }
  }

  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    // Every open window reports the same app-level transition.
    guard launch.lifecycleGate.shouldHandle(newPhase) else { return }
    appState.logToolbarResumeProbe(
      source: "scenePhase",
      scene: "\(scenePhaseName(oldPhase))->\(scenePhaseName(newPhase))"
    )
    switch newPhase {
    case .active:
      // Held until launch has finished, which reconciles once itself; see `returnToForeground()`.
      launch.returnToForeground()
    case .background:
      // The car's screen is still in the foreground: keep the link, battery polling and
      // keepalives running for it. Its disconnect handles the background if the phone stays away.
      // On a Mac, a minimised or hidden window leaves the app running, not suspended: the link
      // and its supervision carry on as if in front.
      if launch.isCarPlayConnected || ProcessInfo.processInfo.isiOSAppOnMac {
        launch.flushLogs()
      } else {
        launch.enterBackground()
      }
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  private func scenePhaseName(_ phase: ScenePhase) -> String {
    switch phase {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }
}

/// The main window's title on a Mac: the tab it shows, as the tab bar names it, or Settings. Read
/// here rather than in `body`, so a tab change redraws this window, not the app's scenes.
private struct MainWindowTitle: ViewModifier {
  @Environment(\.appState) private var appState

  func body(content: Content) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      content.macWindowTitle(title)
    } else {
      content
    }
  }

  private var title: String {
    if appState.navigation.isSettingsPresented { return L10n.Localizable.Tabs.settings }
    return (AppTab(rawValue: appState.navigation.selectedTab) ?? .home).title
  }
}

/// Runs `AppState.handleBecameActive()` when the hosting scene becomes active,
/// for scenes whose root view does not do so itself. Those scenes don't host the
/// pairing sheet or device picker, so they leave both pending for the main window.
private struct BecameActiveHook: ViewModifier {
  @Environment(\.appState) private var appState
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .active {
          appState.handleBecameActive(presentsConnectionUI: false)
        }
      }
  }
}
