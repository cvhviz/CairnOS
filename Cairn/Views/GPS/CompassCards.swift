import CoreLocation
import CairnServices
import SwiftUI

// MARK: - Building blocks

/// One card on the full compass: a titled card on the app's card surface, kept short (a title and
/// a few lines). The cards are sized by what they hold rather than set in an even grid.
struct CompassPanel<Content: View>: View {
  let title: String
  let systemImage: String
  var isCustomSymbol = false
  let tint: Color
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        (isCustomSymbol ? Image(systemImage) : Image(systemName: systemImage))
          .foregroundStyle(tint)
        Text(title.uppercased(with: .current))
          .foregroundStyle(.secondary)
      }
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      content()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .cardSurface(padding: 10)
  }
}

/// A reading's label over its value, for the node card's small columns.
struct CompassStat: View {
  let label: String
  let value: String
  var tint: Color = .primary

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .accessibilityElement(children: .combine)
  }
}

/// A label and its value on one line ("Magnetic 45°"), for the short cards.
struct CompassInlineStat: View {
  let label: String
  let value: String
  var tint: Color = .primary

  var body: some View {
    (Text(label + " ").foregroundStyle(.secondary) + Text(value).foregroundStyle(tint).fontWeight(.semibold))
      .font(.caption)
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

/// An icon tight against its title, for a line of small readings.
private struct CompactIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}

// MARK: - Radio

/// Your own radio as a thin header: its name and where it is from you (or that it is with you)
/// on one line, its battery, transmit power, frequency and what it shares on the next.
struct CompassRadioCard: View {
  let device: DeviceDTO
  let phone: CLLocation?
  let batteryPercent: Int?
  let txPower: Int?

  /// "0.4 mi · 120° SE", "Radio is with you", or nil when either position is unknown.
  private var whereText: String? {
    guard let phone, device.hasLocation else { return nil }
    let radio = CLLocation(latitude: device.latitude, longitude: device.longitude)
    // Within the fixes' own error the two are together; a distance and bearing would be noise.
    guard GPSFormat.positionsDiffer(phone, radio) else { return L10n.Map.Map.Gps.Relation.together }
    return "\(GPSFormat.lengthText(phone.distance(from: radio))) · \(GPSFormat.bearingText(GPSFormat.bearing(from: phone.coordinate, to: radio.coordinate)))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(AppTab.home.symbolName)
          .font(.headline)
          .foregroundStyle(HomeStatusCards.cairnTeal)
        Text(device.nodeName)
          .font(.headline)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let whereText {
          Text(whereText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(HomeStatusCards.cairnTeal)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
      }
      HStack(spacing: 10) {
        Label(BatteryLevel.formattedPercent(batteryPercent), systemImage: BatteryLevel.symbol(for: batteryPercent))
          .foregroundStyle(batteryPercent.map { BatteryLevel(percent: $0).tint } ?? .secondary)
        Label(txPower.map { L10n.Settings.DeviceInfo.txPowerFormat($0.formatted()) } ?? "—", systemImage: "bolt.fill")
        Label(L10n.Settings.Dashboard.frequency(HomeStatusLines.megahertz(device.frequency)), systemImage: "waveform")
        Text(device.locationSharingSummary)
          .foregroundStyle(.secondary)
      }
      .font(.caption.weight(.medium))
      .labelStyle(CompactIconLabelStyle())
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .combine)
    .cardSurface(padding: 10)
  }
}

// MARK: - Orientation

/// Which way you face and which way you move, in four lines: the heading, how far to trust it,
/// the magnetic reading and declination, and the course and speed.
struct CompassOrientationCard: View {
  /// The heading as the compass reads it (true or magnetic, as set).
  let heading: Double?
  /// The heading against true north, when known, for the declination.
  let trueHeading: Double?
  let magneticHeading: Double?
  let isTrueHeading: Bool
  let headingAccuracy: Double?
  let course: Double?
  let speed: Double?

  private var declination: Double? {
    guard isTrueHeading, let trueHeading, let magneticHeading else { return nil }
    return GPSFormat.normalizedDegrees(trueHeading - magneticHeading + 180) - 180
  }

