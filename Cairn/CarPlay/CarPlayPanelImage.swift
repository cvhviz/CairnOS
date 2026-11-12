import SwiftUI
import UIKit

/// Draws a rich card's picture (`CarPlaySnapshot.Panel`) the way the phone draws its dashboard
/// cards: the card fill with a wash of the feature's colour, the feature's icon tile and name,
/// then the readings as `MetricTile` lays them out, label quiet and value loud, two to a line.
/// Rendered with SwiftUI at the car's scale and the size the card asks for, once for a light
/// screen and once for a dark one, in one `UIImageAsset`, so the picture follows the car's
/// appearance. The bottom of the picture is left to the card's title band.
@MainActor
enum CarPlayPanelImage {
  /// The card's picture for a car that has not reported one: the image slot above the title band
  /// of a portrait card about four to a line on an 800-point screen.
  static let fallbackSize = CGSize(width: 165, height: 154)
  /// A reading longer than this takes a line of its own, as a position does.
  static let wideValueLength = 9

  private struct Key: Hashable {
    let panel: CarPlaySnapshot.Panel
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
  }

  /// The pictures drawn last, so an unchanged card (or the other appearance) is not drawn again.
  private static var cache: [Key: UIImageAsset] = [:]
  private static let cacheLimit = 32

  /// The panel's picture for the car's traits, with its light and dark variants.
  static func image(_ panel: CarPlaySnapshot.Panel, size: CGSize, traits: UITraitCollection) -> UIImage? {
    let scale = traits.displayScale > 0 ? traits.displayScale : 2
    let key = Key(panel: panel, width: size.width, height: size.height, scale: scale)
    if let asset = cache[key] {
      return asset.image(with: traits)
    }
    let asset = UIImageAsset()
    for style in [UIUserInterfaceStyle.light, .dark] {
      guard let image = render(panel, size: size, scale: scale, style: style) else { return nil }
      asset.register(image, with: UITraitCollection {
        $0.displayScale = scale
        $0.userInterfaceStyle = style
      })
    }
    if cache.count >= cacheLimit { cache.removeAll() }
    cache[key] = asset
    return asset.image(with: traits)
  }

  /// One appearance's picture, `size` points at `scale`.
  static func render(_ panel: CarPlaySnapshot.Panel, size: CGSize, scale: CGFloat, style: UIUserInterfaceStyle) -> UIImage? {
    let view = PanelView(panel: panel, size: size, style: style)
      .environment(\.colorScheme, style == .dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    renderer.isOpaque = true
    return renderer.uiImage
  }

  /// The readings in lines of two, a wide one (a position) on a line of its own.
  static func lines(_ metrics: [CarPlaySnapshot.Metric]) -> [[CarPlaySnapshot.Metric]] {
    var lines: [[CarPlaySnapshot.Metric]] = []
    var pending: CarPlaySnapshot.Metric?
    for metric in metrics {
      if isWide(metric) {
        if let waiting = pending { lines.append([waiting]) }
        pending = nil
        lines.append([metric])
      } else if let waiting = pending {
        lines.append([waiting, metric])
        pending = nil
      } else {
        pending = metric
      }
    }
    if let pending { lines.append([pending]) }
    return lines
  }

  static func isWide(_ metric: CarPlaySnapshot.Metric) -> Bool {
    metric.isWide || metric.value.count > wideValueLength
  }

  /// An SF Symbol, or the app's own symbol from the asset catalog.
  static func symbol(_ name: String) -> Image {
    UIImage(systemName: name) == nil && UIImage(named: name) != nil ? Image(name) : Image(systemName: name)
  }
}

private struct PanelView: View {
  let panel: CarPlaySnapshot.Panel
  let size: CGSize
  let style: UIUserInterfaceStyle

  /// The readings' lines that fit the picture at the smallest legible size; the lines past the fit
  /// are left out rather than cut off at the edge.
  private var lines: [[CarPlaySnapshot.Metric]] {
    let all = CarPlayPanelImage.lines(panel.metrics)
    let fitting = Int(((contentHeight / Self.minimumUnit) - Self.headingUnits) / Self.lineUnits)
    return Array(all.prefix(max(1, fitting)))
  }

