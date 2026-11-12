import CairnServices
import SwiftUI

/// Result of a ping operation
enum PingResult {
  case success(latencyMs: Int, snrThere: Double, snrBack: Double)
  case error(String)

  /// A round trip's colour: green up to 1.5 s, orange up to 4 s, red beyond. A zero-hop ping over
  /// LoRa usually returns in well under two seconds; much longer means a weak or busy link.
  static func latencyColor(_ latencyMs: Int) -> Color {
    switch latencyMs {
    case ...1500: .green
    case ...4000: .orange
    default: .red
    }
  }
}

/// What Contact Detail knows about a node, read from what the app already holds (the contact, the
/// RX log, stored status snapshots) plus the latest ping, as the Dashboard's Home-style cards.
/// The type, route and distance are the header's, so no card repeats them.
struct ContactDashboardReadings {
  let contact: ContactDTO
  /// The last packet the RX log holds from the node.
  var signal: RxLogEntryDTO?
  /// The path `signal` took to this radio (`NodeHeardSignal.heardPath`), relays named where known:
  /// shortened for the card, in full for its sheet.
  var heardPath: String?
  var heardPathFull: String?
  /// How this radio and the node hear each other, when the radio heard it directly lately.
  var link: NodeLinkSignal?
  /// The latest stored status reading, for repeaters and rooms.
  var storedStatus: NodeStatusSnapshotDTO?
  /// The node's battery curve, for the stored battery's percentage.
  var ocvValues: [Int] = []
  /// The stored battery readings of the last week, for the Battery card's trend line.
  var batteryTrend: [MetricChartView.DataPoint] = []
  var pingResult: PingResult?
  var isPinging = false

  /// Where each card goes; nil leaves the card out (the Messages card where there's no chat).
  struct Actions {
    var openChat: (() -> Void)?
    var ping: (() -> Void)?
  }

