import ActivityKit
import Foundation

struct MeshStatusAttributes: ActivityAttributes {
  let deviceName: String

  /// Stable per-radio identity used to match a same-device reconnect (deviceName is a
  /// user-editable display value, not an identity axis).
  let radioID: UUID

  /// Every field after `disconnectedDate` is optional, so a state encoded by an older build (an
  /// activity still running across an app update) decodes with those fields as nil; its
  /// `packetsPerMinute`, no longer kept, is ignored. Text that
  /// follows the app's settings (position and altitude follow the units preference) arrives
  /// preformatted: the widget can't read the app's defaults.
  struct ContentState: Codable, Hashable {
    var isConnected: Bool
    var batteryPercent: Int?
    var unreadCount: Int
    var disconnectedDate: Date?

    /// When the activity last confirmed the radio hearing packets. Refreshed at most every
    /// `LiveActivityManager.packetRefreshInterval` while they keep coming, not per packet: the
    /// activity goes stale `quietAfter` later, so a mesh gone quiet shows as quiet without the
    /// app waking, with a self-updating "quiet for" timer from this date.
    var lastPacketDate: Date?

    /// Battery voltage in millivolts, from the same reading as `batteryPercent`.
    var batteryMillivolts: Int?
    /// Signal of the last packet the radio heard.
    var lastRSSI: Int?
    var lastSNR: Double?
    /// The radio's noise floor in dBm, from its stats (firmware v8+).
    var noiseFloor: Int?
    /// Distinct nodes whose adverts arrived in the last hour.
    var nodesHeard: Int?
    /// "41.8823, -87.6232": the radio's GPS fix, else the position it advertises.
    var positionText: String?
    /// "182 m" / "597 ft": only with a GPS fix from the radio's own telemetry.
    var altitudeText: String?
    var lastMessage: LastMessage?

    init(
      isConnected: Bool,
      batteryPercent: Int?,
      unreadCount: Int,
      disconnectedDate: Date?,
      lastPacketDate: Date? = nil,
      batteryMillivolts: Int? = nil,
      lastRSSI: Int? = nil,
      lastSNR: Double? = nil,
      noiseFloor: Int? = nil,
      nodesHeard: Int? = nil,
      positionText: String? = nil,
      altitudeText: String? = nil,
      lastMessage: LastMessage? = nil
    ) {
      self.isConnected = isConnected
      self.batteryPercent = batteryPercent
      self.unreadCount = unreadCount
      self.disconnectedDate = disconnectedDate
      self.lastPacketDate = lastPacketDate
      self.batteryMillivolts = batteryMillivolts
      self.lastRSSI = lastRSSI
      self.lastSNR = lastSNR
      self.noiseFloor = noiseFloor
      self.nodesHeard = nodesHeard
      self.positionText = positionText
      self.altitudeText = altitudeText
      self.lastMessage = lastMessage
    }
  }

  /// The latest received message, cut to a one-line preview for the banner.
  struct LastMessage: Codable, Hashable {
    var sender: String
    /// The channel's name, or nil for a direct message.
    var channelName: String?
    var preview: String
    var date: Date

    /// Longest preview kept, in characters; the banner shows one line of it.
    static let previewLimit = 90

    /// Runs of whitespace and line breaks collapsed to one space, cut at `previewLimit` with an
    /// ellipsis. Keeps the state well under ActivityKit's 4 KB payload.
    static func preview(of text: String) -> String {
      let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard oneLine.count > previewLimit else { return oneLine }
      return String(oneLine.prefix(previewLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
  }
}
