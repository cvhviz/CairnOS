import CairnServices
import MeshCore
import SwiftUI

/// One reading in a node header's strip ("Firmware v1.10.0"): its name small over its value and glyph,
/// and a quieter line under it when it has one ("In sync"). With an action it's a button, and a small
/// chevron after the name says so.
struct NodeHeaderFact: Identifiable {
  let id: String
  let label: String
  let value: String
  let systemImage: String
  var tint: Color = .secondary
  /// Grey for a value that is the last visit's, or not read yet.
  var isDim = false
  var caption: String?
  var action: (() -> Void)?
}

/// The lower half of a node header's band (the user, 2026-11-09: use the whole width, with dividers, and
/// keep it short): under a rule, what the page knows about the node as a strip of equal cells split by
/// hairlines, three to a row, each centred: how far it is, its altitude, whatever the page adds (a
/// logged-in repeater's firmware and clock), then its sensors and how old they are. The coordinates are
/// on the header's map, the key and groups beside the subtitle.
struct NodeHeaderFacts<Key: View>: View {
  /// Shown on the header's map; kept for the callers.
  let coordinates: String?
  var altitude: String?
  /// "2.3 km away", for another node; nil for this radio.
  var distance: String?
  /// More facts after the position (a logged-in repeater's firmware and clock).
  var facts: [NodeHeaderFact] = []
  var sensorGroups: [DeviceSensorChipGroup] = []
  /// How old the sensor readings are ("2h ago"), as the strip's last cell; nil for readings taken now.
  var sensorsAge: String?
  @ViewBuilder let key: () -> Key

  /// Read so the altitude and distance redraw in the new units when the setting changes.
  @AppStorage(AppStorageKey.measurementSystem.rawValue)
  private var measurementSystem: MeasurementSystemPreference = .system

  var body: some View {
    let all = positionFacts + facts + sensorFacts
    VStack(spacing: 0) {
      key()
      if !all.isEmpty {
        NodeHeaderStrip(facts: all)
          .id(measurementSystem)
      }
    }
    .frame(maxWidth: .infinity)
    .animation(.snappy(duration: 0.2), value: sensorGroups.isEmpty)
    .accessibilityElement(children: .contain)
  }

  /// The altitude, and the distance for a node with no map to carry it (with coordinates, the map shows
  /// both).
  private var positionFacts: [NodeHeaderFact] {
    [
      (coordinates == nil ? distance : nil).map {
        NodeHeaderFact(id: "distance", label: L10n.Contacts.Contacts.Detail.distance,
                       value: $0, systemImage: "ruler", tint: .orange)
      },
      altitude.map {
        NodeHeaderFact(id: "altitude", label: L10n.Map.Map.Nav.altitude, value: $0,
                       systemImage: "mountain.2.fill", tint: .green)
      },
    ].compactMap(\.self)
  }

  /// The sensors, one cell each (the channel named when there are several), then how old they are.
  private var sensorFacts: [NodeHeaderFact] {
    var cells = sensorGroups.flatMap { group in
      group.chips.map { chip in
        NodeHeaderFact(
          id: chip.id,
          label: group.title.map { NodeRouteFormat.joined([chip.label, $0]) } ?? chip.label,
          value: chip.value,
          systemImage: chip.systemImage,
          tint: SensorReadingGrid.tint(for: chip.systemImage)
        )
      }
    }
    if !cells.isEmpty, let sensorsAge {
      // "Sensors · 8 min ago": the sensors are read on their own, so their age isn't the status's
      // "Updated now" (the user, 2026-11-09: two Updated read as a contradiction)
      cells.append(NodeHeaderFact(id: "sensors.age", label: L10n.RemoteNodes.RemoteNodes.History.sensorsSection,
                                  value: sensorsAge, systemImage: "sensor.fill", tint: .secondary, isDim: true))
    }
    return cells
  }
}

