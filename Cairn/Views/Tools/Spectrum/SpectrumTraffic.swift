import CairnServices
import SwiftUI

// The packets the radio heard, three ways: the card for the one selected on the chart, Cairn's
// traffic table as one card of rows, and the RX log's own detail for any of them. Each names its
// nodes as the RX Log list does, from the app's one `ObservationDirectory`.

extension SpectrumPacket {
  /// Its nodes as the RX Log list resolves them: against what this radio observed on the channel
  /// it was received on (`observations`), with this radio's own sends (`sent`, the app's log when
  /// nil) naming their echoes and the replies to them.
  @MainActor
  func nodes(in observations: ObservationDirectory, sent: TrafficSentPackets? = nil) -> PacketNodes {
    TrafficRouteResolver.packetNodes(for: entry, in: observations.index(for: entry), sent: sent ?? TrafficSentLog.shared.snapshot)
  }
}

// MARK: - Selected packet

/// Cairn's details card for a tapped marker: "MSG · Flood 2 · 12 s ago", "-97 dBm · SNR 6.25 ·
/// 38 B", and who it was from. Stays until dismissed rather than timing out, so there's time to
/// read it and to open its full detail.
struct SpectrumPacketCallout: View {
  let packet: SpectrumPacket
  let onDetails: () -> Void
  let onClose: () -> Void

  @Environment(\.appState) private var appState

  var body: some View {
    let party = packet.party(packet.nodes(in: appState.observationDirectory))
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        SpectrumKindPill(kind: packet.kind)
        Text([packet.kind.title, packet.routeTitle, packet.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))].joined(separator: " · "))
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        Spacer(minLength: 0)
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Localizable.Common.done)
      }

      Text(SpectrumTrafficRow.signalLine(packet))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)

      Text(party ?? L10n.Tools.Tools.Spectrum.Party.none)
        .font(.subheadline)
        .foregroundStyle(party == nil ? .tertiary : .primary)

      Button(action: onDetails) {
        Label(L10n.Tools.Tools.Spectrum.Detail.open, systemImage: "doc.text.magnifyingglass")
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(.borderless)
      .padding(.top, 2)
    }
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Traffic table

/// Cairn's traffic table as one card: TYPE · ROUTE · RSSI · SNR · AGE, the newest packets first.
/// See All opens the RX Log, which has the rest (as does the header's RX Log button).
struct SpectrumTrafficSection: View {
  let packets: [SpectrumPacket]
  let now: Date
  /// One card the height it is given, the title inside it and the rows scrolling within (the
  /// column beside the chart on an iPad); otherwise the title over a card of all its rows.
  var fillsHeight = false
  let onSelect: (SpectrumPacket) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if fillsHeight {
      VStack(alignment: .leading, spacing: 8) {
        titleRow
        ScrollView {
          rows
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .cardSurface(padding: 12)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        titleRow
          .padding(.horizontal, 4)
        rows
          .cardSurface(padding: 12)
      }
    }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(L10n.Tools.Tools.Spectrum.Traffic.title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      NavigationLink {
        RxLogView()
      } label: {
        Text(L10n.Tools.Tools.Spectrum.Traffic.seeAll)
          .font(.subheadline)
      }
      .accessibilityHint(L10n.Tools.Tools.Spectrum.Traffic.seeAllHint)
      .accessibilityIdentifier("spectrum.traffic.seeAll")
    }
  }

