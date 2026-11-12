import SwiftUI

/// Cairn's compass rose as a card, sized by the page: a fixed rose with N in amber, the needle in the accent color
/// pointing where the device faces, and "47° NE" under it. While moving, a small marker on the
/// ring shows the course over ground, with "Course 120° SE" under the heading. Without a compass
/// reading (no magnetometer, or not calibrated yet) the needle is gone, the rose dims, and the
/// reading line says "No heading" — once, in the slot the heading would take, so the rose keeps
/// its size and the card keeps its height when the compass comes alive.
struct GPSCompassCard: View {
  /// Degrees from north, nil when there is no heading.
  let heading: Double?
  /// Direction of travel in degrees from north, nil when standing still or unknown.
  var course: Double?
  /// The full-width card (the GPS page; the user, 2026-11-09): the rose on the left, the heading large
  /// beside it and `details` under that, one to a line.
  var wide = false
  /// Which way the radio is from the phone, in degrees from north: an orange mark on the ring.
  var radioBearing: Double?
  /// The wide card's lines beside the rose (the course, the radio's bearing, the sun's).
  var details: [SensorReadingItem] = []
  /// The square card's strip under the rose (the course, which way and how far the radio is; the user,
  /// 2026-11-09: the card looked bare).
  var strip: [NodeHeaderFact] = []
  /// Which north the heading reads ("True N"), at the square card's title row's end.
  var northTag: String?

  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The needle's angle without wrapping, so 359° → 1° turns 2° clockwise rather than 358° back.
  @State private var needleAngle: Double = 0

  /// The rose fills whatever the card is given (the page sets the card's size so it matches the
  /// map beside it), down to this, which still leaves the letters readable.
  private static let minimumDiameter: CGFloat = 70

  var body: some View {
    Group {
      if wide {
        wideBody
      } else {
        squareBody
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.Map.Map.Gps.heading)
    .accessibilityValue(accessibilityValue)
    .onChange(of: heading, initial: true) { _, newHeading in
      guard let newHeading else { return }
      // Shortest turn from where the needle is now.
      let delta = GPSFormat.normalizedDegrees(newHeading - needleAngle + 180) - 180
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
        needleAngle += delta
      }
    }
  }

