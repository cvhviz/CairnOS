import Foundation

/// Controls whether channel re-sync is skipped on resync.
/// Computed from `DevicePlatform` and `lastCleanChannelSync` state at sync start.
struct ChannelSyncConfig {
  /// If channels were synced more recently than this window, skip channel re-sync.
  let channelSyncSkipWindow: Duration

  /// Longer skip window that applies after a fully-clean channel sync. Defaults to
  /// `channelSyncSkipWindow`; partial or failed attempts keep the shorter window.
  let cleanChannelSyncSkipWindow: Duration

  /// Timestamp of the last fully-clean channel sync for the current device.
  let lastCleanChannelSync: Date?

  /// Timestamp of the last attempted channel sync, even if it was partial.
  let lastAttemptedChannelSync: Date?

  /// Whether the store holds a complete copy of this radio's channel table from a clean read,
  /// possibly by an earlier process (`ConnectionManager.verifiedChannelTableRadioID`). Never
  /// skips channels; it only lets a channel phase that runs in the background (and the pending
  /// sync it leaves) check the stored copy before reading every slot.
  let storedChannelTableVerified: Bool

  /// Whether channel reads should use the windowed read pipeline — nRF52 over BLE (Write
  /// Commands) or ESP32 over WiFi (TCP back-to-back sends). `false` for ESP32 over BLE.
  let usePipelinedChannelRead: Bool

  init(
    channelSyncSkipWindow: Duration = .zero,
    cleanChannelSyncSkipWindow: Duration? = nil,
    lastCleanChannelSync: Date? = nil,
    lastAttemptedChannelSync: Date? = nil,
    storedChannelTableVerified: Bool = false,
    usePipelinedChannelRead: Bool = false
  ) {
    self.channelSyncSkipWindow = channelSyncSkipWindow
    self.cleanChannelSyncSkipWindow = cleanChannelSyncSkipWindow ?? channelSyncSkipWindow
    self.lastCleanChannelSync = lastCleanChannelSync
    self.lastAttemptedChannelSync = lastAttemptedChannelSync
    self.storedChannelTableVerified = storedChannelTableVerified
    self.usePipelinedChannelRead = usePipelinedChannelRead
  }

  /// No skip — used for WiFi connections.
  static let none = ChannelSyncConfig()
}