  var body: some View {
    CompassPanel(title: L10n.Map.Map.Gps.heading, systemImage: "location.north.line.fill", tint: .orange) {
      VStack(alignment: .leading, spacing: 3) {
        Text(heading.map(GPSFormat.bearingText) ?? L10n.Map.Map.Gps.noHeading)
          .font(heading == nil ? .subheadline.weight(.semibold) : .title3.weight(.bold))
          .foregroundStyle(heading == nil ? .secondary : .primary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        CompassInlineStat(
          label: L10n.Map.Map.Gps.accuracy,
          value: headingAccuracy.map { "±\(GPSFormat.wholeDegrees($0))°" } ?? "—"
        )
        HStack(spacing: 8) {
          CompassInlineStat(
            label: L10n.Map.Map.Gps.Compass.magnetic,
            value: magneticHeading.map { "\(GPSFormat.wholeDegrees($0))°" } ?? "—"
          )
          CompassInlineStat(
            label: L10n.Map.Map.Gps.Compass.declination,
            value: declination.map { $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "°" } ?? "—"
          )
        }
        HStack(spacing: 8) {
          CompassInlineStat(label: L10n.Map.Map.Gps.course, value: course.map(GPSFormat.bearingText) ?? "—", tint: course == nil ? .secondary : .green)
          CompassInlineStat(label: L10n.Map.Map.Gps.speed, value: speed.map { GPSFormat.speedText($0) } ?? "—")
        }
      }
    }
  }
}

// MARK: - Position

/// Where you are, in four lines: the coordinates, how tight the fix is, and the altitude.
struct CompassPositionCard: View {
  let location: CLLocation?

