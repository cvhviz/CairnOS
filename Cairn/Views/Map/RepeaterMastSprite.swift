import CairnServices
import SwiftUI
import UIKit

/// A repeater drawn as what it is: a small lattice radio mast standing on its coordinate, with a
/// soft shadow lying on the ground beneath it. MapLibre Native draws no 3D models, so the depth is
/// an illusion built from two symbols per repeater:
///
/// - the mast (`spriteName`), bottom-anchored and viewport-pitched, so it stands upright from its
///   ground point at any tilt, shaded as if lit from the upper left;
/// - the ground shadow (`groundSpriteName`), centre-anchored and map-pitched and map-rotated, so it
///   lies flat on the map, foreshortens as the map tilts and turns with it, falling to the lower
///   right (south-east) of the base, away from that same light.
///
/// The beacon at the mast's top tells its state: lit in a colour with a soft halo (passing traffic,
/// LOS point A or B, in a traced path), or, when quiet, a red lens that the map flashes faintly like
/// a real mast's aviation light (`warningLightName`; a heard-only repeater's stays pale glass). A selected mast draws larger, and
/// its shadow carries an accent ring on the ground. A repeater heard but not saved is outlined, as
/// the other discovered pins are. `spriteName` names each look uniquely, so the map can ask for it
/// again by name after an atlas eviction.
struct RepeaterMastSprite: Equatable {
  /// The light at the mast's top.
  enum Beacon: String, CaseIterable {
    /// Unlit: a quiet repeater, or one with nothing to show.
    case idle
    /// Lit green: passing traffic (Traffic map), or LOS point B.
    case green
    /// Lit blue: LOS point A.
    case blue
    /// Lit in the app's accent: in a traced path, the repeater whose neighbours are mapped, or a
    /// hop a message took.
    case accent
  }

  /// Off for now: the user prefers the avatar pins, which every repeater falls back to while this
  /// is false (no mast, shadow or red light). Flip it to bring the masts back.
  static let isEnabled = false

  static let namePrefix = "pin-mast-"
  static let groundPrefix = "pin-ground"

  let beacon: Beacon
  /// Heard on the mesh but not saved: a pale mast on a hollow base.
  let isOutlined: Bool
  let hopIndex: Int?
  let isSelected: Bool
  /// The colour picked for the repeater, or nil for Automatic (the repeater indigo).
  let color: NodeAvatarColor?
  let appearance: MapAvatarAppearance

  /// The mast for a repeater pin, or nil for every other pin. Rings become beacons: the trace and
  /// LOS rings and the Traffic map's green "active" ring light the beacon in their colour.
  init?(point: MapPoint, appearance: MapAvatarAppearance, isSelected: Bool = false) {
    guard Self.isEnabled else { return nil }
    var hop: Int?
    var isOutlined = false
    let beacon: Beacon
    switch point.pinStyle {
    case .contactRepeater, .repeater: beacon = .idle
    case .discoveredRepeater: beacon = .idle; isOutlined = true
    case .repeaterRingGreen: beacon = .green
    case .repeaterRingBlue: beacon = .blue
    case .repeaterRingWhite, .repeaterHop: beacon = .accent; hop = point.hopIndex
    case .contactChat, .contactRoom, .discoveredChat, .discoveredRoom, .pointA, .pointB, .crosshair,
         .obstruction, .badge, .droppedPin, .locationFix, .locationFixLatest:
      return nil
    }
    self.beacon = beacon
    self.isOutlined = isOutlined
    hopIndex = hop.map { min(max($0, 1), PinSpriteRenderer.maxHopBadge) }
    self.isSelected = isSelected
    // A heard-only repeater has no saved colour; a saved one keeps its pick (photos don't fit a mast).
    color = isOutlined ? nil : point.avatar?.color
    self.appearance = appearance
  }

  /// "pin-mast-<beacon>[-outlined][-hop-<n>][-sel]-<appearance>[-c<colour>]". Stable for the same
  /// look, so every quiet repeater on a busy map shares one sprite.
  var spriteName: String {
    var parts = [beacon.rawValue]
    if isOutlined { parts.append("outlined") }
    if let hopIndex { parts.append("hop-\(hopIndex)") }
    if isSelected { parts.append("sel") }
    parts.append(appearance.fingerprint)
    if let color { parts.append("c" + color.rawValue) }
    return Self.namePrefix + parts.joined(separator: "-")
  }