/// A header's readings as rows of equal cells (three to a row, two at accessibility sizes), hairlines
/// between the cells and above each row, each cell's name, value and caption centred in it.
struct NodeHeaderStrip: View {
  let facts: [NodeHeaderFact]
  /// The hairline above the first row; off where the strip starts a card.
  var topDivider = true

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var perRow: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 3 }

  /// As few rows as hold the cells `perRow` to a row, the cells spread evenly over them (the longer rows
  /// first), so none is left alone on a row: seven go 3, 2, 2 rather than 3, 3, 1.
  private var rows: [[NodeHeaderFact]] {
    guard !facts.isEmpty else { return [] }
    let count = (facts.count + perRow - 1) / perRow
    let base = facts.count / count, extra = facts.count % count
    var rows: [[NodeHeaderFact]] = []
    var start = 0
    for row in 0..<count {
      let size = base + (row < extra ? 1 : 0)
      rows.append(Array(facts[start..<start + size]))
      start += size
    }
    return rows
  }

  var body: some View {
    let rows = rows
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        if index > 0 || topDivider {
          Divider()
        }
        HStack(spacing: 0) {
          ForEach(Array(row.enumerated()), id: \.element.id) { index, fact in
            if index > 0 {
              Divider()
            }
            if let action = fact.action {
              Button(action: action) { cell(fact, leading: isLone) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            } else {
              cell(fact, leading: isLone)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// A single reading (a radio with only a temperature) sits flush left rather than alone in the middle
  /// of the card (the user, 2026-11-09).
  private var isLone: Bool { facts.count == 1 }

  private func cell(_ fact: NodeHeaderFact, leading: Bool) -> some View {
    VStack(alignment: leading ? .leading : .center, spacing: 2) {
      HStack(spacing: 3) {
        Text(fact.label)
        if fact.action != nil {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Label {
        Text(fact.value)
          .monospacedDigit()
          .truncationMode(.middle)
      } icon: {
        Image(systemName: fact.systemImage)
          .foregroundStyle(fact.tint)
      }
      .labelStyle(GPSLineLabelStyle())
      .font(.footnote.weight(.semibold))
      .foregroundStyle(fact.isDim ? Color.secondary : HomeCardDetail.ink)
      .minimumScaleFactor(0.75)
      if let caption = fact.caption {
        Text(caption)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .padding(.vertical, 6)
    .padding(.horizontal, leading ? 0 : 4)
    .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(fact.label)
    .accessibilityValue(NodeRouteFormat.joined([fact.value, fact.caption]))
    .accessibilityIdentifier("node.header.\(fact.id)")
  }
}

/// A dot and a few words on a capsule of their colour, against a node header's trailing edge: when a
/// node was last heard, or how fresh a logged-in node's readings are.
struct NodeStatusCapsule: View {
  let text: String
  let tint: Color

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
      Text(text)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.12), in: .capsule)
  }
}

/// When a node was last heard, at the end of the header's subtitle line as Device Info has its link
/// state: a dot and the age on a tinted capsule (green within the hour, orange within the day, grey
/// after). The route is in the subtitle.
struct NodeHeardStatus: View {
  let lastHeard: Date?
  /// For VoiceOver; the page shows the route in its subtitle ("Repeater · Direct").
  let route: String?
  var now: Date = .now

  var body: some View {
    let age = lastHeard.map { now.timeIntervalSince($0) }
    let tint: Color = switch age {
    case let age? where age < 3600: AppColors.Radio.readyText
    case let age? where age < 86400: .orange
    default: .secondary
    }
    NodeStatusCapsule(
      text: lastHeard.map { RelativeTimestampText.format(date: $0, relativeTo: now) } ?? NodeStatusViewModel.emDash,
      tint: tint
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Contacts.Contacts.Detail.lastHeard)
    .accessibilityValue(NodeRouteFormat.joined([
      lastHeard.map { RelativeTimestampText.format(date: $0, relativeTo: now) },
      route,
    ]))
  }
}

extension DeviceSensorChipGroup {
  /// A node's stored telemetry (the last readings it shared, kept with its status snapshots) as the
  /// header's sensor groups, one per channel. GPS is left out (the header's position says where);
  /// a second temperature on one channel is the board's own, as the telemetry charts name it.
  static func groups(from entries: [TelemetrySnapshotEntry]) -> [DeviceSensorChipGroup] {
    let channels = Set(entries.map(\.channel)).sorted()
    return channels.compactMap { channel in
      var temperatures = 0
      let chips = entries.enumerated().compactMap { offset, entry -> DeviceSensorChip? in
        guard entry.channel == channel else { return nil }
        let type = LPPSensorType(name: entry.type)
        if type == .gps { return nil }
        var label = type?.localizedName ?? entry.type
        if type == .temperature {
          temperatures += 1
          if temperatures > 1 { label = L10n.RemoteNodes.RemoteNodes.Status.Sensor.mcuTemperature }
        }
        return DeviceSensorChip(
          id: "sensors.\(channel).\(offset)",
          label: label,
          value: TelemetrySummaryFormatter.format(entry.value, type: type),
          systemImage: type?.tileSymbol ?? "dial.medium",
          kind: .reading
        )
      }
      guard !chips.isEmpty else { return nil }
      return DeviceSensorChipGroup(
        channel: UInt8(clamping: channel),
        title: channels.count > 1 ? L10n.RemoteNodes.RemoteNodes.Status.channel(channel) : nil,
        chips: chips
      )
    }
  }
}