  var body: some View {
    CompassPanel(title: L10n.Map.Map.Gps.Segment.position, systemImage: "mappin.and.ellipse", tint: .blue) {
      if let location {
        VStack(alignment: .leading, spacing: 3) {
          Group {
            Text(GPSFormat.latitudeText(location.coordinate.latitude))
            Text(GPSFormat.longitudeText(location.coordinate.longitude))
          }
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .textSelection(.enabled)
          CompassInlineStat(label: L10n.Map.Map.Gps.accuracy, value: "±\(GPSFormat.lengthText(location.horizontalAccuracy))")
          CompassInlineStat(
            label: L10n.RemoteNodes.RemoteNodes.Status.Sensor.altitude,
            value: location.verticalAccuracy >= 0
              ? "\(GPSFormat.lengthText(location.altitude)) ±\(GPSFormat.lengthText(location.verticalAccuracy))"
              : "—"
          )
        }
      } else {
        Text(L10n.Map.Map.Gps.Status.searching)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Sun

/// The sun in one slim line: its bearing and height, a small arc of its day with the sun where it
/// stands now, sunrise and sunset, and the daylight left.
struct CompassSunCard: View {
  let sun: SunPosition.Result
  let times: SolarCalculator.Result
  let now: Date
  /// Today's date over the sun (the Map tab's Position page, the user 2026-11-08); the time is
  /// left to the status bar.
  var showsDate = false
  /// False inside another card (the Position page's, with the movement under it).
  var drawsSurface = true

  private var dayFraction: Double? {
    guard case let .times(sunrise, sunset) = times, sunset > sunrise else { return nil }
    return now.timeIntervalSince(sunrise) / sunset.timeIntervalSince(sunrise)
  }

  private var elevationText: String {
    guard sun.isUp else { return L10n.Map.Map.Gps.Compass.belowHorizon }
    var text = "\(L10n.Map.Map.Gps.Compass.elevation) \(GPSFormat.wholeDegrees(sun.elevation))°"
    if case let .times(_, sunset) = times, sunset > now {
      text += " · " + L10n.Map.Map.Gps.Compass.daylightLeft(GPSFormat.shortDuration(sunset.timeIntervalSince(now)))
    }
    return text
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsDate {
        Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .padding(.horizontal, 2)
      }
      sunRow
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.Map.Map.Gps.Compass.sun)
    .modifier(OptionalCardSurface(isOn: drawsSurface, padding: 8))
  }

  private var sunRow: some View {
    HStack(spacing: 10) {
      Image(systemName: sun.isUp ? "sun.max.fill" : "sun.horizon.fill")
        .symbolRenderingMode(.multicolor)
      VStack(alignment: .leading, spacing: 0) {
        Text(GPSFormat.bearingText(sun.azimuth))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
        Text(elevationText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      SunArc(fraction: dayFraction, isUp: sun.isUp)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
      if case let .times(sunrise, sunset) = times {
        VStack(alignment: .trailing, spacing: 0) {
          Label(sunrise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill")
          Label(sunset.formatted(date: .omitted, time: .shortened), systemImage: "sunset.fill")
        }
        .labelStyle(CompactIconLabelStyle())
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
    }
  }
}

/// Half an ellipse over a horizon line, the day's path; the sun sits on it at `fraction` of the
/// way from sunrise (left) to sunset (right), and below the line, dimmed, at night.
private struct SunArc: View {
  let fraction: Double?
  let isUp: Bool

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height
      let horizon = height * 0.85
      let clamped = min(1, max(0, fraction ?? 0.5))
      let angle = Double.pi * (1 - clamped)
      let sunPoint = CGPoint(
        x: width / 2 + (width / 2 - 8) * cos(angle),
        y: horizon - (horizon - 8) * sin(angle) * (isUp ? 1 : -0.15)
      )
      ZStack {
        Path { path in
          path.addArc(
            center: CGPoint(x: width / 2, y: horizon),
            radius: width / 2 - 8,
            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
          )
        }
        .applying(CGAffineTransform(translationX: 0, y: horizon).scaledBy(x: 1, y: (horizon - 8) / (width / 2 - 8)).translatedBy(x: 0, y: -horizon))
        .stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))

        Path { path in
          path.move(to: CGPoint(x: 0, y: horizon))
          path.addLine(to: CGPoint(x: width, y: horizon))
        }
        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)

        Circle()
          .fill(isUp ? Color.yellow : Color.secondary)
          .frame(width: 16, height: 16)
          .shadow(color: .yellow.opacity(isUp ? 0.8 : 0), radius: 8)
          .position(sunPoint)
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Selected node

/// The node picked on the dial or in the list, at the compass: who it is, which way to turn for
/// it and how far, when it was last heard and how it is reached, with a switch to steer to it and
/// a way into its full page.
struct CompassNodeCard: View {
  let node: CompassNode
  let heading: Double?
  @Binding var isSteering: Bool
  /// Whether the phone faces the node, as the compass works it out while steering to it; nil
  /// compares against the tolerance here.
  var isOnTarget: Bool?
  /// Opens Line of Sight from you to the node; nil leaves the button out.
  var onCheckLineOfSight: (() -> Void)?
  let onDetails: () -> Void
  let onClose: () -> Void

  private var turnText: (text: String, tint: Color)? {
    guard let heading else { return nil }
    let delta = GPSFormat.normalizedDegrees(node.bearing - heading + 180) - 180
    let amount = "\(GPSFormat.wholeDegrees(abs(delta)))°"
    if isOnTarget ?? (abs(delta) <= CompassDial.onTargetTolerance) {
      return (L10n.Map.Map.Gps.Compass.onTarget, .green)
    }
    return (delta > 0 ? L10n.Map.Map.Gps.Compass.turnRight(amount) : L10n.Map.Map.Gps.Compass.turnLeft(amount), .primary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        ContactTypeAvatar(contact: node.contact, size: 46)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.contact.displayName)
            .font(.headline)
            .lineLimit(1)
          Text(node.kind)
            .font(.subheadline)
            .foregroundStyle(node.tint)
        }
        Spacer(minLength: 8)
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
            .font(.title2)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.Common.done)
      }

      HStack(alignment: .center, spacing: 14) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 40))
          .foregroundStyle(isSteering ? Color.green : node.tint)
          .rotationEffect(.degrees(node.bearing - (heading ?? 0)))
          .opacity(heading == nil ? 0.4 : 1)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(GPSFormat.lengthText(node.distance))
            .font(.title2.weight(.bold))
            .monospacedDigit()
          if let turnText {
            Text(turnText.text)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(turnText.tint)
              .contentTransition(.numericText())
          }
        }
        Spacer(minLength: 0)
      }

      HStack(alignment: .top, spacing: 16) {
        CompassStat(label: L10n.Map.Map.Gps.Compass.bearing, value: GPSFormat.bearingText(node.bearing))
        if let lastHeard = node.lastHeard {
          CompassStat(label: L10n.Contacts.Contacts.Detail.lastHeard, value: HomeFormat.age(Date().timeIntervalSince(lastHeard)))
        }
        CompassStat(label: L10n.Map.Map.Gps.Compass.route, value: node.route)
      }

      Divider()

      HStack {
        Toggle(isOn: $isSteering) {
          Label(L10n.Map.Map.Gps.Compass.steer, systemImage: "scope")
        }
        .toggleStyle(.switch)
        .fixedSize()
        Spacer(minLength: 12)
        Button(L10n.Contacts.Contacts.Detail.details, action: onDetails)
          .buttonStyle(.bordered)
      }

      if let onCheckLineOfSight {
        Button(L10n.Map.Map.Nav.checkLineOfSight, systemImage: "eye", action: onCheckLineOfSight)
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity)
      }
    }
    .cardSurface(padding: 14)
  }
}
