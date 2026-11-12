import Charts
import CoreLocation
import SwiftUI
import UIKit

/// Draws a card's picture of one of the phone's own views (`CarPlaySnapshot.Picture`): CarPlay
/// lets a communication app show no views of its own, only images, so the Spectrum and GPS tabs
/// are the phone's cards rendered into the car's card images. The phone's views are
/// used as they are where they draw from plain values (`SpectrumChannelChart`,
/// `SpectrumTrafficRow`, `GNSSCardHeader`, `GNSSCoordinateReadout`, `GNSSAccuracyRing`, the
/// compass rose's shapes); the rest are close copies of private ones (the header band, the
/// metric strip, the compass card, the map preview over a still `MKMapSnapshotter` image).
/// Rendered with `ImageRenderer` at the car's scale and the size the card asks for, once for a
/// light screen and once for a dark one, in one `UIImageAsset`, and cached by picture, so an
/// unchanged card is never drawn again. The card's title band sits under the picture, not over it.
@MainActor
enum CarPlayPictureImage {
  /// The chart's and the map's data, which the snapshot only names by revision. Set by the
  /// controller while the car is connected.
  static weak var source: CarPlayPictureSource?

  private struct Key: Hashable {
    let picture: CarPlaySnapshot.Picture
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
  }

  private static var cache: [Key: UIImageAsset] = [:]
  private static let cacheLimit = 24

