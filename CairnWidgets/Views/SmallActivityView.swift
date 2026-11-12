import ActivityKit
import SwiftUI
import WidgetKit

/// The `.small` activity family: the CarPlay Dashboard and the Apple Watch Smart Stack, on the
/// system's own background in the banner's card style. Built for a glance from the driver's seat:
/// the radio's link tile, name and state with its battery on top, then a card saying who wrote
/// last, where and how long ago, with the unread count. It never shows what a message says:
/// the car's screen must not, and the Lock Screen banner keeps its privacy-marked preview.
struct SmallActivityView: View {
  let context: ActivityViewContext<MeshStatusAttributes>

  private var state: MeshStatusAttributes.ContentState { context.state }

  private var showsCard: Bool { state.isConnected || state.lastMessage != nil }

  var body: some View {
    // A short slot (a 41 mm Watch's Smart Stack, say) drops the header's state line first: the
    // link tile's colour already says it.
    ViewThatFits(in: .vertical) {
      layout(showsState: true)
      if showsCard {
        layout(showsState: false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .dynamicTypeSize(...DynamicTypeSize.large)
  }

  private func layout(showsState: Bool) -> some View {
    VStack(alignment: .leading, spacing: showsState ? 6 : 4) {
      header(showsState: showsState)

      if showsCard {
        SmallMessageCard(
          message: state.lastMessage,
          unreadCount: state.isConnected ? state.unreadCount : 0
        )
      }
    }
  }

  private func header(showsState: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      ActivityIconTile(
        image: ActivityStyle.radioImage,
        color: ActivityStyle.linkColor(isConnected: state.isConnected),
        size: 24
      )

      VStack(alignment: .leading, spacing: 0) {
        Text(context.attributes.deviceName)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        if showsState {
          Text(state.isConnected ? "Connected" : "Disconnected")
            .font(.caption2)
            .foregroundStyle(state.isConnected ? .secondary : ActivityStyle.warning)
            .lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityValue(showsState ? Text(verbatim: "") : Text(state.isConnected ? "Connected" : "Disconnected"))

      Spacer(minLength: 4)

      if state.isConnected {
        BatteryGauge(percent: state.batteryPercent, millivolts: state.batteryMillivolts, showsVoltage: false, showsBar: false)
      }
    }
  }
}

/// Who wrote last ("Alex · #Public"), how long ago, and the unread count, on the banner's card
/// fill. No message text.
private struct SmallMessageCard: View {
  let message: MeshStatusAttributes.LastMessage?
  let unreadCount: Int

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      ActivityIconTile(
        systemImage: message?.channelName == nil ? "person.fill" : "number",
        color: message?.channelName == nil ? .indigo : ActivityStyle.teal,
        size: 20
      )

      if let message {
        VStack(alignment: .leading, spacing: 0) {
          MessageOriginText(message: message)
            .font(.caption)
            .lineLimit(1)
          MessageAgeText(date: message.date)
            .font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Last message from \(message.sender)"))
      } else {
        Text("No messages yet")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 2)

      if unreadCount > 0 {
        UnreadBadge(count: unreadCount)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(ActivityStyle.tileFill, in: .rect(cornerRadius: 8, style: .continuous))
  }
}
