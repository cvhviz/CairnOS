import CairnServices
import SwiftUI

struct ActionsDetailsSection: View {

  let message: MessageDTO
  let availability: MessageActionAvailability
  @Binding var isDetailExpanded: Bool
  let repeats: [MessageRepeatDTO]?
  let pathViewModel: MessagePathViewModel
  /// The RX log row of an incoming message's first copy: its RSSI and live reception time.
  var receptionEntry: RxLogEntryDTO?

  private var arrivals: [MessagePathArrival] {
    MessagePathArrivals.assemble(
      message: message,
      repeats: repeats ?? [],
      canonicalRSSI: receptionEntry?.rssi
    )
  }

  private var incomingArrivalCount: Int {
    if repeats == nil {
      max(arrivals.count, MessagePathArrivals.arrivalCount(for: message))
    } else {
      arrivals.count
    }
  }

  var body: some View {
    // The readings first (hops, signal, when it was sent and heard), right under the actions,
    // then who passed it on, then the full path: the facts most looked for are on the half-height
    // sheet without a scroll.
    VStack(alignment: .leading, spacing: 0) {
      Text(L10n.Chats.Chats.Message.Action.details)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)

      MetricTileGrid {
        if message.isOutgoing {
          ActionsOutgoingDetailTiles(message: message)
        } else {
          ActionsIncomingDetailTiles(
            message: message,
            arrivalCount: incomingArrivalCount,
            receptionEntry: receptionEntry
          )
        }
      }
      .padding(.horizontal)
      // The sheet sits on the plain system background, where the grouped card fill the tiles
      // default to is the same white in light mode.
      .cardFill(Color(.secondarySystemBackground))

      if repeats != nil {
        ActionsHeardBySection(
          message: message,
          arrivals: arrivals,
          pathViewModel: pathViewModel
        )
      }

      if availability.showsPathDetail {
        MessagePathDetailBlock(
          message: message,
          arrivals: arrivals,
          pathViewModel: pathViewModel,
          isDetailExpanded: $isDetailExpanded
        )
        .padding(.top, 8)
      }
    }
  }
}

/// A send or receive moment as a tile: the time is the reading, the date its context. Also used
/// by the room message sheet.
struct MessageTimeTile: View {
  let title: String
  let systemImage: String
  let date: Date
  var note: String?

  var body: some View {
    MetricTile(
      title,
      systemImage: systemImage,
      value: date.formatted(date: .omitted, time: .standard),
      caption: [date.formatted(date: .abbreviated, time: .omitted), note]
        .compactMap(\.self)
        .joined(separator: " ")
    )
  }
}

private struct ActionsOutgoingDetailTiles: View {
  let message: MessageDTO

  var body: some View {
    MessageTimeTile(
      title: L10n.Chats.Chats.Message.Info.Title.sent,
      systemImage: message.sentFromRadio ? "antenna.radiowaves.left.and.right" : "paperplane",
      date: message.senderDate,
      note: message.sentFromRadio ? L10n.Chats.Chats.Message.Info.sentFromRadio : nil
    )

    if let rtt = message.roundTripTime {
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.roundTrip,
        systemImage: "arrow.triangle.2.circlepath",
        value: Measurement(value: Double(rtt), unit: UnitDuration.milliseconds)
          .formatted(.measurement(
            width: .abbreviated,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0))
          ))
      )
    }

    if message.heardRepeats > 0 || message.isChannelMessage {
      // A channel message has no ACK: its echoes are the only sign it went out, so a zero
      // reads as such once the echo wait is over.
      let state = ChannelEchoTiming.state(
        heardRepeats: message.heardRepeats,
        sentAt: message.senderDate,
        now: .now
      )
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.heardRepeats,
        systemImage: "dot.radiowaves.left.and.right",
        value: message.heardRepeats.formatted(),
        caption: message.status == .sent && state == .notHeard
          ? L10n.Chats.Chats.Message.Heard.noneAccessibilityLabel
          : nil,
        statusSymbol: message.status == .sent && state == .notHeard ? "exclamationmark.triangle.fill" : nil
      )
    }

    if message.sendCount > 1 {
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.attempts,
        systemImage: "paperplane",
        value: message.sendCount.formatted()
      )
    }
  }
}

private struct ActionsIncomingDetailTiles: View {
  let message: MessageDTO
  let arrivalCount: Int
  let receptionEntry: RxLogEntryDTO?

  /// Hops and SNR describe the first copy heard; say so when more copies arrived later.
  private var firstArrivalCaption: String? {
    arrivalCount > 1 ? L10n.Chats.Chats.Message.Info.firstOfArrivals(arrivalCount) : nil
  }

