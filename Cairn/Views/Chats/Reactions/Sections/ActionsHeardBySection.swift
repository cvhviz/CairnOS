import CoreLocation
import CairnServices
import SwiftUI

/// Who passed a message on, one row per copy heard: for an outgoing message the repeaters that
/// echoed it back ("Repeated By"), for an incoming one the repeater each copy arrived from
/// ("Heard Via"). Each row names the last hop (the node this radio actually heard) through the
/// same resolver the path list and the Traffic map use, so a duplicate short ID resolves to the
/// same node everywhere; an unknown hop shows its hex ID. The SNR/RSSI are this radio's reading
/// of that copy. One card of rows, as a Settings list, rather than a tile per copy (the user,
/// 2026-11-08): the copies read top to bottom in the order they came in, the signal lined up on
/// the right, and a row that opens its repeater's contact carries a chevron.
struct ActionsHeardBySection: View {
  let message: MessageDTO
  let arrivals: [MessagePathArrival]
  let pathViewModel: MessagePathViewModel

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  /// Copies with a hop list or heard straight from the sender; a stored route records no hops.
  private var listedArrivals: [MessagePathArrival] {
    arrivals.filter { !$0.isDirectRoute && !$0.isPathUnavailable }
  }

  /// Rows start past the signal badge, as a Settings row's separator starts past its icon.
  private static let separatorInset: CGFloat = 56

  var body: some View {
    if !listedArrivals.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(message.isOutgoing
          ? L10n.Chats.Chats.Message.HeardBy.repeatedTitle
          : L10n.Chats.Chats.Message.HeardBy.heardViaTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal)
          .accessibilityAddTraits(.isHeader)

        VStack(spacing: 0) {
          ForEach(Array(listedArrivals.enumerated()), id: \.element.id) { index, arrival in
            if index > 0 {
              Divider()
                .padding(.leading, Self.separatorInset)
            }
            row(for: arrival)
          }
        }
        .background(Color(.secondarySystemBackground), in: CardStyle.shape)
        .clipShape(CardStyle.shape)
        .padding(.horizontal)
      }
      .padding(.top, 12)
    }
  }

  @ViewBuilder
  private func row(for arrival: MessagePathArrival) -> some View {
    let reading = reading(for: arrival)
    let content = HeardByRow(
      reading: reading,
      isZeroHop: arrival.isZeroHop,
      snr: arrival.snr,
      rssi: arrival.rssi,
      showsDisclosure: reading.contact != nil
    )
    if let contact = reading.contact {
      Button {
        dismiss()
        appState.navigation.navigateToContactDetail(contact)
      } label: {
        content
      }
      .buttonStyle(.plain)
      .contentShape(.hoverEffect, .rect)
      .hoverEffect(.highlight)
      .accessibilityHint(L10n.Chats.Chats.Path.Hop.openContactHint)
    } else {
      content
    }
  }

  fileprivate struct Reading {
    /// The repeater heard, or "Direct from sender".
    let name: String
    /// "7F · 2 hops · +3s", with "possible match" when the name was guessed from a shared ID.
    let detail: String
    let contact: ContactDTO?
  }

  private func reading(for arrival: MessagePathArrival) -> Reading {
    let first = arrivals.first
    let offset: String? = if message.isOutgoing {
      // Echoes count from the send, which the bubble shows as the sent time.
      HeardByFormatting.offset(from: message.senderDate, to: arrival.receivedAt)
    } else if let first, first.id != arrival.id {
      HeardByFormatting.offset(from: first.receivedAt, to: arrival.receivedAt)
    } else {
      L10n.Chats.Chats.Path.Arrival.first
    }
    let hops = MessagePathArrivalCapsules.hopsTitle(for: arrival)

    guard let lastHop = arrival.pathHops.last else {
      // Heard straight from the sender, no repeater between.
      return Reading(
        name: L10n.Chats.Chats.Message.HeardBy.directFromSender,
        detail: [hops, offset].compactMap(\.self).joined(separator: " · "),
        contact: nil
      )
    }

    // The node this radio heard: named only by what it heard on its channel, never a saved
    // contact sharing the hash
    let match = pathViewModel.relays(for: arrival).last ?? .unknown(lastHop.data)
    let resolution = pathViewModel.repeaterResolution(for: match)
    let name = HeardByFormatting.displayName(resolution: resolution, hex: lastHop.hex)
    let possible = resolution.matchKind == .fallback ? L10n.Chats.Chats.Message.HeardBy.possibleMatch : nil
    // An unknown relay says which node shares its ID but wasn't taken for it, and why.
    let hint = pathViewModel.unknownHint(for: match, receivedAt: arrival.receivedAt)
    // The hex leads only when the name isn't already it.
    let hex = name == lastHop.hex ? nil : lastHop.hex
    return Reading(
      name: name,
      detail: [hex, hops, offset, possible, hint].compactMap(\.self).joined(separator: " · "),
      contact: pathViewModel.repeaterContact(for: match)
    )
  }
}

