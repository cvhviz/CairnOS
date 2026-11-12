import CairnServices
import SwiftUI

/// A small "dB" chip for maps that colour their links by SNR. The key stays out of the way until
/// asked for: tapping the chip shows the colour scale in a popover beside it.
struct SNRLegendChip: View {
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Text(L10n.RemoteNodes.RemoteNodes.Status.snrBadgeUnit)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(minWidth: 44, minHeight: 36)
        .contentShape(.capsule)
        .liquidGlass(in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
    .buttonStyle(.plain)
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .accessibilityLabel(L10n.Map.Map.SnrLegend.accessibilityLabel)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      SNRLegendContent()
        .presentationCompactAdaptation(.popover)
    }
  }
}

/// The popover's key: one row per line colour, its quality name, and the SNR range it covers.
private struct SNRLegendContent: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.Map.Map.SnrLegend.title)
        .font(.headline)
      ForEach(SNRLegend.entries) { entry in
        HStack(spacing: 10) {
          Capsule()
            .fill(Color(uiColor: entry.quality.uiColor))
            .frame(width: 22, height: 5)
            .accessibilityHidden(true)
          Text(entry.quality.localizedLabel)
            .font(.subheadline)
          Spacer(minLength: 12)
          Text(entry.range)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding()
    .frame(minWidth: 220, alignment: .leading)
  }
}

// MARK: - Legend entries

/// The rows of the SNR key, derived from `MapLine.LineStyle.forSNR` (and through it
/// `SNRQuality`) rather than restating its thresholds, so the key always matches the lines.
enum SNRLegend {
  struct Entry: Identifiable, Equatable {
    let style: MapLine.LineStyle
    /// The weakest quality that draws in this style ("Good" rather than "Excellent" for green),
    /// for its colour and name.
    let quality: SNRQuality
    /// The SNR span this style covers, e.g. "−6 – 0 dB".
    let range: String

    var id: MapLine.LineStyle { style }
  }

  /// Whole-dB probe span. The thresholds are whole numbers well inside it; a value outside it
  /// only ever reads as the open-ended top or bottom row.
  private static let probe = -30...30

  /// Strongest first, as a signal key reads.
  static var entries: [Entry] {
    // Walk the probe from the top down and note where the line style changes. `SNRQuality`
    // compares with `>`, so each style's lower bound is the first value that falls below it.
    var runs: [(style: MapLine.LineStyle, quality: SNRQuality, upper: Int?, lower: Int?)] = []
    for snr in probe.reversed() {
      let quality = SNRQuality(snr: Double(snr))
      let style = MapLine.LineStyle.forSNR(Double(snr))
      if let last = runs.last, last.style == style {
        runs[runs.count - 1].quality = quality
        continue
      }
      if !runs.isEmpty { runs[runs.count - 1].lower = snr }
      runs.append((style, quality, runs.isEmpty ? nil : snr, nil))
    }
    let unit = L10n.RemoteNodes.RemoteNodes.Status.snrBadgeUnit
    return runs.map { run in
      let range = switch (run.lower, run.upper) {
      case let (lower?, upper?): "\(format(lower)) – \(format(upper)) \(unit)"
      case let (lower?, nil): "> \(format(lower)) \(unit)"
      case let (nil, upper?): "≤ \(format(upper)) \(unit)"
      case (nil, nil): unit
      }
      return Entry(style: run.style, quality: run.quality, range: range)
    }
  }

  private static func format(_ value: Int) -> String {
    value.formatted(.number.sign(strategy: .automatic))
  }
}

#Preview {
  SNRLegendContent()
}
