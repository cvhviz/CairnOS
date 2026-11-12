import CairnServices
import SwiftUI

/// A tapped node on Scan & Traffic's map, in two lines on the top-left card under the aiming
/// readout (which already names it and gives its distance): its kind, hash and how this radio
/// heard it (and whether it's only the likeliest of a shared hash), then what it has carried in
/// the last half hour; its page and, for a companion, its chat as small buttons beside them. Its
/// busiest links are left to the map, which draws them with their counts while it's picked.
struct TrafficNodeBrief: View {
  @Environment(\.appState) private var appState

  let node: TrafficMapModel.PinnedNode
  let activity: TrafficMapModel.NodeActivity
  let onDetail: (() -> Void)?
  let onMessage: (() -> Void)?
  /// The Map tab's extras, after Message: Add for a heard node, and its ••• menu.
  var onAdd: (() -> Void)?
  var isAdding = false
  var menu: AnyView?
  /// The second line, what it has carried; off on the Map tab while its traffic layer is off.
  var showsActivity = true

  private var kind: ContactType? {
    node.contact?.type ?? node.discovered?.nodeType ?? ContactType(rawValue: node.nodeTypeRaw)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      // Two lines: what it is and how it was heard, then what it has carried.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 4) {
          // what it is opens its page, as the "i" does (the user, 2026-11-09)
          if let onDetail {
            Button(action: onDetail) {
              HStack(spacing: 4) {
                line(identityText(now: context.date), systemImage: identityIcon.name, color: identityIcon.color)
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.Map.Map.Callout.details)
          } else {
            line(identityText(now: context.date), systemImage: identityIcon.name, color: identityIcon.color)
          }
          if showsActivity {
            line(
              activityText(now: context.date),
              systemImage: activity.packets == 0 ? "moon.zzz" : "point.topleft.down.to.point.bottomright.curvepath.fill",
              color: activity.packets == 0 ? .secondary : .cyan
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let onDetail {
        iconButton(L10n.Map.Map.Callout.details, systemImage: "info", action: onDetail)
      }
      if let onMessage {
        iconButton(L10n.Map.Map.Callout.message, systemImage: "message.fill", action: onMessage)
      }
      if let onAdd {
        iconButton(L10n.Map.Map.Callout.add, systemImage: "plus", action: onAdd)
          .disabled(isAdding)
      }
      if let menu {
        menu
      }
    }
  }

  private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label { Text(title) } icon: { MapCalloutIcon(systemImage: systemImage) }
    }
    .mapCalloutIconButton()
  }

  private func line(_ text: String, systemImage: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(width: 18)
      Text(text)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.footnote.monospacedDigit())
    .accessibilityElement(children: .combine)
  }

  /// "Repeater · A3 · Heard directly 3 min. ago", with "Possible match (3)" when the hash it was
  /// named by is shared.
  private func identityText(now: Date) -> String {
    var parts = [kindLine?.title, idPrefixHex]
    if let observed = node.observed, !node.isRadio {
      parts.append(TrafficNodeFormat.basis(of: observed, now: now))
    }
    if node.sharedHashCount > 1 {
      parts.append(L10n.Tools.Tools.Traffic.Map.possibleMatch(node.sharedHashCount))
    }
    return NodeRouteFormat.joined(parts)
  }

  /// The kind's glyph, or a question mark while it's only the likeliest of a shared hash.
  private var identityIcon: (name: String, color: Color) {
    if node.sharedHashCount > 1 { return ("questionmark.circle", .orange) }
    return (kindLine?.systemImage ?? "circle", kindLine?.color ?? .secondary)
  }

  /// "12 packets in 30 min · Last 4s", or that it has been quiet.
  private func activityText(now: Date) -> String {
    guard activity.packets > 0 else { return L10n.Tools.Tools.Traffic.Node.quiet }
    let last = activity.lastSeen.map {
      L10n.Tools.Tools.Traffic.Node.last(SpectrumPacketFormat.age(now.timeIntervalSince($0)))
    }
    return NodeRouteFormat.joined([L10n.Tools.Tools.Traffic.Node.packets(activity.packets), last])
  }

  private var idPrefixHex: String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    return node.key.prefix(hashSize).uppercaseHexString()
  }

  /// "Repeater", "Room", "Contact", with "Heard" for a node not saved, or "This radio".
  private var kindLine: (title: String, systemImage: String, color: Color)? {
    if node.isRadio {
      return (L10n.Tools.Tools.Traffic.Node.thisRadio, "antenna.radiowaves.left.and.right", .accentColor)
    }
    guard let kind else { return nil }
    let name = switch kind {
    case .chat: L10n.Map.Map.Callout.NodeKind.contact
    case .repeater: L10n.Map.Map.Callout.NodeKind.repeater
    case .room: L10n.Map.Map.Callout.NodeKind.room
    }
    let title = node.contact == nil ? "\(name) · \(L10n.Map.Map.Callout.discovered)" : name
    return (title, kind.iconSystemName, kind.displayColor)
  }
}

/// A tapped node with nothing to aim at (this radio, or a phone without location): the brief on
/// the top-left card by itself, under the node's name and a close button.
struct TrafficNodeCard: View {
  let name: String
  let brief: TrafficNodeBrief
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(name)
          .font(.headline)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        Button(L10n.Localizable.Common.done, systemImage: "xmark.circle.fill", action: onClose)
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .font(.title3)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .contentShape(.rect)
      }
      brief
    }
    .padding(10)
    .frame(maxWidth: 360, alignment: .leading)
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .background {
      CardStyle.shape.fill(Color(.secondarySystemGroupedBackground))
      CardStyle.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    .accessibilityElement(children: .contain)
  }
}

