import SwiftUI

/// How much interference the channel carries, from how far the measured noise floor sits above
/// thermal noise. Every decibel of it is a decibel of sensitivity lost.
enum ChannelCondition {
  case quiet
  case someInterference
  case heavyInterference

  static let someInterferenceAbove = 3.0
  static let heavyInterferenceAbove = 10.0

  /// - Parameter desensitization: Noise floor above thermal noise, in dB.
  init(desensitization: Double) {
    if desensitization >= Self.heavyInterferenceAbove {
      self = .heavyInterference
    } else if desensitization >= Self.someInterferenceAbove {
      self = .someInterference
    } else {
      self = .quiet
    }
  }

  var title: String {
    switch self {
    case .quiet: L10n.Tools.Tools.Spectrum.Condition.quiet
    case .someInterference: L10n.Tools.Tools.Spectrum.Condition.some
    case .heavyInterference: L10n.Tools.Tools.Spectrum.Condition.heavy
    }
  }

  var systemImage: String {
    switch self {
    case .quiet: "checkmark.circle.fill"
    case .someInterference: "exclamationmark.triangle.fill"
    case .heavyInterference: "xmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .quiet: SpectrumPalette.good
    case .someInterference: SpectrumPalette.warning
    case .heavyInterference: SpectrumPalette.critical
    }
  }
}

/// Which way the noise floor has moved over the session: the later half of the readings against
/// the earlier half. Moves within a few decibels are the radio's averaging jitter, not a change.
/// (Carried over from the retired Noise Floor tool, which reported the same trend.)
enum NoiseTrend: Equatable {
  case rising
  case falling
  case steady

  static let threshold = 3.0
  /// Fewer readings than this are too few to split into halves worth comparing.
  static let minimumReadings = 4

  init(readings: [Double]) {
    guard readings.count >= Self.minimumReadings else {
      self = .steady
      return
    }
    let half = readings.count / 2
    let earlier = readings.prefix(half).reduce(0, +) / Double(half)
    let later = readings.suffix(half).reduce(0, +) / Double(half)
    if later > earlier + Self.threshold {
      self = .rising
    } else if later < earlier - Self.threshold {
      self = .falling
    } else {
      self = .steady
    }
  }

  var title: String {
    switch self {
    case .rising: L10n.Tools.Tools.Spectrum.Trend.rising
    case .falling: L10n.Tools.Tools.Spectrum.Trend.falling
    case .steady: L10n.Tools.Tools.Spectrum.Trend.steady
    }
  }
}

/// How far a reading stands above the floor, in Cairn's four level classes (`spec::levelClass`):
/// under +6 dB it is noise, then a signal, a strong one from +20 and a very strong one from +35.
/// NOW, the peak and the packet dots wear the class's color, as the radio's trace and PEAK do.
enum SpectrumLevel: Int, CaseIterable, Comparable {
  case noise
  case signal
  case strong
  case veryStrong

  /// Where the class starts, in dB over the floor (`spec::kLvlSignalDb`, `kLvlStrongDb`,
  /// `kLvlVStrongDb`); each edge belongs to the class above it.
  var from: Double {
    switch self {
    case .noise: -.infinity
    case .signal: 6
    case .strong: 20
    case .veryStrong: 35
    }
  }

  init(dBAboveFloor value: Double) {
    self = Self.allCases.last { value >= $0.from } ?? .noise
  }

  /// The class of `rssi` over `floor`, against Cairn's stand-in while the floor is uncalibrated.
  init(rssi: Double, floor: Double?) {
    self.init(dBAboveFloor: rssi - (floor ?? SpectrumStats.uncalibratedFloor))
  }