  private var rows: some View {
      VStack(alignment: .leading, spacing: 0) {
        if packets.isEmpty {
          Text(L10n.Tools.Tools.Spectrum.Traffic.empty)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
          if !dynamicTypeSize.isAccessibilitySize {
            SpectrumTrafficRow.header
              .padding(.bottom, 4)
              .accessibilityHidden(true)
          }
          ForEach(Array(packets.enumerated()), id: \.element.id) { index, packet in
            if index > 0 || !dynamicTypeSize.isAccessibilitySize {
              Divider()
            }
            Button {
              onSelect(packet)
            } label: {
              SpectrumTrafficRow(packet: packet, now: now, stacked: dynamicTypeSize.isAccessibilitySize)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
  }
}

/// One packet as a table row. Fixed columns line up from row to row like Cairn's table; at
/// accessibility sizes the columns stack so nothing truncates.
struct SpectrumTrafficRow: View {
  let packet: SpectrumPacket
  let now: Date
  let stacked: Bool

  @ScaledMetric(relativeTo: .subheadline) private var typeWidth: CGFloat = 52
  @ScaledMetric(relativeTo: .subheadline) private var signalWidth: CGFloat = 54
  @ScaledMetric(relativeTo: .subheadline) private var ageWidth: CGFloat = 40

  /// "-97 dBm · SNR 6.25 · 38 B"
  static func signalLine(_ packet: SpectrumPacket) -> String {
    [
      packet.rssi.map(SpectrumFormat.dBm),
      packet.snr.map { L10n.Tools.Tools.Spectrum.Detail.snr(SpectrumPacketFormat.snr($0)) },
      L10n.Tools.Tools.Spectrum.Detail.bytes(packet.size),
    ].compactMap(\.self).joined(separator: " · ")
  }

  static var header: some View {
    SpectrumTrafficHeader()
  }

  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            SpectrumKindPill(kind: packet.kind)
            Text(packet.routeTitle)
            Spacer()
            Text(age)
              .foregroundStyle(.secondary)
          }
          Text(Self.signalLine(packet))
            .foregroundStyle(.secondary)
        }
      } else {
        HStack(spacing: 8) {
          SpectrumKindPill(kind: packet.kind)
            .frame(width: typeWidth, alignment: .leading)
          Text(packet.routeTitle)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(packet.rssi.map { Int($0).formatted() } ?? "—")
            .frame(width: signalWidth, alignment: .trailing)
          Text(packet.snr.map(SpectrumPacketFormat.snr) ?? "—")
            .frame(width: signalWidth, alignment: .trailing)
          Text(age)
            .foregroundStyle(.secondary)
            .frame(width: ageWidth, alignment: .trailing)
        }
      }
    }
    .font(.subheadline.monospacedDigit())
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(packet.kind.title)
    .accessibilityValue([packet.routeTitle, Self.signalLine(packet), packet.date.formatted(.relative(presentation: .numeric))].joined(separator: ", "))
    .accessibilityAddTraits(.isButton)
  }

  private var age: String {
    SpectrumPacketFormat.age(now.timeIntervalSince(packet.date))
  }
}

/// The table's column titles, aligned with `SpectrumTrafficRow`'s columns.
private struct SpectrumTrafficHeader: View {
  @ScaledMetric(relativeTo: .subheadline) private var typeWidth: CGFloat = 52
  @ScaledMetric(relativeTo: .subheadline) private var signalWidth: CGFloat = 54
  @ScaledMetric(relativeTo: .subheadline) private var ageWidth: CGFloat = 40

  var body: some View {
    HStack(spacing: 8) {
      Text(L10n.Tools.Tools.Spectrum.Traffic.type)
        .frame(width: typeWidth, alignment: .leading)
      Text(L10n.Tools.Tools.Spectrum.Traffic.route)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(L10n.Tools.Tools.Spectrum.Traffic.rssi)
        .frame(width: signalWidth, alignment: .trailing)
      Text(L10n.Tools.Tools.Spectrum.Traffic.snr)
        .frame(width: signalWidth, alignment: .trailing)
      Text(L10n.Tools.Tools.Spectrum.Traffic.age)
        .frame(width: ageWidth, alignment: .trailing)
    }
    .font(.caption2.weight(.semibold))
    .textCase(.uppercase)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}

// MARK: - Detail

/// The packet sheet for one packet, with the text decrypted again for display (the Spectrum tab
/// keeps entries as stored), its nodes named against the same observations the list names them
/// against.
struct SpectrumPacketDetailSheet: View {
  let packet: SpectrumPacket

  @Environment(\.appState) private var appState
  @State private var entry: RxLogEntryDTO?

  var body: some View {
    let observations = appState.observationDirectory
    let shown = entry ?? packet.entry
    let sent = TrafficSentLog.shared.snapshot
    let index = observations.index(for: shown)
    let echo = sent.echo(of: shown, selfKey: index.selfKey).flatMap { match in
      sent.send(id: match.sendID).map { (send: $0, match: match) }
    }
    RxPacketDetailSheet(
      entry: shown,
      groupCount: 1,
      nodeIndex: index,
      packet: TrafficRouteResolver.packetNodes(for: shown, in: index, sent: sent),
      origin: appState.bestAvailableLocation,
      currentChannelKey: observations.nodeIndex.channelKey,
      echo: echo
    )
    .task {
      entry = await appState.services?.rxLogService.decodedEntries([packet.entry]).first
    }
  }
}
