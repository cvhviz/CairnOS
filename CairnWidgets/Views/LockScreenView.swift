import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner: the radio and its battery on top, then the last message, then a strip
/// of signal and mesh readings. Disconnected, the readings go and the last message stays. Kept
/// compact, with text size capped, to fit the banner's 160 pt height. The message and position
/// are privacy sensitive, so iOS redacts them on a locked phone when the user hides previews.
struct LockScreenView: View {
  let context: ActivityViewContext<MeshStatusAttributes>

  private var state: MeshStatusAttributes.ContentState { context.state }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header

      if state.isConnected || state.lastMessage != nil {
        LastMessageCard(
          message: state.lastMessage,
          unreadCount: state.isConnected ? state.unreadCount : 0
        )
      }

      if state.isConnected {
        MetricStrip(state: state, isStale: context.isStale)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dynamicTypeSize(...DynamicTypeSize.large)
    .widgetURL(URL(string: "cairn://status"))
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      ActivityIconTile(
        image: ActivityStyle.radioImage,
        color: ActivityStyle.linkColor(isConnected: state.isConnected),
        size: 30
      )

      VStack(alignment: .leading, spacing: 1) {
        Text(context.attributes.deviceName)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.tail)
        statusLine
          .font(.caption)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)

      Spacer(minLength: 4)

      if state.isConnected {
        BatteryGauge(percent: state.batteryPercent, millivolts: state.batteryMillivolts, showsBar: false)
      }
    }
  }

  /// Connected: whether the mesh is live or quiet (and for how long, counting on by itself), then
  /// the radio's position when it has one. Disconnected: just that.
  @ViewBuilder private var statusLine: some View {
    if !state.isConnected {
      Text("Disconnected")
        .foregroundStyle(ActivityStyle.warning)
    } else {
      HStack(spacing: 6) {
        TrafficStatusText(lastPacketDate: state.lastPacketDate, isStale: context.isStale)
          .layoutPriority(1)
        if let positionLine = state.positionLine {
          HStack(spacing: 3) {
            Image(systemName: "location.fill")
              .font(.caption2)
              .foregroundStyle(ActivityStyle.teal)
              .accessibilityHidden(true)
            Text(positionLine)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .truncationMode(.tail)
              .privacySensitive()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("Position \(positionLine)"))
        }
      }
    }
  }
}

// MARK: - Subviews

/// The last message, one line of it, with who sent it, where and when, and the unread count.
struct LastMessageCard: View {
  let message: MeshStatusAttributes.LastMessage?
  let unreadCount: Int

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      ActivityIconTile(
        systemImage: message?.channelName == nil ? "person.fill" : "number",
        color: message?.channelName == nil ? .indigo : ActivityStyle.teal,
        size: 24
      )

      VStack(alignment: .leading, spacing: 1) {
        if let message {
          HStack(spacing: 6) {
            MessageOriginText(message: message)
            Spacer(minLength: 4)
            MessageAgeText(date: message.date)
          }
          .font(.caption)
          Text(message.preview)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.tail)
            .privacySensitive()
        } else {
          Text("No messages yet")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(message?.accessibilityText ?? Text("No messages yet"))

      if unreadCount > 0 {
        UnreadBadge(count: unreadCount)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(ActivityStyle.tileFill, in: .rect(cornerRadius: 10, style: .continuous))
  }
}

/// The unread count as a teal capsule.
struct UnreadBadge: View {
  let count: Int

  var body: some View {
    Text(verbatim: "\(count)")
      .font(.caption.weight(.bold))
      .monospacedDigit()
      .contentTransition(.numericText())
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(ActivityStyle.teal, in: .capsule)
      .accessibilityLabel(Text("\(count) unread messages"))
  }
}

/// Signal of the last packet, the noise floor, the unread messages and the nodes heard, each as a
/// mini tile. A reading the radio hasn't given shows as a dash, as do the signal readings once
/// the activity is stale (the app hasn't refreshed them in a while).
struct MetricStrip: View {
  let state: MeshStatusAttributes.ContentState
  let isStale: Bool

  private static let placeholder = "—"

  var body: some View {
    let unread = state.isConnected ? state.unreadCount : 0
    let rssi = isStale ? nil : state.lastRSSI
    let snr = isStale ? nil : state.lastSNR
    let noiseFloor = isStale ? nil : state.noiseFloor
    HStack(spacing: 6) {
      MiniMetricTile(value: rssi.map { "\($0)" } ?? Self.placeholder, caption: "RSSI")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rssi.map { Text("Last RSSI \($0) dBm") } ?? Text("RSSI"))
      MiniMetricTile(value: snr.map(ActivityStyle.snr) ?? Self.placeholder, caption: "SNR")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snr.map { Text("Last SNR \(ActivityStyle.snr($0)) dB") } ?? Text("SNR"))
      MiniMetricTile(value: noiseFloor.map { "\($0)" } ?? Self.placeholder, caption: "Noise")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(noiseFloor.map { Text("Noise floor \($0) dBm") } ?? Text("Noise"))
      // only when there is something unread: no "0" tile
      if unread > 0 {
        MiniMetricTile(value: "\(unread)", caption: "Unread", tint: ActivityStyle.teal)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("\(unread) unread messages"))
      }
      MiniMetricTile(value: state.nodesHeard.map { "\($0)" } ?? Self.placeholder, caption: "Nodes 1h")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(state.nodesHeard ?? 0) nodes heard in the last hour"))
    }
  }
}
