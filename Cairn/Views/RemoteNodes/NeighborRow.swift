import CairnServices
import SwiftUI

struct NeighborRow: View {
  let neighbor: Neighbour
  let displayName: String
  let matchKind: NodeNameMatchKind
  let keyDisplayByteCount: Int
  let previousNeighbor: NeighborSnapshotEntry?
  let isNew: Bool
  /// Largest believable age, from the repeater's uptime: a neighbour can't be heard before boot.
  let maxPlausibleSecondsAgo: Int?

  init(
    neighbor: Neighbour,
    displayName: String,
    matchKind: NodeNameMatchKind,
    keyDisplayByteCount: Int,
    previousNeighbor: NeighborSnapshotEntry? = nil,
    isNew: Bool = false,
    maxPlausibleSecondsAgo: Int? = nil
  ) {
    self.neighbor = neighbor
    self.displayName = displayName
    self.matchKind = matchKind
    self.keyDisplayByteCount = keyDisplayByteCount
    self.previousNeighbor = previousNeighbor
    self.isNew = isNew
    self.maxPlausibleSecondsAgo = maxPlausibleSecondsAgo
  }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(displayName)

          if isNew {
            Text(L10n.RemoteNodes.RemoteNodes.History.new)
              .font(.caption2)
              .bold()
              .foregroundStyle(.green)
          }

          if matchKind == .fallback {
            FallbackMatchIndicatorView(
              accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.possibleMatch,
              accessibilityHint: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchExplanation,
              title: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchTitle,
              explanation: L10n.RemoteNodes.RemoteNodes.Status.possibleMatchExplanation
            )
          }
        }

        HStack(spacing: 4) {
          // An unresolved neighbour's title is already this hex.
          if matchKind != .unresolved {
            Text(keyHex)
              .font(.system(.caption2, design: .monospaced))
            Text("·")
          }
          if let lastSeen = Self.lastSeenText(secondsAgo: neighbor.secondsAgo, maxPlausible: maxPlausibleSecondsAgo) {
            Text(lastSeen)
              .font(.caption2)
          } else {
            FallbackMatchIndicatorView(
              accessibilityLabel: L10n.RemoteNodes.RemoteNodes.Status.heardTimeUnknown,
              accessibilityHint: L10n.RemoteNodes.RemoteNodes.Status.heardTimeUnknownExplanation,
              title: L10n.RemoteNodes.RemoteNodes.Status.heardTimeUnknown,
              explanation: L10n.RemoteNodes.RemoteNodes.Status.heardTimeUnknownExplanation
            )
            Text(L10n.RemoteNodes.RemoteNodes.Status.heardTimeUnknown)
              .font(.caption2)
          }
        }
        .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Image(systemName: "cellularbars", variableValue: snrLevel)
          .foregroundStyle(snrColor)

        Text(L10n.RemoteNodes.RemoteNodes.Status.snrFormat(neighbor.snr.formatted(.number.precision(.fractionLength(1)))))
          .font(.caption)
          .foregroundStyle(.secondary)

        if let previous = previousNeighbor {
          let snrDelta = neighbor.snr - previous.snr
          if abs(snrDelta) >= 0.1 {
            StatusDeltaView(delta: snrDelta, higherIsBetter: true, unit: " dB", fractionDigits: 1)
          }
        }
      }
    }
  }

  private var keyHex: String {
    NeighborNameResolver.fallbackName(
      for: neighbor.publicKeyPrefix,
      byteCount: keyDisplayByteCount
    )
  }

  /// Neighbour tables live in the repeater's RAM, so an entry older than this can only come from
  /// its clock jumping (a reboot with no clock, then a clock sync), not a real age.
  static let maxBelievableSecondsAgo = 30 * 86400

  /// "12m ago", or nil when the firmware's age can't be trusted (#363: a repeater whose clock was
  /// set after it heard a neighbour reports that neighbour as heard years ago).
  static func lastSeenText(secondsAgo seconds: Int, maxPlausible: Int?) -> String? {
    if seconds < 0 || seconds > maxBelievableSecondsAgo { return nil }
    if let maxPlausible, seconds > maxPlausible { return nil }
    if seconds < 60 {
      return L10n.RemoteNodes.RemoteNodes.Status.secondsAgo(seconds)
    } else if seconds < 3600 {
      return L10n.RemoteNodes.RemoteNodes.Status.minutesAgo(seconds / 60)
    } else if seconds < 86400 {
      return L10n.RemoteNodes.RemoteNodes.Status.hoursAgo(seconds / 3600)
    } else {
      return L10n.RemoteNodes.RemoteNodes.Status.daysAgo(seconds / 86400)
    }
  }

  private var snrQuality: SNRQuality {
    SNRQuality(snr: neighbor.snr)
  }

  private var snrLevel: Double {
    snrQuality.barLevel
  }

  private var snrColor: Color {
    snrQuality.color
  }
}
