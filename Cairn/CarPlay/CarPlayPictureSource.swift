import CairnServices
import CoreLocation
import MapKit
import MeshCore
import UIKit

/// Moves a picture's revision on when its data changed, and not more often than
/// `minimumInterval`, so a busy mesh or a moving car redraws the Spectrum chart or the GPS map at
/// a calm pace rather than on every packet or fix. A change inside the interval is held back and
/// taken by the first call after it: the Spectrum and GPS tabs refresh every data interval while
/// they are open, so none is lost. The revision only ever grows, so a picture cached under an
/// old revision is never shown for new data. Pure over the dates it is given.
struct CarPlayPictureThrottle {
  let minimumInterval: TimeInterval
  private(set) var revision = 0
  private var key: AnyHashable?
  private var changedAt: Date?

  init(minimumInterval: TimeInterval) {
    self.minimumInterval = minimumInterval
  }

  /// The revision to draw for data described by `key` at `now`.
  mutating func revision(for key: AnyHashable, now: Date) -> Int {
    guard key != self.key else { return revision }
    if let changedAt, now.timeIntervalSince(changedAt) < minimumInterval, now >= changedAt {
      return revision
    }
    self.key = key
    changedAt = now
    revision += 1
    return revision
  }

  /// Forgets the data seen, for a different radio; the revision keeps growing.
  mutating func forget() {
    key = nil
    changedAt = nil
  }
}

/// What the car's Spectrum and GPS pictures are drawn from when their data is too big to carry in
/// the snapshot: the readings for the phone's own Channel chart and traffic table (a
/// `SpectrumViewModel`, fed by the Spectrum tab's statistics reads and the RX log), and the GPS
/// map preview's still snapshot. Runs only while its tab is open; the controller starts and
/// stops it.
@MainActor
final class CarPlayPictureSource {
  /// The least time between two drawings of the chart and traffic table: under the data
  /// interval, so each new reading can show, and never faster.
  static let spectrumInterval: TimeInterval = 8
  /// The least time between two map snapshots: each one loads map tiles, so a moving car
  /// re-frames the map a few times a minute at most.
  static let mapInterval: TimeInterval = 15
  /// How many of the newest packets the traffic card lists.
  static let trafficRows = 3

  /// The readings the phone's chart draws, at the car's reading pace.
  private(set) var spectrum = CarPlayPictureSource.makeSpectrumModel()
  /// The radio's channel, for the chart's packet widths.
  var channel: LoRaChannelMath?
  private var spectrumThrottle = CarPlayPictureThrottle(minimumInterval: spectrumInterval)
  private var packetTask: Task<Void, Never>?
  private(set) var isFollowingPackets = false

  /// The chart's window: the default the phone's Spectrum Settings picked.
  var spectrumWindow: SpectrumWindow {
    let raw = UserDefaults.standard.object(forKey: AppStorageKey.spectrumDefaultWindow.rawValue) as? Int
    return SpectrumWindow(rawValue: raw ?? AppStorageKey.defaultSpectrumWindow) ?? .oneMinute
  }

  private static func makeSpectrumModel() -> SpectrumViewModel {
    let model = SpectrumViewModel()
    model.readingInterval = TimeInterval(CarPlayRefreshGate.dataInterval.components.seconds)
    return model
  }

  // MARK: - Spectrum

  /// Starts over for a different radio or a new link.
  func resetSpectrum() {
    stopPackets()
    spectrum = Self.makeSpectrumModel()
    spectrumThrottle.forget()
  }

  /// One statistics reading, as the phone's Spectrum tab records it.
  func record(_ stats: RadioStats, at date: Date) {
    spectrum.record(noiseFloor: Double(stats.noiseFloor), at: date)
    spectrum.record(airtime: stats.txAirtimeSeconds, rx: stats.rxAirtimeSeconds, at: date)
  }

  /// The RX log's last hour, then each packet it records, as the phone's Spectrum tab follows
  /// it. Subscribing before reading back means a packet that lands in between is caught by one or
  /// the other. Packets don't redraw the car on their own; the next reading picks them up.
  func followPackets(_ service: RxLogService?) {
    guard !isFollowingPackets, let service else { return }
    isFollowingPackets = true
    let model = spectrum
    packetTask = Task {
      let stream = service.entryStream()
      let recent = await service.recentEntries(since: Date().addingTimeInterval(-SpectrumViewModel.packetLookback))
      guard !Task.isCancelled else { return }
      model.record(packets: recent.reversed().map(SpectrumPacket.init(entry:)))
      for await entry in stream {
        guard !Task.isCancelled else { return }
        model.record(packets: [SpectrumPacket(entry: entry)])
      }
    }
  }

  func stopPackets() {
    packetTask?.cancel()
    packetTask = nil
    isFollowingPackets = false
  }

  /// What the chart and the traffic table are drawn from; a change moves their revision on.
  private struct SpectrumKey: Hashable {
    let lastReading: Date?
    let lastPacket: UUID?
    let isCalibrating: Bool
  }

  /// The chart's and traffic table's revision, or nil while there is nothing to draw yet.
  func spectrumRevision(now: Date) -> Int? {
    let key = SpectrumKey(lastReading: spectrum.noise.last?.date, lastPacket: spectrum.latestPacket?.id, isCalibrating: spectrum.isCalibrating)
    guard key.lastReading != nil || key.lastPacket != nil || key.isCalibrating else { return nil }
    return spectrumThrottle.revision(for: key, now: now)
  }

  /// The newest packets, newest first, for the traffic card.
  var recentPackets: [SpectrumPacket] {
    Array(spectrum.packets.elements.suffix(Self.trafficRows).reversed())
  }

  // MARK: - Map

