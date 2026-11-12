import SwiftUI

/// The cursor on the Modern, Analyzer and Waterfall plots: a tap on the plot puts it on that
/// moment, as a tap on the Radio Screen does, and a second tap near it clears it. It is kept as
/// seconds before the newest bar's end, so it slides along with the plot by the clock and reads
/// the bar under it as the bars go by.
enum SpectrumCursor {
  /// Where the cursor goes after a tap at `tapped`: off when the tap lands within two bars of
  /// where it already is, else there.
  static func toggled(_ current: TimeInterval?, tapped: TimeInterval, barSeconds: TimeInterval) -> TimeInterval? {
    let tapped = max(0, tapped)
    if let current, abs(current - tapped) <= barSeconds * 2 { return nil }
    return tapped
  }
}

/// The marker glyphs the plots draw, as an analyzer's: a diamond on the trace at the marker's
/// moment with a tag at the top of its line, and a ▼ over the peak.
enum SpectrumMarkerGlyph {
  /// A diamond centred on `point`.
  static func diamond(at point: CGPoint, radius: CGFloat = 4) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: point.x, y: point.y - radius))
    path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
    path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
    path.addLine(to: CGPoint(x: point.x - radius, y: point.y))
    path.closeSubpath()
    return path
  }

  /// ▼ with its tip at `point`.
  static func peak(at point: CGPoint) -> Path {
    var path = Path()
    path.move(to: point)
    path.addLine(to: CGPoint(x: point.x - 4, y: point.y - 7))
    path.addLine(to: CGPoint(x: point.x + 4, y: point.y - 7))
    path.closeSubpath()
    return path
  }

  /// A small filled tag reading `label`, its `anchor` corner at `point`.
  static func tag(in context: inout GraphicsContext, _ label: String, at point: CGPoint, color: Color, anchor: UnitPoint = .topLeading) {
    let text = context.resolve(Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.black))
    let size = text.measure(in: CGSize(width: 80, height: 20))
    let width = size.width + 6
    let height = size.height + 1
    let rect = CGRect(
      x: anchor.x > 0.5 ? point.x - width : point.x,
      y: anchor.y > 0.5 ? point.y - height : point.y,
      width: width,
      height: height
    )
    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
    context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
  }
}

/// What the bar under the cursor says, in the Radio Screen readout's words: its age, its loudest
/// and quietest readings and the floor it stood against; the longest line first, each shorter
/// than the last, for the chip to fit what it can.
enum SpectrumBarReadout {
  static func lines(frame: MiniSpectrumFrame, secondsBeforeNewest seconds: TimeInterval) -> [String]? {
    guard let index = frame.barIndex(secondsBeforeNewest: seconds) else { return nil }
    let bar = frame.bars[index]
    let when = SpectrumReadout.age(milliseconds: UInt32(clamping: Int(max(0, seconds) * 1000)))
    guard let dBm = bar.dBm else {
      let state = bar.isTX ? L10n.Tools.Tools.Spectrum.Device.Readout.transmitting : L10n.Tools.Tools.Spectrum.Device.Readout.noData
      return [when + " · " + state]
    }
    let high = Int(dBm.rounded())
    let low = Int((bar.low ?? dBm).rounded())
    let span = low < high ? "\(low)…\(high) dBm" : "\(high) dBm"
    let floor = (bar.floor ?? frame.floor)
    let nf = L10n.Tools.Tools.Spectrum.Device.Readout.nf(String(Int(floor.rounded())))
    return [
      [when, span, nf].joined(separator: " · "),
      [when, "\(high) dBm", nf].joined(separator: " · "),
      [when, "\(high) dBm"].joined(separator: " · "),
      when,
    ]
  }

  /// The level class of the bar's loudest reading over its floor, for the chip's stripe.
  static func level(frame: MiniSpectrumFrame, secondsBeforeNewest seconds: TimeInterval) -> SpectrumLevel? {
    guard let index = frame.barIndex(secondsBeforeNewest: seconds), let dBm = frame.bars[index].dBm else { return nil }
    return SpectrumLevel(dBAboveFloor: dBm - (frame.bars[index].floor ?? frame.floor))
  }
}

extension MiniSpectrumFrame {
  /// The bar `seconds` before the newest bar's end; nil off the plot.
  func barIndex(secondsBeforeNewest seconds: TimeInterval) -> Int? {
    guard barSeconds > 0, seconds >= 0 else { return nil }
    let back = Int((seconds / barSeconds).rounded(.down))
    let index = bars.count - 1 - back
    return bars.indices.contains(index) ? index : nil
  }
}

/// The cursor's readout over a plot's top left: a stripe in the bar's level colour, then the
/// longest of the readout's lines that fits, as the Radio Screen's chip.
struct SpectrumFrameReadoutChip: View {
  let lines: [String]
  let level: SpectrumLevel?

  var body: some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 1)
        .fill(level.map(SpectrumPalette.line) ?? SpectrumPalette.text3)
        .frame(width: 3)
      ViewThatFits(in: .horizontal) {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
          if index < lines.count - 1 {
            Text(line).fixedSize()
          } else {
            Text(line).truncationMode(.tail)
          }
        }
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.primary)
      .lineLimit(1)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 2)
    .fixedSize(horizontal: false, vertical: true)
    .background(SpectrumPalette.card, in: .rect(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SpectrumPalette.border, lineWidth: 1))
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("spectrum.cursor.readout")
  }
}
