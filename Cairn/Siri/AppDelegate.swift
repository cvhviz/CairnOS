import Intents
import OSLog
import UIKit

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "AppDelegate")

/// The UIKit side of the app, for what SwiftUI's lifecycle has no hook for: handing Siri's
/// messaging intents to an in-app handler (CarPlay's Chats rows depend on them), registering the
/// Background App Refresh task, and creating the Bluetooth central as the process launches.
/// Scenes are still SwiftUI's (and the CarPlay scene comes from the Info.plist manifest), so this
/// implements nothing about scenes.
final class AppDelegate: NSObject, UIApplicationDelegate {
  /// iOS relaunches the app in the background to hand over a Bluetooth link it kept (state
  /// restoration). That relaunch creates no scene, so no window `.task` runs launch, and the
  /// restoration goes only to a central that exists: the central is created here, its lifecycle
  /// handlers wired first, and launch started behind it. `CairnApp.init` has already registered
  /// the launch controller. A Background App Refresh run can relaunch the app the same way, and
  /// its task's handler must be registered before launch finishes, so it is registered here first.
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let restoredCentrals = launchOptions?[.bluetoothCentrals] as? [String] ?? []
    logger.info(
      "didFinishLaunching: applicationState=\(application.applicationState.rawValue, privacy: .public), bluetoothCentrals=\(restoredCentrals, privacy: .public)"
    )
    guard let launch = AppLaunchController.current else {
      logger.fault("Launched before the app registered its launch controller")
      return true
    }
    launch.backgroundRefresh.register(host: launch)
    launch.prepareBluetoothCentral()
    Task {
      await launch.launchOnce()
    }
    return true
  }

  func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    switch intent {
    case is INSendMessageIntent, is INSearchForMessagesIntent, is INSetMessageAttributeIntent:
      MessageIntentHandler()
    default:
      nil
    }
  }
}
