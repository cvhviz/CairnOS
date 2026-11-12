import Foundation
import CairnServices
import MeshCore

/// Something about a repeater worth the user's attention, most severe first.
enum NetworkHealthIssue: Hashable, Comparable {
  case lowBattery(percent: Int)
  case notHeard
  case batteryFalling(points: Int)
  case highNoise(dBm: Int)
  case restarted

  var isCritical: Bool {
    switch self {
    case let .lowBattery(percent): percent < NetworkHealthReport.criticalBatteryPercent
    case .notHeard: true
    default: false
    }
  }

  var systemImage: String {
    switch self {
    case .lowBattery: "battery.25percent"
    case .notHeard: "antenna.radiowaves.left.and.right.slash"
    case .batteryFalling: "chart.line.downtrend.xyaxis"
    case .highNoise: "waveform.badge.exclamationmark"
    case .restarted: "arrow.counterclockwise"
    }
  }

  var title: String {
    switch self {
    case .lowBattery: L10n.Tools.Tools.NetworkHealth.Issue.lowBattery
    case .notHeard: L10n.Tools.Tools.NetworkHealth.Issue.notHeard
    case .batteryFalling: L10n.Tools.Tools.NetworkHealth.Issue.batteryFalling
    case .highNoise: L10n.Tools.Tools.NetworkHealth.Issue.highNoise
    case .restarted: L10n.Tools.Tools.NetworkHealth.Issue.restarted
    }
  }
}

/// One repeater's health, built from its contact record and recorded status snapshots.
struct NetworkHealthNode: Identifiable {
  let contact: ContactDTO
  /// Snapshots from the trend window, oldest first.
  let snapshots: [NodeStatusSnapshotDTO]
  /// The newest reading, from the trend window or, when the window has none, the last check
  /// ever made. An older reading is shown with its age but raises no issue.
  let batteryPercent: Int?
  let noiseFloor: Int?
  let lastHeard: Date?
  let lastChecked: Date?
  let issues: [NetworkHealthIssue]
  /// When the node last advertised, from contact sync: shown when it hasn't been heard live.
  var lastAdvert: Date?
  var uptimeSeconds: UInt32?
  /// The SNR of the last packet the node heard, from its last check.
  var lastSNR: Double?

  var id: UUID { contact.id }
  var needsAttention: Bool { !issues.isEmpty }
  var hasStatus: Bool { lastChecked != nil }
  var isCritical: Bool { issues.contains(where: \.isCritical) }

  /// Battery percentages over the trend window, for the row sparkline.
  var batteryTrend: [(date: Date, percent: Int)] {
    snapshots.compactMap { snapshot in
      // 0 mV means the node reported no reading, not an empty battery.
      snapshot.batteryMillivolts.flatMap {
        $0 > 0 ? (snapshot.timestamp, BatteryInfo(level: Int($0)).percentage(using: contact.activeOCVArray)) : nil
      }
    }
  }
}

/// Cross-network health overview. Pure so the thresholds are testable; the view model only fetches.
struct NetworkHealthReport {
  static let trendWindow: TimeInterval = 7 * 86400
  static let lowBatteryPercent = 20
  static let criticalBatteryPercent = 10
  /// Percentage points lost within `fallingWindow` that counts as draining.
  static let fallingBatteryPoints = 15
  static let fallingWindow: TimeInterval = 86400
  /// Repeaters flood-advert every few hours by default, so two silent days means trouble.
  static let notHeardAfter: TimeInterval = 2 * 86400
  /// A noise floor above this suggests local interference. Quiet sites sit near -110 to -120 dBm.
  static let highNoiseFloor = -100
  static let restartedWithin: TimeInterval = 86400

  let nodes: [NetworkHealthNode]

  var needsAttention: [NetworkHealthNode] {
    nodes.filter(\.needsAttention).sorted { lhs, rhs in
      if lhs.isCritical != rhs.isCritical { return lhs.isCritical }
      if lhs.issues.count != rhs.issues.count { return lhs.issues.count > rhs.issues.count }
      return lhs.contact.displayName.localizedCaseInsensitiveCompare(rhs.contact.displayName) == .orderedAscending
    }
  }