  /// Cairn's line colors: the accent teal, WARN and DANGER; nil for noise, which keeps the text's
  /// own color.
  var color: Color? {
    switch self {
    case .noise: nil
    case .signal: SpectrumPalette.noise
    case .strong: SpectrumPalette.warning
    case .veryStrong: SpectrumPalette.critical
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Colors for the spectrum tool, each doing one job, in Cairn's own values (`ThemePalette.h`,
/// the Dark and Light themes). Conditions and loads wear the status colors, always beside an icon
/// or a caption. The noise floor is the chart's one continuous series and wears the accent teal of
/// Cairn's trace; packets wear their type's color. Every value keeps 4.5:1 against the plain card
/// in its scheme, so the colored words read as text.
enum SpectrumPalette {
  /// Cairn's OK, WARN and DANGER.
  static let good = Color(light: 0x237A3A, dark: 0x53C06B)
  static let warning = Color(light: 0xA35F00, dark: 0xE8A33D)
  static let critical = Color(light: 0xC0301F, dark: 0xE05544)

  /// Cairn's ACCENT teal.
  static let noise = Color(light: 0x0B7F74, dark: 0x15B6A6)
  /// The window's strongest packet: Cairn's dotted WARN peak line, the one amber.
  static let peak = warning
  static let grid = Color(light: 0xE1E0D9, dark: 0x3A3A3C)

  /// Cairn's packet type colors (`RadioMeters.cpp` `typeColour`).
  static let link = Color(light: 0x1A62C2, dark: 0x4F9DF7)
  static let magenta = Color(light: 0xB0357C, dark: 0xE072B0)
  static let violet = Color(light: 0x6A46B8, dark: 0xA784E0)
  /// Cairn's TEXT2, the dim grey acks wear.
  static let text2 = Color(light: 0x4A5159, dark: 0x828891)

  // The radio's Channel view (`SpecChannelView`, `SpecPaint`), as the device card draws it.

  /// Cairn's PANEL: the ground under the trace and the density.
  static let panel = Color(light: 0xE6E9ED, dark: 0x101214)
  /// Cairn's BORDER: the cells' outlines, the dotted gridlines and the lane's hairline.
  static let border = Color(light: 0xC4C9D0, dark: 0x2E3136)
  /// Cairn's TEXT3: the floor rule, the scale labels and the keys' quiet words.
  static let text3 = Color(light: 0x737A84, dark: 0x565B63)
  /// Cairn's ACCENT_BG: the selected chip's and the Channel pill's fill.
  static let accentBackground = Color(light: 0xCDEDEA, dark: 0x052D29)
  /// Cairn's CARD: the readout chip's ground.
  static let card = Color(light: 0xFFFFFF, dark: 0x1C1E21)
  /// The trace's average dots and the "avg" key: a pale teal (`levels().avgRef`), a reference
  /// under the band rather than the subject.
  static let avgRef = Color(light: 0x0F4B47, dark: 0x7ACCC6).opacity(0.67)

  /// The trace's min..max band in each level class (`levels().band`): the accent at 100 and 190
  /// of 255 over the panel, WARN at 150 and DANGER at 170.
  static func band(_ level: SpectrumLevel) -> Color {
    switch level {
    case .noise: noise.opacity(100.0 / 255)
    case .signal: noise.opacity(190.0 / 255)
    case .strong: warning.opacity(150.0 / 255)
    case .veryStrong: critical.opacity(170.0 / 255)
    }
  }

  /// A level class's line color (`levels().line`): the readout stripe and the level key. Noise is
  /// the accent at 160 of 255.
  static func line(_ level: SpectrumLevel) -> Color {
    level.color ?? noise.opacity(160.0 / 255)
  }
}

/// The density's heat ramp, the firmware's own table (`SpecMath.cpp` `HEAT`): matplotlib's inferno
/// at k / 31 in RGB565, expanded to 8 bits a channel. The same in both themes. Index 0 is never
/// drawn; occupancy cells use 8...31 (`spec::occIndex`), the key 3...31.
enum SpectrumHeat {
  static let rgb565: [UInt16] = [
    0x0000, 0x0002, 0x0824, 0x1046, 0x2069, 0x304B, 0x384C, 0x486D,
    0x588D, 0x60AD, 0x70CD, 0x80ED, 0x892D, 0x994C, 0xA96B, 0xB18B,
    0xC1CA, 0xCA09, 0xD247, 0xE2A6, 0xEB05, 0xEB64, 0xF3C2, 0xFC41,
    0xFCC0, 0xFD41, 0xFDC3, 0xFE25, 0xF6C9, 0xF74C, 0xF7B0, 0xFFF4,
  ]
  static var count: Int { rgb565.count }

  /// Entry `index` (clamped) as 0xRRGGBB, each channel's 5 or 6 bits widened to 8 by repeating its
  /// top bits, as RGB565 panels do.
  static func rgb(_ index: Int) -> Int {
    let value = Int(rgb565[min(max(index, 0), rgb565.count - 1)])
    let red = (value >> 11) & 0x1F
    let green = (value >> 5) & 0x3F
    let blue = value & 0x1F
    return (red << 3 | red >> 2) << 16 | (green << 2 | green >> 4) << 8 | (blue << 3 | blue >> 2)
  }

  static let colors: [Color] = (0..<rgb565.count).map { Color(hex: rgb($0)) }

  static func color(_ index: Int) -> Color {
    colors[min(max(index, 0), colors.count - 1)]
  }

  /// The key's ramp step at `position` of `steps` (`spec::heatKey`): index 3, the faintest, to 31.
  static func keyIndex(_ position: Int, steps: Int) -> Int {
    guard steps > 1 else { return count - 1 }
    return 3 + (position * (count - 4) + (steps - 1) / 2) / (steps - 1)
  }
}

private extension Color {
  init(light: Int, dark: Int) {
    self.init(uiColor: UIColor { traits in
      UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
    })
  }
}

/// Numbers with their units, through localized formats so the unit can be translated.
enum SpectrumFormat {
  static func dBm(_ value: Double) -> String {
    L10n.Tools.Tools.Spectrum.Value.dbm(value.rounded().formatted(.number.precision(.fractionLength(0))))
  }

  /// A whole-decibel difference with its sign: "+14 dB", "−3 dB".
  static func signedDB(_ value: Double) -> String {
    L10n.Tools.Tools.Spectrum.Value.db(value.rounded().formatted(.number.sign(strategy: .always(includingZero: true)).precision(.fractionLength(0))))
  }

  static func megahertz(_ hertz: Double) -> String {
    L10n.Tools.Tools.Spectrum.Value.mhz((hertz / 1_000_000).formatted(.number.precision(.fractionLength(3))))
  }

  static func kilohertz(_ hertz: Double) -> String {
    L10n.Tools.Tools.Spectrum.Value.khz((hertz / 1000).formatted(.number.precision(.fractionLength(0...1))))
  }
}