  /// The red light the map flashes over this mast, for a quiet saved repeater; nil otherwise.
  var warningLightSpriteName: String? {
    beacon == .idle && !isOutlined ? Self.warningLightName(selected: isSelected) : nil
  }

  /// "pin-ground" for every unselected mast, so hundreds of repeaters share one shadow sprite;
  /// "pin-ground-sel-<appearance>" under the selected one, whose ring takes the theme's accent.
  var groundSpriteName: String {
    isSelected ? "\(Self.groundPrefix)-sel-\(appearance.fingerprint)" : Self.groundPrefix
  }

  static func == (lhs: RepeaterMastSprite, rhs: RepeaterMastSprite) -> Bool {
    lhs.spriteName == rhs.spriteName
  }
}

// MARK: - Geometry

extension RepeaterMastSprite {
  /// The mast shows this much larger than the drawing below, whose numbers are all drawing
  /// points: at 1 it read as a thin sliver on the map.
  static let displayScale: CGFloat = 1.3
  /// Height of the mast drawing, base to the top of the beacon's halo.
  static let height: CGFloat = 42
  /// Width of a plain mast sprite: wide enough for the beacon's halo and an easy tap.
  static let width: CGFloat = 30
  /// Width with a hop badge, which sits right of the beacon; widened symmetrically so the base
  /// stays centred on the coordinate.
  static let hopWidth: CGFloat = 40
  /// A selected mast draws this much larger.
  static let selectedScale: CGFloat = 1.2
  /// Side of the square ground shadow drawing, centred on the coordinate.
  static let groundSize: CGFloat = 64

  /// How far a callout over a repeater lifts from its coordinate: the top of the selected mast,
  /// since a callout only opens on the selected pin.
  static let calloutLift: CGFloat = height * displayScale * selectedScale

  /// How much larger than its drawing this sprite shows.
  var scale: CGFloat { Self.displayScale * (isSelected ? Self.selectedScale : 1) }

  /// The sprite's size in points.
  var size: CGSize {
    return CGSize(width: (hopIndex != nil ? Self.hopWidth : Self.width) * scale, height: Self.height * scale)
  }

  /// The beacon's centre and radius, and the halo's radius, in unscaled sprite points.
  fileprivate static let beaconY: CGFloat = 10.5
  fileprivate static let beaconRadius: CGFloat = 3.6
  fileprivate static let haloRadius: CGFloat = 10.5
  /// The lattice: its top (under the beacon's whip) and half-widths at top and foot.
  fileprivate static let towerTopY: CGFloat = 17
  fileprivate static let towerTopHalf: CGFloat = 1.6
  fileprivate static let towerFootHalf: CGFloat = 4.8
  /// The plinth: a short drum seen from a little above, its top face centred at `plinthTopY`.
  fileprivate static let plinthRadiusX: CGFloat = 6.6
  fileprivate static let plinthRadiusY: CGFloat = 2.3
  fileprivate static let plinthDepth: CGFloat = 2.6
  fileprivate static var plinthTopY: CGFloat { height - plinthRadiusY - plinthDepth - 0.4 }
}

// MARK: - Colours

extension RepeaterMastSprite {
  /// The mast's resolved colours for its appearance.
  struct Palette {
    let body: UIColor
    let glow: UIColor?
    let casing: UIColor
    let accent: UIColor
  }

  @MainActor
  func palette() -> Palette {
    let theme = appearance.theme
    let scheme = appearance.colorScheme
    let contrast = appearance.contrast
    let traits = Theme.traitCollection(colorScheme: scheme, contrast: contrast)
    let isDark = scheme == .dark
    let fill = theme.avatarColor(color, category: .repeater, colorScheme: scheme, contrast: contrast)
    var body = UIColor(fill).resolvedColor(with: traits)
    // On a dark basemap the indigo sinks; lift it so the lattice still reads.
    if isDark { body = body.blended(with: .white, amount: 0.3) }
    let accent = UIColor(theme.accentColor).resolvedColor(with: traits)
    let glow: UIColor? = switch beacon {
    case .idle: nil
    case .green: UIColor.systemGreen.resolvedColor(with: traits)
    case .blue: UIColor.systemBlue.resolvedColor(with: traits)
    case .accent: accent
    }
    // A thin casing keeps the slim mast legible over roads, labels and imagery, as the lines'
    // white casings do. On a dark ground a white one turns the lattice into a grey cone and
    // outshines the beacon, so there it's a dark keyline instead.
    let casing: UIColor = if isDark {
      UIColor.black.withAlphaComponent(contrast == .increased ? 0.8 : 0.5)
    } else {
      UIColor.white.withAlphaComponent(contrast == .increased ? 1 : 0.9)
    }
    return Palette(body: body, glow: glow, casing: casing, accent: accent)
  }
}