  private static let snrFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))

  /// Heard, Signal, then for a repeater or room its stored Battery and Uptime, Messages for a
  /// person, and Ping once one has been sent: the readings first, the action results after.
  @MainActor
  func cards(now: Date, actions: Actions) -> [NodeDashboardCardItem] {
    var cards = [heardCard(now: now), signalCard(now: now)]
    if let battery = batteryCard(now: now) { cards.append(battery) }
    // the uptime is a line on the Battery card (the user, 2026-11-09: a card of its own for one figure);
    // alone only when there's no battery reading to put it on
    if batteryCard(now: now) == nil, let uptime = uptimeCard(now: now) { cards.append(uptime) }
    if let openChat = actions.openChat { cards.append(messagesCard(open: openChat)) }
    if let ping = actions.ping, let card = pingCard(again: ping) { cards.append(card) }
    return cards
  }

  // MARK: Cards

  /// The node's stored snapshots, where every reading here is charted.
  private var history: NodeHistoryTarget {
    NodeHistoryTarget(publicKey: contact.publicKey, radioID: contact.radioID, showNeighbors: contact.type != .chat)
  }

  /// "5 min ago · Oct 5, 9:14 PM": how long ago, then exactly when.
  @MainActor
  private static func when(_ date: Date?, now: Date) -> String {
    guard let date else { return NodeStatusViewModel.emDash }
    return NodeRouteFormat.joined([
      ContactReadingsFormat.relative(date, now: now),
      date.formatted(date: .abbreviated, time: .shortened),
    ])
  }

  /// The last packet's kind and how it travelled: "Advert · Flood".
  private var packetKind: String? {
    guard let signal else { return nil }
    return NodeRouteFormat.joined([
      signal.payloadType == .advert ? L10n.Tools.Tools.Spectrum.Kind.advert : L10n.Tools.Tools.Spectrum.Kind.message,
      signal.isFlood ? L10n.Contacts.Contacts.Route.flood : L10n.Contacts.Contacts.Route.direct,
    ])
  }

  /// How messages go out: "2 hops · A3 → 7F", or Flood.
  private var outboundRoute: String {
    if contact.isFloodRouted { return L10n.Contacts.Contacts.Route.flood }
    if contact.pathHopCount == 0 { return L10n.Contacts.Contacts.Route.direct }
    return NodeRouteFormat.joined([NodeRouteFormat.hopCount(contact.pathHopCount), contact.pathString])
  }

  /// When the node was last heard, with its last advert and the relays it came through. Its page
  /// sets the way in beside the way out, with the packet that was heard.
  @MainActor
  private func heardCard(now: Date) -> NodeDashboardCardItem {
    let heard = contact.lastHeardTimestamp.flatMap(ContactReadingsFormat.date(fromTimestamp:))
    let advert = ContactReadingsFormat.date(fromTimestamp: contact.lastAdvertTimestamp)
    var details = [
      "\(L10n.Contacts.Contacts.Detail.lastAdvert) \(ContactReadingsFormat.relative(advert, now: now))",
    ]
    if let via = heardVia {
      details.append("\(L10n.Contacts.Contacts.Detail.heardVia) \(via)")
    }
    let detail = L10n.Contacts.Contacts.Detail.self
    let info = L10n.Chats.Chats.Message.Info.Title.self
    var facts: [NodeReadingDetail.Fact] = [
      .init(title: detail.lastHeard, value: Self.when(heard, now: now)),
      .init(title: detail.lastAdvert, value: Self.when(advert, now: now)),
    ]
    if let signal {
      facts.append(.init(title: detail.heardVia, value: heardPathFull ?? heardVia ?? NodeStatusViewModel.emDash))
      if signal.isFlood {
        facts.append(.init(title: info.hops, value: signal.hopCount == 0
          ? L10n.Contacts.Contacts.Route.direct
          : NodeRouteFormat.hopCount(signal.hopCount)))
      }
      facts.append(.init(title: L10n.Tools.Tools.Spectrum.Detail.title, value: packetKind ?? NodeStatusViewModel.emDash))
      facts.append(.init(title: info.received, value: Self.when(signal.receivedAt, now: now)))
    }
    facts.append(.init(title: detail.outboundPath, value: outboundRoute))
    return NodeDashboardCardItem(
      id: "heard",
      title: detail.lastHeard,
      systemImage: "ear",
      tint: .teal,
      value: ContactReadingsFormat.relative(heard, now: now),
      valueTint: heard == nil ? .secondary : .primary,
      details: details,
      // Nothing to chart: its facts on a page of their own (the user, 2026-11-08).
      destination: .details(.init(facts: facts, history: nil))
    )
  }

  /// The relays the last packet came through, or Direct; nil when unknown.
  private var heardVia: String? {
    signal == nil ? nil : heardPath
  }

  /// The Signal card: the last packet heard from the node and, for a neighbour, both directions.
  @MainActor
  private func signalCard(now: Date) -> NodeDashboardCardItem {
    .heardSignal(packet: signal, heardPath: heardPathFull ?? heardVia, link: link, history: history, now: now)
  }

  /// The battery's last stored reading. Its sheet adds the curve the charge was read from.
  @MainActor
  private func batteryCard(now: Date) -> NodeDashboardCardItem? {
    guard let storedStatus, let millivolts = storedStatus.batteryMillivolts else { return nil }
    let percent = BatteryInfo(level: Int(millivolts)).percentage(using: ocvValues)
    let level = BatteryLevel(percent: percent)
    let warns = level != .good
    let voltage = BatteryLevel.formattedVoltage(Double(millivolts) / 1000)
    let status = L10n.RemoteNodes.RemoteNodes.Status.self
    return NodeDashboardCardItem(
      id: "battery",
      title: status.battery,
      systemImage: BatteryLevel.symbol(for: percent),
      tint: level.tint,
      value: BatteryLevel.formattedPercent(percent),
      // The charge in its level's colour: green, orange when low, red when critical.
      valueTint: level.tint,
      note: level.title,
      noteTint: warns ? level.tint : .secondary,
      details: [
        voltage,
        storedStatus.uptimeSeconds.map { "\(status.uptime) \(NodeStatusViewModel.formatDuration($0))" },
        StoredReadingFormat.asOf(storedStatus.timestamp, now: now),
      ].compactMap(\.self),
      destination: .history(
        history,
        scope: .battery,
        orFacts: [
          .init(
            title: status.battery,
            value: NodeRouteFormat.joined([BatteryLevel.formattedPercent(percent), level.title]),
            tint: level.tint
          ),
          .init(title: L10n.Settings.Battery.voltage, value: voltage),
          .init(title: status.batteryCurve, value: contact.ocvPreset ?? NodeStatusViewModel.emDash),
          .init(title: L10n.Chats.Chats.Message.Info.Title.received, value: Self.when(storedStatus.timestamp, now: now)),
        ],
        footnote: status.batteryCurveFooter
      ),
      trend: NodeBatteryTrend.series(batteryTrend, tint: level.tint)
    )
  }

  /// How long the node has been running, at its last stored reading. It opens the uptime's
  /// history, where a drop is a restart.
  @MainActor
  private func uptimeCard(now: Date) -> NodeDashboardCardItem? {
    guard let storedStatus, let uptime = storedStatus.uptimeSeconds else { return nil }
    let status = L10n.RemoteNodes.RemoteNodes.Status.self
    let started = storedStatus.timestamp.addingTimeInterval(-TimeInterval(uptime))
    return NodeDashboardCardItem(
      id: "uptime",
      title: status.uptime,
      systemImage: "clock",
      tint: .gray,
      value: NodeStatusViewModel.formatDuration(uptime),
      details: [StoredReadingFormat.asOf(storedStatus.timestamp, now: now)],
      destination: .history(
        history,
        scope: .uptime,
        orFacts: [
          .init(title: status.uptime, value: NodeStatusViewModel.formatDuration(uptime)),
          .init(title: L10n.Settings.DeviceInfo.SinceBoot.header, value: started.formatted(date: .abbreviated, time: .shortened)),
          .init(title: L10n.Chats.Chats.Message.Info.Title.received, value: Self.when(storedStatus.timestamp, now: now)),
        ]
      )
    )
  }

  /// A person's unread messages, opening the chat.
  private func messagesCard(open: @escaping () -> Void) -> NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "messages",
      title: L10n.Contacts.Contacts.Detail.unreadMessages,
      systemImage: "message.fill",
      tint: .green,
      value: contact.unreadCount.formatted(),
      valueTint: contact.unreadCount > 0 ? .primary : .secondary,
      destination: .action(open)
    )
  }

  /// The latest zero-hop ping: round-trip time, the SNR each way, and a tap pings again.
  @MainActor
  private func pingCard(again: @escaping () -> Void) -> NodeDashboardCardItem? {
    let title = L10n.Contacts.Contacts.Detail.ping
    if isPinging {
      return NodeDashboardCardItem(
        id: "ping", title: title, systemImage: "wave.3.right", tint: .green,
        value: NodeStatusViewModel.emDash, valueTint: .secondary,
        note: L10n.RemoteNodes.RemoteNodes.Settings.loading,
        destination: .action(again)
      )
    }
    switch pingResult {
    case let .success(latencyMs, snrThere, snrBack):
      return NodeDashboardCardItem(
        id: "ping", title: title, systemImage: "wave.3.right", tint: .green,
        value: Duration.milliseconds(latencyMs).formatted(.units(allowed: [.milliseconds], width: .abbreviated)),
        valueTint: PingResult.latencyColor(latencyMs),
        details: [L10n.Contacts.Contacts.Detail.pingSNR(
          snrThere.formatted(Self.snrFormat),
          snrBack.formatted(Self.snrFormat)
        )],
        destination: .action(again)
      )
    case let .error(message):
      return NodeDashboardCardItem(
        id: "ping", title: title, systemImage: "wave.3.right", tint: .orange,
        value: L10n.Contacts.Contacts.Detail.pingFailureAnnouncement, valueTint: .orange,
        details: [message],
        destination: .action(again)
      )
    case nil:
      return nil
    }
  }
}