  var healthy: [NetworkHealthNode] {
    nodes.filter { !$0.needsAttention && $0.hasStatus }.sortedByName()
  }

  /// Heard or added, but never status-checked, with nothing flagged from adverts alone.
  var withoutStatus: [NetworkHealthNode] {
    nodes.filter { !$0.needsAttention && !$0.hasStatus }.sortedByName()
  }

  func checkedCount(since date: Date) -> Int {
    nodes.count { ($0.lastChecked ?? .distantPast) >= date }
  }

  init(nodes: [NetworkHealthNode]) {
    self.nodes = nodes
  }

  /// The report from stored records only (contacts and the status checks of the trend window), so
  /// reading it sends nothing over the radio. Shared by the Network Health page and CarPlay.
  static func load(dataStore: (any PersistenceStoreProtocol)?, radioID: UUID?, now: Date = Date()) async -> NetworkHealthReport {
    guard let radioID, let dataStore else { return NetworkHealthReport(nodes: []) }
    let contacts = (try? await dataStore.fetchContacts(radioID: radioID)) ?? []
    let since = now.addingTimeInterval(-trendWindow)
    var snapshotsByKey: [Data: [NodeStatusSnapshotDTO]] = [:]
    var latestByKey: [Data: NodeStatusSnapshotDTO] = [:]
    for contact in contacts where contact.type == .repeater {
      let recent = (try? await dataStore.fetchNodeStatusSnapshots(nodePublicKey: contact.publicKey, since: since)) ?? []
      snapshotsByKey[contact.publicKey] = recent
      // Checked, but not this week: the last reading still beats a blank row.
      if recent.isEmpty, let latest = try? await dataStore.fetchLatestNodeStatusSnapshot(nodePublicKey: contact.publicKey) {
        latestByKey[contact.publicKey] = latest
      }
    }
    return NetworkHealthReport(contacts: contacts, snapshotsByKey: snapshotsByKey, latestByKey: latestByKey, now: now)
  }

  /// - Parameters:
  ///   - snapshotsByKey: Each node's snapshots from the trend window, oldest first.
  ///   - latestByKey: The last check ever made, for a node with none in the window.
  init(
    contacts: [ContactDTO],
    snapshotsByKey: [Data: [NodeStatusSnapshotDTO]],
    latestByKey: [Data: NodeStatusSnapshotDTO] = [:],
    now: Date = Date()
  ) {
    nodes = contacts
      .filter { $0.type == .repeater && !$0.isBlocked }
      .map {
        Self.node(for: $0, snapshots: snapshotsByKey[$0.publicKey] ?? [], latest: latestByKey[$0.publicKey], now: now)
      }
  }

