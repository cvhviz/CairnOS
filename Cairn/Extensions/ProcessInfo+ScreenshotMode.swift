import Foundation

#if DEBUG
  extension ProcessInfo {
    /// True when launched with `-screenshotMode` for App Store screenshot capture.
    var isScreenshotMode: Bool {
      arguments.contains("-screenshotMode")
    }

    /// The value after `-name` in the launch arguments, read from the arguments themselves (as
    /// `-uiTestBackground` is) rather than through `UserDefaults`.
    func launchArgument(_ name: String) -> String? {
      guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else {
        return nil
      }
      return arguments[index + 1]
    }
  }
#endif