// MARK: - Signal Card

extension NodeDashboardCardItem {
  /// A node's Signal card from what this radio heard of it: the SNR of the last packet the RX log
  /// holds from it, and, for a node heard directly, how well each side hears the other, as Scan &
  /// Traffic's list says it (``NodeLinkSignal``). Its sheet adds the signal's quality, the RSSI, the
  /// packet and the path it came by, and how the radio heard the node.
  ///
  /// - Parameters:
  ///   - packet: The last packet heard from the node, nil when the RX log holds none.
  ///   - heardPath: The relays `packet` came through, or Direct.
  ///   - history: The node's stored snapshots, nil for a node with none (not saved).
  @MainActor
  static func heardSignal(
    packet: RxLogEntryDTO?,
    heardPath: String?,
    link: NodeLinkSignal?,
    history: NodeHistoryTarget?,
    now: Date
  ) -> NodeDashboardCardItem {
    let info = L10n.Chats.Chats.Message.Info.Title.self
    let snr = packet?.snr ?? link?.youHearThem
    var facts: [NodeReadingDetail.Fact] = []
    if let packet {
      if let packetSNR = packet.snr {
        facts.append(.init(
          title: info.snr,
          value: NodeRouteFormat.joined([
            L10n.Tools.Tools.Spectrum.Value.db(SpectrumPacketFormat.snr(packetSNR)),
            packet.snrQualityLabel,
          ]),
          tint: packet.snrQuality.textColor
        ))
      }
      if let rssi = packet.rssi {
        facts.append(.init(title: L10n.RemoteNodes.RemoteNodes.Status.lastRssi, value: SpectrumFormat.dBm(Double(rssi))))
      }
      facts.append(.init(title: L10n.Contacts.Contacts.Detail.heardVia, value: heardPath ?? NodeStatusViewModel.emDash))
      facts.append(.init(
        title: L10n.Tools.Tools.Spectrum.Detail.title,
        value: NodeRouteFormat.joined([
          packet.payloadType == .advert ? L10n.Tools.Tools.Spectrum.Kind.advert : L10n.Tools.Tools.Spectrum.Kind.message,
          packet.isFlood ? L10n.Contacts.Contacts.Route.flood : L10n.Contacts.Contacts.Route.direct,
        ])
      ))
      facts.append(.init(title: info.received, value: NodeRouteFormat.joined([
        ContactReadingsFormat.relative(packet.receivedAt, now: now),
        packet.receivedAt.formatted(date: .abbreviated, time: .shortened),
      ])))
    }
    if let link {
      facts += link.facts(now: now)
    }

    // Both directions first, the figures people come for; then the last packet's RSSI and age.
    var details = link?.detailLines ?? []
    if let packet {
      if let rssi = packet.rssi {
        details.append("\(L10n.RemoteNodes.RemoteNodes.Status.lastRssi) \(SpectrumFormat.dBm(Double(rssi)))")
      }
      details.append(StoredReadingFormat.asOf(packet.receivedAt, now: now))
    }

    return NodeDashboardCardItem(
      id: "signal",
      title: L10n.RemoteNodes.RemoteNodes.Status.signal,
      systemImage: "cellularbars",
      tint: .blue,
      value: snr.map { L10n.Tools.Tools.Spectrum.Value.db(SpectrumPacketFormat.snr($0)) } ?? NodeStatusViewModel.emDash,
      // The SNR in its quality's colour: green, orange when fair, red when poor.
      valueTint: snr == nil ? .secondary : SNRQuality(snr: snr).textColor,
      details: details,
      destination: .history(history, scope: .signal, orFacts: facts)
    )
  }
}