  /// The picture for the car's traits, with its light and dark variants.
  static func image(_ picture: CarPlaySnapshot.Picture, size: CGSize, traits: UITraitCollection) -> UIImage? {
    let scale = traits.displayScale > 0 ? traits.displayScale : 2
    let key = Key(picture: picture, width: size.width, height: size.height, scale: scale)
    if let asset = cache[key] {
      return asset.image(with: traits)
    }
    let asset = UIImageAsset()
    for style in [UIUserInterfaceStyle.light, .dark] {
      guard let image = render(picture, size: size, scale: scale, style: style) else { return nil }
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
  static func render(_ picture: CarPlaySnapshot.Picture, size: CGSize, scale: CGFloat, style: UIUserInterfaceStyle) -> UIImage? {
    let view = PictureView(picture: picture, size: size, style: style, source: source, now: Date())
      .environment(\.colorScheme, style == .dark ? .dark : .light)
      // The phone's sizes a step down: a card is a phone card at half the width, and a car's
      // points are larger than a phone's.
      .dynamicTypeSize(.small)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    renderer.isOpaque = true
    return renderer.uiImage
  }

  /// The card fill every phone card shares (`CardBackground` without a backdrop).
  static func cardFill(_ style: UIUserInterfaceStyle) -> Color {
    Color(uiColor: UIColor.secondarySystemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
  }
}

// MARK: - Frame

/// A picture's frame: the card fill, and the content over it.
private struct PictureView: View {
  let picture: CarPlaySnapshot.Picture
  let size: CGSize
  let style: UIUserInterfaceStyle
  let source: CarPlayPictureSource?
  let now: Date

  private var padding: CGFloat {
    max(8, min(size.width, size.height) * 0.06)
  }

  var body: some View {
    Group {
      if case .gpsMap = picture {
        MapPictureView(map: source?.map, size: size, style: style)
      } else {
        content
          .padding(.horizontal, padding)
          .padding(.top, padding)
          .padding(.bottom, padding * 0.5)
          .frame(width: size.width, height: size.height, alignment: .topLeading)
          .clipped()
      }
    }
    .frame(width: size.width, height: size.height)
    .background(CarPlayPictureImage.cardFill(style))
  }

  @ViewBuilder private var content: some View {
    switch picture {
    case let .spectrumHeader(header):
      SpectrumHeaderPictureView(header: header)
    case let .spectrumReadings(readings):
      SpectrumReadingsPictureView(readings: readings)
    case .spectrumChart:
      if let source, let channel = source.channel {
        SpectrumChartPictureView(source: source, channel: channel, now: now)
      } else {
        PictureNote(text: L10n.Tools.Tools.Spectrum.waiting)
      }
    case .spectrumTraffic:
      SpectrumTrafficPictureView(packets: source?.recentPackets ?? [], now: now)
    case let .compass(compass):
      CompassPictureView(compass: compass)
    case let .gnssDevice(device):
      GNSSDevicePictureView(device: device)
    case .gpsMap:
      EmptyView()
    }
  }
}

/// A quiet line in place of a picture with nothing to draw yet.
private struct PictureNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A card's small title as the phone's Spectrum cards draw theirs: a tinted glyph beside an
/// uppercase caption.
private struct PictureCaption: View {
  let title: String
  let systemImage: String
  let tint: Color
  var trailing: String?

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
      Text(title)
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Spacer(minLength: 4)
      if let trailing {
        Text(trailing)
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

// MARK: - Spectrum

/// The phone's header band (`SpectrumHeaderBand`), one item a line as at the phone's narrowest:
/// the condition, the preset and frequency, then the modulation, power and a packet's airtime.
private struct SpectrumHeaderPictureView: View {
  let header: CarPlaySnapshot.SpectrumHeaderPicture

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(header.condition)
          .foregroundStyle(header.conditionSymbol == nil ? .secondary : .primary)
      } icon: {
        Image(systemName: header.conditionSymbol ?? "hourglass")
          .foregroundStyle(Color(uiColor: header.conditionTint.color(for: colorScheme == .dark ? .dark : .light)))
      }
      .font(.headline)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .padding(.bottom, 2)

      Text(header.preset)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      if !header.frequency.isEmpty {
        Text(header.frequency)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Group {
        if !header.modulation.isEmpty {
          line(header.modulation, systemImage: "waveform")
        }
        if let power = header.txPower {
          line(power, systemImage: "bolt.fill")
        }
        if !header.airtime.isEmpty {
          line(header.airtime, systemImage: "timer")
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The strip's compact label: a small glyph tight against its text.
  private func line(_ text: String, systemImage: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: systemImage)
        .imageScale(.small)
      Text(text)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }
}

/// The phone's metric strip two by two, as at its large text sizes: NOW, FLOOR, AIR, PKT/MIN.
private struct SpectrumReadingsPictureView: View {
  let readings: CarPlaySnapshot.SpectrumReadingsPicture

  @Environment(\.colorScheme) private var colorScheme

  private func color(_ tint: CarPlayTint) -> Color {
    Color(uiColor: tint.color(for: colorScheme == .dark ? .dark : .light))
  }

  var body: some View {
    Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6) {
      GridRow {
        now
        floor
      }
      Divider()
      GridRow {
        air
        rate
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var now: some View {
    MiniMetric(
      // "Last packet", as the phone's: the figure is a packet's, not a live reading.
      title: L10n.Tools.Tools.Spectrum.Meter.lastPacket,
      systemImage: "dot.radiowaves.left.and.right",
      tint: SpectrumPalette.link,
      value: readings.now,
      valueTint: readings.margin == nil ? .secondary : .primary
    ) {
      if let margin = readings.margin {
        HStack(spacing: 2) {
          Image(systemName: readings.isClear ? "checkmark.circle" : "exclamationmark.circle")
            .imageScale(.small)
          Text(margin)
        }
        .foregroundStyle(readings.isClear ? SpectrumPalette.good : .secondary)
        .modifier(MiniDetailStyle())
      }
      if let snr = readings.snr {
        Text(snr).modifier(MiniDetailStyle())
      }
    }
  }

  private var floor: some View {
    MiniMetric(
      title: L10n.Tools.Tools.Spectrum.Meter.floor,
      systemImage: "waveform.path",
      tint: SpectrumPalette.noise,
      value: readings.floor,
      valueTint: readings.hasFloor ? .primary : .secondary
    ) {
      if let trend = readings.trend, let symbol = readings.trendSymbol {
        HStack(spacing: 2) {
          Image(systemName: symbol)
            .imageScale(.small)
          Text(trend)
        }
        .modifier(MiniDetailStyle())
      }
      if readings.history.count >= 2 {
        Sparkline(values: readings.history)
          .frame(height: 12)
          .padding(.top, 1)
      }
    }
  }

  private var air: some View {
    let tint = readings.loadTint.map(color)
    return MiniMetric(
      title: L10n.Tools.Tools.Spectrum.Meter.air,
      systemImage: tint == nil ? "hourglass" : "exclamationmark.triangle.fill",
      tint: tint ?? .secondary,
      value: readings.air,
      valueTint: tint ?? (readings.split == nil ? .secondary : .primary)
    ) {
      if let split = readings.split, let arrows = readings.splitArrows {
        // "RX 1.2% · TX 0.1%", or the RX log's arrows where the column can't hold it.
        ViewThatFits(in: .horizontal) {
          Text(split).fixedSize().modifier(MiniDetailStyle())
          Text(arrows).modifier(MiniDetailStyle())
        }
      } else {
        Text(readings.split ?? L10n.Tools.Tools.Spectrum.measuring).modifier(MiniDetailStyle())
      }
      if let load = readings.load, let tint {
        Text(load).foregroundStyle(tint).modifier(MiniDetailStyle())
      }
    }
  }

  private var rate: some View {
    MiniMetric(
      title: L10n.Tools.Tools.Spectrum.Meter.packets,
      systemImage: "tray.and.arrow.down",
      tint: .purple,
      value: readings.rate,
      valueTint: readings.rate == "—" ? .secondary : .primary
    ) {
      Text(readings.count).modifier(MiniDetailStyle())
      if let peak = readings.peak {
        Text(peak).modifier(MiniDetailStyle())
      }
    }
  }
}

/// One reading of the strip (`SpectrumMiniMetric`): a tinted glyph beside an uppercase caption,
/// the value, and up to two short lines under it.
private struct MiniMetric<Details: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  let value: String
  var valueTint: Color = .primary
  @ViewBuilder let details: () -> Details

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.caption2.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      Text(value)
        .font(.headline.monospacedDigit())
        .foregroundStyle(valueTint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      details()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A line under a strip reading (`SpectrumMiniDetail`): small, quiet, one line.
private struct MiniDetailStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

/// The FLOOR reading's history line, drawn as the phone draws it: at least a 4 dB span, centred,
/// so a steady floor is a flat line mid-box.
private struct Sparkline: View {
  let values: [Int]

  var body: some View {
    let low = Double(values.min() ?? 0)
    let high = Double(values.max() ?? 0)
    let pad = max(0, 4 - (high - low)) / 2 + 1
    Chart(Array(values.enumerated()), id: \.offset) { index, value in
      LineMark(x: .value("Reading", index), y: .value("dBm", value))
        .foregroundStyle(SpectrumPalette.noise)
        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)
    }
    .chartYScale(domain: (low - pad)...(high + pad))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
  }
}

/// The phone's Channel card: its title with the window, over the phone's own chart
/// (`SpectrumChannelChart`) drawn from the readings the car keeps.
private struct SpectrumChartPictureView: View {
  let source: CarPlayPictureSource
  let channel: LoRaChannelMath
  let now: Date

  var body: some View {
    let window = source.spectrumWindow
    VStack(alignment: .leading, spacing: 4) {
      PictureCaption(
        title: L10n.Tools.Tools.Spectrum.Figure.channel,
        systemImage: "chart.xyaxis.line",
        tint: SpectrumPalette.noise,
        trailing: window.shortTitle
      )
      SpectrumChannelChart(
        channel: channel,
        viewModel: source.spectrum,
        packets: source.spectrum.packets.elements,
        window: window,
        now: now,
        selectedPacketID: .constant(nil)
      )
      .font(.system(size: 9))
      // Room for the axis's "now" past the plot's right edge.
      .padding(.trailing, 6)
    }
  }
}

/// The phone's traffic table, newest first, in its stacked form, the one that fits a narrow card.
private struct SpectrumTrafficPictureView: View {
  let packets: [SpectrumPacket]
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      PictureCaption(title: L10n.Tools.Tools.Spectrum.Traffic.title, systemImage: "list.bullet", tint: SpectrumPalette.noise)
      if packets.isEmpty {
        PictureNote(text: L10n.Tools.Tools.Spectrum.Traffic.empty)
      } else {
        ForEach(Array(packets.enumerated()), id: \.element.id) { index, packet in
          if index > 0 {
            Divider()
          }
          SpectrumTrafficRow(packet: packet, now: now, stacked: true)
            .padding(.vertical, 2)
        }
        Spacer(minLength: 0)
      }
    }
  }
}

// MARK: - GPS

/// The phone's compass card (`GPSCompassCard`): the rose with N in amber, the needle in the
/// accent colour, the reading under it, and the course's marker on the ring. In the car the
/// needle follows the course; standing still the rose dims and says there is no heading.
private struct CompassPictureView: View {
  let compass: CarPlaySnapshot.CompassPicture

  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: "location.north.line")
        Text(L10n.Map.Map.Gps.heading)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.secondary)

      GeometryReader { geometry in
        let diameter = max(40, min(geometry.size.width, geometry.size.height))
        rose(diameter: diameter)
          .frame(width: diameter, height: diameter)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      VStack(spacing: 0) {
        Text(compass.reading)
          .font(.headline.monospacedDigit())
          .foregroundStyle(compass.course == nil ? Color.secondary : Color.primary)
        if let speed = compass.speed {
          Text(speed)
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.secondary)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.7)
    }
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
      .opacity(compass.course == nil ? 0.5 : 1)
      if let course = compass.course {
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: diameter * 0.08))
          .foregroundStyle(Color.green)
          .offset(y: -diameter / 2 + diameter * 0.04)
          .rotationEffect(.degrees(course))
        CompassNeedle()
          .fill(theme.accentColor)
          .frame(width: diameter * 0.5, height: diameter * 0.5)
          .rotationEffect(.degrees(course))
      }
    }
  }

