import CairnServices
import MeshCore
import SwiftUI

/// The Traffic map's "not on map" list: every node packets named over the last half hour that the
/// map couldn't draw, under the name the RX Log list gives it, with its kind, why it isn't drawn
/// (this radio never heard its position, a channel message gave only its name, or its packet's
/// route couldn't be drawn), when it was last heard and how many packets named it. A saved or
/// heard node opens its page. Most lately heard first as it opens, then in that order while it is
/// up, so a row never moves under a finger as packets arrive; a node newly listed joins at the
/// end. Under them, the relays no node heard on this channel has, by hash, each with the node
/// sharing its prefix that it isn't taken for.
struct TrafficOffMapSheet: View {
  let model: TrafficMapModel
  /// Opens the node's page, its saved contact or its heard node: the map closes this list first.
  let onOpen: (ContactDTO?, DiscoveredNodeDTO?) -> Void

  @Environment(\.dismiss) private var dismiss
  /// Each node's place in the list as it opened.
  @State private var order: [TrafficMapModel.OffMapKey: Int]?

  /// The list in the order it opened in, with nodes listed since after, newest first.
  private var entries: [TrafficMapModel.OffMapEntry] {
    let list = model.offMapList
    guard let order else { return list }
    return list.enumerated()
      .sorted { (order[$0.element.id] ?? order.count + $0.offset) < (order[$1.element.id] ?? order.count + $1.offset) }
      .map(\.element)
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(entries) { entry in
          row(for: entry)
        }
        let relays = model.unknownRelayList
        if !relays.isEmpty {
          Section {
            ForEach(relays) { relay in
              TrafficUnknownRelayRow(relay: relay)
            }
          }
        }
      }
      .onAppear {
        guard order == nil else { return }
        order = Dictionary(model.offMapList.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
      .flashingNavigationTitle(L10n.Tools.Tools.Traffic.Map.OffMap.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder
  private func row(for entry: TrafficMapModel.OffMapEntry) -> some View {
    let stored = entry.key.map(model.storedNode(forKey:))
    if let stored, stored.contact != nil || stored.discovered != nil {
      Button {
        onOpen(stored.contact, stored.discovered)
      } label: {
        TrafficOffMapRow(entry: entry, isSaved: stored.contact != nil, opensPage: true)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    } else {
      // Known only from a packet (a key learned from an advert) or by a typed name: no page.
      TrafficOffMapRow(entry: entry, isSaved: false, opensPage: false)
    }
  }
}

/// One node in the "not on map" list: its kind's icon, its name, why the map can't place it, and
/// when it was last heard and how many packets named it.
private struct TrafficOffMapRow: View {
  let entry: TrafficMapModel.OffMapEntry
  let isSaved: Bool
  let opensPage: Bool

  private var kind: ContactType? {
    ContactType(rawValue: entry.nodeTypeRaw)
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: kind?.iconSystemName ?? "questionmark.circle")
        .foregroundStyle(kind?.displayColor ?? .secondary)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName)
          .font(.body)
          .lineLimit(1)
        if let kindTitle {
          Text(kindTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
        if entry.sharedHashCount > 1 {
          Text(L10n.Tools.Tools.Traffic.Map.possibleMatch(entry.sharedHashCount))
            .font(.caption)
            .foregroundStyle(.orange)
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text([
            L10n.Tools.Tools.Traffic.Node.last(SpectrumPacketFormat.age(context.date.timeIntervalSince(entry.lastHeard))),
            L10n.Tools.Tools.Traffic.Node.packets(entry.packets),
          ].joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 8)

      if opensPage {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(opensPage ? .isButton : [])
  }

  /// "Repeater", "Room", "Contact", with "Heard" for a node not saved.
  private var kindTitle: String? {
    guard let kind, entry.reason != .nameOnly else { return nil }
    let name = switch kind {
    case .chat: L10n.Map.Map.Callout.NodeKind.contact
    case .repeater: L10n.Map.Map.Callout.NodeKind.repeater
    case .room: L10n.Map.Map.Callout.NodeKind.room
    }
    return isSaved ? name : "\(name) · \(L10n.Map.Map.Callout.discovered)"
  }

  private var reason: String {
    switch entry.reason {
    case .positionNotHeard: L10n.Tools.Tools.Traffic.Node.positionNotHeard
    case .nameOnly: L10n.Tools.Tools.Traffic.Map.OffMap.Reason.nameOnly
    case .notDrawn: L10n.Tools.Tools.Traffic.Map.OffMap.Reason.notDrawn
    }
  }
}

/// One relay no node heard on this channel has: "Unknown relay 7F", the node sharing its prefix
/// that it isn't taken for, when it was last heard and how many packets named it.
private struct TrafficUnknownRelayRow: View {
  let relay: TrafficMapModel.UnknownRelayEntry

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "questionmark.diamond")
        .foregroundStyle(.secondary)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.Tools.Tools.Traffic.Hop.unknown(relay.hash.uppercaseHexString()))
          .font(.body.monospaced())
          .lineLimit(1)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          VStack(alignment: .leading, spacing: 2) {
            if let hint = relay.hint {
              Text(TrafficNodeFormat.hint(hint, now: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text([
              L10n.Tools.Tools.Traffic.Node.last(SpectrumPacketFormat.age(context.date.timeIntervalSince(relay.lastHeard))),
              L10n.Tools.Tools.Traffic.Node.packets(relay.packets),
            ].joined(separator: " · "))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }

      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
