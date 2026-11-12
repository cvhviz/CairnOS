import CairnServices
import SwiftUI

/// The scan's two buttons, side by side and the same width, in their own row under the sheet's
/// status line, so neither covers the map. Scan, filled: while a probe listens, red with the
/// listening window as a ring round its stop glyph and the seconds left; while scans have to wait,
/// grey with a ring filling as the wait runs out and the time left (a tap says why, in the header);
/// while Wardrive runs, grey and counting down its probes, since Wardrive sends them. Wardrive,
/// tinted: starts a probe each time the gate allows, until stopped; while it runs, filled red as
/// Stop Wardrive. The row is always there and always one line high, whatever the state.
struct NodeDiscoveryScanButtons: View {
  @Bindable var viewModel: NodeDiscoveryViewModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// When the current cooldown began, for its ring; nil while scans may go.
  @State private var cooldownSpan: NodeDiscoveryCooldownSpan?

  var body: some View {
    let status = viewModel.scanStatus
    // Ticks fast while something counts down.
    TimelineView(.animation(minimumInterval: status.isCountingDown ? 0.25 : 5)) { context in
      HStack(spacing: 8) {
        scanButton(status, now: context.date)
        wardriveButton(status)
      }
    }
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .onAppear { syncCooldownSpan(status.state) }
    .onChange(of: status.state) { _, state in syncCooldownSpan(state) }
  }

  private func scanButton(_ status: NodeDiscoveryScanStatus, now: Date) -> some View {
    let secondsLeft = status.secondsLeft(now: now)
    return Button(action: viewModel.toggleScan) {
      HStack(spacing: 6) {
        face(status, now: now)
        Text(Self.label(status, secondsLeft: secondsLeft))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .contentTransition(.numericText(countsDown: true))
      }
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .tint(scanTint(status))
    // A radio that can't send a scan still runs one that only listens. While Wardrive runs it
    // sends the probes, and its own button stops it.
    .disabled(!viewModel.isConnected || status.isWardriving)
    .accessibilityLabel(status.isWardriving ? L10n.Tools.Tools.NodeDiscovery.scan : status.buttonTitle(now: now))
    .accessibilityValue(status.isProbing || status.isWardriving ? secondsLeft.map(NodeDiscoveryScanStatus.countdownText) ?? "" : "")
    .accessibilityHint(status.scanButtonHint)
    .accessibilityIdentifier("nodeDiscovery.scanButton")
  }

  /// The radio glyph; or, counting down, a ring round the glyph of what a tap does.
  @ViewBuilder
  private func face(_ status: NodeDiscoveryScanStatus, now: Date) -> some View {
    if status.isWardriving {
      NodeDiscoveryScanRing(progress: status.windowProgress(now: now), symbol: nil, reduceMotion: reduceMotion)
    } else if status.isProbing {
      NodeDiscoveryScanRing(progress: status.windowProgress(now: now) ?? 0, symbol: "stop.fill", reduceMotion: reduceMotion)
    } else if status.cooldown != nil {
      NodeDiscoveryScanRing(progress: cooldownSpan?.progress(now: now) ?? 0, symbol: nil, reduceMotion: reduceMotion)
    } else {
      Image(systemName: "dot.radiowaves.left.and.right")
    }
  }

  /// "Scan"; the seconds left while a probe listens or Wardrive waits; "0:32" while scans wait.
  static func label(_ status: NodeDiscoveryScanStatus, secondsLeft: Int?) -> String {
    if status.isProbing || status.isWardriving {
      return secondsLeft.map { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow)) }
        ?? L10n.Tools.Tools.NodeDiscovery.scan
    }
    if status.cooldown != nil, let secondsLeft {
      return NodeDiscoveryFormat.countdown(seconds: secondsLeft)
    }
    return L10n.Tools.Tools.NodeDiscovery.scan
  }

  private func scanTint(_ status: NodeDiscoveryScanStatus) -> Color {
    if status.isWardriving || status.cooldown != nil { return .gray }
    if status.isProbing { return .red }
    return ToolSelection.nodeDiscovery.tileColor
  }

  /// Wardrive, tinted beside Scan; while it runs, filled red as Stop Wardrive. Both are one line
  /// with the car, so the row keeps its height.
  @ViewBuilder
  private func wardriveButton(_ status: NodeDiscoveryScanStatus) -> some View {
    let label = HStack(spacing: 6) {
      Image(systemName: "car.fill")
      Text(status.isWardriving ? L10n.Tools.Tools.NodeDiscovery.wardriveStop : L10n.Tools.Tools.NodeDiscovery.wardriveButton)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity)
    if status.isWardriving {
      Button(action: viewModel.stopWardrive) { label }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.red)
        .accessibilityIdentifier("nodeDiscovery.wardriveStopButton")
    } else {
      Button(action: viewModel.startWardrive) { label }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(ToolSelection.nodeDiscovery.tileColor)
        .background(.regularMaterial, in: Capsule())
        .disabled(!viewModel.isConnected || !status.isScanSupported)
        .accessibilityHint(status.wardriveButtonHint)
        .accessibilityIdentifier("nodeDiscovery.wardriveButton")
    }
  }

  /// Starts the ring when a cooldown begins (or the screen opens during one), and drops it after.
  private func syncCooldownSpan(_ state: DiscoveryProbeCoordinator.State) {
    guard case let .coolingDown(until, _) = state else {
      cooldownSpan = nil
      return
    }
    guard cooldownSpan?.until != until else { return }
    cooldownSpan = NodeDiscoveryCooldownSpan(start: Date(), until: until)
  }
}