  private func letters(diameter: CGFloat) -> some View {
    let radius = diameter / 2 - diameter * 0.15
    let points: [(CompassPoint, Double)] = [(.north, 0), (.east, 90), (.south, 180), (.west, 270)]
    return ZStack {
      ForEach(points, id: \.1) { point, degrees in
        Text(point.abbreviation)
          .font(.system(size: max(8, diameter * 0.11), weight: .bold))
          .foregroundStyle(point == .north ? Color.orange : Color.secondary)
          .offset(x: radius * sin(degrees * .pi / 180), y: -radius * cos(degrees * .pi / 180))
      }
    }
  }
}

/// The phone's device cards (`GNSSRadioHero`, `GNSSPhoneHero`) from the phone's own parts: the
/// header and state badge, the coordinate readout with its caption, and the phone's accuracy
/// ring; or the note that says why there is nothing to read.
private struct GNSSDevicePictureView: View {
  let device: CarPlaySnapshot.GNSSDevicePicture

  private var coordinate: CLLocationCoordinate2D? {
    guard let latitude = device.latitude, let longitude = device.longitude else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch device.side {
      case .radio:
        GNSSCardHeader(
          title: L10n.Map.Map.Gps.Dash.radio,
          systemImage: "antenna.radiowaves.left.and.right",
          color: .orange,
          detail: device.detail,
          status: device.status
        )
      case .phone:
        GNSSCardHeader(title: L10n.Map.Map.Gps.Dash.phone, systemImage: "iphone", color: .blue, status: device.status)
      }
      if let note = device.note {
        GNSSNote(note)
      } else {
        GNSSCoordinateReadout(coordinate: coordinate, caption: device.caption)
        if device.side == .phone {
          GNSSAccuracyRing(accuracy: device.accuracy, isApproximate: device.isApproximate)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The phone's map preview (`GNSSMapPreviewCard`) over a still snapshot: the radio's pin, the
/// phone's dot and the mesh nodes nearby in their avatar colours, under the "Map · 12" capsule.
private struct MapPictureView: View {
  let map: CarPlayPictureSource.MapPicture?
  let size: CGSize
  let style: UIUserInterfaceStyle

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let image = map?.images[style] ?? map?.images.values.first {
        Image(uiImage: image)
          .resizable()
          .frame(width: size.width, height: size.height)
      }
      ForEach(Array((map?.markers ?? []).enumerated()), id: \.offset) { _, marker in
        markerView(marker.kind)
          .position(marker.point)
      }
      HStack(spacing: 4) {
        Image(systemName: "map")
        Text(L10n.Localizable.Tabs.map)
        if let count = map?.nearbyCount, count > 0 {
          Text("· \(count)")
            .monospacedDigit()
        }
      }
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(CarPlayPictureImage.cardFill(style).opacity(0.9), in: Capsule())
      .padding(8)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .clipped()
  }

  @ViewBuilder
  private func markerView(_ kind: CarPlayPictureSource.MapMarker.Kind) -> some View {
    switch kind {
    case let .radio(name):
      // The radio's own avatar, as the phone card's pin: its colour, emoji or walkie-talkie.
      let tint = CarPlayAvatar.radioTint(name)
      let fill = tint.color(for: style)
      let glyph = Color(uiColor: CarPlayAvatar.glyphColor(on: tint, fill: fill))
      Group {
        if let emoji = CarPlayAvatar.emoji(CarPlayAvatar.companion(name)) {
          Text(emoji)
            .font(.system(size: 22 * 0.4, weight: .semibold))
        } else {
          Image(CarPlayAvatar.companionSymbol)
            .font(.system(size: 22 * 0.42, weight: .semibold))
        }
      }
      .foregroundStyle(glyph)
      .frame(width: 22, height: 22)
      .background(Color(uiColor: fill), in: AvatarPebble())
      .overlay(AvatarPebble().stroke(.white, lineWidth: 2))
      .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    case .phone:
      Circle()
        .fill(Color.blue)
        .frame(width: 12, height: 12)
        .overlay(Circle().stroke(.white, lineWidth: 2.5))
        .background(Circle().fill(Color.blue.opacity(0.2)).frame(width: 30, height: 30))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    case let .node(tint):
      Circle()
        .fill(Color(uiColor: tint.color(for: style)))
        .frame(width: 9, height: 9)
        .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
  }
}
