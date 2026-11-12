import CoreLocation
import SwiftUI

// MARK: - Navigation Readout

/// The GPS map's compact navigation readout, floating top-left over the map: one line with the
/// phone's heading, speed, altitude and fix accuracy (always shown), and, with a
/// pin selected, one aiming row: an arrow that points at it from where the phone faces, its name,
/// the distance with its bearing and which way and how far to turn, and Line of Sight. With a
/// target it widens into the room beside the controls, so it stays short over the map. Lined up
/// with the target, the row turns green and the phone taps once. Fields without data are left out
/// rather than shown as junk.
/// Drawn as one of the app's cards (the opaque card fill, `MetricTile` type, accent glyphs) rather
/// than clear glass, so it stays readable over a busy map.
struct MapNavigationHUD: View {
  let live: GPSLiveLocation
  let target: MapNavigationTarget?
  /// Where to measure the target from while the phone has no fix (the radio's own position).
  let fallbackOrigin: CLLocationCoordinate2D?
  let onClearTarget: () -> Void
  /// Opens Line of Sight from here to the target; nil leaves the button out.
  let onCheckLineOfSight: (() -> Void)?
  /// Told when the phone comes onto or goes off the target, so the map can colour its guide line.
  let onTargetChange: ((Bool) -> Void)?
  /// More about the target under its row, on the same card (what a traffic node has carried, the
  /// ways to its page): the map's facts in one place rather than a callout of their own.
  let targetDetail: AnyView?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appTheme) private var theme
  /// The target arrow's angle without wrapping, so it turns the short way past north.
  @State private var arrowAngle: Double = 0
  /// The phone faces the target (within `MapNavigationMath`'s tolerance, with hysteresis).
  @State private var isOnTarget = false

  init(
    live: GPSLiveLocation,
    target: MapNavigationTarget?,
    fallbackOrigin: CLLocationCoordinate2D? = nil,
    onCheckLineOfSight: (() -> Void)? = nil,
    onTargetChange: ((Bool) -> Void)? = nil,
    targetDetail: AnyView? = nil,
    onClearTarget: @escaping () -> Void
  ) {
    self.live = live
    self.target = target
    self.fallbackOrigin = fallbackOrigin
    self.onCheckLineOfSight = onCheckLineOfSight
    self.onTargetChange = onTargetChange
    self.targetDetail = targetDetail
    self.onClearTarget = onClearTarget
  }

  /// The widest it grows with a target: all the room beside the controls on a phone, a
  /// comfortable line on an iPad. Without one it hugs its line.
  private static let maxWidth: CGFloat = 360

  private var location: CLLocation? { live.location }

  private var speedText: String? {
    guard let location, location.speed >= 0 else { return nil }
    return GPSFormat.speedText(location.speed)
  }

  private var altitudeText: String? {
    guard let location, location.verticalAccuracy > 0 else { return nil }
    return GPSFormat.lengthText(location.altitude)
  }

  private var accuracyText: String? {
    guard let location, location.horizontalAccuracy >= 0 else { return nil }
    return GPSFormat.accuracyText(location.horizontalAccuracy)
  }

  /// Distance and bearing from the phone (or the fallback origin) to the target, once both are known.
  private var targetMetrics: (distance: CLLocationDistance, bearing: Double)? {
    guard let target, let origin = location?.coordinate ?? fallbackOrigin else { return nil }
    return (
      MapNavigationMath.distance(from: origin, to: target.coordinate),
      GPSFormat.bearing(from: origin, to: target.coordinate)
    )
  }

  /// Where the target lies from the way the phone faces; nil without a compass.
  private var relativeAngle: Double? {
    guard let bearing = targetMetrics?.bearing, let heading = live.heading else { return nil }
    return MapNavigationMath.relativeAngle(bearing: bearing, heading: heading)
  }

  /// Nothing worth a card yet: no fix, no compass, no target.
  private var hasContent: Bool {
    location != nil || live.heading != nil || target != nil
  }

  var body: some View {
    if hasContent {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 8) {
          statusLine
          if let target {
            Divider()
            targetRow(target)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Map.Map.Nav.title)
        .accessibilityValue(accessibilityValue)
        .modifier(ClearTargetAction(isEnabled: target != nil, action: onClearTarget))
        .modifier(CheckLineOfSightAction(action: target == nil ? nil : onCheckLineOfSight))
        // Its own elements, so its buttons stay reachable.
        if target != nil, let targetDetail {
          Divider()
          targetDetail
        }
      }
      .padding(10)
      // At most its width: beside the offline badge on a narrow screen it takes what is left.
      .frame(maxWidth: target == nil ? nil : Self.maxWidth, alignment: .leading)
      // Narrow card over the map: cap the type like the controls toolbar does.
      .dynamicTypeSize(...DynamicTypeSize.xxLarge)
      .background {
        CardStyle.shape.fill(Color(.secondarySystemGroupedBackground))
        CardStyle.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
      .accessibilityElement(children: .contain)
      .onChange(of: relativeAngle, initial: true) { _, angle in
        updateOnTarget(relativeAngle: angle)
        guard let angle else { return }
        let turn = MapNavigationMath.shortestTurn(from: arrowAngle, to: angle)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
          arrowAngle += turn
        }
      }
      // A new target starts unaimed, so lining up with it taps again.
      .onChange(of: target?.pointID) { _, _ in
        updateOnTarget(relativeAngle: nil)
        updateOnTarget(relativeAngle: relativeAngle)
      }
      .onDisappear { setOnTarget(false) }
      // One tap as the phone comes onto the target, so an antenna can be aimed by feel.
      .sensoryFeedback(.success, trigger: isOnTarget) { wasOn, isOn in !wasOn && isOn }
      .transition(.opacity)
    }
  }

  // MARK: - Rows

  /// The phone's own line: its heading, then speed, altitude and accuracy, always shown. The
  /// readings go under the heading when the line is too narrow for them.
  private var statusLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        headingReading
        readingLabels
      }
      VStack(alignment: .leading, spacing: 4) {
        headingReading
        if !readingItems.isEmpty {
          HStack(spacing: 12) { readingLabels }
        }
      }
    }
    // Hugs its line without a target; with one, the card is as wide as the target row.
    .frame(maxWidth: target == nil ? nil : .infinity, alignment: .leading)
  }

  private var headingReading: some View {
    HStack(spacing: 4) {
      Image(systemName: "location.north.line.fill")
        .imageScale(.small)
        .foregroundStyle(theme.accentColor)
      Text(GPSCompassCard.readingText(heading: live.heading))
        .foregroundStyle(live.heading == nil ? Color.secondary : Color.primary)
        .contentTransition(.numericText())
    }
    .modifier(ReadoutNumberFont(.subheadline, weight: .semibold))
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
  }

  /// Speed, altitude and accuracy, each its glyph and value; the glyphs name them, as VoiceOver
  /// does in words.
  private var readingLabels: some View {
    ForEach(readingItems, id: \.symbol) { item in
      Label(item.text, systemImage: item.symbol)
        .labelStyle(CompactReadingLabelStyle(iconColor: theme.accentColor))
        .modifier(ReadoutNumberFont(.footnote, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
  }

  private var readingItems: [ReadingItem] {
    var items: [ReadingItem] = []
    if let speedText {
      items.append(ReadingItem(symbol: "speedometer", text: speedText))
    }
    if let altitudeText {
      items.append(ReadingItem(symbol: "mountain.2", text: altitudeText))
    }
    if let accuracyText {
      items.append(ReadingItem(symbol: "scope", text: accuracyText))
    }
    return items
  }

  /// The aiming row: the arrow, the target's name over its distance with the bearing and the turn
  /// to make, then Line of Sight and clear. Green while the phone faces the target.
  private func targetRow(_ target: MapNavigationTarget) -> some View {
    let tint: Color = isOnTarget ? .green : theme.accentColor
    return HStack(spacing: 10) {
      Group {
        if relativeAngle != nil {
          Image(systemName: isOnTarget ? "location.north.circle.fill" : "location.north.fill")
            .rotationEffect(.degrees(arrowAngle))
        } else {
          Image(systemName: "mappin.circle.fill")
        }
      }
      .font(.title2)
      .foregroundStyle(tint)
      .frame(width: 30, height: 30)

      VStack(alignment: .leading, spacing: 1) {
        Text(target.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(targetMetrics.map { GPSFormat.lengthText($0.distance) } ?? "—")
            .modifier(ReadoutNumberFont(.title3, weight: .bold))
            .contentTransition(.numericText())
            .layoutPriority(1)
          if let aimText {
            Text(aimText)
              .modifier(ReadoutNumberFont(.footnote, weight: .semibold))
              .foregroundStyle(isOnTarget ? Color.green : Color.secondary)
              .minimumScaleFactor(0.75)
          }
        }
        .monospacedDigit()
        .lineLimit(1)
      }

      Spacer(minLength: 4)

      if let onCheckLineOfSight {
        Button(L10n.Map.Map.Nav.checkLineOfSight, systemImage: "eye", action: onCheckLineOfSight)
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .controlSize(.small)
      }

      Button(L10n.Map.Map.Nav.clearTarget, systemImage: "xmark.circle.fill", action: onClearTarget)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .contentShape(.rect)
    }
    .padding(isOnTarget ? 4 : 0)
    .background(tint.opacity(isOnTarget ? 0.15 : 0), in: .rect(cornerRadius: 8, style: .continuous))
    .animation(reduceMotion ? nil : .snappy, value: isOnTarget)
  }

  /// "47° NE · Turn right 30°": where the target lies, and the turn once the compass gives one.
  private var aimText: String? {
    guard let metrics = targetMetrics else { return nil }
    return ([GPSFormat.bearingText(metrics.bearing)] + [turnText].compactMap(\.self)).joined(separator: " · ")
  }

  /// "On bearing", or which way and how far to turn (the full-screen compass's words), once the compass gives a heading.
  private var turnText: String? {
    guard let relativeAngle else { return nil }
    if isOnTarget { return L10n.Map.Map.Gps.Compass.onTarget }
    let degrees = "\(GPSFormat.wholeDegrees(abs(relativeAngle)))°"
    return relativeAngle < 0 ? L10n.Map.Map.Gps.Compass.turnLeft(degrees) : L10n.Map.Map.Gps.Compass.turnRight(degrees)
  }

  private func updateOnTarget(relativeAngle: Double?) {
    guard let relativeAngle else {
      setOnTarget(false)
      return
    }
    setOnTarget(MapNavigationMath.isOnTarget(relativeAngle: relativeAngle, wasOnTarget: isOnTarget))
  }

  private func setOnTarget(_ value: Bool) {
    guard value != isOnTarget else { return }
    isOnTarget = value
    onTargetChange?(value)
  }

  // MARK: - Accessibility

  /// Every reading in one sentence: "Heading, 274 degrees, west, Speed 3.2 km/h, …, Alice, 1.2 km,
  /// Bearing 47 degrees, northeast, At 2 o'clock".
  private var accessibilityValue: String {
    var parts: [String] = []
    parts.append(live.heading.map {
      "\(L10n.Map.Map.Gps.heading), \(GPSFormat.bearingAccessibilityText($0))"
    } ?? L10n.Map.Map.Gps.noHeading)
    if let speedText { parts.append("\(L10n.Map.Map.Gps.speed) \(speedText)") }
    if let altitudeText { parts.append("\(L10n.Map.Map.Nav.altitude) \(altitudeText)") }
    if let accuracyText { parts.append("\(L10n.Map.Map.Gps.accuracy) \(accuracyText)") }
    if let target {
      parts.append(target.name)
      if let metrics = targetMetrics {
        parts.append("\(L10n.Map.Map.Nav.distance) \(GPSFormat.lengthText(metrics.distance))")
        parts.append("\(L10n.Map.Map.Nav.bearing) \(GPSFormat.bearingAccessibilityText(metrics.bearing))")
      }
      if let turnText {
        parts.append(turnText)
      }
      if let relativeAngle, !isOnTarget {
        parts.append(L10n.Map.Map.Nav.clockPosition(MapNavigationMath.clockPosition(relativeAngle: relativeAngle)))
      }
    }
    return parts.joined(separator: ", ")
  }
}

/// One reading on the readout's line, keyed by its glyph (each appears once).
private struct ReadingItem {
  let symbol: String
  let text: String
}

/// The readout's numbers, a point larger than their text style and scaling as it does (under the
/// card's type cap, since it reads the size where it's applied), so they stand out a little from
/// their labels.
private struct ReadoutNumberFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let weight: Font.Weight

  init(_ style: Font.TextStyle, weight: Font.Weight) {
    _size = ScaledMetric(wrappedValue: Self.baseSize(style) + 1, relativeTo: style)
    self.weight = weight
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: weight))
  }

  /// The styles' sizes at the default (Large) text size.
  private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
    switch style {
    case .title3: 20
    case .subheadline: 15
    case .footnote: 13
    default: 17
    }
  }
}

