import CairnServices
import Charts
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// One trip the radio recorded, from the copy on this iPhone (`TripRecorder` copies what's missing when
/// it opens, and keeps copying while the radio still records it):
///
/// - The trail on a map, coloured by elevation (teal at its lowest, through the sunrise gold, to the
///   sunset orange at its highest: `MapLine.LineStyle.tripTrail`), the last point marked.
/// - Distance, moving time, average speed, climb, descent and the highest point, in one card.
/// - The elevation along the trail.
/// - Export GPX, Delete from iPhone, Delete from Radio.
struct TripDetailView: View {
  let id: String

  @Environment(\.appState) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  @State private var model: TripDetailModel
  @State private var cameraVersion = 0
  @State private var confirm: Confirm?

  private enum Confirm: Identifiable {
    case phone, radio
    var id: Self { self }
  }

  private static let teal = HomeStatusCards.cairnTeal
  private static let mapHeight: CGFloat = 260
  private static let chartHeight: CGFloat = 160

  init(id: String) {
    self.id = id
    _model = State(initialValue: TripDetailModel(id: id))
  }

  var body: some View {
    let recorder = appState.tripRecorder
    CardForm {
      header(recorder)
      if model.summary.points.count >= 1 {
        mapCard
        stats
        if model.summary.hasAltitude { elevationChart }
      } else if model.hasLoaded {
        notice(recorder)
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let log = model.log {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            if !model.summary.isEmpty {
              ShareLink(item: TripGPX(name: gpxName(log), summary: model.summary), preview: SharePreview(gpxName(log))) {
                Label(L10n.Map.Map.Trips.export, systemImage: "square.and.arrow.up")
              }
            }
            if log.syncedCount > 0 {
              Button(L10n.Map.Map.Trips.deletePhone, systemImage: "iphone", role: .destructive) { confirm = .phone }
            }
            if recorder.canCopy(log), !log.isRecording {
              Button(L10n.Map.Map.Trips.deleteRadio, systemImage: "sdcard", role: .destructive) { confirm = .radio }
            }
          } label: {
            Label(L10n.Map.Map.Trips.menu, systemImage: "ellipsis.circle")
          }
          .accessibilityIdentifier("trip.menu")
        }
      }
    }
    .confirmationDialog(
      confirm == .radio ? L10n.Map.Map.Trips.Confirm.radioTitle : L10n.Map.Map.Trips.Confirm.phoneTitle,
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
      titleVisibility: .visible,
      presenting: confirm
    ) { which in
      Button(which == .radio ? L10n.Map.Map.Trips.deleteRadio : L10n.Map.Map.Trips.deletePhone, role: .destructive) {
        guard let log = model.log else { return }
        Task {
          if which == .radio {
            _ = await recorder.deleteFromRadio(log)
          } else {
            await recorder.deleteCopy(log)
            dismiss()
          }
        }
      }
    } message: { which in
      Text(which == .radio ? L10n.Map.Map.Trips.Confirm.radioMessage : L10n.Map.Map.Trips.Confirm.phoneMessage)
    }
    .task(id: recorder.version) {
      await model.load(store: appState.connectionManager.persistenceStore)
      cameraVersion += 1
    }
    // copy what's missing; while the radio still records this trip, its new points every 10 s
    .task(id: appState.connectedDevice?.id) {
      await model.load(store: appState.connectionManager.persistenceStore)
      guard let log = model.log else { return }
      await recorder.copy(log)
      while !Task.isCancelled, model.log?.isRecording == true {
        try? await Task.sleep(for: .seconds(10))
        if Task.isCancelled { break }
        await recorder.refresh()
        await model.load(store: appState.connectionManager.persistenceStore)
        if let log = model.log { await recorder.copy(log) }
      }
    }
  }

  private var title: String {
    guard let log = model.log else { return L10n.Map.Map.Trips.title }
    return log.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }

  private func gpxName(_ log: TripLogDTO) -> String {
    let base = log.name.hasSuffix(".trk") ? String(log.name.dropLast(4)) : log.name
    return "Cairn \(base)"
  }

  // MARK: - Header

  /// When and where: the time span, the radio, and what's happening with the copy.
  @ViewBuilder
  private func header(_ recorder: TripRecorder) -> some View {
    if let log = model.log {
      VStack(alignment: .leading, spacing: 4) {
        Text(span(log))
          .font(.headline.monospacedDigit())
        Label(log.radioName, systemImage: "antenna.radiowaves.left.and.right")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let progress = recorder.copying[log.id], progress.total > 0, progress.done < progress.total {
          ProgressView(value: Double(progress.done), total: Double(progress.total)) {
            Text(L10n.Map.Map.Trips.Detail.copying).font(.caption)
          }
          .tint(Self.teal)
        } else if log.isRecording {
          Label(L10n.Map.Map.Trips.Detail.live, systemImage: "record.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
    }
  }

  private func span(_ log: TripLogDTO) -> String {
    let start = log.startedAt.formatted(date: .omitted, time: .shortened)
    let end = (model.summary.end ?? log.endedAt).formatted(date: .omitted, time: .shortened)
    return log.isRecording ? start : "\(start) – \(end)"
  }

  /// Nothing to draw yet: still on the radio (with no radio to copy it from), or no fix yet.
  private func notice(_ recorder: TripRecorder) -> some View {
    let onRadioOnly = model.log.map { !$0.isRecording && $0.pointCount > 0 && !recorder.canCopy($0) } ?? false
    return VStack(spacing: 8) {
      Image(systemName: onRadioOnly ? "sdcard" : "figure.hiking")
        .font(.largeTitle)
        .foregroundStyle(Self.teal)
      Text(onRadioOnly ? L10n.Map.Map.Trips.Detail.notCopied : L10n.Map.Map.Trips.Detail.noPoints)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .cardSurface(padding: 12)
  }

  // MARK: - Map

  /// The trail as runs of one colour each, by their place in the trip's elevation range in 16 steps (one
  /// solid teal line when there's no altitude). Each run starts where the last ended, so the line is
  /// unbroken; a run per step rather than a feature per point, since the map drops lines shorter than
  /// a pixel or two (a 20 m segment, zoomed out) and leaves gaps.
  private var trailLines: [MapLine] {
    let points = model.summary.thinned(to: 600)
    guard points.count >= 2 else { return [] }
    let altitudes = points.compactMap(\.altitude)
    let low = altitudes.min() ?? 0, span = max((altitudes.max() ?? 0) - low, 1)
    let steps = 16.0
    func step(_ point: TripSummary.Point) -> Double {
      guard let altitude = point.altitude else { return 0 }
      return min(steps - 1, ((altitude - low) / span * steps).rounded(.down))
    }
    var lines: [MapLine] = []
    var run = [points[0].coordinate]
    var runStep = step(points[0])
    for point in points.dropFirst() {
      run.append(point.coordinate)
      let next = step(point)
      if next != runStep {
        lines.append(MapLine(id: "trip-\(lines.count)", coordinates: run, style: .tripTrail, opacity: 1,
                             elevationFraction: altitudes.isEmpty ? 0 : (runStep + 0.5) / steps))
        run = [point.coordinate]
        runStep = next
      }
    }
    if run.count >= 2 {
      lines.append(MapLine(id: "trip-\(lines.count)", coordinates: run, style: .tripTrail, opacity: 1,
                           elevationFraction: altitudes.isEmpty ? 0 : (runStep + 0.5) / steps))
    }
    return lines
  }

  private var endPoint: [MapPoint] {
    guard let last = model.summary.points.last else { return [] }
    return [MapPoint(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000717f") ?? UUID(),
      coordinate: last.coordinate,
      pinStyle: .locationFixLatest,
      label: nil,
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil
    )]
  }

  private var region: MKCoordinateRegion {
    let coordinates = model.summary.thinned(to: 200).map(\.coordinate)
    // 1.7: room for the end pin above the line
    if coordinates.count > 1, let fit = coordinates.boundingRegion(paddingMultiplier: 1.7) { return fit }
    return MKCoordinateRegion(
      center: coordinates.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
      span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
  }

  private var mapCard: some View {
    CairnMapView(
      points: endPoint,
      lines: trailLines,
      mapStyle: .standard,
      isDarkMode: resolvedMapIsDark(
        preference: AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system,
        colorScheme: colorScheme
      ),
      isOffline: !appState.offlineMapService.isNetworkAvailable,
      showLabels: false,
      showsUserLocation: false,
      isInteractive: true,
      showsScale: true,
      hidesAttribution: true,
      isMuted: false,
      cameraRegion: .constant(region),
      cameraRegionVersion: cameraVersion,
      onPointTap: nil,
      onMapTap: nil,
      onCameraRegionChange: nil
    )
    .frame(height: Self.mapHeight)
    .clipShape(CardStyle.shape)
    // the map applies its camera when the version moves after it exists: fit the trail once it's up
    .onAppear { cameraVersion += 1 }
    .accessibilityLabel(L10n.Map.Map.Trips.title)
  }

  // MARK: - Numbers

  /// The trip's numbers in one card, laid out as the headers' readings are (`SensorReadingGrid`: each
  /// one's name above its value, spread evenly), worked out from the points as the radio works them out.
  private var stats: some View {
    SensorReadingGrid(items: statItems)
      .padding(.vertical, 4)
      .cardSurface(padding: 12)
  }

  private var statItems: [SensorReadingItem] {
    let summary = model.summary
    var items = [
      SensorReadingItem(id: "trip.distance", label: L10n.Map.Map.Trips.Stat.distance,
                        value: TripFormat.distance(summary.distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        tint: Self.teal),
      SensorReadingItem(id: "trip.moving", label: L10n.Map.Map.Trips.Stat.moving,
                        value: TripFormat.duration(summary.movingTime), systemImage: "timer", tint: Self.teal),
    ]
    if summary.movingTime >= 60 {
      items.append(SensorReadingItem(id: "trip.speed", label: L10n.Map.Map.Trips.Stat.averageSpeedTitle,
                                     value: TripFormat.speed(summary.distance / summary.movingTime),
                                     systemImage: "speedometer", tint: Self.teal))
    }
    if summary.hasAltitude {
      items.append(SensorReadingItem(id: "trip.climb", label: L10n.Map.Map.Trips.Stat.climb,
                                     value: TripFormat.altitude(summary.climb), systemImage: "arrow.up.right", tint: .green))
      items.append(SensorReadingItem(id: "trip.descent", label: L10n.Map.Map.Trips.Stat.descent,
                                     value: TripFormat.altitude(summary.descent), systemImage: "arrow.down.right", tint: .orange))
      if let highest = summary.highest {
        items.append(SensorReadingItem(id: "trip.highest", label: L10n.Map.Map.Trips.Stat.highest,
                                       value: TripFormat.altitude(highest), systemImage: "mountain.2", tint: .orange))
      }
    }
    if let start = summary.start, let end = summary.end, end > start {
      items.append(SensorReadingItem(id: "trip.time", label: L10n.Map.Map.Trips.Stat.time,
                                     value: TripFormat.duration(end.timeIntervalSince(start)), systemImage: "clock",
                                     tint: Self.teal))
    }
    return items
  }

  // MARK: - Chart

  /// Elevation along the trail: distance across (mi or km), altitude up (ft or m), Cairn's teal with
  /// the soft fill the app's other charts have.
  private var elevationChart: some View {
    let imperial = TripFormat.isImperial
    let distanceUnit: UnitLength = imperial ? .miles : .kilometers
    let altitudeUnit: UnitLength = imperial ? .feet : .meters
    let points = model.summary.thinned(to: 300).compactMap { point -> (x: Double, y: Double)? in
      guard let altitude = point.altitude else { return nil }
      return (Measurement(value: point.distance, unit: UnitLength.meters).converted(to: distanceUnit).value,
              Measurement(value: altitude, unit: UnitLength.meters).converted(to: altitudeUnit).value)
    }
    let low = points.map(\.y).min() ?? 0
    return VStack(alignment: .leading, spacing: 8) {
      Label(L10n.Map.Map.Trips.Chart.elevation, systemImage: "mountain.2")
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(Self.teal)
      Chart {
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
          AreaMark(x: .value("Distance", point.x), yStart: .value("Base", low), yEnd: .value("Elevation", point.y))
            .foregroundStyle(LinearGradient(colors: [Self.teal.opacity(0.25), Self.teal.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom))
          LineMark(x: .value("Distance", point.x), y: .value("Elevation", point.y))
            .foregroundStyle(Self.teal)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
      }
      .chartYScale(domain: .automatic(includesZero: false))
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
          AxisValueLabel()
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
          AxisValueLabel {
            if let x = value.as(Double.self) { Text("\(x.formatted(.number.precision(.fractionLength(0...1)))) \(imperial ? "mi" : "km")") }
          }
        }
      }
      .frame(height: Self.chartHeight)
    }
    .cardSurface(padding: 12)
  }
}

/// A trip's trail as a GPX track file, written when it's shared (`ShareLink`).
struct TripGPX: Transferable {
  let name: String
  let summary: TripSummary

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .gpx) { trip in
      let gpx = GPXDocument.renderTrack(
        points: trip.summary.points.map { ($0.latitude, $0.longitude, $0.altitude, $0.time) },
        name: trip.name
      )
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("\(trip.name).gpx")
      try Data(gpx.utf8).write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