// MARK: - Drawing

extension RepeaterMastSprite {
  @MainActor
  func render() -> UIImage {
    let size = size
    let palette = palette()
    return UIGraphicsImageRenderer(size: size, format: .preferred()).image { ctx in
      let cg = ctx.cgContext
      cg.scaleBy(x: scale, y: scale)
      draw(in: cg, width: size.width / scale, palette: palette)
    }
  }

  private func draw(in cg: CGContext, width: CGFloat, palette: Palette) {
    let centerX = width / 2
    let beacon = CGPoint(x: centerX, y: Self.beaconY)
    let flat = appearance.contrast == .increased

    // Halo first, so the mast and beacon draw over it.
    if let glow = palette.glow {
      let colors = [glow.withAlphaComponent(0.85), glow.withAlphaComponent(0.4), glow.withAlphaComponent(0)]
      Self.radialGradient(cg, colors: colors, locations: [0.3, 0.55, 1], center: beacon, radius: Self.haloRadius)
    }

    // Casing pass: the whole silhouette a little fatter in the casing colour.
    drawStructure(in: cg, centerX: centerX, palette: palette, casing: palette.casing)

    // Colour pass in its own layer, so the top-lit wash lands on the mast only.
    cg.saveGState()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawStructure(in: cg, centerX: centerX, palette: palette, casing: nil)
    if !flat {
      // Sky light from above, a touch of occlusion toward the ground.
      cg.setBlendMode(.sourceAtop)
      Self.linearGradient(
        cg,
        colors: [UIColor.white.withAlphaComponent(0.22), UIColor.clear, UIColor.black.withAlphaComponent(0.2)],
        locations: [0, 0.45, 1],
        from: CGPoint(x: centerX, y: Self.towerTopY - 2),
        to: CGPoint(x: centerX, y: Self.height)
      )
    }
    cg.endTransparencyLayer()
    cg.restoreGState()

    drawBeacon(in: cg, at: beacon, palette: palette, flat: flat)
    if let hopIndex { drawHopBadge(hopIndex, in: cg, beacon: beacon, palette: palette) }
  }

