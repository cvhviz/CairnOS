import CairnServices
import CoreLocation
import Foundation
import MeshCore

/// Builds the car's Scan for Nodes screen from what the app's own screen reads: the neighbour
/// directory (every node the radio hears directly, listed without a scan) and the app's one probe
/// coordinator (a scan asked from the phone, the car or Wardrive, or the wait before the next), so
/// the phone and the car always show the same nodes and the same scan. Car-safe text only: names,
/// counts, signal, "%d nearby" and "Next scan in %@", never a message. Pure over `CarPlayInputs`
/// and a `Source`.
enum CarPlayScanBuilder {
  /// What the Scan screen shows, read off `NeighbourDirectory` and `DiscoveryProbeCoordinator`.
  struct Source: Equatable {
    enum Phase: Equatable {
      case idle
      /// A probe is listening, wherever it was asked from; `secondsLeft` of its window, nil while
      /// the request is still waiting to go out.
      case probing(secondsLeft: Int?)
      /// The gate refuses another request until `until`: nothing can be sent before then.
      case coolingDown(until: Date)
    }

    /// The kind listed: the running probe's, else the one last picked in the car.
    var filter: NodeDiscoveryFilter = .repeaters
    var phase: Phase = .idle
    /// The neighbours of `filter` heard in the last two hours, strongest first.
    var neighbours: [ResolvedNeighbour] = []
    /// Confirmed neighbours of every kind heard in the last 10 minutes; nil before the radio's
    /// first snapshot.
    var nearbyCount: Int?
    /// How many answered the running probe so far.
    var answeredCount = 0
    /// The kind the last finished probe asked for: its row reads Scan Again.
    var lastProbedFilter: NodeDiscoveryFilter?
    /// The saved nodes' keys, for the New / Contacts split.
    var contactKeys: Set<Data> = []
    /// The saved nodes' names by whole key: a row resolved to exactly that key reads it.
    var nicknames: [Data: String] = [:]
    /// Text safe for the car: never a raw error that might mention the phone.
    var message: String?
    /// Wardrive is scanning each time the gate allows, started on the phone; the car can stop it.
    var isWardriving = false
    /// The radio's firmware can send a scan request (official MeshCore firmware 1.10+); without
    /// it the rows stay off and the heard nodes are still listed.
    var canScan = true
    /// Packets the radio heard during the last finished scan that never reached the app; nil when
    /// not measured.
    var radioMissed: Int?
    var now = Date.now
  }

  /// The car's view of the directory and the coordinator. There is one probe for the whole app,
  /// so one asked from the phone or by Wardrive shows here as running, and a cooldown any of them
  /// started holds the car's controls too.
  @MainActor
  static func source(
    directory: NeighbourDirectory,
    probeState: DiscoveryProbeCoordinator.State,
    lastSummary: DiscoveryProbeCoordinator.Summary?,
    filter: NodeDiscoveryFilter,
    contactKeys: Set<Data> = [],
    nicknames: [Data: String] = [:],
    message: String? = nil,
    isWardriving: Bool = false,
    canScan: Bool = true,
    now: Date
  ) -> Source {
    var source = Source(
      filter: filter,
      lastProbedFilter: lastSummary?.filter,
      contactKeys: contactKeys,
      nicknames: nicknames,
      message: message,
      isWardriving: isWardriving,
      canScan: canScan,
      radioMissed: lastSummary?.radioMissed,
      now: now
    )
    switch probeState {
    case .idle:
      break
    case let .probing(probe), let .interrupted(probe):
      // A scan that only listens, on a radio that can't send one (started on the phone): nothing
      // was asked to answer and the car can't scan this radio, so its screen stays as it was.
      guard !probe.listensOnly else { break }
      source.filter = probe.filter
      source.phase = .probing(secondsLeft: probe.endsAt.map { secondsLeft(until: $0, now: now) })
      if let sentAt = probe.sentAt {
        source.answeredCount = (directory.snapshot?.neighbours ?? []).count { neighbour in
          (neighbour.record.sources[.replyToUs]?.lastHeard).map { $0 >= sentAt } ?? false
        }
      }
    case let .coolingDown(until, _):
      source.phase = .coolingDown(until: until)
    }
    source.neighbours = NeighbourDirectory.sorted(directory.neighbours(source.filter, now: now), by: .snr)
    source.nearbyCount = directory.nearbyNowCount(now: now)
    return source
  }

