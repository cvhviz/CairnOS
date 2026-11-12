import ActivityKit
import SwiftUI
import WidgetKit

/// Cairn's card look for the Live Activity on the system's own background (the Lock Screen
/// material, light or dark): brand teal for accents, small coloured icon tiles and compact metric
/// tiles in fills that follow the appearance.
enum ActivityStyle {
  /// Brand teal (#14B5A6).
  static let teal = Color(red: 20 / 255, green: 181 / 255, blue: 166 / 255)
  static let warning = Color.orange
  static let critical = Color.red
  /// The metric tiles' and message card's fill.
  static let tileFill = Color.primary.opacity(0.08)

  /// The radio: Cairn's walkie-talkie, the app's Home tab symbol (`AppTab.home`). SF Symbols has
  /// no MeshCore radio, so it is an asset-catalog symbol, copied into the widget's own catalog.
  /// It has no slashed form: disconnected, it keeps its shape and takes the warning colour.
  static var radioImage: Image { Image("cairn.walkietalkie.fill") }

  static func linkColor(isConnected: Bool) -> Color {
    isConnected ? teal : warning
  }

  static func batteryColor(percent: Int) -> Color {
    switch percent {
    case ...10: critical
    case ...20: warning
    default: teal
    }
  }

  static func batteryIconName(for percent: Int) -> String {
    switch percent {
    case 88...100: "battery.100"
    case 63..<88: "battery.75"
    case 38..<63: "battery.50"
    case 13..<38: "battery.25"
    default: "battery.0"
    }
  }

  /// Millivolts as volts with two decimals, e.g. "4.12 V", in the reader's number format.
  static func voltage(millivolts: Int) -> String {
    Measurement(value: Double(millivolts) / 1000, unit: UnitElectricPotentialDifference.volts)
      .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
  }

  /// SNR with one decimal, e.g. "7.5".
  static func snr(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
}

/// A white symbol on a gradient rounded square, like the app's `IconTile`.
struct ActivityIconTile: View {
  let image: Image
  let color: Color
  var size: CGFloat = 28

  init(image: Image, color: Color, size: CGFloat = 28) {
    self.image = image
    self.color = color
    self.size = size
  }

  init(systemImage: String, color: Color, size: CGFloat = 28) {
    self.init(image: Image(systemName: systemImage), color: color, size: size)
  }

  var body: some View {
    image
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(color.gradient, in: .rect(cornerRadius: size * 0.25, style: .continuous))
      .accessibilityHidden(true)
  }
}

/// The battery as a small ring filled to its level with the number inside, in the battery's
/// colour: for the compact Dynamic Island's trailing side, about as wide as one icon.
struct BatteryRing: View {
  let percent: Int
  var size: CGFloat = 22

  var body: some View {
    let color = ActivityStyle.batteryColor(percent: percent)
    let fraction = Double(min(max(percent, 0), 100)) / 100
    ZStack {
      Circle()
        .stroke(color.opacity(0.3), lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Text(verbatim: "\(percent)")
        .font(.system(size: 9, weight: .bold).monospacedDigit())
        .foregroundStyle(color)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .padding(.horizontal, 3)
        .contentTransition(.numericText())
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
  }
}

/// A value over its caption on a tinted rounded rectangle, like Device Info's sensor strip.
struct MiniMetricTile: View {
  let value: String
  let caption: LocalizedStringKey
  var tint: Color = .primary

  var body: some View {
    VStack(spacing: 1) {
      Text(value)
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
      Text(caption)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
    .background(ActivityStyle.tileFill, in: .rect(cornerRadius: 8, style: .continuous))
  }
}

/// Battery percent with a small bar and the voltage beneath. Nothing until the first reading.
/// The Lock Screen drops the bar (the icon already shows the level) to save height.
struct BatteryGauge: View {
  let percent: Int?
  let millivolts: Int?
  var showsVoltage = true
  var showsBar = true

  var body: some View {
    if let percent {
      let color = ActivityStyle.batteryColor(percent: percent)
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 4) {
          Image(systemName: ActivityStyle.batteryIconName(for: percent))
            .foregroundStyle(color)
          Text(verbatim: "\(percent)%")
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .font(.subheadline.weight(.semibold))

        if showsBar {
          Capsule()
            .fill(.primary.opacity(0.15))
            .frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
              Capsule()
                .fill(color)
                .frame(width: 44 * CGFloat(min(max(percent, 0), 100)) / 100, height: 4)
            }
        }

        if showsVoltage, let millivolts {
          Text(ActivityStyle.voltage(millivolts: millivolts))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityText(percent: percent))
    }
  }

  private func accessibilityText(percent: Int) -> Text {
    if showsVoltage, let millivolts {
      Text("Battery \(percent) percent, \(ActivityStyle.voltage(millivolts: millivolts))")
    } else {
      Text("Battery \(percent) percent")
    }
  }
}

/// "Alex · Direct" / "Alex · #Public": who sent the last message and where.
struct MessageOriginText: View {
  let message: MeshStatusAttributes.LastMessage

  var body: some View {
    HStack(spacing: 4) {
      Text(message.sender)
        .fontWeight(.semibold)
        .lineLimit(1)
        .layoutPriority(1)
      Text(verbatim: "·")
        .foregroundStyle(.secondary)
      if let channelName = message.channelName {
        Text(channelName)
          .foregroundStyle(ActivityStyle.teal)
          .lineLimit(1)
      } else {
        Text("Direct")
          .foregroundStyle(ActivityStyle.teal)
          .lineLimit(1)
      }
    }
  }
}

/// How long ago the message arrived, kept current by the system ("5 min ago").
struct MessageAgeText: View {
  let date: Date

  var body: some View {
    Text(.currentDate, format: .reference(to: date, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

/// Whether the radio is hearing the mesh: "Live" while the activity is fresh (it is refreshed at
/// most every few minutes while packets keep coming), else "Quiet · 12 min" since the last packet
/// it showed, counting on by itself with no update from the app; "Listening" before any packet.
struct TrafficStatusText: View {
  let lastPacketDate: Date?
  let isStale: Bool

  var body: some View {
    Group {
      if let lastPacketDate, isStale {
        Text("Quiet · \(Text(.currentDate, format: .reference(to: lastPacketDate, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)))")
          .foregroundStyle(.secondary)
      } else if lastPacketDate != nil {
        Text("Live")
          .foregroundStyle(ActivityStyle.teal)
      } else {
        Text("Listening")
          .foregroundStyle(.secondary)
      }
    }
    .monospacedDigit()
    .lineLimit(1)
  }
}

extension MeshStatusAttributes.LastMessage {
  /// Spoken as one sentence: sender, place, text.
  var accessibilityText: Text {
    if let channelName {
      Text("Message from \(sender) in \(channelName): \(preview)")
    } else {
      Text("Direct message from \(sender): \(preview)")
    }
  }
}

extension MeshStatusAttributes.ContentState {
  /// "41.8823, -87.6232 · 182 m", or nil without a position.
  var positionLine: String? {
    guard let positionText else { return nil }
    guard let altitudeText else { return positionText }
    return "\(positionText) · \(altitudeText)"
  }
}
