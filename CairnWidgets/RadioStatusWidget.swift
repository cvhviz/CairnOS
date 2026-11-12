import SwiftUI
import WidgetKit

/// The home-screen widget: the radio's link, battery and unread count, and the node heard
/// last, from the snapshot the app keeps in the App Group (`WidgetSnapshotStore`). The widget
/// has no radio access, so it only ever shows what the app last wrote and says how old that is;
/// the app reloads it on every change (paced by `WidgetSnapshotPublisher`). A tap opens the app.
struct RadioStatusWidget: Widget {
  static let kind = WidgetSnapshotStore.widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: RadioStatusProvider()) { entry in
      RadioStatusView(entry: entry)
        .containerBackground(for: .widget) {
          Color.clear
        }
        .widgetURL(URL(string: "cairn://status"))
    }
    .configurationDisplayName("Radio Status")
    .description("Your radio's link, battery and unread messages at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct RadioStatusEntry: TimelineEntry {
  let date: Date
  /// Nil when the app has never written one: shown as "No radio".
  let snapshot: WidgetSnapshot?
}

/// One entry per reload: the app asks for one whenever the snapshot changes, so the timeline
/// never needs a second. Ages ("5 min ago") count on by themselves.
struct RadioStatusProvider: TimelineProvider {
  func placeholder(in context: Context) -> RadioStatusEntry {
    RadioStatusEntry(date: .now, snapshot: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping (RadioStatusEntry) -> Void) {
    // The gallery shows the sample radio; a widget on the Home Screen shows the real one.
    completion(RadioStatusEntry(date: .now, snapshot: context.isPreview ? .placeholder : Self.current()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RadioStatusEntry>) -> Void) {
    completion(Timeline(entries: [RadioStatusEntry(date: .now, snapshot: Self.current())], policy: .never))
  }

  static func current() -> WidgetSnapshot? {
    WidgetSnapshotStore.defaults().flatMap(WidgetSnapshotStore.load(from:))
  }
}

// MARK: - Views

struct RadioStatusView: View {
  @Environment(\.widgetFamily) private var family
  let entry: RadioStatusEntry

  var body: some View {
    Group {
      if let snapshot = entry.snapshot, snapshot.radioName != nil {
        switch family {
        case .systemMedium:
          MediumRadioStatusView(snapshot: snapshot)
        default:
          SmallRadioStatusView(snapshot: snapshot)
        }
      } else {
        NoRadioView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
  }
}

/// The small family: the radio and its state on top, battery and unread in the middle, the node
/// heard last at the bottom.
private struct SmallRadioStatusView: View {
  let snapshot: WidgetSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RadioHeader(snapshot: snapshot, tileSize: 28)
      HStack(spacing: 8) {
        if snapshot.isConnected {
          BatteryGauge(percent: snapshot.batteryPercent, millivolts: nil, showsVoltage: false, showsBar: false)
        }
        Spacer(minLength: 0)
        if snapshot.unreadCount > 0 {
          UnreadBadge(count: snapshot.unreadCount)
        }
      }
      Spacer(minLength: 0)
      LastHeardCard(node: snapshot.lastHeard)
      UpdatedLine(date: snapshot.updatedAt)
    }
  }
}

/// The medium family: the radio, its state and battery on the left, the unread count and the
/// node heard last on the right.
private struct MediumRadioStatusView: View {
  let snapshot: WidgetSnapshot

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        RadioHeader(snapshot: snapshot, tileSize: 34)
        if snapshot.isConnected {
          BatteryGauge(percent: snapshot.batteryPercent, millivolts: nil, showsVoltage: false)
        }
        Spacer(minLength: 0)
        UpdatedLine(date: snapshot.updatedAt)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        UnreadCard(count: snapshot.unreadCount)
        LastHeardCard(node: snapshot.lastHeard)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// No snapshot yet, or the last radio was forgotten: say so and invite a tap.
private struct NoRadioView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ActivityIconTile(
          systemImage: "antenna.radiowaves.left.and.right.slash",
          color: .secondary,
          size: 28
        )
        Text("No radio")
          .font(.headline)
          .lineLimit(1)
      }
      Text("Open Cairn to connect")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The link tile, the radio's name and its state.
private struct RadioHeader: View {
  let snapshot: WidgetSnapshot
  let tileSize: CGFloat

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      ActivityIconTile(
        systemImage: snapshot.isConnected
          ? "antenna.radiowaves.left.and.right"
          : "antenna.radiowaves.left.and.right.slash",
        color: ActivityStyle.linkColor(isConnected: snapshot.isConnected),
        size: tileSize
      )
      VStack(alignment: .leading, spacing: 0) {
        Text(snapshot.radioName ?? "")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        stateText
          .font(.caption2)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var stateText: some View {
    switch snapshot.connectionState {
    case .connected:
      Text("Connected")
        .foregroundStyle(.secondary)
    case .connecting:
      Text("Connecting…")
        .foregroundStyle(.secondary)
    case .disconnected:
      Text("Disconnected")
        .foregroundStyle(ActivityStyle.warning)
    }
  }
}

/// The unread count as a card, for the medium family's column.
private struct UnreadCard: View {
  let count: Int

  var body: some View {
    HStack(spacing: 8) {
      ActivityIconTile(systemImage: "envelope.fill", color: count > 0 ? ActivityStyle.teal : .secondary, size: 22)
      Text("\(count) unread")
        .font(.caption)
        .monospacedDigit()
        .contentTransition(.numericText())
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(ActivityStyle.tileFill, in: .rect(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("\(count) unread messages"))
  }
}

/// The node heard last and how long ago, on the banner's card fill.
private struct LastHeardCard: View {
  let node: WidgetSnapshot.HeardNode?

  var body: some View {
    HStack(spacing: 8) {
      ActivityIconTile(systemImage: "dot.radiowaves.left.and.right", color: .indigo, size: 22)
      VStack(alignment: .leading, spacing: 0) {
        if let node {
          Text(node.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
          HStack(spacing: 4) {
            Text("Last heard")
            MessageAgeText(date: node.date)
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        } else {
          Text("Nothing heard yet")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(ActivityStyle.tileFill, in: .rect(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(node.map { Text("Last heard \($0.name)") } ?? Text("Nothing heard yet"))
  }
}

/// How old the app's picture is, counting on by itself.
private struct UpdatedLine: View {
  let date: Date

  var body: some View {
    HStack(spacing: 4) {
      Text("Updated")
      MessageAgeText(date: date)
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Samples

extension WidgetSnapshot {
  /// The gallery's and placeholder's sample radio.
  static let placeholder = WidgetSnapshot(
    radioName: "Ridge Relay",
    connectionState: .connected,
    batteryPercent: 76,
    unreadCount: 3,
    lastHeard: HeardNode(name: "Alex", date: .now.addingTimeInterval(-300)),
    updatedAt: .now.addingTimeInterval(-60)
  )
}

#if DEBUG
#Preview("Small", as: .systemSmall) {
  RadioStatusWidget()
} timeline: {
  RadioStatusEntry(date: .now, snapshot: .placeholder)
  RadioStatusEntry(
    date: .now,
    snapshot: WidgetSnapshot(
      radioName: "Ridge Relay", connectionState: .disconnected, batteryPercent: nil, unreadCount: 0,
      lastHeard: nil, updatedAt: .now.addingTimeInterval(-3600)
    )
  )
  RadioStatusEntry(date: .now, snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
  RadioStatusWidget()
} timeline: {
  RadioStatusEntry(date: .now, snapshot: .placeholder)
  RadioStatusEntry(date: .now, snapshot: nil)
}
#endif
