import CairnServices
import SwiftUI

/// A theme's colour solver for names: it takes a picked or category colour and solves its
/// brightness (and, when needed, saturation) so the result clears WCAG AA against the surfaces a
/// name renders on. A hue swatch draws its saturation from the theme's band; a category or custom
/// colour stays exact when it already reads, else keeps its hue and moves only as far as it must.
///
/// All math is pure `Double` work — no UIKit, no SwiftUI environment — so it can run off the main
/// actor inside the message-text bake. Callers resolve their surface colors to relative-luminance
/// values and pass them in.
struct IdentityGamut: Equatable {
  /// Saturation band hue swatches draw from. The solver may dip below `lowerBound` only when a hue
  /// physically cannot reach the luminance a dark background demands at full saturation.
  let saturation: ClosedRange<Double>

  // MARK: - Tunables

  private static let degreesPerCircle = 360.0
  /// Floor the solver desaturates toward when a vivid hue cannot otherwise reach the luminance a
  /// dark surface requires. Near zero so legibility is always achievable (a gray reaches any
  /// luminance); colors only wash out this far in the rare high-contrast-on-dark case that needs it.
  private static let saturationReachFloor = 0.0
  /// Step used when relaxing saturation to reach an unreachable luminance target.
  private static let saturationRelaxStep = 0.04
  /// Fraction of the AA-feasible luminance span a dark-text colour may sit in: a variety of 0
  /// lands at `darkVarietyFloor` of the boundary, 1 at the boundary itself.
  private static let darkVarietyFloor = 0.45
  /// Upper luminance cap for light-text (dark-appearance) colors so they never go pure white.
  private static let lightLuminanceCap = 0.86
  /// Added to the target contrast ratio so rendering drift (HSB rounding, wide-gamut resolution)
  /// cannot drop the rendered color below the real AA floor.
  private static let contrastSafetyMargin = 0.35
  /// Binary-search iteration count for mapping a luminance target to a brightness value.
  private static let brightnessSearchIterations = 24
  /// Luminance above which a background is treated as "light" (dark text) rather than "dark".
  private static let appearanceMidpointLuminance = 0.3

  private static let contrastFlare = 0.05

  // MARK: - Public

  /// A picked or category colour, legible against every surface in `backgroundLuminances` (all
  /// expected to share the current appearance's polarity — e.g. the canvas and incoming-bubble
  /// luminances for one appearance), in light, dark and Increase Contrast.
  func color(for swatch: NodeAvatarColor, backgroundLuminances: [Double], highContrast: Bool) -> Color {
    let resolved = resolve(swatch: swatch, backgroundLuminances: backgroundLuminances, highContrast: highContrast)
    // Build the color from the exact sRGB components the solver evaluated, rather than letting
    // `Color(hue:saturation:brightness:)` re-derive them in a wider gamut: that would drift the
    // rendered luminance off the solved value and could undercut the AA floor the solver targeted.
    let rgb = Self.hsbToRGB(hue: resolved.hue, saturation: resolved.saturation, brightness: resolved.brightness)
    return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
  }

  /// The same values `color(for:...)` renders, for tests that assert contrast on a swatch.
  func resolve(swatch: NodeAvatarColor, backgroundLuminances: [Double], highContrast: Bool)
    -> (hue: Double, saturation: Double, brightness: Double) {
    let backgrounds = backgroundLuminances.isEmpty ? [1.0] : backgroundLuminances
    guard let fixed = swatch.fixedRGB else {
      return solve(
        hue: swatch.hueDegrees ?? 0,
        saturation: swatchSaturation,
        variety: Self.swatchVariety,
        backgrounds: backgrounds,
        highContrast: highContrast
      )
    }
    let red = Double((fixed >> 16) & 0xFF) / 255
    let green = Double((fixed >> 8) & 0xFF) / 255
    let blue = Double(fixed & 0xFF) / 255
    let exact = Self.rgbToHSB(red: red, green: green, blue: blue)
    let luminance = WCAGContrast.relativeLuminance(red: red, green: green, blue: blue)
    let floor = (highContrast ? WCAGContrast.increasedContrastFloor : WCAGContrast.aaFloor) + Self.contrastSafetyMargin
    if backgrounds.allSatisfy({ WCAGContrast.contrastRatio(luminance, $0) >= floor }) {
      return exact
    }
    // Too light for dark text, so take the lightest legible value (variety 1); too dark for light
    // text, so the darkest (variety 0). Both are the legible brightness nearest the pick.
    let darkText = (backgrounds.min() ?? 1.0) >= Self.appearanceMidpointLuminance
    return solve(
      hue: exact.hue,
      saturation: exact.saturation,
      variety: darkText ? 1 : 0,
      backgrounds: backgrounds,
      highContrast: highContrast
    )
  }

  /// Brightness draw for swatches: a little above the darkest legible value, so they read as rich
  /// colours on both surfaces.
  static let swatchVariety = 0.25

  /// Swatches sit three quarters of the way up the theme's saturation band, so neighbouring hues
  /// stay distinct from each other.
  var swatchSaturation: Double {
    saturation.lowerBound + (saturation.upperBound - saturation.lowerBound) * 0.75
  }