extension NodeDiscoveryScanStatus {
  /// "12 seconds", as VoiceOver reads a countdown.
  static func countdownText(_ seconds: Int) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .wide))
  }
}

// MARK: - Cooldown ring

/// When a cooldown began and ends, for the ring that fills as it runs out.
struct NodeDiscoveryCooldownSpan: Equatable {
  let start: Date
  let until: Date

  /// Share of the wait gone, 0 to 1.
  func progress(now: Date) -> Double {
    let total = until.timeIntervalSince(start)
    guard total > 0 else { return 1 }
    return min(1, max(0, now.timeIntervalSince(start) / total))
  }
}

/// A small ring in the scan button's label, filling as the listening window or the wait for the
/// next scan runs out, round the glyph of what a tap does. In the label's own colour.
private struct NodeDiscoveryScanRing: View {
  /// Share gone, 0 to 1; nil draws the track alone.
  let progress: Double?
  let symbol: String?
  let reduceMotion: Bool

  @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 20

  var body: some View {
    ZStack {
      Circle()
        .stroke(.foreground.opacity(0.3), lineWidth: 2.5)
      if let progress {
        Circle()
          .trim(from: 0, to: progress)
          .stroke(.foreground, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
      }
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: size * 0.4, weight: .bold))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Summary stat

/// One figure in a scan card's summary strip (Scan for Nodes, a repeater's Neighbors): a small label, the value, and the node it belongs
/// to, a line each. A `MetricTile`'s reading without the tile, so three fit on one row.
struct ScanSummaryStat: View {
  let title: String
  let systemImage: String
  let value: String
  let caption: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Label(title, systemImage: systemImage)
        .labelStyle(ScanSummaryStatLabelStyle())
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      if let caption {
        Text(caption)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue([value, caption].compactMap(\.self).joined(separator: ", "))
  }
}

/// A small glyph tight against the label, as on the GPS map's readout.
private struct ScanSummaryStatLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
        .imageScale(.small)
      configuration.title
    }
  }
}

// MARK: - Ring

/// A scan button's face (Scan for Nodes, a repeater's neighbour discovery). Idle, a filled accent disc with the radio glyph; scanning, the
/// listening window as a ring that fills around the seconds left, over a stop square.
struct ScanRingButtonFace: View {
  /// Share of the window gone, nil when not scanning.
  let progress: Double?
  let secondsLeft: Int?
  let isScanning: Bool
  let reduceMotion: Bool