/// The callout for a tapped link on the Traffic map: its two ends, packets over it in the last
/// half hour and how long since the last, how far apart its ends are, and, for the leg into this
/// radio, the signal the last packet was heard at (the only leg of a flood whose signal is known).
struct TrafficLinkCalloutContent: View {
  let detail: TrafficMapModel.LinkDetail
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        // Wraps rather than truncating: a link's two names together rarely fit one line.
        Text("\(detail.fromName) ↔ \(detail.toName)")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 4)
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

      Divider()

      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 2) {
          Label {
            Text(L10n.Tools.Tools.Traffic.Node.packets(detail.packets))
              .font(.subheadline.weight(.semibold))
          } icon: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
              .foregroundStyle(.cyan)
          }
          Text(L10n.Tools.Tools.Traffic.Node.last(SpectrumPacketFormat.age(context.date.timeIntervalSince(detail.lastUsed))))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }

      Label {
        Text(L10n.Tools.Tools.Traffic.Link.distance(distanceText))
          .font(.subheadline)
      } icon: {
        Image(systemName: "ruler")
          .foregroundStyle(.secondary)
      }

      if let snr = detail.lastLegSNR {
        Label {
          Text(L10n.Tools.Tools.Traffic.Link.heard(snrText(snr)))
            .font(.subheadline)
        } icon: {
          Image(systemName: "cellularbars", variableValue: SNRQuality(snr: snr).barLevel)
            .foregroundStyle(SNRQuality(snr: snr).color)
        }
      }

      if let snr = detail.tracedSNR {
        Label {
          Text(L10n.Tools.Tools.Traffic.Link.traced(snrText(snr)))
            .font(.subheadline)
        } icon: {
          Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            .foregroundStyle(SNRQuality(snr: snr).color)
        }
      }
    }
    .padding(12)
    // A set width, not a range: the map's callout bubble sizes its content to fit (`fixedSize`),
    // which would lay the title out on one line however long; given a width, it wraps.
    .frame(width: 280)
  }

  private var distanceText: String {
    Measurement(value: detail.distance, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road).locale(MeasurementPreference.locale()))
  }

  private func snrText(_ snr: Double) -> String {
    "\(snr.formatted(.number.precision(.fractionLength(1)))) \(L10n.RemoteNodes.RemoteNodes.Status.snrBadgeUnit)"
  }
}

/// What a node has carried lately, as the Traffic map counts it: packets through it in the last
/// half hour, how long since the last, and its busiest links with how many crossed each. Shared
/// by the Traffic map's callouts and the other maps' while their traffic is on.
struct TrafficActivitySummary: View {
  let activity: TrafficMapModel.NodeActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if activity.packets == 0, activity.links.isEmpty {
        Label(L10n.Tools.Tools.Traffic.Node.quiet, systemImage: "moon.zzz")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          VStack(alignment: .leading, spacing: 2) {
            Label {
              Text(L10n.Tools.Tools.Traffic.Node.packets(activity.packets))
                .font(.subheadline.weight(.semibold))
            } icon: {
              Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .foregroundStyle(.cyan)
            }
            if let lastSeen = activity.lastSeen {
              Text(L10n.Tools.Tools.Traffic.Node.last(SpectrumPacketFormat.age(context.date.timeIntervalSince(lastSeen))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }

        if !activity.links.isEmpty {
          Text(L10n.Tools.Tools.Traffic.Node.links)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 2)
          ForEach(Array(activity.links.enumerated()), id: \.offset) { _, link in
            HStack {
              Text(link.name)
                .font(.subheadline)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(link.count.formatted())
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }
}

/// How this radio observed a node, and the hint for a relay no observed node has, as the Traffic
/// map's callouts and the RX log's detail say them.
enum TrafficNodeFormat {
  /// "Heard directly 3 min. ago", or "Heard via 3 hops 2 days ago"; nil for a node this radio
  /// didn't observe on the channel (a key a packet proves, a saved contact).
  static func basis(of entry: NeighbourKeyEntry, now: Date) -> String? {
    guard entry.isObserved else { return nil }
    if let direct = entry.lastDirectAt {
      return L10n.Tools.Tools.Traffic.Node.heardDirectly(relative(direct, now: now))
    }
    guard let lastHeard = entry.lastHeard else { return nil }
    if let hops = entry.minHops {
      return L10n.Tools.Tools.Traffic.Node.heardRelayed(hops, relative(lastHeard, now: now))
    }
    return L10n.Tools.Tools.Traffic.Node.last(relative(lastHeard, now: now))
  }

  /// "Not heard on this channel: Kona Hill shares this prefix", or "Last heard on this channel
  /// 12d ago: Ridge". A detail view's line only: never a name in a row, a stop or a pin.
  static func hint(_ sharer: UnobservedSharer, now: Date) -> String {
    let name = sharer.entry.name ?? Data(sharer.entry.publicKey.prefix(3)).uppercaseHexString()
    switch sharer.reason {
    case .notHeard:
      return L10n.Tools.Tools.Traffic.Hop.notHeardHint(name)
    case let .stale(lastObservedAt):
      return L10n.Tools.Tools.Traffic.Hop.staleHint(SpectrumPacketFormat.age(now.timeIntervalSince(lastObservedAt)), name)
    }
  }

  /// "3 min. ago", against `now`.
  static func relative(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }
}
