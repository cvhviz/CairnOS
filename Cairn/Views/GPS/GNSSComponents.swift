import CoreLocation
import SwiftUI
import UIKit

// The GPS page's parts: the device cards' header and status badge, the big coordinate readout and
// the phone's accuracy ring (inside a device card, so they draw no card of their own).

/// A device card's top: the device's tile and uppercase name with an optional detail (the radio's
/// name), and the state badge under them, compact enough for two cards side by side on a phone.
struct GNSSCardHeader: View {
  let title: String
  let systemImage: String
  let color: Color
  var detail: String?
  /// How old the device's reading is ("3m ago"), beside the status badge on the right, so the
  /// name has the top row's width to itself (the user, 2026-11-08).
  var updated: String?
  let status: GNSSStatus
  /// A full-width row (the GPS page's Radio and Phone, one over the other; the user, 2026-11-09): the
  /// badge and the age on the right of the name, so the name keeps the rest of the line.
  var trailingStatus = false

  var body: some View {
    if trailingStatus {
      HStack(alignment: .center, spacing: 8) {
        name
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 3) {
          GNSSStatusBadge(status: status)
          if let updated {
            Label(updated, systemImage: "clock")
              .labelStyle(GPSLineLabelStyle())
              .font(.caption2)
              .foregroundStyle(Color.secondary)
              .lineLimit(1)
              .accessibilityLabel(L10n.Map.Map.Gps.Reading.updated)
              .accessibilityValue(updated)
          }
        }
        .fixedSize()
      }
    } else {
      stacked
    }
  }

  private var name: some View {
    HStack(spacing: 8) {
      IconTile(systemImage: systemImage, color: color)
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color.secondary)
          .textCase(.uppercase)
          .lineLimit(1)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 8) {
      name
      HStack(spacing: 6) {
        GNSSStatusBadge(status: status)
          .layoutPriority(1)
        if let updated {
          Spacer(minLength: 4)
          Label(updated, systemImage: "clock")
            .labelStyle(GPSLineLabelStyle())
            .font(.caption2)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(L10n.Map.Map.Gps.Reading.updated)
            .accessibilityValue(updated)
        }
      }
    }
  }
}

/// A device card's top, compact (the user, 2026-11-09: the GPS page's cards were too tall to leave the
/// compass and map on screen): the device's tile, its name with the status badge at the line's end, and
/// under the name its coordinates on one small line with where they come from and how old they are. The
/// lines open the device's GPS details; a long press copies the coordinates.
struct GNSSCompactHeader: View {
  /// "Radio", "Phone": for VoiceOver; the tile's glyph and colour say it on screen.
  let kind: String
  let systemImage: String
  let color: Color
  let name: String
  let status: GNSSStatus
  let coordinate: CLLocationCoordinate2D?
  /// After the coordinates: "Saved position", "3m ago".
  var facts: [String] = []
  var onOpenDetails: (() -> Void)?

  @State private var copiedAt: Date?