/// One copy heard: a badge in the signal's colour, the repeater and how the copy came, and the
/// SNR over the RSSI on the right.
private struct HeardByRow: View {
  let reading: ActionsHeardBySection.Reading
  let isZeroHop: Bool
  let snr: Double?
  let rssi: Int?
  let showsDisclosure: Bool

  var body: some View {
    let quality = SNRQuality(snr: snr)
    HStack(spacing: 12) {
      Image(systemName: isZeroHop ? "person.wave.2.fill" : "dot.radiowaves.left.and.right")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(snr == nil ? Color.secondary : quality.color)
        .frame(width: 32, height: 32)
        .background((snr == nil ? Color.secondary : quality.color).opacity(0.15), in: .circle)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(reading.name)
          .font(.body.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(reading.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if snr != nil || rssi != nil {
        VStack(alignment: .trailing, spacing: 2) {
          if let snr {
            HStack(spacing: 4) {
              Image(systemName: "cellularbars", variableValue: quality.barLevel)
                .font(.caption)
                .foregroundStyle(quality.color)
                .accessibilityHidden(true)
              Text("\(snr.formatted(.number.precision(.fractionLength(1)))) dB")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            }
          }
          if let rssi {
            Text("\(rssi) dBm")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .fixedSize()
      }

      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(minHeight: 52)
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(reading.name)
    .accessibilityValue(
      [reading.detail, HeardByFormatting.signal(snr: snr, rssi: rssi)].compactMap(\.self).joined(separator: ", ")
    )
    .accessibilityAddTraits(showsDisclosure ? .isButton : [])
  }
}

/// Text for the heard-by tiles, kept pure for tests.
enum HeardByFormatting {
  /// The hop's resolved name, or its hex ID when nothing on this radio has that hash.
  static func displayName(resolution: NodeNameResolution, hex: String) -> String {
    resolution.matchKind == .unresolved ? hex : resolution.displayName
  }

  /// "+3s" after the reference moment; a copy logged a moment early still reads "+0s".
  static func offset(from start: Date, to end: Date) -> String {
    let seconds = max(0, end.timeIntervalSince(start)).rounded()
    let duration = Duration.seconds(seconds)
    let text = seconds < 60
      ? duration.formatted(.units(allowed: [.seconds], width: .narrow))
      : duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    return L10n.Chats.Chats.Path.Arrival.offset(text)
  }

  /// "8.5 dB, −95 dBm", either part left out when unknown; nil when neither is.
  static func signal(snr: Double?, rssi: Int?) -> String? {
    var parts: [String] = []
    if let snr {
      parts.append("\(snr.formatted(.number.precision(.fractionLength(1)))) dB")
    }
    if let rssi {
      parts.append("\(rssi) dBm")
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}