  /// The plinth, lattice, head and whip. With `casing` everything is drawn fatter in that one
  /// colour (the outline pass); without it, shaded as lit from the upper left.
  private func drawStructure(in cg: CGContext, centerX: CGFloat, palette: Palette, casing: UIColor?) {
    let grow: CGFloat = casing == nil ? 0 : 1.5
    let body = isOutlined ? palette.body.blended(with: .white, amount: 0.42) : palette.body
    let lit = body.blended(with: .white, amount: 0.3)
    let shade = body.blended(with: .black, amount: 0.28)
    let footY = Self.plinthTopY
    let topY = Self.towerTopY
    let footHalf = Self.towerFootHalf
    let topHalf = Self.towerTopHalf

    func legX(_ side: CGFloat, at y: CGFloat) -> CGFloat {
      let t = (footY - y) / (footY - topY)
      return centerX + side * (footHalf + (topHalf - footHalf) * t)
    }

    // Plinth: a drum seen from slightly above, its side shaded left to right.
    let rx = Self.plinthRadiusX + grow
    let ry = Self.plinthRadiusY + grow
    let topFace = CGRect(x: centerX - rx, y: footY - ry, width: rx * 2, height: ry * 2)
    let bottomFace = topFace.offsetBy(dx: 0, dy: Self.plinthDepth)
    let drum = CGMutablePath()
    drum.addEllipse(in: bottomFace)
    drum.addRect(CGRect(x: topFace.minX, y: topFace.midY, width: topFace.width, height: Self.plinthDepth))
    if let casing {
      cg.setFillColor(casing.cgColor)
      cg.addPath(drum)
      cg.fillPath()
      cg.fillEllipse(in: topFace)
    } else {
      cg.saveGState()
      cg.addPath(drum)
      cg.clip()
      Self.linearGradient(
        cg,
        colors: isOutlined ? [body, body.blended(with: .black, amount: 0.12)] : [lit, shade.blended(with: .black, amount: 0.15)],
        locations: [0, 1],
        from: CGPoint(x: topFace.minX, y: 0),
        to: CGPoint(x: topFace.maxX, y: 0)
      )
      cg.restoreGState()
      if isOutlined {
        // Heard, not saved: a hollow white base ringed in the repeater colour.
        UIColor.white.setFill()
        cg.fillEllipse(in: topFace)
        body.blended(with: .black, amount: 0.15).setStroke()
        cg.setLineWidth(1)
        cg.strokeEllipse(in: topFace.insetBy(dx: 0.5, dy: 0.5))
      } else {
        body.blended(with: .white, amount: 0.45).setFill()
        cg.fillEllipse(in: topFace)
        // The mast's footing on the plinth.
        shade.withAlphaComponent(0.5).setFill()
        cg.fillEllipse(in: CGRect(x: centerX - footHalf - 0.6, y: footY - 0.9, width: (footHalf + 0.6) * 2, height: 1.8))
      }
    }

    // A faint panel between the legs gives the lattice some mass at a glance.
    if casing == nil, !isOutlined {
      let panel = CGMutablePath()
      panel.move(to: CGPoint(x: legX(-1, at: footY), y: footY))
      panel.addLine(to: CGPoint(x: legX(-1, at: topY), y: topY))
      panel.addLine(to: CGPoint(x: legX(1, at: topY), y: topY))
      panel.addLine(to: CGPoint(x: legX(1, at: footY), y: footY))
      panel.closeSubpath()
      cg.addPath(panel)
      cg.setFillColor(body.withAlphaComponent(0.18).cgColor)
      cg.fillPath()
    }

    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    // Bracing: a strut at each panel line and one diagonal per panel, alternating, panels
    // shortening toward the top as a real tower's do.
    let panels: [CGFloat] = [0, 0.3, 0.55, 0.78, 1]
    let braces = CGMutablePath()
    for (index, fraction) in panels.enumerated() {
      let y = footY + (topY - footY) * fraction
      braces.move(to: CGPoint(x: legX(-1, at: y), y: y))
      braces.addLine(to: CGPoint(x: legX(1, at: y), y: y))
      guard index + 1 < panels.count else { continue }
      let nextY = footY + (topY - footY) * panels[index + 1]
      let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
      braces.move(to: CGPoint(x: legX(side, at: y), y: y))
      braces.addLine(to: CGPoint(x: legX(-side, at: nextY), y: nextY))
    }
    cg.addPath(braces)
    cg.setStrokeColor((casing ?? body).cgColor)
    cg.setLineWidth(1.1 + grow * 2)
    cg.strokePath()

    // Legs: the left catches the light, the right is in shade.
    for side: CGFloat in [-1, 1] {
      cg.move(to: CGPoint(x: legX(side, at: footY), y: footY))
      cg.addLine(to: CGPoint(x: legX(side, at: topY), y: topY))
      cg.setStrokeColor((casing ?? (side < 0 ? lit : shade)).cgColor)
      cg.setLineWidth(2 + grow * 2)
      cg.strokePath()
    }

    // Head: a small platform, and the whip rising to the beacon.
    let head = CGRect(x: centerX - topHalf - 1.6, y: topY - 1.3, width: (topHalf + 1.6) * 2, height: 2.4)
      .insetBy(dx: -grow, dy: -grow)
    cg.addPath(UIBezierPath(roundedRect: head, cornerRadius: head.height / 2).cgPath)
    cg.setFillColor((casing ?? body.blended(with: .black, amount: 0.1)).cgColor)
    cg.fillPath()
    cg.move(to: CGPoint(x: centerX, y: topY - 1))
    cg.addLine(to: CGPoint(x: centerX, y: Self.beaconY + Self.beaconRadius - 0.5))
    cg.setStrokeColor((casing ?? lit).cgColor)
    cg.setLineWidth(1.2 + grow * 2)
    cg.strokePath()

    if let casing {
      let r = Self.beaconRadius + grow
      cg.setFillColor(casing.cgColor)
      cg.fillEllipse(in: CGRect(x: centerX - r, y: Self.beaconY - r, width: r * 2, height: r * 2))
    }
  }