// MARK: - Link

/// How this radio and a node hear each other, as Scan & Traffic's list says it: how well you hear
/// them, how well they hear you once a scan reply or link check measured it, how the radio heard
/// them (an advert, relaying, an answer to a scan), how long ago, and how far it carried. Read from
/// the neighbour directory, so only for a node this radio heard directly in the last day.
@MainActor
struct NodeLinkSignal {
  let entry: NodeDiscoveryEntry
  /// This radio's smoothed SNR for the node's transmissions; nil when no reception carried one.
  let youHearThem: Double?

  /// Nil when the radio hasn't heard the node directly lately, or only as a relay hash it can't
  /// pin on the node.
  init?(publicKey: Data, directory: NeighbourDirectory, now: Date) {
    guard let neighbour = directory.neighbour(publicKey: publicKey, now: now) else { return nil }
    let filter: NodeDiscoveryFilter = neighbour.isListed(as: .sensors) ? .sensors : .repeaters
    let results = NodeDiscoveryViewModel.makeResults([neighbour], filter: filter, storedNames: [:], now: now)
    guard let entry = NodeDiscoveryEntries.make(results: results, contacts: [:], discovered: [:]).first else { return nil }
    self.entry = entry
    youHearThem = neighbour.signal
  }

  /// How well the node hears this radio, once a scan reply or a link check measured it.
  var theyHearYou: Double? { entry.result.uplinkSNR }

