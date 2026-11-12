import CoreLocation
import Foundation
import CairnServices

/// One neighbour as the results panel shows it: the row plus what the stored records add, where
/// the node is and how far, and whether it is already a contact.
struct NodeDiscoveryEntry: Identifiable {
  let result: NodeDiscoveryResult
  /// The node's known position, nil when no record has one or the row names no single node.
  let coordinate: CLLocationCoordinate2D?
  /// The user hid this node from the map it would be drawn on.
  let isHiddenFromMap: Bool
  /// Meters from where this radio heard the node best (`NodeDiscoveryResult.heardFrom`), when
  /// both positions are known.
  let distance: CLLocationDistance?
  /// Degrees clockwise from north, from where the node was heard to the node, when both
  /// positions are known.
  let bearing: Double?
  let isContact: Bool

  /// The row's key (`NodeDiscoveryResult.key`): the node's key, or the relay's hash.
  var id: Data { result.key }
  /// The node's key when the row names one node.
  var publicKey: Data? { result.publicKey }
  /// Not a contact yet: the "New" badge, and what the New filter keeps.
  var isNew: Bool { !isContact }
}

/// Which rows the results panel lists. Every row is a direct neighbour of the listed kind, so the
/// useful split is between nodes already saved and the ones worth a look.
enum NodeDiscoveryListFilter: String, CaseIterable {
  case all
  case new
  case contacts

  var localizedTitle: String {
    switch self {
    case .all: L10n.Contacts.Contacts.Discovery.Segment.all
    case .new: L10n.Tools.Tools.NodeDiscovery.Badge.new
    case .contacts: L10n.Contacts.Contacts.Discovery.Segment.contacts
    }
  }

  func includes(_ entry: NodeDiscoveryEntry) -> Bool {
    switch self {
    case .all: true
    case .new: entry.isNew
    case .contacts: entry.isContact
    }
  }
}

/// Pure building blocks of the results panel, kept out of the views so the tests can pin them.
enum NodeDiscoveryEntries {
  /// The entries for `results`, positioned where each node advertised itself in a packet this
  /// radio received (the rule the map uses; a stored record's position never counts) and
  /// measured from where each was heard. A row no single node could be pinned on has no position.
  /// A node heard without a fresh fix has no distance: the phone has moved on since, so measuring
  /// from where it is now would say how far the node is from here, not how far it carried.
  static func make(
    results: [NodeDiscoveryResult],
    contacts: [Data: ContactDTO],
    discovered: [Data: DiscoveredNodeDTO],
    hiddenKeys: Set<Data> = []
  ) -> [NodeDiscoveryEntry] {
    results.map { result in
      let coordinate = NodeDiscoveryMapBuilder.coordinate(for: result)
      let origin = result.heardFrom.map(\.coordinate).flatMap { $0.isValidFix ? $0 : nil }
      var distance: CLLocationDistance?
      var bearing: Double?
      if let origin, let coordinate {
        distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
          .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        bearing = HomeFormat.bearing(from: origin, to: coordinate)
      }
      return NodeDiscoveryEntry(
        result: result,
        coordinate: coordinate,
        isHiddenFromMap: hiddenKeys.contains(result.key),
        distance: distance,
        bearing: bearing,
        isContact: result.publicKey.map { contacts[$0] != nil } ?? false
      )
    }
  }

  /// `entries` in `order`. Signal is strongest first (what this radio hears, the figure the map's
  /// lines are colored by); distance is nearest first with unplaced nodes after, strongest
  /// first; name is alphabetical. The current scan's rows go before the earlier ones Show Older
  /// adds, and rows no single node could be pinned on go last within each, in every order. Ties
  /// keep a stable order by key so rows never swap places while evidence arrives.
  static func sorted(_ entries: [NodeDiscoveryEntry], by order: NodeDiscoverySortOrder) -> [NodeDiscoveryEntry] {
    entries.sorted { lhs, rhs in
      if lhs.result.isEarlier != rhs.result.isEarlier { return !lhs.result.isEarlier }
      if lhs.result.isResolved != rhs.result.isResolved { return lhs.result.isResolved }
      switch order {
      case .snr:
        if lhs.result.snr != rhs.result.snr { return lhs.result.snr > rhs.result.snr }
      case .distance:
        switch (lhs.distance, rhs.distance) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default:
          if lhs.result.snr != rhs.result.snr { return lhs.result.snr > rhs.result.snr }
        }
      case .name:
        let comparison = lhs.result.name.localizedCaseInsensitiveCompare(rhs.result.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
      }
      return lhs.id.lexicographicallyPrecedes(rhs.id)
    }
  }