  /// The beacon: a lit sphere, white-hot in the middle, or dark glass with a glint.
  private func drawBeacon(in cg: CGContext, at center: CGPoint, palette: Palette, flat: Bool) {
    let r = Self.beaconRadius
    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    let glint = CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4)
    cg.saveGState()
    cg.addEllipse(in: rect)
    cg.clip()
    if let glow = palette.glow {
      if flat {
        glow.setFill()
        cg.fill(rect)
      } else {
        Self.radialGradient(
          cg,
          colors: [.white, glow.blended(with: .white, amount: 0.35), glow],
          locations: [0, 0.4, 1],
          center: glint,
          radius: r * 1.5
        )
      }
    } else {
      // A saved quiet mast's lens is the warning light's red, unlit; the map flashes it.
      let base = isOutlined ? palette.body.blended(with: .white, amount: 0.55) : Self.warningRed.blended(with: .black, amount: 0.45)
      Self.radialGradient(
        cg,
        colors: [base.blended(with: .white, amount: 0.4), base],
        locations: [0, 1],
        center: glint,
        radius: r * 1.5
      )
    }
    cg.restoreGState()
    if palette.glow == nil {
      UIColor.white.withAlphaComponent(0.75).setFill()
      cg.fillEllipse(in: CGRect(x: glint.x - 0.8, y: glint.y - 0.8, width: 1.6, height: 1.6))
    }
  }

  /// The hop number in a blue disc beside the beacon, as the pins' hop badges were.
  private func drawHopBadge(_ hop: Int, in cg: CGContext, beacon: CGPoint, palette: Palette) {
    let diameter: CGFloat = 15
    // Clear of the beacon, so its light still shows.
    let rect = CGRect(x: beacon.x + 10.5 - diameter / 2, y: beacon.y - 2.5 - diameter / 2, width: diameter, height: diameter)
    UIColor.white.withAlphaComponent(0.9).setFill()
    cg.fillEllipse(in: rect.insetBy(dx: -1, dy: -1))
    UIColor.systemBlue.setFill()
    cg.fillEllipse(in: rect)
    let text = "\(hop)" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: hop > 9 ? 9 : 10, weight: .bold),
      .foregroundColor: UIColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
  }

  // MARK: Warning light

  /// The aviation red a quiet mast's light flashes.
  static let warningRed = UIColor(red: 1, green: 0.13, blue: 0.1, alpha: 1)
  static let warningLightPrefix = "pin-warning-light"

  /// The flash over a quiet mast: a sprite the size of the mast's (selected or not), bottom-
  /// anchored like it, holding only the lit lens and a faint halo where its beacon is.
  static func warningLightName(selected: Bool) -> String {
    selected ? warningLightPrefix + "-sel" : warningLightPrefix
  }

  @MainActor
  static func renderWarningLight(selected: Bool) -> UIImage {
    let scale = displayScale * (selected ? selectedScale : 1)
    let size = CGSize(width: width * scale, height: height * scale)
    return UIGraphicsImageRenderer(size: size, format: .preferred()).image { ctx in
      let cg = ctx.cgContext
      cg.scaleBy(x: scale, y: scale)
      let center = CGPoint(x: width / 2, y: beaconY)
      let red = warningRed
      radialGradient(
        cg,
        colors: [red.withAlphaComponent(0.6), red.withAlphaComponent(0.25), red.withAlphaComponent(0)],
        locations: [0.3, 0.55, 1],
        center: center,
        radius: haloRadius
      )
      let r = beaconRadius
      cg.saveGState()
      cg.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
      cg.clip()
      radialGradient(
        cg,
        colors: [.white, red.blended(with: .white, amount: 0.35), red],
        locations: [0, 0.4, 1],
        center: CGPoint(x: center.x - r * 0.35, y: center.y - r * 0.4),
        radius: r * 1.5
      )
      cg.restoreGState()
    }
  }

  // MARK: Ground shadow

  /// The shadow on the ground, drawn in the map's plane (up is the map's up), centred on the
  /// coordinate: a soft contact shadow round the base, and the mast's longer, fainter shadow
  /// cast toward the lower right, away from the upper-left light the mast is shaded by. A
  /// selected mast also gets a ring on the ground in the theme's accent.
  @MainActor
  func renderGround() -> UIImage {
    let side = Self.groundSize
    let accent = isSelected ? palette().accent : nil
    let shown = side * Self.displayScale
    return UIGraphicsImageRenderer(size: CGSize(width: shown, height: shown), format: .preferred()).image { ctx in
      let cg = ctx.cgContext
      cg.scaleBy(x: Self.displayScale, y: Self.displayScale)
      let center = CGPoint(x: side / 2, y: side / 2)

      if let accent {
        let ring = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
        Self.radialGradient(
          cg,
          colors: [accent.withAlphaComponent(0.05), accent.withAlphaComponent(0.22)],
          locations: [0, 1],
          center: center,
          radius: 15
        )
        UIColor.white.withAlphaComponent(0.85).setStroke()
        cg.setLineWidth(4)
        cg.strokeEllipse(in: ring)
        accent.setStroke()
        cg.setLineWidth(2)
        cg.strokeEllipse(in: ring)
      }

      // The cast shadow: an ellipse along the light, darkest at the foot.
      let angle = CGFloat.pi * 32 / 180
      let length: CGFloat = 25
      cg.saveGState()
      cg.translateBy(x: center.x, y: center.y)
      cg.rotate(by: angle)
      cg.translateBy(x: length * 0.42, y: 0)
      cg.scaleBy(x: length * 0.58, y: 4.6)
      if let gradient = Self.gradient([UIColor.black.withAlphaComponent(0.4), UIColor.black.withAlphaComponent(0)], [0, 1]) {
        cg.drawRadialGradient(
          gradient,
          startCenter: CGPoint(x: -0.62, y: 0),
          startRadius: 0,
          endCenter: .zero,
          endRadius: 1,
          options: []
        )
      }
      cg.restoreGState()

      // Contact shadow round the plinth, nudged the same way.
      cg.saveGState()
      cg.translateBy(x: center.x + 1, y: center.y + 0.6)
      cg.scaleBy(x: 9, y: 7)
      if let gradient = Self.gradient(
        [UIColor.black.withAlphaComponent(0.42), UIColor.black.withAlphaComponent(0.2), UIColor.black.withAlphaComponent(0)],
        [0, 0.5, 1]
      ) {
        cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
      }
      cg.restoreGState()
    }
  }

  // MARK: Helpers

  private static func gradient(_ colors: [UIColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors.map(\.cgColor) as CFArray,
      locations: locations
    )
  }

  private static func radialGradient(
    _ cg: CGContext,
    colors: [UIColor],
    locations: [CGFloat],
    center: CGPoint,
    radius: CGFloat
  ) {
    guard let gradient = gradient(colors, locations) else { return }
    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
  }

  private static func linearGradient(
    _ cg: CGContext,
    colors: [UIColor],
    locations: [CGFloat],
    from start: CGPoint,
    to end: CGPoint
  ) {
    guard let gradient = gradient(colors, locations) else { return }
    cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }
}