/// A reading: a small accent glyph tight against its value.
private struct CompactReadingLabelStyle: LabelStyle {
  let iconColor: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
        .imageScale(.small)
        .foregroundStyle(iconColor)
      configuration.title
    }
  }
}

/// Offers "Check Line of Sight" to VoiceOver while there is a target and a way to check it.
private struct CheckLineOfSightAction: ViewModifier {
  let action: (() -> Void)?

  func body(content: Content) -> some View {
    if let action {
      content.accessibilityAction(named: L10n.Map.Map.Nav.checkLineOfSight, action)
    } else {
      content
    }
  }
}

/// Offers "Clear Target" to VoiceOver only while there is one.
private struct ClearTargetAction: ViewModifier {
  let isEnabled: Bool
  let action: () -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content.accessibilityAction(named: L10n.Map.Map.Nav.clearTarget, action)
    } else {
      content
    }
  }
}

// MARK: - Compass

/// Apple Maps' compass for the GPS map: shown only while the map is rotated or tilted, its
/// needle and N turn with the map so they point at north on screen, and a tap turns the map back
/// to north-up and flat. Replaces MapLibre's own compass ornament on this map.
struct MapCompassButton: View {
  /// Which way the map is held, for a compass whose tap cycles them (the Scan & Traffic map's):
  /// a badge marks the two that aren't free north-up, and VoiceOver reads it.
  enum Mode {
    case northUp
    case headingUp
    case northLocked
  }