  /// The entries `filter` keeps. The chips are shown only while the list holds both kinds; with
  /// them hidden every entry is listed, whatever chip was last picked, so a filter picked earlier
  /// can never hide the list behind chips that are gone.
  static func filtered(
    _ entries: [NodeDiscoveryEntry],
    by filter: NodeDiscoveryListFilter,
    chipsVisible: Bool = true
  ) -> [NodeDiscoveryEntry] {
    guard chipsVisible else { return entries }
    return entries.filter(filter.includes)
  }

  static func count(_ entries: [NodeDiscoveryEntry], matching filter: NodeDiscoveryListFilter) -> Int {
    entries.count(where: filter.includes)
  }

  /// Whether the All / New / Contacts chips are worth a row: only when the list holds new nodes
  /// and contacts both.
  static func chipsVisible(_ entries: [NodeDiscoveryEntry]) -> Bool {
    let newCount = count(entries, matching: .new)
    return newCount > 0 && newCount < entries.count
  }

  /// The chip to keep picked as the chips show or hide: back to All once they hide, so a filter
  /// picked earlier can't come back stuck when they return.
  static func listFilter(_ current: NodeDiscoveryListFilter, chipsVisible: Bool) -> NodeDiscoveryListFilter {
    chipsVisible ? current : .all
  }
}

/// The figures over the results list, only from what the neighbour rows and stored records say:
/// the panel gives it the current scan's entries, never the earlier ones Show Older adds.
struct NodeDiscoverySummary: Equatable {
  struct Highlight: Equatable {
    /// The row's key (`NodeDiscoveryResult.key`), to select it.
    let key: Data
    let name: String
    let value: Double
  }

  let replied: Int
  let newCount: Int
  /// The node this radio hears best (highest SNR).
  let bestSignal: Highlight?
  /// The farthest node with a known position; nil when no distance is known.
  let farthest: Highlight?

  init(entries: [NodeDiscoveryEntry]) {
    replied = entries.count
    newCount = entries.count(where: \.isNew)
    bestSignal = entries.max { $0.result.snr < $1.result.snr }.map {
      Highlight(key: $0.id, name: $0.result.name, value: $0.result.snr)
    }
    farthest = entries
      .compactMap { entry in entry.distance.map { (entry, $0) } }
      .max { $0.1 < $1.1 }
      .map { Highlight(key: $0.0.id, name: $0.0.result.name, value: $0.1) }
  }
}