private extension UIColor {
  /// This colour moved `amount` of the way toward `other`.
  func blended(with other: UIColor, amount: CGFloat) -> UIColor {
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
          other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
    return UIColor(
      red: r1 + (r2 - r1) * amount,
      green: g1 + (g2 - g1) * amount,
      blue: b1 + (b2 - b1) * amount,
      alpha: a1 + (a2 - a1) * amount
    )
  }
}

// MARK: - Flashing

/// Flashes the quiet masts' red lights the way an aviation light does: a short faint flash every
/// couple of seconds, all in step. Only the light layers' opacity changes, so no sprite is redrawn
/// and no symbol re-placed. With Reduce Motion on, the lights glow steadily instead.
@MainActor
final class MastLightFlasher {
  /// One flash every `period`, lit for `onTime`: about 33 a minute, as tower lights flash.
  static let period: TimeInterval = 1.8
  static let onTime: TimeInterval = 0.3
  /// Faint: the light at full strength would outshine the traffic and trace beacons.
  static let litLevel = 0.7
  static let steadyLevel = 0.45

  private var isLit = false
  private var timer: Timer?
  private let apply: @MainActor () -> Void

  init(apply: @escaping @MainActor () -> Void) {
    self.apply = apply
  }

  /// The light layers' opacity for the flash's current step, faded with each pin.
  var opacity: NSExpression {
    let level = UIAccessibility.isReduceMotionEnabled ? Self.steadyLevel : (isLit ? Self.litLevel : 0)
    return NSExpression(format: "pinOpacity * %@", NSNumber(value: level))
  }

  func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.flash() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func flash() {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    isLit = true
    apply()
    Timer.scheduledTimer(withTimeInterval: Self.onTime, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isLit = false
        self?.apply()
      }
    }
  }
}