  /// Why a scan can't start, in the link's own words: starting, connecting and syncing are not
  /// "not connected".
  static func blockedReason(_ inputs: CarPlayInputs) -> String? {
    if inputs.isStarting { return L10n.Localizable.CarPlay.Home.starting }
    guard !inputs.isRadioReady else { return nil }
    if inputs.connectionState != .disconnected { return HomeStatusLines.linkTitle(inputs.connectionState) }
    if let problem = CarPlaySnapshotBuilder.bluetoothProblem(inputs) { return problem }
    return inputs.hasAnyRadio ? L10n.Localizable.CarPlay.Scan.notReady : L10n.Localizable.CarPlay.Home.noRadioPaired
  }

  static func scan(_ inputs: CarPlayInputs, source: Source) -> CarPlaySnapshot.Scan {
    let reason = blockedReason(inputs)
    let controls = self.controls(source, reason: reason)
    let room = max(0, inputs.listLimit - controls.count)
    return .init(
      header: header(source),
      subtitle: subtitle(source, reason: reason),
      controls: controls,
      sections: sections(source, room: room)
    )
  }

  /// From `CarPlayInputs.scan` alone, for `CarPlaySnapshotBuilder.make`: the phase and why a
  /// scan can't start, without rows. The controller fills in the rest with `complete`.
  static func scan(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Scan {
    scan(inputs, source: Source(inputs.scan))
  }

  /// Puts the directory's rows and the coordinator's state into a snapshot made from
  /// `CarPlayInputs`: the Scan screen, and the Dashboard's Scan for Nodes row, which counts the
  /// answers while a probe listens.
  static func complete(_ snapshot: inout CarPlaySnapshot, inputs: CarPlayInputs, source: Source) {
    snapshot.scan = scan(inputs, source: source)
    guard case let .probing(secondsLeft) = source.phase else { return }
    let detail = progress(answered: source.answeredCount, secondsLeft: secondsLeft)
    snapshot.dashboard.options = snapshot.dashboard.options.map { option in
      guard option.kind == .scan else { return option }
      return .init(
        kind: option.kind,
        text: option.text,
        detail: detail,
        symbol: option.symbol,
        tint: option.tint,
        isEnabled: option.isEnabled,
        pushes: option.pushes
      )
    }
  }

  /// The headline: the answers so far while a probe listens, else how many nodes are near.
  static func header(_ source: Source) -> String {
    if case .probing = source.phase {
      return L10n.Tools.Tools.NodeDiscovery.Status.listening(source.answeredCount)
    }
    if let nearby = source.nearbyCount {
      return L10n.Localizable.CarPlay.Scan.nearby(nearby)
    }
    return L10n.Tools.Tools.Subtitle.nodeDiscovery
  }

  /// What sits under the headline: why the last scan failed, else why a scan can't start (the
  /// link, then the radio's firmware), else when the next can, else that the last scan may have
  /// missed replies (beside the wait while there is one, until the next scan), else the best and
  /// farthest nodes listed, else that nothing is heard yet.
  static func subtitle(_ source: Source, reason: String?) -> String? {
    if let message = source.message { return message }
    if let reason { return reason }
    if !source.canScan { return L10n.Localizable.CarPlay.Scan.unsupported }
    let missed: String? = if let radioMissed = source.radioMissed, radioMissed > 0, !isProbing(source.phase) {
      L10n.Localizable.CarPlay.Scan.repliesMayBeMissing
    } else {
      nil
    }
    if case let .coolingDown(until) = source.phase {
      return NodeRouteFormat.joined([L10n.Localizable.CarPlay.Scan.nextScanIn(timeLeft(until: until, now: source.now)), missed])
    }
    if let missed { return missed }
    let best = source.neighbours
      .compactMap { neighbour in neighbour.signal.map { (neighbour, $0) } }
      .max { $0.1 < $1.1 }
    if let best {
      let farthest = source.neighbours
        .compactMap { neighbour in distanceAndBearing(neighbour).map { (neighbour, $0.distance) } }
        .max { $0.1 < $1.1 }
      return NodeRouteFormat.joined([
        L10n.Localizable.CarPlay.Scan.best(
          NodeDiscoveryFormat.snr(best.1), CarPlaySnapshotBuilder.glanceName(name(best.0, nicknames: source.nicknames))
        ),
        farthest.map {
          L10n.Localizable.CarPlay.Scan.farthest(
            NodeDiscoveryFormat.distance($0.1), CarPlaySnapshotBuilder.glanceName(name($0.0, nicknames: source.nicknames))
          )
        },
      ])
    }
    if source.neighbours.isEmpty, source.phase == .idle {
      return L10n.Tools.Tools.NodeDiscovery.NothingHeard.title
    }
    return nil
  }

  /// One row per kind, replacing the card's segmented picker and ring button: a tap picks the
  /// kind and scans. The running kind's row becomes Stop with the countdown; the other waits.
  /// While the gate says wait, neither row can scan; on radio firmware that can't send a scan
  /// request, neither ever can, and each says why. While Wardrive runs it owns the scans, and one
  /// row stops it, as the phone's button does.
  static func controls(_ source: Source, reason: String?) -> [CarPlaySnapshot.ScanControl] {
    if source.isWardriving {
      return [.init(
        filter: source.filter,
        title: L10n.Tools.Tools.NodeDiscovery.wardriveStop,
        detail: L10n.Tools.Tools.NodeDiscovery.wardriveRunning,
        symbol: "stop.fill",
        tint: .critical,
        isEnabled: true,
        stops: true
      )]
    }
    return NodeDiscoveryFilter.allCases.map { filter in
      if case let .probing(secondsLeft) = source.phase, source.filter == filter {
        return .init(
          filter: filter,
          title: L10n.Tools.Tools.NodeDiscovery.stopButton,
          detail: progress(answered: source.answeredCount, secondsLeft: secondsLeft),
          symbol: "stop.fill",
          tint: .critical,
          isEnabled: true,
          stops: true
        )
      }
      let asked = source.lastProbedFilter == filter
      let kindTitle = filter == .repeaters ? L10n.Localizable.CarPlay.Scan.repeaters : L10n.Localizable.CarPlay.Scan.sensors
      return .init(
        filter: filter,
        // "Scan Again" as on the card, with the kind underneath so two such rows stay distinct.
        title: asked ? L10n.Tools.Tools.NodeDiscovery.scanAgain : kindTitle,
        detail: !source.canScan ? L10n.Localizable.CarPlay.Scan.unsupported : asked ? filter.localizedTitle : nil,
        symbol: CarPlayFeature.scan.symbol,
        tint: .feature(.scan),
        isEnabled: source.canScan && reason == nil && source.phase == .idle,
        stops: false
      )
    }
  }

  /// A probe is listening or waiting to go out.
  private static func isProbing(_ phase: Source.Phase) -> Bool {
    if case .probing = phase { true } else { false }
  }

  /// "Scanning · 2 heard · 9 s", or the answers alone while the request waits to go out.
  static func progress(answered: Int, secondsLeft: Int?) -> String {
    guard let secondsLeft else { return L10n.Tools.Tools.NodeDiscovery.Status.listening(answered) }
    return L10n.Localizable.CarPlay.Scan.progress(answered, secondsLeft)
  }

  /// The neighbours, strongest first, `room` of them. When the list holds both new nodes and
  /// contacts (the app's rule for showing its New / Contacts chips) they are split into those
  /// two sections, each titled with its full count; otherwise one section for the kind.
  static func sections(_ source: Source, room: Int) -> [CarPlaySnapshot.ScanSection] {
    let shown = Array(source.neighbours.prefix(room))
    guard !shown.isEmpty else { return [] }
    let total = source.neighbours.count
    let saved = { (neighbour: ResolvedNeighbour) in Self.isContact(neighbour, keys: source.contactKeys) }
    let newCount = source.neighbours.count { !saved($0) }
    let row = { (neighbour: ResolvedNeighbour) in self.row(neighbour, source: source) }
    if newCount > 0, newCount < total {
      return [
        (L10n.Tools.Tools.NodeDiscovery.Badge.new, newCount, false),
        (L10n.Contacts.Contacts.Discovery.Segment.contacts, total - newCount, true),
      ].compactMap { title, count, contacts in
        let rows = shown.filter { saved($0) == contacts }.map(row)
        guard !rows.isEmpty else { return nil }
        return .init(title: NodeRouteFormat.joined([title, count.formatted()]), rows: rows)
      }
    }
    return [.init(title: NodeRouteFormat.joined([source.filter.localizedTitle, total.formatted()]), rows: shown.map(row))]
  }

  static func row(_ neighbour: ResolvedNeighbour, source: Source) -> CarPlaySnapshot.ScanResultRow {
    let quality = SNRQuality(snr: neighbour.signal)
    return .init(
      publicKey: id(neighbour),
      name: name(neighbour, nicknames: source.nicknames),
      detail: detail(neighbour),
      barLevel: quality.barLevel,
      tint: CarPlayTint.state(quality.color),
      info: info(neighbour, source: source)
    )
  }

  /// A row's identity: the node's key once resolved, else the hash it was heard by.
  static func id(_ neighbour: ResolvedNeighbour) -> Data {
    neighbour.resolution.entry?.publicKey ?? neighbour.record.identity.bytes
  }

  /// The node's name, a saved one for exactly its resolved key first, as the phone's list names
  /// it: "Unidentified relay 3A7F" for a relay no node heard on this channel starts with, and
  /// "Ridge? · could be 3 nodes" for one several could be. A saved node sharing the hash never
  /// names it.
  static func name(_ neighbour: ResolvedNeighbour, nicknames: [Data: String] = [:]) -> String {
    neighbour.displayName(nicknames: nicknames) ?? neighbour.placeholderName(nicknames: nicknames)
  }

  /// A saved node: its resolved key is one of the contacts'.
  static func isContact(_ neighbour: ResolvedNeighbour, keys: Set<Data>) -> Bool {
    neighbour.resolution.entry.map { keys.contains($0.publicKey) } ?? false
  }

  /// "↓ 10.5 dB · ↑ 8.0 dB · 3.4 km · 47° NE": how this radio hears the node, how it hears this
  /// radio when a reply or a trace said, and where it is from where it was heard best.
  static func detail(_ neighbour: ResolvedNeighbour) -> String {
    NodeRouteFormat.joined([
      neighbour.signal.map { L10n.Tools.Tools.NodeDiscovery.snrDown(snrNumber($0)) },
      neighbour.record.uplinkSNR.map { L10n.Tools.Tools.NodeDiscovery.snrUp(snrNumber($0)) },
      place(neighbour),
    ])
  }

  /// The expanded card as a read-only screen: both directions with their quality, RSSI, when it
  /// was last heard, place, type, and status with how it was heard. Adding, checking the link and
  /// asking for a name are setup and stay on the phone.
  static func info(_ neighbour: ResolvedNeighbour, source: Source) -> [CarPlaySnapshot.InfoRow] {
    let record = neighbour.record
    let signal: (Double) -> String = { NodeRouteFormat.joined([NodeDiscoveryFormat.snr($0), SNRQuality(snr: $0).localizedLabel]) }
    var rows: [CarPlaySnapshot.InfoRow] = []
    if let snr = neighbour.signal {
      rows.append(.init(title: L10n.Tools.Tools.NodeDiscovery.youHearThem, detail: signal(snr)))
    }
    if let uplink = record.uplinkSNR {
      rows.append(.init(title: L10n.Tools.Tools.NodeDiscovery.theyHearYou, detail: signal(uplink)))
    }
    if let rssi = record.lastRSSI {
      rows.append(.init(title: L10n.RemoteNodes.RemoteNodes.History.rssi, detail: "\(rssi) dBm"))
    }
    rows.append(.init(title: L10n.Contacts.Contacts.Detail.lastHeard, detail: heardAgo(record.lastHeard, now: source.now)))
    // Measured from where the node was heard best, not from the car now: titled so, since no map
    // beside it shows the line it is measured along.
    if let place = place(neighbour) {
      rows.append(.init(title: L10n.Tools.Tools.NodeDiscovery.distanceWhenHeard, detail: place))
    }
    if let type = typeName(neighbour.nodeTypeRaw) {
      rows.append(.init(title: L10n.Contacts.Contacts.Detail.type, detail: type))
    }
    rows.append(.init(title: L10n.Contacts.Contacts.PathDetail.status, detail: status(neighbour, source: source)))
    return Array(rows.prefix(CarPlaySnapshotBuilder.maxInfoItems))
  }

  /// "New · Relaying · Answered your scan": saved or not, then each way the node was heard, as
  /// the phone's card badges it.
  static func status(_ neighbour: ResolvedNeighbour, source: Source) -> String {
    let record = neighbour.record
    let saved = isContact(neighbour, keys: source.contactKeys)
      ? L10n.Tools.Tools.NodeDiscovery.Badge.contact
      : L10n.Tools.Tools.NodeDiscovery.Badge.new
    return NodeRouteFormat.joined([
      saved,
      record.sources[.relay] != nil ? L10n.Tools.Tools.NodeDiscovery.Badge.relaying : nil,
      record.sources[.advert] != nil ? L10n.Tools.Tools.NodeDiscovery.Badge.advert : nil,
      record.sources[.replyToUs] != nil
        ? L10n.Tools.Tools.NodeDiscovery.Badge.answeredYourScan
        : record.sources[.replyToOthers] != nil ? L10n.Tools.Tools.NodeDiscovery.Badge.answeredAnotherScan : nil,
      record.hearsYou(now: source.now) ? L10n.Tools.Tools.NodeDiscovery.Badge.hearsYou : nil,
      record.isConfirmed ? nil : L10n.Tools.Tools.NodeDiscovery.Badge.heardOnce,
    ])
  }

  /// "Repeater", "Sensor"; nil when no advert or reply said.
  static func typeName(_ raw: UInt8) -> String? {
    if raw == sensorType { return L10n.Tools.Tools.NodeDiscovery.typeSensor }
    guard raw != 0, let type = ContactType(rawValue: raw) else { return nil }
    return type.localizedName
  }

  /// "3.4 km · 47° NE" from where the node was heard best to where it says it is.
  static func place(_ neighbour: ResolvedNeighbour) -> String? {
    guard let measured = distanceAndBearing(neighbour) else { return nil }
    // Whole degrees as well as the compass point, for aiming a directional antenna.
    return "\(NodeDiscoveryFormat.distance(measured.distance)) · \(GPSFormat.bearingText(measured.bearing))"
  }

  /// Metres and degrees from where this radio heard the node best to the node's advertised
  /// position, when both are known.
  static func distanceAndBearing(_ neighbour: ResolvedNeighbour) -> (distance: CLLocationDistance, bearing: Double)? {
    guard let fix = neighbour.record.heardFrom?.fix, let coordinate = neighbour.coordinate else { return nil }
    let origin = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
    guard origin.isValidFix else { return nil }
    let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
      .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    return (distance, HomeFormat.bearing(from: origin, to: coordinate))
  }

  /// "now", or "2m ago".
  static func heardAgo(_ date: Date, now: Date) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    let age = HomeFormat.age(interval)
    return interval < 60 ? age : L10n.Tools.Tools.NodeDiscovery.freshness(age)
  }