  /// Heading height, and each line's: a label (0.8), a value (1.35) and space or a gauge (0.55),
  /// in units of `unit`.
  private static let headingUnits: CGFloat = 1.5
  private static let lineUnits: CGFloat = 2.7
  /// The smallest body size a driver can read at a glance.
  private static let minimumUnit: CGFloat = 7

  private var padding: CGFloat {
    max(6, min(size.width, size.height) * 0.06)
  }

  private var contentHeight: CGFloat {
    size.height - padding * 1.5
  }

  /// The body text size everything else is scaled from: as large as the lines allow, within the
  /// width two values need.
  private var unit: CGFloat {
    let lineCount = CGFloat(lines.count)
    let byHeight = contentHeight / (Self.headingUnits + lineCount * Self.lineUnits)
    let byWidth = (size.width - padding * 3) / 2 / 5.5
    return max(Self.minimumUnit, min(byHeight, byWidth, 22))
  }

  private func color(_ tint: CarPlayTint) -> Color {
    Color(uiColor: tint.color(for: style))
  }

  var body: some View {
    let unit = unit
    VStack(alignment: .leading, spacing: unit * 0.45) {
      header(unit)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .top, spacing: padding) {
          ForEach(line, id: \.id) { metric in
            MetricView(metric: metric, unit: unit, style: style)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if line.count == 1, !CarPlayPanelImage.isWide(line[0]) {
            Color.clear.frame(maxWidth: .infinity)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, padding)
    .padding(.top, padding)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .clipped()
    .background {
      ZStack {
        Color(uiColor: UIColor.secondarySystemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
        LinearGradient(
          colors: [color(panel.tint).opacity(style == .dark ? 0.28 : 0.16), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
  }

  /// The feature's icon tile (`IconTile`), its name, and a dot in the state's colour.
  private func header(_ unit: CGFloat) -> some View {
    let side = unit * 1.5
    return HStack(spacing: unit * 0.4) {
      CarPlayPanelImage.symbol(panel.symbol)
        .font(.system(size: side * 0.52, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .background(color(panel.tint).gradient, in: .rect(cornerRadius: side * 0.25, style: .continuous))
      Text(panel.heading)
        .font(.system(size: unit * 0.95, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Spacer(minLength: 0)
      if let status = panel.status {
        Circle()
          .fill(color(status))
          .frame(width: unit * 0.6, height: unit * 0.6)
      }
    }
  }
}

/// One reading, as the phone's `MetricTile`: glyph and label, then the value with its caption,
/// then the gauge.
private struct MetricView: View {
  let metric: CarPlaySnapshot.Metric
  let unit: CGFloat
  let style: UIUserInterfaceStyle

  private func color(_ tint: CarPlayTint) -> Color {
    Color(uiColor: tint.color(for: style))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: unit * 0.12) {
      HStack(spacing: unit * 0.25) {
        CarPlayPanelImage.symbol(metric.symbol)
        Text(metric.label)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
      .font(.system(size: unit * 0.72, weight: .medium))
      .foregroundStyle(.secondary)

      HStack(alignment: .firstTextBaseline, spacing: unit * 0.25) {
        if case let .bars(level, tint) = metric.gauge {
          Image(systemName: "cellularbars", variableValue: level)
            .font(.system(size: unit * 0.95, weight: .semibold))
            .foregroundStyle(color(tint))
        }
        Text(metric.value)
          .font(.system(size: unit * 1.3, weight: .semibold, design: .rounded))
          .foregroundStyle(metric.valueTint.map { AnyShapeStyle(color($0)) } ?? AnyShapeStyle(.primary))
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .layoutPriority(1)
        if let caption = metric.caption, !caption.isEmpty {
          Text(caption)
            .font(.system(size: unit * 0.7))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
      }

      if case let .meter(share, tint) = metric.gauge {
        GeometryReader { proxy in
          Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
              Capsule()
                .fill(color(tint))
                .frame(width: proxy.size.width * min(1, max(0, share)))
            }
        }
        .frame(height: unit * 0.32)
      }
    }
  }
}
