import Foundation

// MARK: - Channel Sync Configuration

extension DevicePlatform {
  /// If channels were synced more recently than this, skip channel re-sync on resync.
  /// Only enabled for ESP32 where channel re-sync wastes scarce connection time.
  /// Channel skipping is a correctness tradeoff (not just performance), so it stays
  /// disabled for unknown platforms until field evidence warrants it.
  var channelSyncSkipWindow: Duration {
    switch self {
    case .esp32: .seconds(30)
    case .nrf52, .unknown: .zero
    }
  }

  /// If the last channel sync finished cleanly more recently than this, a transient reconnect
  /// (a background link drop, say) skips re-reading every channel slot. Past it, the reconnect
  /// checks the stored copy against the radio (`verifyChannels`: the occupied slots and the
  /// first empty one, which also catches a channel joined or left on the radio's own screen)
  /// and reads every slot only on a difference. The timestamp is in-memory and cleared on user
  /// disconnect and device switch. A process started in the background has no timestamp, but a
  /// clean read by an earlier process (`ChannelSyncConfig.storedChannelTableVerified`) still lets
  /// its background channel phase, and the foreground sync it leaves pending, check first.
  /// Foreground launches, manual connects, and forced full syncs always read every channel.
  var cleanChannelSyncSkipWindow: Duration {
    .seconds(300)
  }

  /// Builds a channel sync config for a sync operation.
  func channelSyncConfig(
    lastCleanChannelSync: Date?,
    lastAttemptedChannelSync: Date? = nil,
    storedChannelTableVerified: Bool = false,
    usePipelinedChannelRead: Bool = false
  ) -> ChannelSyncConfig {
    ChannelSyncConfig(
      channelSyncSkipWindow: channelSyncSkipWindow,
      cleanChannelSyncSkipWindow: cleanChannelSyncSkipWindow,
      lastCleanChannelSync: lastCleanChannelSync,
      lastAttemptedChannelSync: lastAttemptedChannelSync,
      storedChannelTableVerified: storedChannelTableVerified,
      usePipelinedChannelRead: usePipelinedChannelRead
    )
  }
}
