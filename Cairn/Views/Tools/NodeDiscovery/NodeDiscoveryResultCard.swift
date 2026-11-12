import CairnServices
import MeshCore
import SwiftUI

/// What a Check Link (one zero-hop trace to a neighbour) found.
enum NodeDiscoveryLinkCheck: Equatable {
  /// The node answered: the round trip, and the SNR at the node and back here.
  case answered(latencyMs: Int, snrThere: Double, snrBack: Double)
  /// No answer in time. The node may still be there: a repeater with forwarding off doesn't
  /// answer traces.
  case noAnswer
  /// The trace couldn't be sent (no radio).
  case failed
}

/// One neighbour as a card, compact until opened: its kind, name, an Answered tag when it answered
/// this scan, and signal bars. Tapping it selects the node (highlighted and centered on the map)
/// and opens the card in place with the rest: how it was heard, how well each side hears the
/// other, how long ago and where it is (or which nodes a relay hash could be), its key and
/// actions. Tapping its pin on the map does the same.
struct NodeDiscoveryResultCard: View {
  let entry: NodeDiscoveryEntry
  let isSelected: Bool
  var isAdding = false
  /// The node is being asked for its name right now.
  var isResolvingName = false
  var linkCheck: NodeDiscoveryLinkCheck?
  var isCheckingLink = false
  let onSelect: () -> Void
  /// Set for a node that can become a contact (a whole key; repeaters, rooms, companions; not sensors).
  var onAdd: (() -> Void)?
  /// Set for an unnamed node that can be asked for its name.
  var onRequestName: (() -> Void)?
  /// Set for a confirmed repeater a zero-hop trace can be addressed to.
  var onCheckLink: (() -> Void)?
  /// Set for a relay known only by a hash or prefix: its traffic is drawn on the Traffic map.
  var onShowOnTrafficMap: (() -> Void)?
  /// Set when a stored record has a detail sheet.
  var onDetails: (() -> Void)?

