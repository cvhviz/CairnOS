import Foundation

/// Messages a Cairn radio reported lost from its offline queue (firmware's `QUEUE_SYNC.md`) that no
/// notification has told the user about yet, kept in the app's defaults until the user sees them.
///
/// The radio's loss counters are cleared once the app has the report, so a report whose notification
/// could not be posted (notifications off, not yet allowed, or the post failed) would otherwise be
/// gone. It lands here instead, and Settings → Notifications shows it until dismissed. Device-local:
/// not part of a settings backup.
// UserDefaults is thread-safe; it is the only stored property.
public struct RadioQueueLossLedger: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Lost messages not yet shown to the user (0 = none).
  public var unseenLostMessages: Int {
    defaults.integer(forKey: AppStorageKey.radioQueueLossUnseen.rawValue)
  }

  /// The radio the last unseen loss came from.
  public var deviceName: String? {
    defaults.string(forKey: AppStorageKey.radioQueueLossDevice.rawValue)
  }

  /// Adds a loss the user was not told about.
  public func record(lostMessages: Int, deviceName: String) {
    guard lostMessages > 0 else { return }
    let total = unseenLostMessages.addingReportingOverflow(lostMessages)
    defaults.set(total.overflow ? Int.max : total.partialValue, forKey: AppStorageKey.radioQueueLossUnseen.rawValue)
    defaults.set(deviceName, forKey: AppStorageKey.radioQueueLossDevice.rawValue)
  }

  /// The user has seen it.
  public func dismiss() {
    defaults.removeObject(forKey: AppStorageKey.radioQueueLossUnseen.rawValue)
    defaults.removeObject(forKey: AppStorageKey.radioQueueLossDevice.rawValue)
  }
}
