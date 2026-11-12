import SwiftUI

/// Something with a direction that rides the full compass's dial: the course over ground, the
/// sun, or a node.
struct CompassDialMarker: Identifiable, Equatable {
  enum Kind: Equatable {
    case course
    case sun(isUp: Bool)
    /// `symbol` names an asset-catalog symbol when `isCustomSymbol` (Cairn's tower and
    /// walkie-talkie), else an SF Symbol.
    case node(symbol: String, isCustomSymbol: Bool, tint: Color, isTarget: Bool)
  }

  let id: String
  /// Degrees clockwise from north.
  let bearing: Double
  let kind: Kind
}

/// The full compass's dial: a rose that turns so the way you face is always at the top, under a
/// fixed amber pointer, as a ship's compass card does. Ticks every degree (longer at 5° and 10°),
/// numbers every 30°, the eight points with N in amber; the course, the sun and nearby nodes ride
/// a track inside the numbers. A locked bearing shows as an arc from the pointer to it, green once
/// you're within 5°. Every label stays upright as the rose turns.
///
/// `rotation` is animatable, unwrapped (359° → 361° rather than back to 1°), so the rose glides the
/// short way round between readings.
struct CompassDial: View, @MainActor Animatable {
  /// How far the rose is turned, in degrees, not wrapped: the heading when the way you face is at
  /// the top, zero when north is.
  var rotation: Double
  /// How far the pointer is turned from the top: zero when the rose turns, the heading when north
  /// stays up and the pointer swings instead.
  var pointer: Double = 0
  let hasHeading: Bool
  let markers: [CompassDialMarker]
  /// A bearing to steer by, if locked.
  let target: Double?
  /// Called with a node marker's id when it is tapped.
  var onSelectNode: ((String) -> Void)?
  /// Leaves the face clear so a map behind the dial shows through it at full strength. The ticks,
  /// numbers and marks still cast their shadows, so the dial reads as sitting above the map.
  var isFaceTranslucent = false
  /// Whether the target counts as lined up, when the caller works it out (with the map's
  /// hysteresis); nil compares against the tolerance here.
  var isOnTarget: Bool?

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(rotation, pointer) }
    set {
      rotation = newValue.first
      pointer = newValue.second
    }
  }

  static let onTargetTolerance = MapNavigationMath.onTargetTolerance

  var body: some View {
    GeometryReader { geometry in
      let diameter = min(geometry.size.width, geometry.size.height)
      let radius = diameter / 2
      ZStack {
        face(radius: radius)
        if let target {
          targetArc(target: target, radius: radius)
        }
        ForEach(markers) { marker in
          markerView(marker, radius: radius)
        }
        lubber(radius: radius)
          .frame(width: radius * 2, height: radius * 2)
          .rotationEffect(.degrees(pointer))
      }
      .frame(width: diameter, height: diameter)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
  }

  /// Where a bearing sits on screen at `fraction` of the radius from the centre.
  private func offset(_ bearing: Double, radius: CGFloat, fraction: CGFloat) -> CGSize {
    let angle = (bearing - rotation) * .pi / 180
    return CGSize(width: radius * fraction * sin(angle), height: -radius * fraction * cos(angle))
  }

  // MARK: - Face

  private func face(radius: CGFloat) -> some View {
    Canvas { context, size in
      let centre = CGPoint(x: size.width / 2, y: size.height / 2)
      let bezel = Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
      // The face on the page's card colours, lit from the centre, so it sits with the cards
      // around it in light and dark alike. Over a map it's a glass the map shows faintly through.
      // Over a map the face is clear glass: the map shows at full strength and the print's
      // shadows carry the depth. Otherwise the face sits on the card colours with its rim
      // darkening inward, set down into the bezel.
      if !isFaceTranslucent {
        context.fill(bezel, with: .radialGradient(
          Gradient(colors: [Color(.secondarySystemGroupedBackground), Color(.tertiarySystemGroupedBackground)]),
          center: centre, startRadius: 0, endRadius: radius
        ))
        context.fill(bezel, with: .radialGradient(
          Gradient(stops: [
            .init(color: .black.opacity(0), location: 0.8),
            .init(color: .black.opacity(0.1), location: 1),
          ]),
          center: centre, startRadius: 0, endRadius: radius
        ))
      }
      context.stroke(bezel, with: .color(.primary.opacity(0.15)), lineWidth: 1.5)
      // Everything printed on the card casts a small shadow down the screen, as if lit from
      // above, so it stands off the face (and the map under it) as the rose turns.
      context.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.2, x: 0, y: 1))
      // The inner track the markers ride, and the crosshair.
      let track = Path(ellipseIn: CGRect(x: centre.x - radius * 0.56, y: centre.y - radius * 0.56, width: radius * 1.12, height: radius * 1.12))
      context.stroke(track, with: .color(.primary.opacity(0.08)), lineWidth: 1)
      var cross = Path()
      cross.move(to: CGPoint(x: centre.x - radius * 0.12, y: centre.y))
      cross.addLine(to: CGPoint(x: centre.x + radius * 0.12, y: centre.y))
      cross.move(to: CGPoint(x: centre.x, y: centre.y - radius * 0.12))
      cross.addLine(to: CGPoint(x: centre.x, y: centre.y + radius * 0.12))
      context.stroke(cross, with: .color(.primary.opacity(0.12)), lineWidth: 1)

      // Ticks.
      let outer = radius * 0.97
      for degree in 0..<360 {
        let angle = (Double(degree) - rotation) * .pi / 180
        let (length, width, opacity): (CGFloat, CGFloat, Double) =
          degree % 30 == 0 ? (0.12, 2, 0.95) : degree % 10 == 0 ? (0.09, 1.5, 0.7) : degree % 5 == 0 ? (0.06, 1, 0.5) : (0.035, 0.75, 0.3)
        let inner = outer - radius * length
        var tick = Path()
        tick.move(to: CGPoint(x: centre.x + inner * sin(angle), y: centre.y - inner * cos(angle)))
        tick.addLine(to: CGPoint(x: centre.x + outer * sin(angle), y: centre.y - outer * cos(angle)))
        let isNorth = degree == 0
        context.stroke(tick, with: .color(isNorth ? .orange : .primary.opacity(opacity)), lineWidth: isNorth ? 3 : width)
      }

      // Labels: the eight points and the degrees between, upright.
      let labelRadius = radius * 0.71
      for degree in stride(from: 0, to: 360, by: 15) {
        let angle = (Double(degree) - rotation) * .pi / 180
        let point = CGPoint(x: centre.x + labelRadius * sin(angle), y: centre.y - labelRadius * cos(angle))
        if degree % 45 == 0 {
          let compassPoint = CompassPoint(rawValue: degree / 45) ?? .north
          let isCardinal = degree % 90 == 0
          let text = Text(compassPoint.abbreviation)
            .font(.system(size: radius * (isCardinal ? 0.15 : 0.085), weight: isCardinal ? .heavy : .bold, design: .rounded))
            .foregroundStyle(compassPoint == .north ? Color.orange : Color.primary.opacity(isCardinal ? 1 : 0.7))
          context.draw(text, at: point)
        } else if degree % 30 == 0 {
          let text = Text(degree.formatted())
            .font(.system(size: radius * 0.065, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.55))
          context.draw(text, at: point)
        }
      }
    }
    .opacity(hasHeading || isFaceTranslucent ? 1 : 0.55)
  }

  // MARK: - Pointer and target

  /// The fixed pointer at the top: the way you face.
  private func lubber(radius: CGFloat) -> some View {
    Triangle()
      .fill(Color.orange)
      .frame(width: radius * 0.1, height: radius * 0.09)
      .shadow(color: .orange.opacity(0.6), radius: 4)
      .offset(y: -radius * 1.0 - radius * 0.02)
  }

  private func targetArc(target: Double, radius: CGFloat) -> some View {
    // From where the pointer is (the heading) round to the target, the short way.
    let delta = GPSFormat.normalizedDegrees(target - rotation - pointer + 180) - 180
    let onTarget = isOnTarget ?? (abs(delta) <= Self.onTargetTolerance)
    let tint: Color = onTarget ? .green : .red
    return ZStack {
      // From the pointer (straight up) round to the target.
      Circle()
        .trim(from: 0, to: min(abs(delta), 359.9) / 360)
        .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: radius * 0.05, lineCap: .round))
        .rotationEffect(.degrees(-90 + pointer + (delta < 0 ? delta : 0)))
        .padding(radius * 0.13)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1.5)
      Image(systemName: "scope")
        .font(.system(size: radius * 0.09, weight: .bold))
        .foregroundStyle(tint)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        .offset(offset(target, radius: radius, fraction: 0.87))
    }
  }

  // MARK: - Markers

  @ViewBuilder
  private func markerView(_ marker: CompassDialMarker, radius: CGFloat) -> some View {
    switch marker.kind {
    case .course:
      Image(systemName: "arrowtriangle.up.fill")
        .font(.system(size: radius * 0.08))
        .foregroundStyle(Color.green)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        .rotationEffect(.degrees(marker.bearing - rotation))
        .offset(offset(marker.bearing, radius: radius, fraction: 0.47))
    case let .sun(isUp):
      Image(systemName: isUp ? "sun.max.fill" : "sun.horizon.fill")
        .font(.system(size: radius * 0.09))
        .symbolRenderingMode(.multicolor)
        .opacity(isUp ? 1 : 0.5)
        .shadow(color: .yellow.opacity(isUp ? 0.7 : 0), radius: 6)
        .offset(offset(marker.bearing, radius: radius, fraction: 0.56))
    case let .node(symbol, isCustomSymbol, tint, isTarget):
      // The node's own glyph, upright, in its kind's colour; the selected one larger and ringed.
      // The slender tower takes a larger size to read as large as the walkie-talkie.
      let scale: CGFloat = symbol == "cairn.repeater.fill" ? 1.3 : 1
      Button {
        onSelectNode?(marker.id)
      } label: {
        (isCustomSymbol ? Image(symbol) : Image(systemName: symbol))
          .font(.system(size: radius * (isTarget ? 0.085 : 0.065) * scale, weight: .semibold))
          .foregroundStyle(tint)
          .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
          .padding(radius * 0.03)
          .background {
            if isTarget {
              Circle()
                .fill(Color.green.opacity(0.15))
                .strokeBorder(Color.green, lineWidth: 2)
            }
          }
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .offset(offset(marker.bearing, radius: radius, fraction: 0.56))
    }
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

#Preview {
  CompassDial(
    rotation: 32,
    hasHeading: true,
    markers: [
      CompassDialMarker(id: "course", bearing: 50, kind: .course),
      CompassDialMarker(id: "sun", bearing: 210, kind: .sun(isUp: true)),
      CompassDialMarker(id: "a", bearing: 120, kind: .node(symbol: "cairn.repeater.fill", isCustomSymbol: true, tint: .teal, isTarget: true)),
    ],
    target: 120
  )
  .padding()
}
