import os

/// Whether the app is in the background, for services that pace their own work by it.
///
/// Set by `ConnectionManager`'s lifecycle hooks, which the app calls as its windows (and the car's
/// screen) come and go. Process-wide because the services are rebuilt on every reconnect, also
/// while the app is in the background, and a service made then must start out knowing it.
public enum AppActivity {
  private static let background = OSAllocatedUnfairLock(initialState: false)

  public static var isBackground: Bool {
    get { background.withLock { $0 } }
    set { background.withLock { $0 = newValue } }
  }
}