  /// The glyph (icon) color that reads on a fill of the given luminance: white when the fill is
  /// dark enough, otherwise near-black.
  static func glyphColor(forFillLuminance luminance: Double) -> Color {
    let whiteContrast = (1.0 + contrastFlare) / (luminance + contrastFlare)
    let blackContrast = (luminance + contrastFlare) / contrastFlare
    return whiteContrast >= blackContrast ? .white : Color(white: 0.1)
  }

  // MARK: - Solver

  /// The brightness (and, if a dark surface demands it, the saturation) at which `hue` clears the
  /// contrast floor against `backgrounds`. `variety` picks where in the legible range it lands:
  /// 0 the darkest legible value, 1 the lightest.
  private func solve(
    hue: Double,
    saturation baseSaturation: Double,
    variety: Double,
    backgrounds: [Double],
    highContrast: Bool
  ) -> (hue: Double, saturation: Double, brightness: Double) {
    let floor = (highContrast ? WCAGContrast.increasedContrastFloor : WCAGContrast.aaFloor) + Self.contrastSafetyMargin
    let darkText = (backgrounds.min() ?? 1.0) >= Self.appearanceMidpointLuminance

    if darkText {
      // Light surfaces -> dark text. Binding surface is the darkest (least headroom).
      let bindingBackground = backgrounds.min() ?? 1.0
      let maxLuminance = (bindingBackground + Self.contrastFlare) / floor - Self.contrastFlare
      let safeMax = max(maxLuminance, 0)
      let targetLuminance = safeMax * (Self.darkVarietyFloor + (1 - Self.darkVarietyFloor) * variety)
      let brightness = brightnessFor(luminance: targetLuminance, hue: hue, saturation: baseSaturation)
      return (hue, baseSaturation, brightness)
    } else {
      // Dark surfaces -> light text. Binding surface is the lightest (least headroom).
      let bindingBackground = backgrounds.max() ?? 0.0
      // Required luminance to clear the floor. Not capped: a light dark-mode bubble can demand a
      // near-white text, and undershooting it would breach AA.
      let requiredLuminance = max(floor * (bindingBackground + Self.contrastFlare) - Self.contrastFlare, 0)
      // A vivid hue caps the luminance it can reach at full brightness; desaturate as far as
      // needed to reach the requirement. Legibility outranks saturation in the rare
      // high-contrast-on-dark case that forces this; a gray reaches any luminance.
      var saturation = baseSaturation
      while saturation > Self.saturationReachFloor,
            Self.luminance(hue: hue, saturation: saturation, brightness: 1.0) < requiredLuminance {
        saturation = max(Self.saturationReachFloor, saturation - Self.saturationRelaxStep)
      }
      // Vary lighter than the minimum (lighter = more contrast = still AA), capped at what the
      // hue can reach so the target is always achievable.
      let reachableMax = Self.luminance(hue: hue, saturation: saturation, brightness: 1.0)
      let ceiling = max(requiredLuminance, min(reachableMax, Self.lightLuminanceCap))
      let targetLuminance = min(requiredLuminance + (ceiling - requiredLuminance) * variety, reachableMax)
      let brightness = brightnessFor(luminance: targetLuminance, hue: hue, saturation: saturation)
      return (hue, saturation, brightness)
    }
  }

  // MARK: - Luminance / brightness math

  private func brightnessFor(luminance target: Double, hue: Double, saturation: Double) -> Double {
    var low = 0.0
    var high = 1.0
    for _ in 0..<Self.brightnessSearchIterations {
      let mid = (low + high) / 2
      if Self.luminance(hue: hue, saturation: saturation, brightness: mid) < target {
        low = mid
      } else {
        high = mid
      }
    }
    return (low + high) / 2
  }

  private static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
    let rgb = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
    return WCAGContrast.relativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
  }

  /// Standard sRGB HSB-to-RGB conversion (`hue` in degrees). Matches `Color(hue:saturation:brightness:)`
  /// closely enough that the solver's luminance prediction tracks the rendered color; the
  /// `contrastSafetyMargin` absorbs any residual drift.
  private static func hsbToRGB(hue: Double, saturation: Double, brightness: Double) -> (red: Double, green: Double, blue: Double) {
    let h = (hue.truncatingRemainder(dividingBy: degreesPerCircle) + degreesPerCircle).truncatingRemainder(dividingBy: degreesPerCircle) / 60
    let sector = Int(h) % 6
    let fraction = h - Double(Int(h))
    let p = brightness * (1 - saturation)
    let q = brightness * (1 - fraction * saturation)
    let t = brightness * (1 - (1 - fraction) * saturation)
    switch sector {
    case 0: return (brightness, t, p)
    case 1: return (q, brightness, p)
    case 2: return (p, brightness, t)
    case 3: return (p, q, brightness)
    case 4: return (t, p, brightness)
    default: return (brightness, p, q)
    }
  }

  /// Standard sRGB RGB-to-HSB conversion (`hue` in degrees), the inverse of `hsbToRGB`.
  private static func rgbToHSB(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double, brightness: Double) {
    let maxComponent = max(red, green, blue)
    let delta = maxComponent - min(red, green, blue)
    guard delta > 0 else { return (0, 0, maxComponent) }
    let sector: Double = switch maxComponent {
    case red: ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
    case green: (blue - red) / delta + 2
    default: (red - green) / delta + 4
    }
    let hue = (sector * 60 + degreesPerCircle).truncatingRemainder(dividingBy: degreesPerCircle)
    return (hue, delta / maxComponent, maxComponent)
  }
}