  let orientation: MapCameraOrientation
  /// Nil for a compass that only turns the map back to north (the GPS tab's).
  var mode: Mode?
  let action: () -> Void

  private static let size: CGFloat = 44

  var body: some View {
    Button(action: action) {
      ZStack {
        CompassRoseTicks()
          .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
          .padding(4)
        // North needle: red toward N, grey tail, as on Apple's compass.
        VStack(spacing: 0) {
          Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 9))
            .foregroundStyle(.red)
          Text(L10n.Map.Map.Gps.Cardinal.n)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(orientation.direction))
        }
        .offset(y: -4)
      }
      .rotationEffect(.degrees(-orientation.direction))
      // A hint of the tilt, so a pitched flat-north map still reads as "not flat".
      .rotation3DEffect(.degrees(min(orientation.pitch, 60) * 0.6), axis: (x: 1, y: 0, z: 0))
      .frame(width: Self.size, height: Self.size)
      .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .liquidGlass(in: .circle)
    .overlay(alignment: .bottomTrailing) { badge }
    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    .animation(.snappy, value: mode)
    .accessibilityLabel(L10n.Map.Map.Nav.compass)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(mode == nil ? L10n.Map.Map.Nav.Compass.hint : L10n.Map.Map.Nav.Compass.cycleHint)
  }

  /// A lock for north locked, the heading line for heading up; nothing for free north-up.
  @ViewBuilder
  private var badge: some View {
    if let symbol = badgeSymbol {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(Color.accentColor, in: .circle)
        .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1) }
        .offset(x: 3, y: 3)
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)
    }
  }

  private var badgeSymbol: String? {
    switch mode {
    case .headingUp: "location.north.line.fill"
    case .northLocked: "lock.fill"
    case .northUp, nil: nil
    }
  }

  private var accessibilityValue: String {
    let facing = L10n.Map.Map.Nav.Compass.value(GPSFormat.bearingAccessibilityText(orientation.direction))
    var parts = [facing]
    if orientation.pitch >= MapNavigationMath.orientationTolerance {
      parts.append(L10n.Map.Map.Nav.Compass.tilted)
    }
    switch mode {
    case .headingUp: parts.append(L10n.Map.Map.Controls.Tracking.heading)
    case .northLocked: parts.append(L10n.Map.Map.Controls.lockNorth)
    case .northUp, nil: break
    }
    return parts.joined(separator: ", ")
  }
}

/// Twelve ticks round the compass ring, the four cardinal ones longer.
private struct CompassRoseTicks: Shape {
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = min(rect.width, rect.height) / 2
    var path = Path()
    for index in 0..<12 {
      let angle = Double(index) * 30 * .pi / 180
      let inner = outer - (index % 3 == 0 ? outer * 0.22 : outer * 0.12)
      path.move(to: CGPoint(x: center.x + inner * sin(angle), y: center.y - inner * cos(angle)))
      path.addLine(to: CGPoint(x: center.x + outer * sin(angle), y: center.y - outer * cos(angle)))
    }
    return path
  }
}

#Preview {
  ZStack(alignment: .topLeading) {
    Color.gray.opacity(0.3)
    VStack(alignment: .leading) {
      MapNavigationHUD(live: GPSLiveLocation(), target: nil, onClearTarget: {})
      MapCompassButton(orientation: MapCameraOrientation(direction: 40, pitch: 20), action: {})
    }
    .padding()
  }
}