  /// "You hear them +8.5 dB", then "They hear you +5.0 dB" once measured: a card's lines.
  var detailLines: [String] {
    let scan = L10n.Tools.Tools.NodeDiscovery.self
    return [
      youHearThem.map { "\(scan.youHearThem) \(NodeDiscoveryFormat.snr($0))" },
      theyHearYou.map { "\(scan.theyHearYou) \(NodeDiscoveryFormat.snr($0))" },
    ].compactMap(\.self)
  }

  /// Both directions with their quality, the scan's evidence, how long ago, and how far it carried.
  func facts(now: Date) -> [NodeReadingDetail.Fact] {
    let scan = L10n.Tools.Tools.NodeDiscovery.self
    let result = entry.result
    var facts: [NodeReadingDetail.Fact] = []
    if let youHearThem {
      facts.append(Self.snrFact(scan.youHearThem, snr: youHearThem))
    }
    if let theyHearYou {
      facts.append(Self.snrFact(scan.theyHearYou, snr: theyHearYou))
    }
    let badges = NodeDiscoveryFormat.badges(result)
    if !badges.isEmpty {
      facts.append(.init(title: scan.heardAs, value: badges.map(\.title).joined(separator: ", ")))
    }
    facts.append(.init(
      title: L10n.Contacts.Contacts.Detail.lastHeard,
      value: NodeDiscoveryFormat.freshness(lastHeard: result.receivedAt, now: now)
    ))
    if let distance = NodeDiscoveryFormat.distanceAndDirection(entry) {
      facts.append(.init(title: scan.distanceWhenHeard, value: distance))
    }
    return facts
  }

  private static func snrFact(_ title: String, snr: Double) -> NodeReadingDetail.Fact {
    let quality = SNRQuality(snr: snr)
    return .init(
      title: title,
      value: NodeRouteFormat.joined([NodeDiscoveryFormat.snr(snr), quality.localizedLabel]),
      tint: quality.textColor
    )
  }
}

enum ContactReadingsFormat {
  /// Wire-format unix seconds; 0 means the radio never reported one.
  static func date(fromTimestamp timestamp: UInt32) -> Date? {
    timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
  }

  /// "5 min", or "—" when it never happened.
  @MainActor
  static func relative(_ date: Date?, now: Date) -> String {
    date.map { RelativeTimestampText.format(date: $0, relativeTo: now) } ?? NodeStatusViewModel.emDash
  }
}

extension View {
  /// A Copy menu for a value shown as text, such as coordinates, that people paste elsewhere.
  func copyValueContextMenu(_ value: String) -> some View {
    contextMenu {
      Button {
        UIPasteboard.general.string = value
      } label: {
        Label(L10n.Contacts.Contacts.Qr.copy, systemImage: "doc.on.doc")
      }
    }
  }
}