  private var coordinateText: String {
    coordinate.map { "\(GPSFormat.latitudeText($0.latitude))  \(GPSFormat.longitudeText($0.longitude))" } ?? "—"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      IconTile(systemImage: systemImage, color: color)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .center, spacing: 8) {
          Text(name)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel(kind)
            .accessibilityValue(name)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 4)
          GNSSStatusBadge(status: status, compact: true)
            .fixedSize()
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) { coordinates; factsText }
            VStack(alignment: .leading, spacing: 1) { coordinates; factsText }
          }
          Spacer(minLength: 0)
          if onOpenDetails != nil {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Color(.tertiaryLabel))
          }
        }
        .contentShape(.rect)
        .onTapGesture { onOpenDetails?() }
        .contextMenu {
          if let coordinate {
            Button(L10n.RemoteNodes.RemoteNodes.Status.copyCoordinates, systemImage: "doc.on.doc") {
              UIPasteboard.general.string = GPSFormat.coordinatePairText(coordinate)
              copiedAt = .now
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Map.Map.Gps.coordinates)
        .accessibilityValue(([coordinate == nil ? "—" : coordinateText] + facts).joined(separator: ", "))
        .accessibilityHint(onOpenDetails == nil ? "" : L10n.Map.Map.Gps.Details.hint)
        .accessibilityAddTraits(onOpenDetails == nil ? [] : .isButton)
      }
    }
    .sensoryFeedback(.success, trigger: copiedAt) { _, new in new != nil }
  }

  private var coordinates: some View {
    Text(coordinateText)
      .font(.subheadline.weight(.semibold).monospacedDigit())
      .foregroundStyle(coordinate == nil ? Color.secondary : Color.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .contentTransition(.numericText())
  }

  @ViewBuilder
  private var factsText: some View {
    if !facts.isEmpty {
      Text(facts.joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .lineLimit(1)
    }
  }
}

/// The state as a tinted capsule. The words carry the state; the tint only echoes it.
struct GNSSStatusBadge: View {
  let status: GNSSStatus
  /// Smaller, for the compact header's name line.
  var compact = false

  var body: some View {
    Label(status.text, systemImage: status.systemImage)
      .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
      .foregroundStyle(status.tint)
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .padding(.horizontal, compact ? 8 : 10)
      .padding(.vertical, compact ? 3 : 5)
      .background(status.tint.opacity(0.15), in: Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L10n.Map.Map.Detail.status)
      .accessibilityValue(status.text)
  }
}

/// The coordinate pair as the loud part of a device card: two compact lines of fixed-width digits with
/// the hemisphere letters, and a caption under them. A tap opens the device's GPS details where a card
/// offers them, or copies the signed pair (with a brief "Copied!"), and a long press offers Copy too.
struct GNSSCoordinateReadout: View {
  let coordinate: CLLocationCoordinate2D?
  var caption: String?
  /// Readings that belong with the position, one small line each under the pair: the altitude,
  /// and on the radio's card its distance from the phone.
  var lines: [GNSSReading] = []
  /// Room kept for this many of those lines, so one arriving or leaving doesn't resize the card.
  var reservedLines = 0
  /// What a tap does instead of copying.
  var onOpenDetails: (() -> Void)?
  /// The pair on one line where it fits (a full-width row), with a chevron when a tap opens details.
  var oneLine = false

  @State private var copiedAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if oneLine {
        HStack(spacing: 8) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { latitude; longitude }
            VStack(alignment: .leading, spacing: 2) { latitude; longitude }
          }
          .font(.body.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(coordinate == nil ? Color.secondary : Color.primary)
          .contentTransition(.numericText())
          Spacer(minLength: 0)
          if onOpenDetails != nil {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color(.tertiaryLabel))
          }
        }
      } else {
        Group {
          latitude
          longitude
        }
        .font(.body.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(coordinate == nil ? Color.secondary : Color.primary)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText())
      }

      ForEach(lines) { reading in
        HStack(spacing: 4) {
          Label(reading.value, systemImage: reading.systemImage)
            .labelStyle(GPSLineLabelStyle())
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
          if let caption = reading.caption, !caption.isEmpty {
            Text(caption)
              .font(.caption)
              .foregroundStyle(Color.secondary)
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.top, 2)
      }
      ForEach(lines.count..<max(reservedLines, lines.count), id: \.self) { _ in
        Text(verbatim: " ")
          .font(.subheadline.weight(.semibold))
          .padding(.top, 2)
          .accessibilityHidden(true)
      }

      if let line = copiedAt == nil ? caption : L10n.Contacts.Contacts.Qr.copied {
        Text(line)
          .font(.caption)
          .foregroundStyle(copiedAt == nil ? Color.secondary : Color.green)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .onTapGesture { if let onOpenDetails { onOpenDetails() } else { copy() } }
    .contextMenu {
      if coordinate != nil {
        Button(L10n.RemoteNodes.RemoteNodes.Status.copyCoordinates, systemImage: "doc.on.doc", action: copy)
      }
    }
    .sensoryFeedback(.success, trigger: copiedAt) { _, new in new != nil }
    .task(id: copiedAt) {
      guard copiedAt != nil else { return }
      try? await Task.sleep(for: .seconds(1.5))
      copiedAt = nil
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Map.Map.Gps.coordinates)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(onOpenDetails != nil ? L10n.Map.Map.Gps.Details.hint : coordinate == nil ? "" : L10n.Map.Map.Gps.copyHint)
    .accessibilityAddTraits(coordinate == nil && onOpenDetails == nil ? [] : .isButton)
  }

  private var latitude: some View {
    Text(coordinate.map { GPSFormat.latitudeText($0.latitude) } ?? "—").lineLimit(1)
  }

  private var longitude: some View {
    Text(coordinate.map { GPSFormat.longitudeText($0.longitude) } ?? "—").lineLimit(1)
  }

  private var accessibilityValue: String {
    let extra = lines.map { "\($0.title) \($0.value)" }
    guard let coordinate else { return ([caption].compactMap(\.self) + extra).joined(separator: ", ") }
    return ([GPSFormat.latitudeText(coordinate.latitude), GPSFormat.longitudeText(coordinate.longitude)] + extra
      + [caption].compactMap(\.self))
      .joined(separator: ", ")
  }

  private func copy() {
    guard let coordinate else { return }
    UIPasteboard.general.string = GPSFormat.coordinatePairText(coordinate)
    copiedAt = .now
  }
}

/// One reading on the dashboard, as data, so a side shows only the readings it really has.
struct GNSSReading: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let value: String
  var caption: String?
}

/// The phone's speed, course and altitude as one line of readings (`SensorReadingGrid`). Each is always
/// in its place, saying "—" with nothing to show, so a reading coming or going never moves the page;
/// the speed's glyph goes green, orange, red with it. One VoiceOver element per reading.
struct GPSMotionTile: View {
  let live: GPSLiveLocation
  /// The fix to read: the live one, or the last the app took until it lands.
  let location: CLLocation?
  let now: Date
  /// False inside another card (the Position page's sun card), which draws the surface.
  var drawsSurface = true

