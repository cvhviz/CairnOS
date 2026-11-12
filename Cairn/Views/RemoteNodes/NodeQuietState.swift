import CairnServices
import SwiftUI

/// Whether a logged-in node can be talked to: live, or sent a reboot or a power-off and quiet since.
/// After `reboot` the firmware comes back without its sessions, so the page's requests would go
/// unanswered; the dashboard says so, holds its request tiles, and offers a reconnect (a fresh
/// login through the auth sheet) once the node has had time to come up.
enum NodeQuietState: Equatable {
  case live
  /// `reboot` was sent at `since`; the node takes about `rebootWait` to come back.
  case rebooting(since: Date)
  /// `poweroff` was sent at `since`; only someone at the node can bring it back.
  case poweredOff(since: Date)

  /// About how long a repeater takes to boot and advertise again.
  static let rebootWait: TimeInterval = 30

  var isQuiet: Bool {
    self != .live
  }

  /// Seconds left before a reconnect is worth trying; 0 when it is (or when the node was powered
  /// off, since only the user knows when it's back on).
  func secondsUntilReconnect(now: Date) -> Int {
    switch self {
    case .live, .poweredOff:
      return 0
    case let .rebooting(since):
      let remaining = Self.rebootWait - now.timeIntervalSince(since)
      return max(0, Int(remaining.rounded(.up)))
    }
  }

  func canReconnect(now: Date) -> Bool {
    secondsUntilReconnect(now: now) == 0
  }

  /// What the banner says at `now`.
  func message(now: Date) -> String? {
    switch self {
    case .live:
      return nil
    case .rebooting:
      let seconds = secondsUntilReconnect(now: now)
      return seconds > 0
        ? L10n.RemoteNodes.RemoteNodes.Reboot.bannerRebooting(seconds)
        : L10n.RemoteNodes.RemoteNodes.Reboot.bannerReady
    case .poweredOff:
      return L10n.RemoteNodes.RemoteNodes.Reboot.bannerPoweredOff
    }
  }
}

/// "Rebooting… try again in about 30 s" with a Reconnect button, under the dashboard's header
/// while the node is quiet. Counts down by the second.
struct NodeRebootBanner: View {
  let state: NodeQuietState
  let onReconnect: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if state.isQuiet {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack(spacing: 10) {
          Image(systemName: isPoweredOff ? "power" : "restart")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(state.message(now: context.date) ?? "")
            .font(.subheadline)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(L10n.RemoteNodes.RemoteNodes.Reboot.reconnect, action: onReconnect)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!state.canReconnect(now: context.date))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: CardStyle.cornerRadius))
        .accessibilityElement(children: .contain)
      }
      .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }
  }

  private var isPoweredOff: Bool {
    if case .poweredOff = state { return true }
    return false
  }
}

/// Asks for the status again every `minutes` while the page is open: a `TimelineView` tick drives
/// each request, so nothing runs once the page is gone. Draws nothing.
struct NodeAutoRefreshTicker: View {
  /// Nil or 0 turns it off.
  let minutes: Int?
  let isEnabled: Bool
  let action: () async -> Void

  var body: some View {
    if let minutes, minutes > 0 {
      TimelineView(.periodic(from: .now.addingTimeInterval(TimeInterval(minutes * 60)), by: TimeInterval(minutes * 60))) { context in
        Color.clear
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
          .task(id: context.date) {
            guard isEnabled else { return }
            await action()
          }
      }
    }
  }
}
