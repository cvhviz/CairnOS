import Foundation
import CairnServices

/// Builds the car's card rows (iOS 26's `CPListImageRowItem` cards): the Dashboard's radio,
/// mesh, message and location cards over a condensed line of shortcuts and tools, and the
/// Spectrum and GPS tabs. A Dashboard card is a picture of several readings, as the phone's
/// cards, with a one-line summary under it; the rest are a glyph tile, the reading's name and its
/// value in a few characters, so a glance is enough.
/// Pure over `CarPlayInputs`; nothing is built for a car that draws rows instead (`usesCards`).
enum CarPlayCardBuilder {
  /// Longest card title or value: a card is narrow, and a driver reads it at a glance.
  static let maxTextLength = 20
  /// The app's signal glyph, filled to `SNRQuality.barLevel`.
  static let signalSymbol = "cellularbars"

  /// Text cut to `limit` characters with "…", whitespace collapsed to single spaces.
  static func short(_ text: String, limit: Int = maxTextLength) -> String {
    let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard oneLine.count > limit else { return oneLine }
    return String(oneLine.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  private static func dbm(_ value: Double) -> String {
    L10n.Tools.Tools.Spectrum.Value.dbm(value.formatted(.number.precision(.fractionLength(0))))
  }

  private static func decibels(_ value: Double) -> String {
    L10n.Localizable.CarPlay.Cards.decibels(value.formatted(.number.precision(.fractionLength(1))))
  }

  /// "−92 dBm · 7.5 dB", either half alone, or nil without either.
  static func signalText(rssi: Int?, snr: Double?) -> String? {
    guard rssi != nil || snr != nil else { return nil }
    return NodeRouteFormat.joined([rssi.map { dbm(Double($0)) }, snr.map(decibels)])
  }

  /// A signal's colour: the app's SNR quality colour, grey with nothing heard.
  static func signalTint(snr: Double?) -> CarPlayTint {
    snr.map { .color(SNRQuality(snr: $0).color) } ?? .secondaryLabel
  }

  /// Green, orange or red by charge, as the app's battery card; grey with no reading.
  static func batteryTint(_ percent: Int?) -> CarPlayTint {
    guard let percent else { return .secondaryLabel }
    return switch BatteryLevel(percent: percent) {
    case .good: .success
    case .low: .warning
    case .critical: .critical
    }
  }

  // MARK: - Dashboard

  /// The Dashboard as one screen: the Radio, Mesh, Messages and Location cards side by side,
  /// each a picture of its readings (`CarPlaySnapshot.Panel`) with a one-line summary under it,
  /// then the mesh's shortcuts and the tools as one condensed row. The car wraps condensed cards
  /// two to a line on a typical screen, so they pair up: traffic and heard, then Send Advert and
  /// Scan, which share a colour. Nodes and Network Health stay off the Dashboard: the Nodes tab
  /// and the Mesh card already reach them. Empty while the app starts, when the list's empty view
  /// says so.
  static func dashboard(_ inputs: CarPlayInputs, now: Date) -> [CarPlaySnapshot.TileSection] {
    guard inputs.usesCards, !inputs.isStarting else { return [] }
    var cards = [radioCard(inputs)]
    if inputs.hasAnyRadio {
      cards.append(meshCard(inputs))
    }
    cards.append(messagesCard(inputs, now: now))
    if inputs.radio != nil {
      cards.append(locationCard(inputs))
    }
    var rows = [CarPlaySnapshot.TileRow(id: overviewRowID, title: nil, tiles: cards)]
    let shortcuts = (inputs.hasAnyRadio ? meshShortcuts(inputs) : []) + toolTiles(inputs)
    if !shortcuts.isEmpty {
      rows.append(.init(id: shortcutsRowID, title: nil, tiles: shortcuts, style: .condensed))
    }
    return [.init(header: nil, rows: rows)]
  }

  /// The Dashboard's rows: the rich cards, then the condensed shortcuts and tools.
  static let overviewRowID = "overview"
  static let shortcutsRowID = "shortcuts"

  private static func tabIfShown(_ tab: CarPlayTab, _ inputs: CarPlayInputs) -> CarPlaySnapshot.TileAction? {
    inputs.tabs.contains(tab) ? .openTab(tab) : nil
  }

  private static func nodesIfShown(_ category: CarPlaySnapshot.NodeCategory?, _ inputs: CarPlayInputs) -> CarPlaySnapshot.TileAction? {
    inputs.tabs.contains(.nodes) ? .nodes(category) : nil
  }

  /// The nodes heard in the last hour: the Nodes tab's Recently Heard group, so the number on a
  /// card is the list it opens (`CarPlayNodesSource.members(of: .recentlyHeard)`).
  static func heardCount(_ inputs: CarPlayInputs) -> Int {
    inputs.nodeCategories.first { $0.list == .category(.recentlyHeard) }?.count ?? 0
  }

  /// "3 new" after a count, or nil with nothing new.
  private static func newNodes(_ inputs: CarPlayInputs) -> String? {
    inputs.newNodeCount > 0 ? L10n.Localizable.Home.Nodes.new(inputs.newNodeCount) : nil
  }

  /// The radio as the phone's header and Device Info cards: how it is linked, its battery (with
  /// the bar and voltage) and its model, under the radio's name and link. A tap opens the Radio
  /// card's lines read-only. Without a radio, the card says why.
  static func radioCard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Tile {
    let card = CarPlaySnapshotBuilder.radioCard(inputs)
    let info = CarPlaySnapshot.TileAction.info(title: card.title, rows: card.info)
    let name = short(card.title)
    guard let radio = inputs.radio else {
      return .init(id: "radio", symbol: card.symbol, tint: card.tint, title: name, subtitle: short(card.detail), action: info)
    }
    let percent = inputs.batteryPercent
    let batteryTint = batteryTint(percent)
    var battery = CarPlaySnapshot.Metric(
      id: "battery",
      symbol: BatteryLevel.symbol(for: percent),
      label: L10n.Settings.DeviceInfo.battery,
      value: BatteryLevel.formattedPercent(percent),
      caption: inputs.batteryDetail.isEmpty ? nil : short(inputs.batteryDetail, limit: 8),
      valueTint: percent == nil ? nil : batteryTint
    )
    if let percent {
      battery.gauge = .meter(Double(percent) / 100, batteryTint)
    }
    var metrics: [CarPlaySnapshot.Metric] = [
      .init(
        id: "transport",
        symbol: radio.isWiFi ? "wifi" : CarPlayFeature.network.symbol,
        label: L10n.Settings.Connection.transport,
        value: short(HomeStatusLines.transportName(isWiFi: radio.isWiFi))
      ),
      battery,
    ]
    if let model = radio.model {
      metrics.append(.init(id: "model", symbol: "cpu", label: L10n.Settings.DeviceInfo.model, value: short(model)))
    }
    // The radio's own colour whatever the link; a link that isn't up shows in the status dot.
    let tint = card.tint
    return .init(
      id: "radio",
      symbol: card.symbol,
      tint: tint,
      title: name,
      subtitle: short(NodeRouteFormat.joined([
        CarPlaySnapshotBuilder.linkStatus(inputs),
        percent.map(BatteryLevel.formattedPercent),
      ])),
      action: info,
      panel: .init(
        symbol: card.symbol,
        tint: tint,
        heading: L10n.Localizable.CarPlay.Cards.radio,
        status: inputs.isRadioReady ? .success : .warning,
        metrics: metrics
      )
    )
  }

  /// What the radio hears, from the Live Activity's readings: the last packet's signal with the
  /// app's bars, the noise floor, packets a minute, nodes heard in the hour and the saved nodes.
  /// It leads with the signal, so a tap opens Spectrum; on a car with no room for that tab, its
  /// readings on a screen of their own. The shortcuts beside it open the rest.
  static func meshCard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Tile {
    let live = inputs.live
    let heard = heardCount(inputs)
    let signalTint = signalTint(snr: live.lastSNR)
    var signal = CarPlaySnapshot.Metric(
      id: "signal",
      symbol: "dot.radiowaves.forward",
      label: L10n.Tools.Tools.Spectrum.Figure.lastPacket,
      value: live.lastRSSI.map { dbm(Double($0)) } ?? "—",
      caption: live.lastSNR.map(decibels),
      gauge: .bars(SNRQuality(snr: live.lastSNR).barLevel, signalTint)
    )
    if live.lastRSSI == nil, let snr = live.lastSNR {
      signal = .init(id: "signal", symbol: signal.symbol, label: signal.label, value: decibels(snr), gauge: signal.gauge)
    }
    let metrics: [CarPlaySnapshot.Metric] = [
      signal,
      .init(
        id: "noise",
        symbol: CarPlayFeature.spectrum.symbol,
        label: L10n.Tools.Tools.Spectrum.Figure.noiseFloor,
        value: live.noiseFloor.map { dbm(Double($0)) } ?? "—"
      ),
      .init(
        id: "traffic",
        symbol: "waveform",
        label: L10n.Localizable.CarPlay.Cards.traffic,
        value: L10n.Localizable.CarPlay.Cards.perMinute(live.packetsPerMinute)
      ),
      .init(
        id: "heard",
        symbol: CarPlayAvatar.recentSymbol,
        label: L10n.Localizable.CarPlay.Cards.heard,
        value: heard.formatted()
      ),
      .init(
        id: "nodes",
        symbol: CarPlayFeature.nodes.symbol,
        label: L10n.Localizable.Tabs.nodes,
        value: inputs.contactCount.map { $0.formatted() } ?? "—",
        caption: newNodes(inputs)
      ),
    ]
    return .init(
      id: "mesh",
      symbol: CarPlayFeature.spectrum.symbol,
      tint: signalTint,
      title: short(signalText(rssi: live.lastRSSI, snr: live.lastSNR) ?? L10n.Localizable.CarPlay.Cards.mesh),
      subtitle: short(NodeRouteFormat.joined([
        L10n.Localizable.CarPlay.Cards.perMinute(live.packetsPerMinute),
        L10n.Localizable.CarPlay.Cards.heardCount(heard),
      ])),
      level: SNRQuality(snr: live.lastSNR).barLevel,
      action: tabIfShown(.spectrum, inputs) ?? .info(title: L10n.Localizable.CarPlay.Cards.mesh, rows: infoRows(metrics)),
      panel: .init(
        symbol: CarPlayFeature.spectrum.symbol,
        tint: .feature(.spectrum),
        heading: L10n.Localizable.CarPlay.Cards.mesh,
        status: live.lastSNR == nil ? nil : signalTint,
        metrics: metrics
      )
    )
  }

  /// A rich card's readings as a read-only screen's lines, for a card with nowhere else to go.
  static func infoRows(_ metrics: [CarPlaySnapshot.Metric]) -> [CarPlaySnapshot.InfoRow] {
    metrics.map { metric in
      .init(title: metric.label, detail: NodeRouteFormat.joined([metric.value, metric.caption]))
    }
  }

  /// The mesh's readings as condensed cards: the traffic opens Spectrum, whose traffic table lists
  /// it (left out on a car with no room for that tab: the Mesh card already shows the rate), and
  /// the nodes heard in the hour open Nodes.
  static func meshShortcuts(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.Tile] {
    let live = inputs.live
    var tiles: [CarPlaySnapshot.Tile] = []
    if let spectrum = tabIfShown(.spectrum, inputs) {
      tiles.append(.init(
        id: "traffic",
        symbol: "waveform",
        tint: .feature(.spectrum),
        title: short(L10n.Localizable.CarPlay.Cards.traffic),
        subtitle: L10n.Localizable.CarPlay.Cards.perMinute(live.packetsPerMinute),
        action: spectrum
      ))
    }
    return tiles + [
      .init(
        id: "heard",
        symbol: CarPlayAvatar.recentSymbol,
        tint: CarPlayAvatar.tint(.recentlyHeard),
        title: short(L10n.Localizable.CarPlay.Cards.heard),
        subtitle: heardCount(inputs).formatted(),
        action: nodesIfShown(.recentlyHeard, inputs)
      ),
    ]
  }

  /// Send Advert and Scan for Nodes as condensed cards (`radioTools`). Network Health stays off
  /// the card Dashboard.
  static func toolTiles(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.Tile] {
    CarPlaySnapshotBuilder.dashboardOptions(inputs).filter { $0.kind != .health }.map { option in
      CarPlaySnapshot.Tile(
        id: option.kind.rawValue,
        symbol: option.symbol,
        tint: option.tint,
        title: short(option.text),
        subtitle: short(option.detail),
        action: .option(option.kind),
        isEnabled: option.isEnabled
      )
    }
  }

  /// Unread, then the last message that would notify: who sent it and when, and where it came
  /// (a channel, or direct), and (with `CarPlayFeatures.messagePreview`) one short line of it.
  /// A tap opens Comm, where Siri reads the conversation.
  static func messagesCard(_ inputs: CarPlayInputs, now: Date) -> CarPlaySnapshot.Tile {
    let unread: String = if !inputs.isSiriAvailable {
      L10n.Localizable.CarPlay.Cards.siriOff
    } else if inputs.unread > 0 {
      L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(inputs.unread)
    } else {
      L10n.Localizable.CarPlay.Cards.noUnread
    }
    var metrics: [CarPlaySnapshot.Metric] = [.init(
      id: "unread",
      symbol: CarPlayFeature.comm.symbol,
      label: L10n.Chats.Chats.Filter.unread,
      value: inputs.isSiriAvailable ? inputs.unread.formatted() : short(L10n.Localizable.CarPlay.Cards.siriOff),
      valueTint: inputs.unread > 0 && inputs.isSiriAvailable ? .feature(.comm) : nil
    )]
    var subtitle: String?
    if let message = inputs.live.lastMessage {
      let sender = short(CarPlaySnapshotBuilder.glanceName(message.sender), limit: 12)
      let age = HomeFormat.age(now.timeIntervalSince(message.date))
      metrics.append(.init(
        id: "last",
        symbol: CarPlayAvatar.companionSymbol,
        label: L10n.Localizable.CarPlay.Cards.lastMessage,
        value: sender,
        caption: age
      ))
      metrics.append(.init(
        id: "place",
        symbol: message.channelName == nil ? "person.fill" : CarPlayAvatar.channelSymbol,
        label: message.channelName == nil ? L10n.Localizable.CarPlay.Cards.conversation : L10n.Localizable.CarPlay.Chats.Kind.channel,
        value: short(message.channelName ?? L10n.Localizable.CarPlay.Cards.direct)
      ))
      if CarPlayFeatures.messagePreview, !message.preview.isEmpty {
        // The sender over their line, as a message reads.
        metrics.append(.init(id: "preview", symbol: "text.bubble.fill", label: sender, value: short(message.preview), isWide: true))
      }
      subtitle = short(NodeRouteFormat.joined([sender, age]))
    } else {
      metrics.append(.init(
        id: "last",
        symbol: "text.bubble.fill",
        label: L10n.Localizable.CarPlay.Cards.lastMessage,
        value: short(L10n.Localizable.CarPlay.Cards.noMessages)
      ))
      subtitle = short(L10n.Localizable.CarPlay.Cards.noMessages)
    }
    return .init(
      id: "messages",
      symbol: CarPlayFeature.comm.symbol,
      tint: inputs.unread > 0 ? .feature(.comm) : .secondaryLabel,
      title: short(unread),
      subtitle: subtitle,
      action: tabIfShown(.comm, inputs),
      panel: .init(
        symbol: CarPlayFeature.comm.symbol,
        tint: .feature(.comm),
        heading: L10n.Localizable.CarPlay.Cards.messages,
        status: inputs.unread > 0 && inputs.isSiriAvailable ? .feature(.comm) : nil,
        metrics: metrics
      )
    )
  }

  /// The radio's GPS state, altitude and position as the Live Activity shows them (the altitude
  /// in the app's units), under the GPS state and how the location is shared. Only with a radio
  /// connected; a tap opens GPS.
  static func locationCard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Tile {
    let status = inputs.radio?.gpsStatus ?? .noRadio
    let statusTint = CarPlayTint.state(status.tint)
    var metrics: [CarPlaySnapshot.Metric] = [.init(
      id: "gps",
      symbol: CarPlayFeature.gps.symbol,
      label: L10n.Localizable.Tabs.gps,
      value: short(status.text, limit: 12),
      valueTint: statusTint == .secondaryLabel ? nil : statusTint
    )]
    if let altitude = inputs.live.altitudeText {
      metrics.append(.init(id: "altitude", symbol: "mountain.2.fill", label: L10n.Map.Map.Nav.altitude, value: altitude))
    }
    metrics.append(.init(
      id: "position",
      symbol: "mappin.and.ellipse",
      label: L10n.Map.Map.Gps.Segment.position,
      // Coordinates are never cut: a cut one would point somewhere else.
      value: inputs.live.positionText ?? short(L10n.Localizable.Home.Gps.noPosition)
    ))
    return .init(
      id: "location",
      symbol: CarPlayFeature.gps.symbol,
      tint: inputs.live.positionText == nil ? .secondaryLabel : .feature(.gps),
      title: short(status.text),
      subtitle: inputs.radio.map { short($0.locationSharing) },
      action: tabIfShown(.gps, inputs),
      panel: .init(
        symbol: CarPlayFeature.gps.symbol,
        tint: .feature(.gps),
        heading: L10n.Localizable.CarPlay.Cards.location,
        status: statusTint,
        metrics: metrics
      )
    )
  }

  // MARK: - Spectrum

  /// The Spectrum tab's one row of cards, the row Spectrum and GPS build.
  static let spectrumRowID = "spectrum"
  static let gpsRowID = "gps"
  static let gpsReadingsRowID = "readings"

  /// The Spectrum tab as the phone's page, one picture a card on one line: the header band (the
  /// condition, preset and frequency, modulation, power and airtime), the metric strip (NOW,
  /// FLOOR, AIR, PKT/MIN), the Channel chart and the traffic table. The chart and the table wait
  /// for their first readings. Nil for a car that draws rows.
  static func spectrum(_ state: CarPlayInputs.SpectrumState, inputs: CarPlayInputs) -> [CarPlaySnapshot.TileSection]? {
    guard inputs.usesCards else { return nil }
    guard inputs.isRadioReady, !inputs.isStarting else {
      let reason = CarPlayScanBuilder.blockedReason(inputs) ?? L10n.Localizable.CarPlay.Scan.notReady
      let tile = CarPlaySnapshot.Tile(
        id: "blocked",
        symbol: CarPlayFeature.spectrum.symbol,
        tint: .secondaryLabel,
        title: L10n.Localizable.Tabs.spectrum,
        subtitle: short(reason)
      )
      return [.init(header: nil, rows: [.init(id: spectrumRowID, title: nil, tiles: [tile])])]
    }
    let header = spectrumHeader(state)
    let readings = spectrumReadings(state)
    var cards: [CarPlaySnapshot.Tile] = [
      .init(
        id: "header",
        symbol: header.conditionSymbol ?? CarPlayFeature.spectrum.symbol,
        tint: header.conditionTint,
        title: short(header.condition),
        subtitle: short(NodeRouteFormat.joined([state.presetName, state.frequency])),
        picture: .spectrumHeader(header)
      ),
      .init(
        id: "readings",
        symbol: signalSymbol,
        tint: signalTint(snr: state.lastSNR),
        title: short(NodeRouteFormat.joined([readings.now, readings.margin])),
        subtitle: short(NodeRouteFormat.joined([readings.floor, readings.air])),
        level: SNRQuality(snr: state.lastSNR).barLevel,
        picture: .spectrumReadings(readings)
      ),
    ]
    if let revision = state.chartRevision {
      cards.append(.init(
        id: "chart",
        symbol: "chart.xyaxis.line",
        tint: .feature(.spectrum),
        title: short(L10n.Tools.Tools.Spectrum.Figure.channel),
        subtitle: short(readings.rate),
        picture: .spectrumChart(revision: revision)
      ))
      cards.append(.init(
        id: "traffic",
        symbol: "list.bullet",
        tint: .feature(.spectrum),
        title: short(L10n.Tools.Tools.Spectrum.Traffic.title),
        subtitle: short(readings.count),
        picture: .spectrumTraffic(revision: revision)
      ))
    }
    return [.init(header: nil, rows: [.init(id: spectrumRowID, title: nil, tiles: cards)])]
  }

  /// "Measuring…", or "Calibrating…" while the radio's floor hasn't settled.
  private static func measuring(_ state: CarPlayInputs.SpectrumState) -> String {
    state.isCalibrating ? L10n.Tools.Tools.Spectrum.Meter.calibrating : L10n.Tools.Tools.Spectrum.measuring
  }

  /// The header band's words, as `SpectrumHeaderBand` puts them.
  static func spectrumHeader(_ state: CarPlayInputs.SpectrumState) -> CarPlaySnapshot.SpectrumHeaderPicture {
    let condition: ChannelCondition? = if let floor = state.noiseFloor, let channel = state.channel {
      ChannelCondition(desensitization: channel.desensitization(noiseFloor: floor))
    } else {
      nil
    }
    return .init(
      condition: condition?.title ?? (state.statsUnsupported ? L10n.Localizable.CarPlay.Spectrum.unsupported : measuring(state)),
      conditionSymbol: condition?.systemImage,
      conditionTint: condition.map { .color($0.color) } ?? .secondaryLabel,
      preset: state.presetName ?? "—",
      frequency: state.frequency ?? "",
      modulation: state.modulation ?? "",
      txPower: state.txPower,
      airtime: state.airtimePerPacket ?? ""
    )
  }

  /// The metric strip's four readings, worded as the phone's (`SpectrumNowMetric`,
  /// `SpectrumFloorMetric`, `SpectrumAirMetric` and the packet rate).
  static func spectrumReadings(_ state: CarPlayInputs.SpectrumState) -> CarPlaySnapshot.SpectrumReadingsPicture {
    let percent: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(1))) }
    let floor = state.noiseFloor
    let margin = SpectrumStats.margin(packetRSSI: state.nowRSSI, floor: floor)
    let load = state.airtime.map { SpectrumStats.Load(share: min(1, $0.rx + $0.tx)) }
    let loadText = load?.title
    let loadTint = load?.color.map(CarPlayTint.color)
    let trend = floor == nil ? nil : state.trend
    return .init(
      now: state.nowRSSI.map(SpectrumFormat.dBm) ?? "—",
      margin: margin.map { (floor == nil ? "≈ " : "") + SpectrumFormat.signedDB($0) },
      isClear: margin.map { $0 >= SpectrumStats.clearMargin } == true,
      snr: state.lastSNR.map { L10n.Tools.Tools.Spectrum.Detail.snr($0.formatted(.number.precision(.fractionLength(1)))) },
      floor: floor.map(SpectrumFormat.dBm)
        ?? (state.isCalibrating ? "≈ " + SpectrumFormat.dBm(SpectrumStats.uncalibratedFloor) : "—"),
      hasFloor: floor != nil,
      trend: trend?.title,
      trendSymbol: trend.map(trendSymbol),
      history: state.history.suffix(historyLength).map { Int($0.rounded()) },
      air: state.airtime.map { percent(min(1, $0.rx + $0.tx)) } ?? "—",
      split: state.airtime.map { L10n.Tools.Tools.Spectrum.Meter.airCaption(percent($0.rx), percent($0.tx)) },
      splitArrows: state.airtime.map { "↓" + percent($0.rx) + " ↑" + percent($0.tx) },
      load: loadText,
      loadTint: loadTint,
      rate: state.packetsPerMinute.map {
        L10n.Tools.Tools.Spectrum.Figure.perMinute($0.formatted(.number.precision(.fractionLength(1))))
      } ?? "—",
      count: state.packetsPerMinute == nil ? measuring(state) : L10n.Tools.Tools.RxLog.packetsCount(state.packetCount),
      peak: state.peak.map { L10n.Tools.Tools.Spectrum.Meter.peakPacket(SpectrumFormat.dBm($0)) }
    )
  }

  /// Readings the floor's history line draws: ten minutes at the car's 10-second pace.
  static let historyLength = 60

  /// The floor's direction as the phone's FLOOR draws it.
  static func trendSymbol(_ trend: NoiseTrend) -> String {
    switch trend {
    case .rising: "arrow.up.right"
    case .steady: "arrow.right"
    case .falling: "arrow.down.right"
    }
  }

  // MARK: - GPS

  /// The GPS tab as the phone's Position page: the compass, the map preview, the radio's and the
  /// phone's cards as pictures on one line, then the readings both sides have and how the
  /// location is shared as one condensed line. The map waits for its first snapshot, and stays
  /// away without a position to centre on, as on the phone. Nil for a car that draws rows.
  static func gps(_ state: CarPlayInputs.GPSState, inputs: CarPlayInputs) -> [CarPlaySnapshot.TileSection]? {
    guard inputs.usesCards else { return nil }
    let radioStatus = state.radioStatus ?? .noRadio
    var cards: [CarPlaySnapshot.Tile] = []
    let compass = compassPicture(state)
    cards.append(.init(
      id: "compass",
      symbol: "location.north.line",
      tint: compass.course == nil ? .secondaryLabel : .feature(.gps),
      title: short(L10n.Map.Map.Gps.heading),
      subtitle: short(NodeRouteFormat.joined([compass.reading, compass.speed])),
      picture: .compass(compass)
    ))
    if let revision = state.mapRevision {
      cards.append(.init(
        id: "map",
        symbol: "map",
        tint: .feature(.gps),
        title: short(L10n.Localizable.Tabs.map),
        // Coordinates are never cut: a cut one would point somewhere else.
        subtitle: state.radioPosition ?? phonePosition(state),
        picture: .gpsMap(revision: revision)
      ))
    }
    cards.append(.init(
      id: "radio",
      symbol: "antenna.radiowaves.left.and.right",
      tint: CarPlayTint.state(radioStatus.tint),
      title: short(L10n.Map.Map.Gps.Dash.radio),
      subtitle: short(radioStatus.text),
      picture: .gnssDevice(.init(
        side: .radio,
        detail: state.radioName,
        status: radioStatus,
        latitude: state.radioLatitude,
        longitude: state.radioLongitude,
        caption: state.source,
        note: state.radioStatus == nil ? L10n.Map.Map.Gps.notConnected : nil
      ))
    ))
    cards.append(.init(
      id: "phone",
      symbol: "iphone",
      tint: state.phoneHasFix ? .feature(.gps) : .secondaryLabel,
      title: short(L10n.Map.Map.Gps.Dash.phone),
      subtitle: short(NodeRouteFormat.joined([state.phoneStatus, state.phoneAccuracy])),
      picture: .gnssDevice(.init(
        side: .phone,
        status: state.phoneGNSSStatus,
        latitude: state.phoneLatitude,
        longitude: state.phoneLongitude,
        accuracy: state.phoneAccuracyMeters,
        isApproximate: state.isApproximate,
        note: state.phoneNote
      ))
    ))
    var rows = [CarPlaySnapshot.TileRow(id: gpsRowID, title: nil, tiles: cards)]

    var details = state.readings
      .filter { !CarPlaySnapshotBuilder.gpsSkippedReadings.contains($0.id) }
      .map { reading in
        CarPlaySnapshot.Tile(
          id: reading.id,
          symbol: reading.systemImage,
          tint: .feature(.gps),
          title: short(reading.title),
          subtitle: short(reading.value)
        )
      }
    if state.radioStatus != nil {
      details.append(.init(
        id: "sharing",
        symbol: "location.circle",
        tint: .feature(.gps),
        title: short(L10n.Localizable.CarPlay.Gps.sharing),
        subtitle: short(state.advert ?? state.sharing)
      ))
    }
    if !details.isEmpty {
      rows.append(.init(id: gpsReadingsRowID, title: nil, tiles: details, style: .condensed))
    }
    return [.init(header: nil, rows: rows)]
  }

  private static func phonePosition(_ state: CarPlayInputs.GPSState) -> String? {
    guard let latitude = state.phoneLatitude, let longitude = state.phoneLongitude else { return nil }
    return GPSFormat.coordinatePairText(.init(latitude: latitude, longitude: longitude))
  }

  /// Course steps the compass is drawn in: finer would redraw it on every wobble of the fix.
  static let courseStep = 5.0

  /// The compass as the phone's card, the needle on the course over ground.
  static func compassPicture(_ state: CarPlayInputs.GPSState) -> CarPlaySnapshot.CompassPicture {
    let course = state.course.map { (($0 / courseStep).rounded() * courseStep).truncatingRemainder(dividingBy: 360) }
    return .init(
      course: course,
      reading: course.map(GPSFormat.bearingText) ?? L10n.Map.Map.Gps.noHeading,
      speed: state.speed
    )
  }
}