/// Wording for the results panel.
enum NodeDiscoveryFormat {
  /// "+10.5 dB" / "-3.0 dB": signed, one decimal.
  static func snr(_ snr: Double, locale: Locale = .current) -> String {
    let value = snr.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()).locale(locale))
    return "\(value) \(L10n.RemoteNodes.RemoteNodes.Status.snrBadgeUnit)"
  }

  /// "3.4 km", in the user's measurement preference.
  static func distance(_ meters: CLLocationDistance) -> String {
    Measurement(value: meters, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road).locale(MeasurementPreference.locale()))
  }

  /// "3.4 km · 47° NE".
  static func distanceAndDirection(_ entry: NodeDiscoveryEntry) -> String? {
    guard let distance = entry.distance else { return nil }
    guard let bearing = entry.bearing else { return Self.distance(distance) }
    // Whole degrees as well as the compass point, for aiming a directional antenna.
    return "\(Self.distance(distance)) · \(GPSFormat.bearingText(bearing))"
  }

  /// "3.4 km · 47° NE · RSSI -82 dBm", or where the position is missing or hidden instead.
  static func placeLine(_ entry: NodeDiscoveryEntry) -> String {
    let place: String = if entry.isHiddenFromMap {
      L10n.Tools.Tools.NodeDiscovery.Map.hidden
    } else if let distance = distanceAndDirection(entry) {
      distance
    } else if entry.coordinate == nil {
      L10n.Tools.Tools.NodeDiscovery.Map.noLocation
    } else {
      // Positioned, but no fresh fix was known when it was heard, so there is no line or distance.
      L10n.Tools.Tools.NodeDiscovery.Map.noFixWhenHeard
    }
    return NodeRouteFormat.joined([place, L10n.Tools.Tools.NodeDiscovery.rssi(entry.result.rssi.formatted())])
  }

  /// What VoiceOver reads after a result's name: kind, status, its badges, both directions when
  /// known, how long ago, and place.
  static func accessibilityValue(_ entry: NodeDiscoveryEntry, now: Date = Date()) -> String {
    let result = entry.result
    let kind = result.scanFilter == .repeaters
      ? L10n.Tools.Tools.NodeDiscovery.typeRepeater
      : L10n.Tools.Tools.NodeDiscovery.typeSensor
    // New or Contact only for a node known by its whole key: a relay hash can be neither.
    let status: [String] = !result.hasFullKey ? [] : [
      entry.isNew ? L10n.Tools.Tools.NodeDiscovery.Badge.new : L10n.Tools.Tools.NodeDiscovery.Badge.contact,
    ]
    let heard = "\(L10n.Tools.Tools.NodeDiscovery.youHearThem) \(snr(result.snr)), "
      + SNRQuality(snr: result.snr).localizedLabel
    let heardBy = result.uplinkSNR.map {
      "\(L10n.Tools.Tools.NodeDiscovery.theyHearYou) \(snr($0)), " + SNRQuality(snr: $0).localizedLabel
    }
    var parts = [kind] + status + badges(result).map(\.title) + [heard]
    if let heardBy { parts.append(heardBy) }
    parts += [freshness(lastHeard: result.receivedAt, now: now), placeLine(entry)]
    return parts.joined(separator: ", ")
  }

  /// "now", "2m ago": how long ago a node was last heard, in Home's terse units (as CarPlay says it).
  static func freshness(lastHeard: Date, now: Date) -> String {
    let interval = max(0, now.timeIntervalSince(lastHeard))
    let age = HomeFormat.age(interval)
    return interval < 60 ? age : L10n.Tools.Tools.NodeDiscovery.freshness(age)
  }

  /// One of a card's evidence badges.
  enum Badge: Hashable, CaseIterable {
    case relaying
    case advert
    case answeredYourScan
    /// A row heard only before the current scan answered one of this radio's earlier scans.
    case answeredEarlierScan
    case answeredAnotherScan
    case hearsYou
    case heardOnce

    var title: String {
      switch self {
      case .relaying: L10n.Tools.Tools.NodeDiscovery.Badge.relaying
      case .advert: L10n.Tools.Tools.NodeDiscovery.Badge.advert
      case .answeredYourScan: L10n.Tools.Tools.NodeDiscovery.Badge.answeredYourScan
      case .answeredEarlierScan: L10n.Tools.Tools.NodeDiscovery.Badge.answeredEarlierScan
      case .answeredAnotherScan: L10n.Tools.Tools.NodeDiscovery.Badge.answeredAnotherScan
      case .hearsYou: L10n.Tools.Tools.NodeDiscovery.Badge.hearsYou
      case .heardOnce: L10n.Tools.Tools.NodeDiscovery.Badge.heardOnce
      }
    }
  }

  /// Where a row's evidence came from, in a fixed order: how it was heard, then whether it hears
  /// this radio, then "Heard once" for a relay heard a single time. A reply to this radio's scan
  /// is "Answered your scan" on the current scan's rows and "Answered an earlier scan" on the
  /// ones heard before it.
  static func badges(_ result: NodeDiscoveryResult) -> [Badge] {
    var badges: [Badge] = []
    if result.sources.contains(.relay) { badges.append(.relaying) }
    if result.sources.contains(.advert) { badges.append(.advert) }
    if result.sources.contains(.replyToUs) { badges.append(result.isEarlier ? .answeredEarlierScan : .answeredYourScan) }
    if result.sources.contains(.replyToOthers) { badges.append(.answeredAnotherScan) }
    if result.hearsYou { badges.append(.hearsYou) }
    if !result.isConfirmed { badges.append(.heardOnce) }
    return badges
  }

  /// A row drawn faded: one heard only before the current scan (Show Older), a relay heard only
  /// once, or one last heard over two hours ago.
  static func isDimmed(_ result: NodeDiscoveryResult) -> Bool {
    result.isEarlier || !result.isConfirmed || result.freshness >= .older
  }

  /// "0:32": a cooldown's time left, minutes and seconds.
  static func countdown(seconds: Int) -> String {
    Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
  }
}