  static func node(
    for contact: ContactDTO,
    snapshots: [NodeStatusSnapshotDTO],
    latest: NodeStatusSnapshotDTO? = nil,
    now: Date
  ) -> NetworkHealthNode {
    let ocv = contact.activeOCVArray
    func percent(_ snapshot: NodeStatusSnapshotDTO) -> Int? {
      snapshot.batteryMillivolts.flatMap { $0 > 0 ? BatteryInfo(level: Int($0)).percentage(using: ocv) : nil }
    }

    let latestBattery = snapshots.last(where: { percent($0) != nil })
    let batteryPercent = latestBattery.flatMap(percent)
    let noiseFloor = snapshots.last(where: { $0.noiseFloor != nil })?.noiseFloor.map(Int.init)
    let lastChecked = snapshots.last?.timestamp
    // The heard stamp is only set by live events, so it gates "heard before" while the age comes from
    // the newer of it and the advert time that contact sync brings in.
    let lastHeard = contact.lastHeardTimestamp.flatMap { $0 > 0 ? contact.recencyDate : nil }

    var issues: [NetworkHealthIssue] = []
    if let batteryPercent, batteryPercent < lowBatteryPercent {
      issues.append(.lowBattery(percent: batteryPercent))
    }
    // Only flag silence for nodes this phone has heard before; "never heard" isn't news.
    if let lastHeard, now.timeIntervalSince(lastHeard) > notHeardAfter {
      issues.append(.notHeard)
    }
    if let latestBattery, let batteryPercent,
       let earlier = snapshots.first(where: {
         percent($0) != nil && latestBattery.timestamp.timeIntervalSince($0.timestamp) <= fallingWindow
       }),
       let earlierPercent = percent(earlier),
       earlierPercent - batteryPercent >= fallingBatteryPoints {
      issues.append(.batteryFalling(points: earlierPercent - batteryPercent))
    }
    // A floor of exactly 0 is the firmware's "not yet converged" reading, not interference.
    if let noiseFloor, noiseFloor < 0, noiseFloor > highNoiseFloor {
      issues.append(.highNoise(dBm: noiseFloor))
    }
    if restartedRecently(snapshots, now: now) {
      issues.append(.restarted)
    }

    // Shown, not judged: the last check outside the window fills a row that would be blank.
    let older = snapshots.isEmpty ? latest : nil
    return NetworkHealthNode(
      contact: contact,
      snapshots: snapshots,
      batteryPercent: batteryPercent ?? older.flatMap(percent),
      noiseFloor: noiseFloor ?? older?.noiseFloor.map(Int.init),
      lastHeard: lastHeard,
      lastChecked: lastChecked ?? older?.timestamp,
      issues: issues.sorted(),
      lastAdvert: contact.lastAdvertTimestamp > 0
        ? Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp))
        : nil,
      uptimeSeconds: (snapshots.last(where: { $0.uptimeSeconds != nil }) ?? older)?.uptimeSeconds,
      lastSNR: (snapshots.last(where: { $0.lastSNR != nil }) ?? older)?.lastSNR
    )
  }

  /// Uptime going backwards between two checks means the node rebooted in between. Every pair of
  /// consecutive checks is compared, so a later check doesn't hide a restart still inside the window.
  private static func restartedRecently(_ snapshots: [NodeStatusSnapshotDTO], now: Date) -> Bool {
    let checks = snapshots.filter { $0.uptimeSeconds != nil }
    return zip(checks, checks.dropFirst()).contains { previous, later in
      guard now.timeIntervalSince(later.timestamp) <= restartedWithin,
            let previousUptime = previous.uptimeSeconds,
            let uptime = later.uptimeSeconds else { return false }
      let expected = TimeInterval(previousUptime) + later.timestamp.timeIntervalSince(previous.timestamp)
      return TimeInterval(uptime) + 60 < expected && TimeInterval(uptime) < restartedWithin
    }
  }
}

private extension [NetworkHealthNode] {
  func sortedByName() -> [NetworkHealthNode] {
    sorted { $0.contact.displayName.localizedCaseInsensitiveCompare($1.contact.displayName) == .orderedAscending }
  }
}

// MARK: - Sorting

/// How each of the page's groups is ordered: by what's wrong (the default: worst first, then by
/// name), by battery (lowest first, unknown last), or by when each was last heard (longest
/// silent first, never heard last).
enum NetworkHealthSort: String, CaseIterable {
  case issues
  case battery
  case lastHeard

  var title: String {
    switch self {
    case .issues: L10n.Tools.Tools.NetworkHealth.Sort.issues
    case .battery: L10n.Tools.Tools.NetworkHealth.Sort.battery
    case .lastHeard: L10n.Tools.Tools.NetworkHealth.Sort.lastHeard
    }
  }

  var systemImage: String {
    switch self {
    case .issues: "exclamationmark.triangle"
    case .battery: "battery.25percent"
    case .lastHeard: "clock"
    }
  }

  /// `nodes` (a group already in its default order) in this order.
  func apply(_ nodes: [NetworkHealthNode]) -> [NetworkHealthNode] {
    switch self {
    case .issues:
      return nodes
    case .battery:
      return nodes.sorted { lhs, rhs in
        switch (lhs.batteryPercent, rhs.batteryPercent) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.contact.displayName.localizedCaseInsensitiveCompare(rhs.contact.displayName) == .orderedAscending
        }
      }
    case .lastHeard:
      return nodes.sorted { lhs, rhs in
        switch (lhs.lastHeard ?? lhs.lastAdvert, rhs.lastHeard ?? rhs.lastAdvert) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.contact.displayName.localizedCaseInsensitiveCompare(rhs.contact.displayName) == .orderedAscending
        }
      }
    }
  }
}