  private var result: NodeDiscoveryResult { entry.result }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: onSelect) {
        header
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(result.name)
      .accessibilityValue(accessibilityValue)
      .accessibilityHint(accessibilityHint)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityActions { accessibilityActions }
      .accessibilityIdentifier("nodeDiscovery.result.\(keyPrefix)")

      if isSelected {
        expanded
          .transition(.opacity)
      }
    }
    .cardSurface(isSelected: isSelected)
    .cardInteractionShape()
    .contextMenu { contextMenuItems }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      NodeDiscoveryResultSummary(entry: entry, isResolvingName: isResolvingName, isExpanded: isSelected)
      Image(systemName: "chevron.down")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color(.tertiaryLabel))
        .rotationEffect(.degrees(isSelected ? 180 : 0))
        .frame(height: 28)
    }
  }

  // MARK: - Expanded

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        signalRow(L10n.Tools.Tools.NodeDiscovery.youHearThem, arrow: "arrow.down", snr: result.snr)
        if let uplink = result.uplinkSNR {
          signalRow(L10n.Tools.Tools.NodeDiscovery.theyHearYou, arrow: "arrow.up", snr: uplink)
        }
      }
      .font(.subheadline)

      if let candidates = result.candidates {
        candidateList(candidates.entries, total: candidates.total)
      }

      if !result.unobservedSharers.isEmpty {
        unobservedHints
      }

      Text(result.key.uppercaseHexString())
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
        // Read out it is noise; VoiceOver users copy it with the card's Copy Key action.
        .accessibilityHidden(true)

      if let checkLine {
        Label(checkLine.text, systemImage: checkLine.symbol)
          .font(.subheadline)
          .foregroundStyle(checkLine.tint)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { actionButtons }
        VStack(alignment: .leading, spacing: 8) { actionButtons }
      }
    }
  }

  private func signalRow(_ title: String, arrow: String, snr: Double) -> some View {
    let quality = SNRQuality(snr: snr)
    return GridRow {
      Label(title, systemImage: arrow)
        .foregroundStyle(.secondary)
      Text(NodeRouteFormat.joined([NodeDiscoveryFormat.snr(snr), quality.localizedLabel]))
        .foregroundStyle(quality.color)
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }

  /// The nodes an ambiguous relay could be, likeliest first: none is drawn on the map, since the
  /// relay could be any of them.
  private func candidateList(_ candidates: [NeighbourKeyEntry], total: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.Tools.Tools.NodeDiscovery.Ambiguous.candidatesTitle)
        .font(.subheadline.weight(.semibold))
      ForEach(candidates, id: \.publicKey) { candidate in
        Text(candidate.name ?? NodeDiscoveryViewModel.placeholderName(for: candidate.publicKey))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if total > candidates.count {
        Text("+\((total - candidates.count).formatted())")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// The saved and discovered nodes sharing the hash that this radio never heard on its channel,
  /// or not lately: why none of them names the relay, never a name for it.
  private var unobservedHints: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(result.unobservedSharers.enumerated()), id: \.offset) { _, sharer in
          Text(TrafficNodeFormat.hint(sharer, now: context.date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    if let onAdd {
      if entry.isContact {
        Button(L10n.Contacts.Contacts.Discovery.added, systemImage: "checkmark") {}
          .buttonStyle(.bordered)
          .disabled(true)
          .accessibilityLabel(L10n.Contacts.Contacts.Discovery.addedAccessibility)
      } else {
        Button(L10n.Contacts.Contacts.Discovery.add, systemImage: "person.crop.circle.badge.plus", action: onAdd)
          .buttonStyle(.borderedProminent)
          .disabled(isAdding)
      }
    }
    if let onCheckLink {
      Button(L10n.Tools.Tools.NodeDiscovery.checkLink, systemImage: "wave.3.right", action: onCheckLink)
        .buttonStyle(.bordered)
        .disabled(isCheckingLink)
        .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.CheckLink.hint)
    }
    if !result.isNamed, let onRequestName, !isResolvingName {
      Button(L10n.Tools.Tools.NodeDiscovery.requestName, systemImage: "questionmark.bubble", action: onRequestName)
        .buttonStyle(.bordered)
        .accessibilityHint(L10n.Tools.Tools.NodeDiscovery.requestNameHint)
    }
    if let onShowOnTrafficMap {
      Button(L10n.Tools.Tools.NodeDiscovery.showOnTrafficMap, systemImage: "point.3.filled.connected.trianglepath.dotted", action: onShowOnTrafficMap)
        .buttonStyle(.bordered)
    }
    if let onDetails {
      Button(L10n.Map.Map.Callout.details, systemImage: "info.circle", action: onDetails)
        .buttonStyle(.bordered)
    }
  }

  /// The link check in a line: waiting, the answer with its round trip and SNR both ways, or that
  /// it went unanswered (never "gone": repeaters with forwarding off don't answer traces).
  private var checkLine: (text: String, symbol: String, tint: Color)? {
    if isCheckingLink {
      return (L10n.Tools.Tools.NodeDiscovery.CheckLink.checking, "wave.3.right", .secondary)
    }
    switch linkCheck {
    case let .answered(latencyMs, snrThere, snrBack):
      let latency = Duration.milliseconds(latencyMs).formatted(.units(allowed: [.milliseconds], width: .abbreviated))
      let snr = L10n.Contacts.Contacts.Detail.pingSNR(Self.snrNumber(snrThere), Self.snrNumber(snrBack))
      let text = NodeRouteFormat.joined([L10n.Tools.Tools.NodeDiscovery.CheckLink.answered, latency, snr])
      return (text, "checkmark.circle.fill", .green)
    case .noAnswer:
      return (L10n.Tools.Tools.NodeDiscovery.CheckLink.noAnswer, "questionmark.circle.fill", .orange)
    case .failed:
      return (L10n.Tools.Tools.NodeDiscovery.CheckLink.failed, "exclamationmark.circle.fill", .orange)
    case nil:
      return nil
    }
  }

  // MARK: - Menus and accessibility

  @ViewBuilder
  private var contextMenuItems: some View {
    Button(L10n.RemoteNodes.RemoteNodes.Acl.copyKey, systemImage: "doc.on.doc") {
      UIPasteboard.general.string = result.key.uppercaseHexString()
    }
    if let onAdd, !entry.isContact {
      Button(L10n.Contacts.Contacts.Discovery.add, systemImage: "person.crop.circle.badge.plus", action: onAdd)
    }
    if let onCheckLink, !isCheckingLink {
      Button(L10n.Tools.Tools.NodeDiscovery.checkLink, systemImage: "wave.3.right", action: onCheckLink)
    }
    if let onDetails {
      Button(L10n.Map.Map.Callout.details, systemImage: "info.circle", action: onDetails)
    }
  }

  @ViewBuilder
  private var accessibilityActions: some View {
    Button(L10n.RemoteNodes.RemoteNodes.Acl.copyKey) {
      UIPasteboard.general.string = result.key.uppercaseHexString()
    }
    if let onAdd, !entry.isContact {
      Button(L10n.Contacts.Contacts.Discovery.add, action: onAdd)
    }
    if let onCheckLink {
      Button(L10n.Tools.Tools.NodeDiscovery.checkLink, action: onCheckLink)
    }
    if !result.isNamed, let onRequestName {
      Button(L10n.Tools.Tools.NodeDiscovery.requestName, action: onRequestName)
    }
    if let onShowOnTrafficMap {
      Button(L10n.Tools.Tools.NodeDiscovery.showOnTrafficMap, action: onShowOnTrafficMap)
    }
    if let onDetails {
      Button(L10n.Map.Map.Callout.details, action: onDetails)
    }
  }

  private var accessibilityValue: String {
    NodeDiscoveryFormat.accessibilityValue(entry)
  }

  /// Opening an ambiguous relay's card lists the nodes it could be.
  private var accessibilityHint: String {
    if isSelected { return "" }
    return result.candidates != nil
      ? L10n.Tools.Tools.NodeDiscovery.Ambiguous.hint
      : L10n.Tools.Tools.NodeDiscovery.cardHint
  }

  private var keyPrefix: String {
    result.key.prefix(4).map { String(format: "%02X", $0) }.joined()
  }

  nonisolated static func snrNumber(_ snr: Double) -> String {
    snr.formatted(.number.precision(.fractionLength(1)))
  }
}

/// Who it is and how it was heard, the top of a result's card. Compact, one line: the kind's
/// avatar, the name, an Answered tag when it answered this scan, and signal bars, always in the
/// same places. Opened, under it the New / Contact chip and the evidence badges, how long ago it
/// was heard and where it is (the card's own grid adds the signal both ways). A relay heard only
/// once, or last heard over two hours ago, is drawn faded.
struct NodeDiscoveryResultSummary: View {
  let entry: NodeDiscoveryEntry
  var isResolvingName = false
  var isExpanded = false

  private var result: NodeDiscoveryResult { entry.result }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        avatar
        Text(result.name)
          .font(.body.weight(.semibold))
          .foregroundStyle(result.isNamed ? .primary : .secondary)
          .lineLimit(1)
        if isResolvingName {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel(L10n.Tools.Tools.NodeDiscovery.requestingName)
        }
        Spacer(minLength: 4)
        if NodeDiscoveryFormat.badges(result).contains(.answeredYourScan) {
          answeredTag
        }
        let quality = SNRQuality(snr: result.snr)
        Image(systemName: "cellularbars", variableValue: quality.barLevel)
          .foregroundStyle(quality.color)
          .accessibilityHidden(true)
      }
      if isExpanded {
        expandedDetails
      }
    }
    .opacity(NodeDiscoveryFormat.isDimmed(result) ? 0.6 : 1)
  }

  /// The evidence and where and when, under the compact line once the card is open.
  private var expandedDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      let badges = NodeDiscoveryFormat.badges(result).filter { $0 != .answeredYourScan }
      FlowRow(spacing: 4) {
        if result.hasFullKey {
          badge
        }
        ForEach(badges, id: \.self) { evidenceBadge($0) }
      }
      // Re-read now and then, so "2 min ago" keeps up while nothing new is heard.
      TimelineView(.periodic(from: .now, by: 15)) { context in
        Text(NodeRouteFormat.joined([
          NodeDiscoveryFormat.placeLine(entry),
          NodeDiscoveryFormat.freshness(lastHeard: result.receivedAt, now: context.date),
        ]))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      if isResolvingName {
        Text(L10n.Tools.Tools.NodeDiscovery.requestingName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 38)
  }

  /// "Answered": this node answered the current scan.
  private var answeredTag: some View {
    Text(L10n.Tools.Tools.NodeDiscovery.Badge.answered)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(Color.green)
      .background { Capsule().strokeBorder(Color.green.opacity(0.6), lineWidth: 1) }
      .fixedSize()
  }

  @ViewBuilder
  private var avatar: some View {
    if result.scanFilter == .repeaters {
      NodeAvatar(publicKey: result.key, role: .repeater, size: 28, name: result.isNamed ? result.name : nil)
    } else {
      ZStack {
        AvatarPebble().fill(Color.teal.opacity(0.2))
        Image(systemName: "sensor")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.teal)
      }
      .frame(width: 28, height: 28)
      .accessibilityHidden(true)
    }
  }

  /// "New" for a node worth adding, "Contact" for one already saved: Cairn's row chips.
  private var badge: some View {
    Text(entry.isNew ? L10n.Tools.Tools.NodeDiscovery.Badge.new : L10n.Tools.Tools.NodeDiscovery.Badge.contact)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(entry.isNew ? Color.white : Color.green)
      .background {
        if entry.isNew {
          Capsule().fill(Color.accentColor)
        } else {
          Capsule().strokeBorder(Color.green, lineWidth: 1)
        }
      }
      .fixedSize()
  }

  /// Where the evidence came from, outlined so it reads apart from the New / Contact chip.
  private func evidenceBadge(_ badge: NodeDiscoveryFormat.Badge) -> some View {
    let tint: Color = switch badge {
    case .answeredYourScan, .hearsYou: .green
    case .heardOnce: .orange
    case .relaying, .advert, .answeredEarlierScan, .answeredAnotherScan: .secondary
    }
    return Text(badge.title)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(tint)
      .background { Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1) }
      .fixedSize()
  }
}