  var body: some View {
    MetricTile(
      L10n.Chats.Chats.Message.Info.Title.hops,
      systemImage: "arrowshape.bounce.right",
      value: message.isDirectRouted
        ? L10n.Chats.Chats.Message.Hops.direct
        : message.hopCount.formatted(),
      caption: firstArrivalCaption
    )

    if let snr = message.snr {
      let quality = SNRQuality(snr: snr)
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.snr,
        systemImage: "cellularbars",
        value: "\(snr.formatted(.number.precision(.fractionLength(1)))) dB",
        caption: [quality.localizedLabel, firstArrivalCaption]
          .compactMap(\.self)
          .joined(separator: " · "),
        valueTint: quality.color
      )
    }

    if let rssi = receptionEntry?.rssi {
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.rssi,
        systemImage: "antenna.radiowaves.left.and.right",
        value: "\(rssi) dBm",
        caption: firstArrivalCaption
      )
    }

    if let region = MessageRegionReading(message: message) {
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.region,
        systemImage: "globe",
        value: region.value,
        caption: region.caption
      )
    }

    if let hashSize = message.pathHashSizeIfKnown {
      MetricTile(
        L10n.Chats.Chats.Message.Info.Title.pathHash,
        systemImage: "number",
        value: Int64(hashSize).formatted(.byteCount(style: .memory))
      )
    }

    MessageTimeTile(
      title: L10n.Chats.Chats.Message.Info.Title.sent,
      systemImage: "paperplane",
      date: message.senderDate,
      note: message.timestampCorrected ? L10n.Chats.Chats.Message.Info.adjusted : nil
    )

    if message.timestampCorrected {
      MessageTimeTile(
        title: L10n.Chats.Chats.Message.Info.Title.originalSend,
        systemImage: "clock.arrow.circlepath",
        date: message.wireSentDate
      )
    }

    MessageTimeTile(
      title: L10n.Chats.Chats.Message.Info.Title.received,
      systemImage: "tray.and.arrow.down",
      date: message.createdAt
    )

    // The RX log's time is when the radio heard it live; the message row's can be later (a
    // message queued on the radio while the app was away), so only the live time says
    // anything about transit or the sender's clock.
    if let heardAt = receptionEntry?.receivedAt {
      MessageClockTile(reading: MessageClockReading(sent: message.wireSentDate, heard: heardAt))
    }
  }
}

/// Time between the sender's stamp and this radio hearing it, flagged when only a clock offset
/// explains it.
struct MessageClockTile: View {
  let reading: MessageClockReading

  var body: some View {
    let text = MessageClockText(reading: reading)
    MetricTile(
      L10n.Chats.Chats.Message.Info.Title.clock,
      systemImage: "clock",
      value: text.value,
      caption: text.caption,
      statusSymbol: reading.suggestsClockOffset ? "exclamationmark.triangle.fill" : nil
    )
  }
}

/// Words for a `MessageClockReading`, kept pure for tests.
struct MessageClockText: Equatable {
  let value: String
  let caption: String

  init(reading: MessageClockReading) {
    let strings = L10n.Chats.Chats.Message.Info.Clock.self
    switch reading {
    case let .inTransit(seconds):
      value = Self.duration(seconds)
      caption = strings.inTransit
    case let .senderAhead(seconds):
      value = Self.duration(seconds)
      caption = strings.senderAhead
    case let .senderBehind(seconds):
      value = Self.duration(seconds)
      caption = strings.senderBehind
    }
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let rounded = seconds.rounded()
    let units: Set<Duration.UnitsFormatStyle.Unit> = switch rounded {
    case ..<60: [.seconds]
    case ..<3600: [.minutes, .seconds]
    case ..<86400: [.hours, .minutes]
    default: [.days, .hours]
    }
    return Duration.seconds(rounded).formatted(.units(allowed: units, width: .narrow, maximumUnitCount: 2))
  }
}

/// The region a received message was flooded under, as a tile value plus an optional caption.
struct MessageRegionReading: Equatable {
  let value: String
  let caption: String?

  /// A region only applies to flood routing. A plain flood is stated as unscoped so it
  /// does not read like a route that was never correlated, which has no reading.
  init?(message: MessageDTO) {
    let strings = L10n.Chats.Chats.Message.Info.Region.self
    switch message.routeType {
    case .tcFlood:
      switch RegionScopeSemantics.coalesce(
        scope: message.regionScope,
        matches: message.regionScopeMatches
      ) {
      case .none:
        self.init(value: strings.unknown, caption: nil)
      case let .unique(name):
        self.init(value: name, caption: nil)
      case let .ambiguous(names):
        self.init(value: ListFormatter.localizedString(byJoining: names), caption: strings.ambiguous)
      }
    case .flood:
      self.init(value: strings.unscoped, caption: nil)
    case .direct, .tcDirect, nil:
      return nil
    }
  }

  init(value: String, caption: String?) {
    self.value = value
    self.caption = caption
  }
}
