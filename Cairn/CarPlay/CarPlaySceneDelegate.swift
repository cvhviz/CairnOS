#if canImport(CarPlay)
  import CarPlay
  import OSLog

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "CarPlay")

  /// The CarPlay scene, named in the Info.plist scene manifest. UIKit makes it from that name, so
  /// it reaches the app through `AppLaunchController.current`. The app can launch with only the
  /// car's screen showing, so connecting here runs the same once-per-process launch the iPhone
  /// window runs; a later connection just reconciles the radio link as a foreground return does.
  @MainActor
  final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
      _ templateApplicationScene: CPTemplateApplicationScene,
      didConnect interfaceController: CPInterfaceController
    ) {
      guard let launch = AppLaunchController.current else {
        logger.fault("CarPlay connected before the app registered its launch controller")
        return
      }
      let applicationState = switch UIApplication.shared.applicationState {
      case .active: "active"
      case .inactive: "inactive"
      case .background: "background"
      @unknown default: "unknown"
      }
      logger.info("CarPlay connected, applicationState: \(applicationState, privacy: .public), launched: \(launch.hasLaunched)")
      launch.carPlayDidConnect()
      let controller = CarPlayController(interfaceController: interfaceController, launch: launch)
      self.controller = controller
      controller.start()

      Task {
        await launch.launchOnce()
        // The car's screen is a foreground even when the phone is locked, where the application
        // state stays background and launch's own pass skips the reconciliation: without this the
        // BLE link stays in its background mode and battery polling never starts. Joins the
        // pass launch ran when it did run.
        await launch.appState.handleReturnToForeground()
      }
      // No Siri prompt here: it would show on the phone, which a driver should not need. Onboarding
      // and Settings → CarPlay & Siri ask; until Siri is allowed the car says "Siri messaging is off".
    }

    func templateApplicationScene(
      _ templateApplicationScene: CPTemplateApplicationScene,
      didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
      controller?.stop()
      controller = nil
      AppLaunchController.current?.carPlayDidDisconnect()
    }
  }
#endif