  /// A point on the map preview.
  struct MapMarker: Equatable {
    enum Kind: Equatable {
      /// The connected radio, drawn as its own avatar (the radio colour and its name's emoji).
      case radio(name: String)
      case phone
      case node(CarPlayTint)
    }

    let kind: Kind
    /// Where it sits on the snapshot, in points.
    let point: CGPoint
  }

  /// One map snapshot in both appearances, with its markers placed on it.
  struct MapPicture {
    let images: [UIUserInterfaceStyle: UIImage]
    let markers: [MapMarker]
    let nearbyCount: Int
  }

  private(set) var map: MapPicture?
  /// The map preview's revision; nil while there is no map to show.
  private(set) var mapRevision: Int?
  /// Called on the main actor when a new map is ready.
  var onMapReady: (() -> Void)?
  private var mapKey: MapKey?
  private var mapRequestedAt: Date?
  /// Maps drawn so far; only ever grows, so a cached picture is never shown for a new map.
  private var mapCount = 0
  private var mapTask: Task<Void, Never>?

  /// What the map is framed on, to about a hundred metres, so a moving car re-frames it only when
  /// it has really moved.
  private struct MapKey: Hashable {
    let radio: [Int]?
    let radioName: String?
    let phone: [Int]?
    let nodes: [Data]
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    static func rounded(_ coordinate: CLLocationCoordinate2D?) -> [Int]? {
      coordinate.map { [Int(($0.latitude * 1000).rounded()), Int(($0.longitude * 1000).rounded())] }
    }
  }

  /// Takes a new map snapshot when the radio or the phone moved, at most every `mapInterval`;
  /// no map at all without a position to centre on, as on the phone.
  func updateMap(
    radio: CLLocationCoordinate2D?,
    radioName: String? = nil,
    phone: CLLocationCoordinate2D?,
    nodes: [CarPlayNodesSource.Node],
    size: CGSize,
    scale: CGFloat,
    now: Date
  ) {
    guard let anchor = radio ?? phone else {
      mapTask?.cancel()
      mapTask = nil
      clearMap()
      return
    }
    let located = nodes.compactMap { node -> (node: CarPlayNodesSource.Node, coordinate: CLLocationCoordinate2D)? in
      guard let latitude = node.latitude, let longitude = node.longitude, latitude != 0 || longitude != 0 else { return nil }
      return (node, CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
    let nearby = GNSSMapFraming.nearby(located, coordinate: \.coordinate, around: anchor)
    let key = MapKey(
      radio: MapKey.rounded(radio),
      radioName: radioName,
      phone: MapKey.rounded(phone),
      nodes: nearby.map(\.node.publicKey),
      width: size.width,
      height: size.height,
      scale: scale
    )
    guard key != mapKey, mapTask == nil else { return }
    // Held back while the last map is recent: the next refresh asks again.
    if let last = mapRequestedAt, now >= last, now.timeIntervalSince(last) < Self.mapInterval { return }
    mapRequestedAt = now
    mapKey = key
    guard let region = Self.region(radio: radio, phone: phone, nodes: nearby.map(\.coordinate)) else { return }
    let points: [(MapMarker.Kind, CLLocationCoordinate2D)] = nearby.map { (.node(CarPlayAvatar.tint($0.node.type, name: $0.node.name)), $0.coordinate) }
      + (phone.map { [(.phone, $0)] } ?? [])
      + (radio.map { [(.radio(name: radioName ?? ""), $0)] } ?? [])
    mapTask = Task { [weak self] in
      var images: [UIUserInterfaceStyle: UIImage] = [:]
      var markers: [MapMarker] = []
      for style in [UIUserInterfaceStyle.light, .dark] {
        guard let snapshot = await Self.snapshot(region: region, size: size, scale: scale, style: style) else { break }
        images[style] = snapshot.image
        if markers.isEmpty {
          markers = points.map { MapMarker(kind: $0.0, point: snapshot.point(for: $0.1)) }
        }
      }
      guard let self, !Task.isCancelled else { return }
      mapTask = nil
      guard images.count == 2 else {
        // Offline or the tiles failed: no map rather than an old one framed somewhere else, and
        // try again on a later refresh.
        clearMap()
        return
      }
      map = MapPicture(images: images, markers: markers, nearbyCount: nearby.count)
      mapCount += 1
      mapRevision = mapCount
      onMapReady?()
    }
  }

  /// Off the GPS tab: the map is dropped with its pins, so coming back after a drive never shows
  /// the old place as now; the next visit draws a fresh one at once.
  func stopMap() {
    mapTask?.cancel()
    mapTask = nil
    mapRequestedAt = nil
    clearMap()
  }

  private func clearMap() {
    map = nil
    mapRevision = nil
    mapKey = nil
  }

  /// The phone preview's framing (`GNSSMapFraming.region`): the card's title band sits under the
  /// picture, so the whole picture is map.
  static func region(
    radio: CLLocationCoordinate2D?,
    phone: CLLocationCoordinate2D?,
    nodes: [CLLocationCoordinate2D]
  ) -> MKCoordinateRegion? {
    GNSSMapFraming.region(for: [radio, phone].compactMap(\.self) + nodes)
  }

  private static func snapshot(region: MKCoordinateRegion, size: CGSize, scale: CGFloat, style: UIUserInterfaceStyle) async -> MKMapSnapshotter.Snapshot? {
    let options = MKMapSnapshotter.Options()
    options.region = region
    options.size = size
    options.traitCollection = UITraitCollection {
      $0.displayScale = scale
      $0.userInterfaceStyle = style
    }
    // The phone preview's muted map, without the shops and fuel stations a driver would read.
    let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
    configuration.pointOfInterestFilter = .excludingAll
    configuration.showsTraffic = false
    options.preferredConfiguration = configuration
    return try? await MKMapSnapshotter(options: options).start()
  }
}
