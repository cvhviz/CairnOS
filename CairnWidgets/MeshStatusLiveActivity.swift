import ActivityKit
import SwiftUI
import WidgetKit

struct MeshStatusLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MeshStatusAttributes.self) { context in
      // No background tint: the banner keeps the system's own Lock Screen material, light or dark.
      ActivityContentView(context: context)
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            ActivityIconTile(
              image: ActivityStyle.radioImage,
              color: ActivityStyle.linkColor(isConnected: state.isConnected),
              size: 26
            )
            VStack(alignment: .leading, spacing: 0) {
              Text(context.attributes.deviceName)
                .font(.subheadline.bold())
                .lineLimit(1)
                .truncationMode(.tail)
              Text(state.isConnected ? "Connected" : "Disconnected")
                .font(.caption2)
                .foregroundStyle(state.isConnected ? .secondary : ActivityStyle.warning)
            }
          }
          .accessibilityElement(children: .combine)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if state.isConnected {
            BatteryGauge(percent: state.batteryPercent, millivolts: state.batteryMillivolts)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            if let message = state.lastMessage {
              IslandMessageLine(message: message, unreadCount: state.isConnected ? state.unreadCount : 0)
            }
            if state.isConnected {
              IslandReadingsLine(state: state, isStale: context.isStale)
            }
          }
          .padding(.top, 2)
        }
      } compactLeading: {
        ActivityStyle.radioImage
          .foregroundStyle(ActivityStyle.linkColor(isConnected: state.isConnected))
          .accessibilityLabel(Text(state.isConnected ? "Connected" : "Disconnected"))
      } compactTrailing: {
        if !state.isConnected {
          Text(verbatim: "—")
            .accessibilityLabel(Text("Disconnected"))
        } else if state.unreadCount > 0 {
          // The number is the unread messages, never the packet rate (mostly adverts): the
          // rate stays in the expanded readings and the banner's strip. Nothing unread: the
          // battery instead (below), never a "0" envelope.
          HStack(spacing: 2) {
            Image(systemName: "envelope.fill")
              .accessibilityHidden(true)
            Text(verbatim: "\(state.unreadCount)")
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          .foregroundStyle(ActivityStyle.teal)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("\(state.unreadCount) unread messages"))
        } else if let percent = state.batteryPercent {
          // iOS keeps the compact island's trailing side even when it's empty, which left a blank
          // beside the radio (the user, 2026-11-08): the radio's battery fills it, as a ring with
          // the number inside, since "76%" as text is wider than the side allows.
          BatteryRing(percent: percent)
            .accessibilityLabel(Text("Battery \(percent) percent"))
        }
      } minimal: {
        if !state.isConnected {
          ActivityStyle.radioImage
            .foregroundStyle(ActivityStyle.warning)
            .accessibilityLabel(Text("Disconnected"))
        } else if state.unreadCount > 0 {
          Text(verbatim: "\(state.unreadCount)")
            .font(.caption2.bold())
            .monospacedDigit()
            .foregroundStyle(ActivityStyle.teal)
            .contentTransition(.numericText())
            .accessibilityLabel(Text("\(state.unreadCount) unread messages"))
        } else {
          // no unread: the link, as the compact leading shows it (no envelope, no "0")
          ActivityStyle.radioImage
            .foregroundStyle(ActivityStyle.linkColor(isConnected: true))
            .accessibilityLabel(Text("Connected"))
        }
      }
      .keylineTint(ActivityStyle.teal)
      .widgetURL(URL(string: "cairn://status"))
    }
    // The CarPlay Dashboard (iOS 26) and the Watch Smart Stack show the small family; without it
    // CarPlay falls back to the Dynamic Island's compact pair, which is too terse to read at a glance.
    .supplementalActivityFamilies([.small])
  }
}

/// Picks the lock-screen banner or the small family's glanceable card.
private struct ActivityContentView: View {
  @Environment(\.activityFamily) private var family
  let context: ActivityViewContext<MeshStatusAttributes>

  var body: some View {
    switch family {
    case .small:
      SmallActivityView(context: context)
    default:
      LockScreenView(context: context)
    }
  }
}

// MARK: - Dynamic Island lines

/// "Alex · #Public  5 min ago" over one line of the message, with the unread count.
private struct IslandMessageLine: View {
  let message: MeshStatusAttributes.LastMessage
  let unreadCount: Int

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          MessageOriginText(message: message)
          Spacer(minLength: 4)
          MessageAgeText(date: message.date)
        }
        .font(.caption)
        Text(message.preview)
          .font(.footnote)
          .lineLimit(1)
          .truncationMode(.tail)
          .privacySensitive()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(message.accessibilityText)

      if unreadCount > 0 {
        UnreadBadge(count: unreadCount)
      }
    }
  }
}

/// Traffic (live, or quiet for how long), signal, nodes heard and position on one line of small
/// labelled readings. The signal goes once the activity is stale: the mesh has gone quiet.
private struct IslandReadingsLine: View {
  let state: MeshStatusAttributes.ContentState
  let isStale: Bool

