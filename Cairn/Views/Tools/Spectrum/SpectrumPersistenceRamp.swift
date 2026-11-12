import SwiftUI

/// The Radio Screen's density colours: a real-time analyzer's persistence ramp, dark blue where a
/// level was barely seen through cyan and green to yellow and red where the column sat most of
/// its time. 32 steps, indexed by the radio's heat index (`SpectrumHeat`'s 0...31, 0 = nothing).
enum SpectrumPersistenceRamp {
  static let count = 32

  /// The ramp's anchors, as (index, red, green, blue).
  private static let stops: [(Int, Double, Double, Double)] = [
    (0, 0.04, 0.09, 0.32),
    (6, 0.08, 0.24, 0.85),
    (12, 0.10, 0.62, 1.00),
    (18, 0.20, 0.95, 0.55),
    (24, 0.95, 0.93, 0.15),
    (28, 1.00, 0.55, 0.05),
    (31, 1.00, 0.16, 0.05),
  ]

  /// The 32 colours, interpolated between the anchors.
  static let colors: [Color] = (0..<count).map { index in
    let (r, g, b) = rgb(index)
    return Color(red: r, green: g, blue: b)
  }

  static func color(_ index: Int) -> Color {
    colors[min(max(index, 0), count - 1)]
  }

  /// The ramp's colour at `index`, 0...31.
  static func rgb(_ index: Int) -> (red: Double, green: Double, blue: Double) {
    let index = min(max(index, 0), count - 1)
    var low = stops[0]
    var high = stops[stops.count - 1]
    for (position, stop) in stops.enumerated() where stop.0 <= index {
      low = stop
      high = position + 1 < stops.count ? stops[position + 1] : stop
    }
    guard high.0 > low.0 else { return (low.1, low.2, low.3) }
    let fraction = Double(index - low.0) / Double(high.0 - low.0)
    return (
      low.1 + (high.1 - low.1) * fraction,
      low.2 + (high.2 - low.2) * fraction,
      low.3 + (high.3 - low.3) * fraction
    )
  }

  /// The trace line over the density: the analyzers' yellow.
  static let trace = Color(red: 1.0, green: 0.90, blue: 0.25)
  /// The plot's own ground, whatever the app's appearance: an instrument's dark glass.
  static let panel = Color(red: 0.03, green: 0.04, blue: 0.09)
  static let grid = Color.white.opacity(0.16)
  static let label = Color.white.opacity(0.72)
  static let floorRule = Color.white.opacity(0.55)
}