// MARK: - Sharing

extension NetworkHealthReport {
  static let csvHeaders = [
    "name", "key_hex", "group", "issues", "battery_percent", "noise_floor_dbm", "last_snr_db", "uptime_s",
    "last_heard_utc", "last_advert_utc", "last_checked_utc", "route", "latitude", "longitude",
  ]

  /// Which group a node is listed under: "attention", "healthy" or "no_status".
  static func groupName(_ node: NetworkHealthNode) -> String {
    if node.needsAttention { return "attention" }
    return node.hasStatus ? "healthy" : "no_status"
  }

  /// One row per repeater, the ones needing attention first.
  func csvTable() -> CSVTable {
    var table = CSVTable(headers: Self.csvHeaders)
    for node in needsAttention + healthy + withoutStatus {
      let contact = node.contact
      table.append([
        contact.displayName,
        ExportFormat.hex(contact.publicKey),
        Self.groupName(node),
        node.issues.map { "\($0)" }.joined(separator: "|"),
        ExportFormat.integer(node.batteryPercent),
        ExportFormat.integer(node.noiseFloor),
        ExportFormat.number(node.lastSNR, fractionDigits: 2),
        ExportFormat.integer(node.uptimeSeconds),
        ExportFormat.timestamp(node.lastHeard),
        ExportFormat.timestamp(node.lastAdvert),
        ExportFormat.timestamp(node.lastChecked),
        contact.isFloodRouted ? "flood" : "\(contact.pathHopCount)",
        contact.hasLocation ? ExportFormat.number(contact.latitude) : nil,
        contact.hasLocation ? ExportFormat.number(contact.longitude) : nil,
      ])
    }
    return table
  }

  /// The report as text: the three figures, then each group's repeaters with what's wrong and
  /// their last readings.
  func text(now: Date = Date()) -> String {
    var lines: [String] = [
      "\(L10n.Tools.Tools.NetworkHealth.Report.title) · \(now.formatted(date: .abbreviated, time: .shortened))",
      "\(L10n.Tools.Tools.NetworkHealth.Summary.repeaters): \(nodes.count) · "
        + "\(L10n.Tools.Tools.NetworkHealth.Summary.attention): \(needsAttention.count) · "
        + "\(L10n.Tools.Tools.NetworkHealth.Summary.checkedToday): \(checkedCount(since: now.addingTimeInterval(-86400)))",
    ]
    let groups: [(String, [NetworkHealthNode])] = [
      (L10n.Tools.Tools.NetworkHealth.Section.attention, needsAttention),
      (L10n.Tools.Tools.NetworkHealth.Section.healthy, healthy),
      (L10n.Tools.Tools.NetworkHealth.Section.noStatus, withoutStatus),
    ]
    for (title, group) in groups where !group.isEmpty {
      lines.append("")
      lines.append(title)
      for node in group {
        var parts = [node.contact.displayName]
        if !node.issues.isEmpty { parts.append(node.issues.map(\.title).joined(separator: ", ")) }
        if let percent = node.batteryPercent { parts.append(L10n.Tools.Tools.NetworkHealth.batteryPercent(percent)) }
        if let noise = node.noiseFloor { parts.append(L10n.Tools.Tools.NetworkHealth.noise(noise)) }
        if let heard = node.lastHeard {
          parts.append(L10n.Tools.Tools.NetworkHealth.heard(heard.formatted(.relative(presentation: .named))))
        }
        if let checked = node.lastChecked {
          parts.append(L10n.Tools.Tools.NetworkHealth.checked(checked.formatted(.relative(presentation: .named))))
        }
        lines.append("• " + parts.joined(separator: " · "))
      }
    }
    return lines.joined(separator: "\n")
  }

  /// The CSV staged for sharing.
  func csvExport(date: Date = Date()) -> ExportedFile {
    let table = csvTable()
    return ExportedFile(
      data: table.renderData(),
      filename: "Cairn-network-health-\(ExportFormat.filenameStamp(date)).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }
}