  @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 52

  var body: some View {
    ZStack {
      if isScanning {
        Circle()
          .fill(Color.red.opacity(0.12))
        Circle()
          .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
        if let progress {
          Circle()
            .trim(from: 0, to: progress)
            .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
        }
        VStack(spacing: 0) {
          Image(systemName: "stop.fill")
            .font(.caption2.weight(.bold))
          if let secondsLeft {
            Text("\(secondsLeft)")
              .font(.caption.weight(.semibold))
              .monospacedDigit()
              .contentTransition(.numericText(countsDown: true))
          }
        }
        .foregroundStyle(.red)
      } else {
        Circle()
          .fill(Color.accentColor.gradient)
          .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
    .contentShape(.circle)
    .animation(reduceMotion ? nil : .snappy, value: isScanning)
  }
}

extension NodeDiscoveryFilter {
  var systemImage: String {
    switch self {
    case .repeaters: "antenna.radiowaves.left.and.right"
    case .sensors: "sensor"
    }
  }
}

// MARK: - Scan wording

/// The scan's state in words, shared by the status line and the full-screen map's bottom bar so both
/// always say the same thing. Pure: built from the probe coordinator, the neighbour directory and
/// the connection at one moment, so the tests can pin each state's words.
struct NodeDiscoveryScanStatus: Equatable {
  /// What the current scan's list holds, so the words count what the list shows.
  struct ScanCounts: Equatable {
    /// The current scan's rows of the kind listed (not the earlier ones Show Older adds).
    let listed: Int
    /// Those that answered it.
    let answered: Int
  }

  var state: DiscoveryProbeCoordinator.State = .idle
  /// The kind being listed; "answered your scan" is said only for the kind the scan asked for.
  var filter: NodeDiscoveryFilter = .repeaters
  var isConnected = true
  /// The current scan's rows of the kind listed; nil before the first snapshot.
  var nearbyCount: Int?
  /// When the list last changed; while disconnected, when it was last heard.
  var updatedAt: Date?
  /// What the last finished probe heard.
  var summary: DiscoveryProbeCoordinator.Summary?
  /// The cooldown's explainer is open.
  var showsCooldownReason = false
  var isWardriving = false
  var wardriveProbeCount = 0
  var nextWardriveProbeAt: Date?
  /// The radio's firmware can send a scan (`DiscoveryProbeCoordinator.isDiscoverSupported`):
  /// false before companion v1.10, or once the radio refused one. Its scans only listen.
  var isScanSupported = true
  /// The scan whose list is shown; nil before the first scan.
  var scan: DiscoveryProbeCoordinator.Scan?
  /// What that list holds; nil before the first snapshot.
  var scanCounts: ScanCounts?

  /// The probe asking, waiting for a fix or listening.
  var probe: DiscoveryProbeCoordinator.Probe? {
    switch state {
    case let .probing(probe), let .interrupted(probe): probe
    case .idle, .coolingDown: nil
    }
  }

  var isProbing: Bool {
    probe != nil
  }

  /// Until when scans wait, and why.
  var cooldown: (until: Date, reason: DiscoverRequestGate.Reason)? {
    if case let .coolingDown(until, reason) = state { (until, reason) } else { nil }
  }

  /// Something on the card counts down: a probe's window, a cooldown, or Wardrive's next probe.
  var isCountingDown: Bool {
    isProbing || cooldown != nil || (isWardriving && nextWardriveProbeAt != nil)
  }

  /// "Listening · 4 nearby · updated 2 min ago", counting the current scan's list; before the
  /// first scan, that one is ready; while a probe runs, that it asks (or only listens, on a radio
  /// that can't send one) or that the connection was rebuilt under it; while disconnected, until
  /// when the list was heard.
  func headline(now: Date) -> String {
    if !isConnected {
      guard let updatedAt else { return L10n.Tools.Tools.NodeDiscovery.NothingHeard.title }
      return L10n.Tools.Tools.NodeDiscovery.Status.disconnected(updatedAt.formatted(date: .omitted, time: .shortened))
    }
    switch state {
    case let .probing(probe):
      return probe.listensOnly ? L10n.Tools.Tools.NodeDiscovery.Status.listeningOnly : L10n.Tools.Tools.NodeDiscovery.Status.probing
    case .interrupted: return L10n.Tools.Tools.NodeDiscovery.Status.interrupted
    case .idle, .coolingDown: break
    }
    guard let nearbyCount, let updatedAt else { return L10n.Tools.Tools.NodeDiscovery.NothingHeard.title }
    guard scan != nil else { return L10n.Tools.Tools.NodeDiscovery.Status.readyToScan }
    return L10n.Tools.Tools.NodeDiscovery.Status.listeningNearby(nearbyCount, Self.relative(updatedAt, now: now))
  }

  /// The sheet header's one line: "Listening · 3 nearby · 12 packets/min". What the scan is doing
  /// (asking, with how many replied; Wardrive and how much it heard; ready; how many are near),
  /// then how many packets a minute the radio hears, once there's been time to measure.
  func headerLine(now: Date, packetsPerMinute: Double?) -> String {
    guard isConnected else { return headline(now: now) }
    let doing: String
    if isWardriving {
      doing = L10n.Tools.Tools.NodeDiscovery.Status.wardrive(nearbyCount ?? 0)
    } else {
      switch state {
      case .probing, .interrupted:
        doing = L10n.Tools.Tools.NodeDiscovery.Status.listening(scanCounts?.answered ?? 0)
      case .idle, .coolingDown:
        if let nearbyCount, updatedAt != nil {
          doing = scan == nil ? L10n.Tools.Tools.NodeDiscovery.Status.readyToScan : L10n.Tools.Tools.NodeDiscovery.Status.nearby(nearbyCount)
        } else {
          doing = L10n.Tools.Tools.NodeDiscovery.NothingHeard.title
        }
      }
    }
    guard let packetsPerMinute else { return doing }
    let rate = packetsPerMinute.formatted(.number.precision(.fractionLength(packetsPerMinute < 10 ? 0...1 : 0...0)))
    return NodeRouteFormat.joined([doing, L10n.Tools.Tools.NodeDiscovery.Status.packetsPerMinute(rate)])
  }

  /// The line under the headline: how Wardrive is going, that the radio's firmware can't send a
  /// scan, why scans wait (once asked), or what the current scan's list holds: how many answered
  /// it and how many more were heard since it started (the list's own count), with how many
  /// packets the radio heard during it that never reached the app.
  func detail(now: Date) -> String? {
    if isWardriving {
      let round = isProbing
        ? L10n.Tools.Tools.NodeDiscovery.Status.wardriveListening(wardriveProbeCount)
        : L10n.Tools.Tools.NodeDiscovery.Status.wardriveWaiting(wardriveProbeCount)
      return NodeRouteFormat.joined([L10n.Tools.Tools.NodeDiscovery.wardriveRunning, round])
    }
    if cooldown != nil, showsCooldownReason {
      return L10n.Tools.Tools.NodeDiscovery.Cooldown.explainer
    }
    guard !isProbing, let scan, let scanCounts else {
      return isScanSupported ? nil : L10n.Tools.Tools.NodeDiscovery.scanUnsupported
    }
    // A scan that only listened, or one that asked for the other kind: nothing of this kind
    // was asked to answer
    guard !scan.listensOnly, scan.filter == filter else {
      return L10n.Tools.Tools.NodeDiscovery.Status.listenSummary(scanCounts.listed)
    }
    let found = L10n.Tools.Tools.NodeDiscovery.Status.probeSummary(scanCounts.answered, scanCounts.listed - scanCounts.answered)
    guard let summary, summary.filter == scan.filter, summary.finishedAt >= scan.startedAt,
          let missed = summary.radioMissed, missed > 0 else { return found }
    return NodeRouteFormat.joined([found, L10n.Tools.Tools.NodeDiscovery.Summary.radioMissed(missed)])
  }

  /// The detail line in the full-screen map's bar, where room is short: the same, but just the
  /// firmware it needs where the card explains that the radio can't send a scan.
  func compactDetail(now: Date) -> String? {
    let detail = detail(now: now)
    return detail == L10n.Tools.Tools.NodeDiscovery.scanUnsupported ? L10n.Tools.Tools.NodeDiscovery.scanUnsupportedShort : detail
  }

  /// "Scan Now"; "Stop Scanning" while a probe listens; "Scan again in 0:32" or "Waiting — someone
  /// nearby just scanned" while scans wait; "Stop Wardrive" while Wardrive runs.
  func buttonTitle(now: Date) -> String {
    if isWardriving { return L10n.Tools.Tools.NodeDiscovery.wardriveStop }
    switch state {
    case .probing, .interrupted:
      return L10n.Tools.Tools.NodeDiscovery.stopButton
    case let .coolingDown(until, reason):
      if reason == .othersScanning { return L10n.Tools.Tools.NodeDiscovery.Cooldown.othersScanning }
      let seconds = Self.seconds(until: until, now: now)
      return L10n.Tools.Tools.NodeDiscovery.Cooldown.scanAgainIn(NodeDiscoveryFormat.countdown(seconds: seconds))
    case .idle:
      return L10n.Tools.Tools.NodeDiscovery.scanNow
    }
  }

  var buttonSymbol: String {
    if isWardriving || isProbing { return "stop.fill" }
    return cooldown != nil ? "hourglass" : "dot.radiowaves.left.and.right"
  }

  /// What VoiceOver adds to the scan button, on the card and the map's bar alike: that a scan only
  /// listens when the radio's firmware can't send one, or that scans wait during a cooldown.
  var scanButtonHint: String {
    if !isScanSupported, !isWardriving { return L10n.Tools.Tools.NodeDiscovery.scanListensOnlyHint }
    return cooldown != nil ? L10n.Tools.Tools.NodeDiscovery.Cooldown.hint : ""
  }

  /// What VoiceOver adds to the Wardrive button: what it does, or why it is off.
  var wardriveButtonHint: String {
    isScanSupported ? L10n.Tools.Tools.NodeDiscovery.wardriveHint : L10n.Tools.Tools.NodeDiscovery.scanUnsupportedShort
  }

  /// Seconds left of the probe's listening window (nil while it still waits to be sent), of the
  /// cooldown, or until Wardrive's next probe.
  func secondsLeft(now: Date) -> Int? {
    if let probe {
      return probe.endsAt.map { Self.seconds(until: $0, now: now) }
    }
    if let cooldown, !isWardriving {
      return Self.seconds(until: cooldown.until, now: now)
    }
    if isWardriving, let nextWardriveProbeAt {
      return Self.seconds(until: nextWardriveProbeAt, now: now)
    }
    return nil
  }

  /// Share of the probe's listening window gone, 0 to 1; nil without a probe on air.
  func windowProgress(now: Date) -> Double? {
    guard let sentAt = probe?.sentAt, let endsAt = probe?.endsAt else { return nil }
    let total = endsAt.timeIntervalSince(sentAt)
    guard total > 0 else { return 1 }
    return min(1, max(0, now.timeIntervalSince(sentAt) / total))
  }

  /// Whole seconds until `date`, rounded up so a countdown reaches 0 when it ends, never negative.
  static func seconds(until date: Date, now: Date) -> Int {
    max(0, Int(date.timeIntervalSince(now).rounded(.up)))
  }

  /// "2 min ago", "now": how long ago the list changed.
  static func relative(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }
}