  private var speed: CLLocationSpeed? { live.steadySpeed(now: now) }
  private var course: CLLocationDirection? { GNSSReadings.course(of: location) }
  /// Negative vertical accuracy means the fix has no altitude.
  private var altitude: CLLocation? { location.flatMap { $0.verticalAccuracy >= 0 ? $0 : nil } }

  private var speedTint: Color {
    switch speed ?? 0 {
    case ..<14: .green
    case ..<25: .orange
    default: .red
    }
  }

  /// One line, as every page's readings are (`SensorReadingGrid`: the name over the value and its
  /// glyph, the first flush left and the last flush right): the speed, the course and the phone's
  /// altitude, each with its accuracy where the fix gives one. (2026-11-09: was three columns of four
  /// rows with a speed bar, too tall a section.)
  /// The three readings as a strip of equal cells with hairlines between (the user, 2026-11-09: as the
  /// device cards under it have them); `topDivider` when it follows the sun on its card.
  var topDivider = false

  var body: some View {
    NodeHeaderStrip(facts: items.map { NodeHeaderFact($0) }, topDivider: topDivider)
      .modifier(OptionalCardSurface(isOn: drawsSurface, padding: 12))
      .fixedSize(horizontal: false, vertical: true)
  }

  private var items: [SensorReadingItem] {
    [
      SensorReadingItem(
        id: "gps.speed", label: L10n.Map.Map.Gps.speed,
        value: speed.map { GPSFormat.speedText($0) } ?? "—",
        systemImage: "speedometer", tint: speed == nil ? .secondary : speedTint
      ),
      SensorReadingItem(
        id: "gps.course", label: L10n.Map.Map.Gps.course,
        value: course.map(GPSFormat.bearingText) ?? "—",
        systemImage: "location.north.fill", tint: course == nil ? .secondary : .green
      ),
      SensorReadingItem(
        id: "gps.altitude", label: L10n.Map.Map.Gps.Reading.phoneAltitude,
        value: altitude.map { "\(GPSFormat.lengthText($0.altitude)) \(GPSFormat.accuracyText($0.verticalAccuracy))" } ?? "—",
        systemImage: "mountain.2", tint: altitude == nil ? .secondary : .brown
      ),
    ]
  }
}

/// The phone's horizontal accuracy as a small ring, fuller and greener the tighter the fix, with
/// "±5 m" and its grade beside it: compact enough for the phone's half-width card. One VoiceOver
/// element.
struct GNSSAccuracyRing: View {
  /// Metres, nil without a fix.
  let accuracy: CLLocationAccuracy?
  /// The app has approximate location only.
  var isApproximate = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 26

  private var grade: GNSSAccuracyGrade? { accuracy.map(GNSSAccuracyGrade.init(meters:)) }
  private var fraction: Double { accuracy.map(GNSSAccuracyGrade.ringFraction(meters:)) ?? 0 }
  private var tint: Color { grade?.tint ?? .secondary }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        Circle()
          .stroke(Color.primary.opacity(0.1), lineWidth: 4)
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
      }
      .frame(width: min(diameter, 44), height: min(diameter, 44))
      VStack(alignment: .leading, spacing: 0) {
        Text(accuracy.map(GPSFormat.accuracyText) ?? "—")
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
        Text(caption)
          .font(.caption2)
          .foregroundStyle(tint == .secondary ? Color.secondary : tint)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Map.Map.Gps.accuracy)
    .accessibilityValue(accessibilityValue)
  }

  private var caption: String {
    if isApproximate { return L10n.Map.Map.Gps.Accuracy.approximate }
    return grade?.text ?? L10n.Map.Map.Gps.accuracy
  }

  private var accessibilityValue: String {
    guard let accuracy else { return "—" }
    return [GPSFormat.accuracyText(accuracy), caption].joined(separator: ", ")
  }
}

/// A section's label inside a GPS card ("SENSORS"), small and quiet like a Home card's title, so a card
/// holding two kinds of reading reads as two groups.
struct GNSSSectionLabel: View {
  let title: String
  let systemImage: String

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .textCase(.uppercase)
      .foregroundStyle(Color.secondary)
      .labelStyle(.titleAndIcon)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A short note under a control, in the card's quiet voice.
struct GNSSNote: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(Color.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// `cardSurface(padding:)` when on; nothing when the view sits inside a card that draws its own.
struct OptionalCardSurface: ViewModifier {
  let isOn: Bool
  var padding: CGFloat = 12

  func body(content: Content) -> some View {
    if isOn {
      content.cardSurface(padding: padding)
    } else {
      content
    }
  }
}

extension NodeHeaderFact {
  /// A reading in a node header's strip look (`NodeHeaderStrip`): the Map tab's Radio and Phone cards
  /// lay theirs out as the node pages' headers do (the user, 2026-11-09).
  @MainActor
  init(_ item: SensorReadingItem, caption: String? = nil) {
    self.init(
      id: item.id, label: item.label, value: item.value, systemImage: item.systemImage,
      tint: item.tint ?? SensorReadingGrid.tint(for: item.systemImage),
      isDim: item.value == "—", caption: caption
    )
  }
}
