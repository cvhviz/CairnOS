import Foundation

/// How an incoming message reached the app, used to decide its persisted sort order.
///
/// This value is ephemeral — it is never stored on `Message` or `MessageDTO`. It only
/// flows through the message-handler pipeline so the sort date can be derived per the
/// delivery path:
/// - `live` keeps just-arrived messages at the bottom of the transcript (sort by receive time).
/// - `initialSync` positions a drained backlog batch as one contiguous block at the drain
///   time carried in `anchor`, so reconnect history lands together near the bottom rather
///   than scattered through scrollback by send time.
enum DeliveryContext {
  /// Drained from the device's stored backlog during initial connect or resync.
  /// `anchor` is captured once per drain so every message in the batch shares a sort
  /// date and forms a contiguous block positioned at delivery time, send-ordered within.
  case initialSync(anchor: Date)
  /// Pushed in real time while connected.
  case live
  /// Pulled from a Cairn board's own chat history (firmware's `HIST_SYNC.md`): already seen there,
  /// so stored read and silent. `storedAt` is when the board stored it: its sort date and the
  /// receive time its timestamp is judged against.
  case history(storedAt: Date)

  /// Pulled from the board's history: no unread count, notification, badge or "heard" stamp.
  var isHistory: Bool {
    if case .history = self { return true }
    return false
  }

  /// The receive time a message is judged against: the board's storage time for history.
  func receiveTime(now: Date = Date()) -> Date {
    if case let .history(storedAt) = self { return storedAt }
    return now
  }
}
