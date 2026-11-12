import CairnServices
import UIKit

/// UIKit-based implementation of AppStateProvider.
///
/// Checks UIApplication.shared.applicationState to determine if app is in foreground. A car's
/// screen showing the app counts as foreground too: with the phone locked the application state
/// stays background while the driver uses the app.
/// MainActor-isolated with async getter to allow cross-actor access.
@MainActor
final class AppStateProviderImpl: AppStateProvider {
  init() {}

  nonisolated var isInForeground: Bool {
    get async {
      await MainActor.run {
        UIApplication.shared.applicationState != .background
          || AppLaunchController.current?.isCarPlayConnected == true
      }
    }
  }
}