  private var title: some View {
    HStack(spacing: 5) {
      Image(systemName: "location.north.line")
      Text(L10n.Map.Map.Gps.heading)
        .lineLimit(1)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(Color.secondary)
  }

  /// The rose's size on the wide card: large enough to read the needle, small enough to leave the
  /// readings beside it their room.
  @ScaledMetric(relativeTo: .body) private var wideDiameter: CGFloat = 132

  private var wideBody: some View {
    VStack(alignment: .leading, spacing: 8) {
      title
      HStack(alignment: .center, spacing: 16) {
        rose(diameter: min(wideDiameter, 180))
          .frame(width: min(wideDiameter, 180), height: min(wideDiameter, 180))
        VStack(alignment: .leading, spacing: 10) {
          Text(Self.readingText(heading: heading))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(heading == nil ? Color.secondary : Color.primary)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          ForEach(details) { item in
            VStack(alignment: .leading, spacing: 1) {
              Text(item.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
              Label {
                Text(item.value)
                  .monospacedDigit()
              } icon: {
                Image(systemName: item.systemImage)
                  .foregroundStyle(item.tint ?? Color.secondary)
              }
              .font(.footnote.weight(.medium))
              .foregroundStyle(HomeCardDetail.ink)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
  }

  /// The square card, compact (the user, 2026-11-09: the compass and map row was too tall for the page
  /// to fit): the title with which north it reads and the heading at its end, the rose filling the
  /// middle, the course and the radio's bearing under it.
  private var squareBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: "location.north.line")
        if let northTag {
          Text(northTag)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.teal)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.teal.opacity(0.12), in: .capsule)
        } else {
          Text(L10n.Map.Map.Gps.heading)
        }
        Spacer(minLength: 4)
        Text(Self.readingText(heading: heading))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(heading == nil ? Color.secondary : Color.primary)
          .contentTransition(.numericText())
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)

      GeometryReader { geometry in
        let diameter = max(min(geometry.size.width, geometry.size.height), Self.minimumDiameter)
        rose(diameter: diameter)
          .frame(width: diameter, height: diameter)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(minHeight: Self.minimumDiameter)

      if !strip.isEmpty {
        NodeHeaderStrip(facts: strip)
      } else if let course {
        Text(L10n.Map.Map.Gps.Compass.course(GPSFormat.bearingText(course)))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(Color.secondary)
          .frame(maxWidth: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .cardSurface(padding: 10)
  }

  /// The line under the rose: "47° NE", or "No heading" when there is no compass reading. The
  /// rose itself stays wordless so the state shows once.
  static func readingText(heading: Double?) -> String {
    heading.map(GPSFormat.bearingText) ?? L10n.Map.Map.Gps.noHeading
  }

  private var accessibilityValue: String {
    let heading = heading.map(GPSFormat.bearingAccessibilityText) ?? L10n.Map.Map.Gps.noHeading
    if wide {
      return ([heading] + details.map { "\($0.label) \($0.value)" }).joined(separator: ", ")
    }
    guard let course else { return heading }
    return "\(heading), \(L10n.Map.Map.Gps.Compass.course(GPSFormat.bearingAccessibilityText(course)))"
  }

  private func rose(diameter: CGFloat) -> some View {
    ZStack {
      Group {
        Circle()
          .strokeBorder(Color(.separator), lineWidth: 2)
        CompassTicks()
          .stroke(Color(.tertiaryLabel), lineWidth: 1)
          .padding(1)
        letters(diameter: diameter)
      }
      // Dimmed without a reading, so the idle rose reads as inactive rather than "facing north".
      .opacity(heading == nil ? 0.5 : 1)
      if let course {
        // The course as a small triangle riding the ring, pointing inward, so travel and facing
        // read apart at a glance.
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: diameter * 0.08))
          .foregroundStyle(Color.green)
          .offset(y: -diameter / 2 + diameter * 0.04)
          .rotationEffect(.degrees(course))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: course)
      }
      if let radioBearing {
        // The radio as an orange dot on the ring, where it lies from the phone.
        Circle()
          .fill(Color.orange)
          .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
          .frame(width: diameter * 0.075, height: diameter * 0.075)
          .offset(y: -diameter / 2 + diameter * 0.0375)
          .rotationEffect(.degrees(radioBearing))
      }
      if heading != nil {
        CompassNeedle()
          .fill(theme.accentColor)
          .frame(width: diameter * 0.5, height: diameter * 0.5)
          .rotationEffect(.degrees(needleAngle))
      }
    }
  }

  /// N, E, S, W just inside the ring; N in amber like Cairn's, so north reads at a glance.
  private func letters(diameter: CGFloat) -> some View {
    let radius = diameter / 2 - diameter * 0.15
    let points: [(CompassPoint, Double)] = [(.north, 0), (.east, 90), (.south, 180), (.west, 270)]
    return ZStack {
      ForEach(points, id: \.1) { point, degrees in
        Text(point.abbreviation)
          .font(.caption.weight(.bold))
          .foregroundStyle(point == .north ? Color.orange : Color.secondary)
          .offset(
            x: radius * sin(degrees * .pi / 180),
            y: -radius * cos(degrees * .pi / 180)
          )
      }
    }
  }
}

/// A tick every 10°, longer on the four cardinal points.
struct CompassTicks: Shape {
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = min(rect.width, rect.height) / 2
    var path = Path()
    for index in 0..<36 {
      let angle = Double(index) * 10 * .pi / 180
      let inner = outer - (index % 9 == 0 ? outer * 0.12 : outer * 0.05)
      path.move(to: CGPoint(x: center.x + inner * sin(angle), y: center.y - inner * cos(angle)))
      path.addLine(to: CGPoint(x: center.x + outer * sin(angle), y: center.y - outer * cos(angle)))
    }
    return path
  }
}

/// Cairn's arrowhead with a notched tail, pointing up (north) in its own frame; the card rotates it.
struct CompassNeedle: Shape {
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let length = min(rect.width, rect.height) / 2
    let spread = 2.6 // radians either side of the tip, as Cairn draws it
    let tail = length * 0.4
    var path = Path()
    path.move(to: CGPoint(x: center.x, y: center.y - length))
    path.addLine(to: CGPoint(x: center.x + tail * sin(spread), y: center.y - tail * cos(spread)))
    path.addLine(to: center)
    path.addLine(to: CGPoint(x: center.x + tail * sin(-spread), y: center.y - tail * cos(-spread)))
    path.closeSubpath()
    return path
  }
}

#Preview {
  HStack {
    GPSCompassCard(heading: 47, course: 120)
    GPSCompassCard(heading: nil)
  }
  .frame(height: 200)
  .padding()
}
