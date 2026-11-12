import Foundation
import OSLog
import WidgetKit

/// Feeds the home-screen widget: writes a `WidgetSnapshot` to the App Group and asks WidgetKit
/// to reload the widget, paced so a busy mesh (adverts, unread bumps, battery polls) costs at
/// most one reload per `minimumInterval`. A change of connection state goes out at once: the
/// widget must not say "Connected" for half a minute after the link dropped. Anything that
/// arrives inside the interval folds into one trailing write of the newest snapshot, so the last
/// value always lands. A snapshot that says what the widget already shows writes nothing.
///
/// Also keeps the slow-moving inputs the app reports piecemeal (the unread count and the node
/// heard last), so `AppState.publishWidgetSnapshot` can rebuild the whole snapshot from any
/// of its call sites.
@MainActor
final class WidgetSnapshotPublisher {
  static let minimumInterval: TimeInterval = 30

  /// The unread total as `AppState.refreshConversations` last counted it.
  var unreadCount = 0
  /// The node whose advert arrived last, for the widget's "Last heard" line.
  var lastHeardNode: WidgetSnapshot.HeardNode?

  private(set) var lastWritten: WidgetSnapshot?
  private(set) var lastWriteDate: Date?
  /// The newest snapshot waiting for the interval to pass.
  private(set) var pending: WidgetSnapshot?

  private let interval: TimeInterval
  private let now: @MainActor () -> Date
  private let write: @MainActor (WidgetSnapshot) -> Void
  private var trailing: Task<Void, Never>?

  init(
    interval: TimeInterval = WidgetSnapshotPublisher.minimumInterval,
    now: @escaping @MainActor () -> Date = { .now },
    write: @escaping @MainActor (WidgetSnapshot) -> Void = WidgetSnapshotPublisher.writeToAppGroup
  ) {
    self.interval = interval
    self.now = now
    self.write = write
  }

  /// Whether `next` goes out now rather than waiting: the first snapshot, a connection-state
  /// change, or the interval having passed since the last write.
  static func writesImmediately(
    previous: WidgetSnapshot?,
    next: WidgetSnapshot,
    lastWriteDate: Date?,
    now: Date,
    interval: TimeInterval = minimumInterval
  ) -> Bool {
    guard let previous, let lastWriteDate else { return true }
    if previous.connectionState != next.connectionState { return true }
    return now.timeIntervalSince(lastWriteDate) >= interval
  }

  func publish(_ snapshot: WidgetSnapshot) {
    if let lastWritten, lastWritten.hasSameContent(as: snapshot) {
      // Back to what the widget shows: nothing to write, and nothing stale to flush later.
      cancelTrailing()
      return
    }
    let now = now()
    if Self.writesImmediately(
      previous: lastWritten, next: snapshot, lastWriteDate: lastWriteDate, now: now, interval: interval
    ) {
      cancelTrailing()
      commit(snapshot, at: now)
      return
    }
    pending = snapshot
    guard trailing == nil, let lastWriteDate else { return }
    let delay = max(0, interval - now.timeIntervalSince(lastWriteDate))
    trailing = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled else { return }
      trailing = nil
      flushPending()
    }
  }

  /// Writes the snapshot waiting for the interval, if any. The trailing task calls this when
  /// the interval passes.
  func flushPending() {
    guard let pending else { return }
    self.pending = nil
    commit(pending, at: now())
  }

  private func commit(_ snapshot: WidgetSnapshot, at date: Date) {
    var stamped = snapshot
    stamped.updatedAt = date
    lastWritten = stamped
    lastWriteDate = date
    write(stamped)
  }

  private func cancelTrailing() {
    trailing?.cancel()
    trailing = nil
    pending = nil
  }

  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "WidgetSnapshotPublisher")

  /// The production write: the App Group's defaults, then a timeline reload.
  static func writeToAppGroup(_ snapshot: WidgetSnapshot) {
    guard let defaults = WidgetSnapshotStore.defaults() else {
      logger.error("App Group \(WidgetSnapshotStore.appGroupID, privacy: .public) unavailable; widget not updated")
      return
    }
    WidgetSnapshotStore.save(snapshot, to: defaults)
    WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
  }
}