  var body: some View {
    HStack(spacing: 10) {
      if !isStale, let rssi = state.lastRSSI {
        reading(icon: "cellularbars", text: state.lastSNR.map { "\(rssi) · \(ActivityStyle.snr($0))" } ?? "\(rssi)")
          .accessibilityLabel(signalAccessibility(rssi: rssi))
      }
      HStack(spacing: 3) {
        Image(systemName: "arrow.down")
          .foregroundStyle(ActivityStyle.teal)
        TrafficStatusText(lastPacketDate: state.lastPacketDate, isStale: isStale)
      }
      .accessibilityElement(children: .combine)
      if let nodes = state.nodesHeard {
        reading(icon: "point.3.connected.trianglepath.dotted", text: "\(nodes)")
          .accessibilityLabel(Text("\(nodes) nodes heard in the last hour"))
      }
      if let positionLine = state.positionLine {
        reading(icon: "location.fill", text: positionLine)
          .privacySensitive()
          .layoutPriority(-1)
          .accessibilityLabel(Text("Position \(positionLine)"))
      }
      Spacer(minLength: 0)
    }
    .font(.caption2)
  }

  private func reading(icon: String, text: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .foregroundStyle(ActivityStyle.teal)
      Text(verbatim: text)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .accessibilityElement(children: .ignore)
  }

  private func signalAccessibility(rssi: Int) -> Text {
    if let snr = state.lastSNR {
      Text("Last RSSI \(rssi) dBm, SNR \(ActivityStyle.snr(snr)) dB")
    } else {
      Text("Last RSSI \(rssi) dBm")
    }
  }
}

// MARK: - Previews

#if DEBUG
extension MeshStatusAttributes {
  fileprivate static let preview = MeshStatusAttributes(deviceName: "Ridge Relay", radioID: UUID())
}

extension MeshStatusAttributes.ContentState {
  fileprivate static let busy = MeshStatusAttributes.ContentState(
    isConnected: true,
    batteryPercent: 76,
    unreadCount: 3,
    disconnectedDate: nil,
    lastPacketDate: .now.addingTimeInterval(-20),
    batteryMillivolts: 3980,
    lastRSSI: -92,
    lastSNR: 7.5,
    noiseFloor: -118,
    nodesHeard: 12,
    positionText: "41.8823, -87.6232",
    altitudeText: "597 ft",
    lastMessage: MeshStatusAttributes.LastMessage(
      sender: "Alex",
      channelName: "Public",
      preview: "Trail's clear past the second ridge, meet at the trailhead at 7?",
      date: .now.addingTimeInterval(-300)
    )
  )

  fileprivate static let quiet = MeshStatusAttributes.ContentState(
    isConnected: true,
    batteryPercent: 18,
    unreadCount: 0,
    disconnectedDate: nil,
    lastPacketDate: .now.addingTimeInterval(-1500),
    batteryMillivolts: 3610,
    nodesHeard: 0
  )

  fileprivate static let direct = MeshStatusAttributes.ContentState(
    isConnected: true,
    batteryPercent: 100,
    unreadCount: 1,
    disconnectedDate: nil,
    lastPacketDate: .now.addingTimeInterval(-90),
    batteryMillivolts: 4180,
    lastRSSI: -71,
    lastSNR: 11.25,
    nodesHeard: 4,
    positionText: "51.5072, -0.1276",
    lastMessage: MeshStatusAttributes.LastMessage(
      sender: "Sam",
      channelName: nil,
      preview: "On my way",
      date: .now.addingTimeInterval(-40)
    )
  )

  fileprivate static let disconnected = MeshStatusAttributes.ContentState(
    isConnected: false,
    batteryPercent: nil,
    unreadCount: 0,
    disconnectedDate: .now,
    nodesHeard: 12,
    lastMessage: busy.lastMessage
  )
}

#Preview("Lock Screen", as: .content, using: MeshStatusAttributes.preview) {
  MeshStatusLiveActivity()
} contentStates: {
  MeshStatusAttributes.ContentState.busy
  MeshStatusAttributes.ContentState.direct
  MeshStatusAttributes.ContentState.quiet
  MeshStatusAttributes.ContentState.disconnected
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: MeshStatusAttributes.preview) {
  MeshStatusLiveActivity()
} contentStates: {
  MeshStatusAttributes.ContentState.busy
  MeshStatusAttributes.ContentState.quiet
  MeshStatusAttributes.ContentState.disconnected
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: MeshStatusAttributes.preview) {
  MeshStatusLiveActivity()
} contentStates: {
  MeshStatusAttributes.ContentState.busy
  MeshStatusAttributes.ContentState.quiet
  MeshStatusAttributes.ContentState.disconnected
}

#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: MeshStatusAttributes.preview) {
  MeshStatusLiveActivity()
} contentStates: {
  MeshStatusAttributes.ContentState.busy
  MeshStatusAttributes.ContentState.quiet
}
#endif
