import CairnServices
import MeshCore
import SwiftUI

// The on-demand readings on Device Info: one Home-style Since Boot card for the counters the radio
// keeps since it started, which the page puts in the same `NodeDashboardCardGrid` as its fixed
// facts, and the radio's own sensors as one compact strip near the top of the page (every channel's
// readings as mini-metrics, and a GPS fix as a chip that copies its coordinates).

// MARK: - Since Boot

@MainActor
extension DeviceReadingsModel {
  static let placeholder = "—"

  /// Uptime as the reading, then packets received and sent, their flood/direct split and the
  /// receive errors. "—" until the first read lands; afterwards only what the firmware reported,
  /// and no card at all when it reports none.
  var sinceBootCard: NodeDashboardCardItem? {
    let counters = lifetimeCounters
    guard !counters.isEmpty else { return nil }

    let value: String
    var note: String?
    var details: [String] = []
    let packets = counters.contains(.received) ? self.packets : nil

    if counters.contains(.uptime) {
      value = core.map { RadioStatsFormatter.duration(seconds: $0.uptimeSeconds) } ?? Self.placeholder
      if let packets {
        details.append("↓ \(packets.received.formatted()) · ↑ \(packets.sent.formatted())")
      }
    } else {
      // No uptime from this firmware: the packet totals take the reading's place.
      value = packets.map { "↓ \($0.received.formatted())" } ?? Self.placeholder
      note = packets.map { "↑ \($0.sent.formatted())" }
    }

    if let packets {
      details.append("\(L10n.Contacts.Contacts.Route.flood) ↓\(packets.floodRx.formatted()) ↑\(packets.floodTx.formatted())")
      details.append("\(L10n.Contacts.Contacts.Route.direct) ↓\(packets.directRx.formatted()) ↑\(packets.directTx.formatted())")
      let rate = packets.receiveErrors > 0
        ? RadioStatsFormatter.receiveErrorRate(errors: packets.receiveErrors, received: packets.received)
        : nil
      details.append(NodeRouteFormat.joined([
        "\(L10n.Settings.RadioStats.errors) \(packets.receiveErrors.formatted())",
        rate.map { $0.formatted(.percent.precision(.fractionLength(1))) },
      ]))
    }

    return NodeDashboardCardItem(
      id: "sinceBoot",
      title: L10n.Settings.DeviceInfo.SinceBoot.header,
      systemImage: "clock",
      tint: .purple,
      value: value,
      valueTint: value == Self.placeholder ? .secondary : .primary,
      note: note,
      details: details,
      destination: .none
    )
  }
}

// MARK: - Sensors

/// One of the radio's own sensor readings, as a mini-metric in the sensor strip: a value with its
/// glyph and label, or a GPS fix that copies its coordinates on a tap.
struct DeviceSensorChip: Identifiable {
  enum Kind {
    case reading
    case gps(coordinates: String, altitude: String)
  }

  /// "sensors.<channel>.<offset>" for a reading, "sensors.<channel>.gps.<offset>" for a GPS fix, so
  /// the "Copied" feedback and the `node.card.*` identifiers stay what the cards had.
  let id: String
  let label: String
  let value: String
  let systemImage: String
  let kind: Kind
}

/// One sensor channel's chips; `title` names the channel only when the radio reports several.
struct DeviceSensorChipGroup: Identifiable {
  let channel: UInt8
  let title: String?
  let chips: [DeviceSensorChip]

  var id: UInt8 { channel }
}

@MainActor
extension DeviceReadingsModel {
  /// The radio's own GPS fix from its sensors (the first channel that has one), for Device Info's
  /// header line; nil until a read brings one back. The sensor strip leaves it out.
  var sensorGPSFix: (latitude: Double, longitude: Double, altitude: Double)? {
    guard sensorsLoaded else { return nil }
    for group in displayedSensorGroups {
      for point in group.dataPoints {
        if case let .gps(latitude, longitude, altitude) = point.value { return (latitude, longitude, altitude) }
      }
    }
    return nil
  }

  /// The radio's own LPP telemetry, without the battery voltage, which the Battery page shows, as
  /// the sensor strip's chips: one group per channel, in channel order. None until the radio
  /// reports a reading. On Cairn firmware the IMU readings read as steps, tilt and motion.
  func sensorChipGroups(cairnFirmware: Bool = false) -> [DeviceSensorChipGroup] {
    Self.sensorChipGroups(sensors, cairnFirmware: cairnFirmware)
  }

  /// The same, for readings another page decoded itself (the Map tab's radio read).
  static func sensorChipGroups(_ sensors: [LPPDataPoint], cairnFirmware: Bool = false) -> [DeviceSensorChipGroup] {
    let groups = displayedSensorGroups(sensors)
    return groups.map { group in
      let chips = group.dataPoints.enumerated().map { offset, point in
        let label = telemetryLabel(for: point, at: offset, in: group.dataPoints)
        if case let .gps(latitude, longitude, altitude) = point.value {
          // Coordinates always use '.' so they read and paste the same in every locale (#386).
          let coordinates = String(format: "%.5f, %.5f", latitude, longitude)
          return DeviceSensorChip(
            id: "sensors.\(group.channel).gps.\(offset)",
            label: label,
            value: coordinates,
            systemImage: point.type.tileSymbol,
            // Metres or feet by the Units preference and the locale.
            kind: .gps(coordinates: coordinates, altitude: LocationReportFormat.altitude(altitude))
          )
        }
        if cairnFirmware, let cairn = CairnSensorReading(point) {
          return DeviceSensorChip(
            id: "sensors.\(group.channel).\(offset)",
            label: cairn.label,
            value: cairn.value,
            systemImage: cairn.systemImage,
            kind: .reading
          )
        }
        return DeviceSensorChip(
          id: "sensors.\(group.channel).\(offset)",
          label: label,
          value: point.formattedValue,
          systemImage: point.type.tileSymbol,
          kind: .reading
        )
      }
      return DeviceSensorChipGroup(
        channel: group.channel,
        title: groups.count > 1 ? L10n.RemoteNodes.RemoteNodes.Status.channel(Int(group.channel)) : nil,
        chips: chips
      )
    }
  }
}

extension DeviceSensorChipGroup {
  /// "Channel 2 Temperature" with several channels, else just the reading's label: how VoiceOver
  /// reads a chip in Device Info's sensor row.
  static func spokenLabel(_ label: String, channelTitle: String?) -> String {
    channelTitle.map { L10n.Settings.DeviceSensors.A11y.channelReading($0, label) } ?? label
  }
}

extension LPPSensorType {
  /// A glyph for the reading's chip (Device Info's and every node header's sensor row).
  var tileSymbol: String {
    switch self {
    case .digitalInput, .digitalOutput, .switchValue: "switch.2"
    case .analogInput, .analogOutput, .genericSensor: "dial.medium"
    case .illuminance: "sun.max"
    case .presence: "figure.stand"
    case .temperature: "thermometer.medium"
    case .humidity: "humidity"
    case .accelerometer: "move.3d"
    case .barometer: "barometer"
    case .voltage: "bolt"
    case .current: "bolt.horizontal"
    case .frequency: "waveform"
    case .percentage: "percent"
    case .altitude: "mountain.2"
    case .load: "scalemass"
    case .concentration: "aqi.medium"
    case .power: "powerplug"
    case .distance: "ruler"
    case .energy: "bolt.batteryblock"
    case .direction: "location.north.line"
    case .unixTime: "clock"
    case .gyrometer: "gyroscope"
    case .colour: "paintpalette"
    case .gps: "location"
    }
  }
}