  /// "0:32": the time left until `date`.
  static func timeLeft(until date: Date, now: Date) -> String {
    Duration.seconds(secondsLeft(until: date, now: now)).formatted(.time(pattern: .minuteSecond))
  }

  /// Whole seconds left until `date`, rounded up so a countdown reaches 0 as it ends, never
  /// negative.
  static func secondsLeft(until date: Date, now: Date) -> Int {
    max(0, Int(date.timeIntervalSince(now).rounded(.up)))
  }

  /// MeshCore's ADV_TYPE_SENSOR; `ContactType` has no case for it.
  static let sensorType: UInt8 = 4

  /// "10.5": one decimal, the figure in "↓ 10.5 dB".
  static func snrNumber(_ snr: Double) -> String {
    snr.formatted(.number.precision(.fractionLength(1)))
  }
}

extension CarPlayScanBuilder.Source {
  /// What `CarPlayInputs.ScanState` carries: the kind, whether a probe listens and for how long,
  /// why the last one failed, and whether the radio can scan at all. No rows: those come from
  /// the directory.
  init(_ state: CarPlayInputs.ScanState) {
    self.init(
      filter: state.filter,
      phase: state.isScanning ? .probing(secondsLeft: state.secondsLeft) : .idle,
      message: state.message,
      canScan: state.canScan
    )
  }
}
