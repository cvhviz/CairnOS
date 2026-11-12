// BLELinkDiagnostics.swift
import Foundation

/// One consistent snapshot of the transport's observable state, read in a
/// single actor hop so a log line cannot interleave values from different
/// moments.
public struct BLELinkDiagnostics: Sendable {
  /// CBCentralManager state name (e.g. "poweredOn", "notActivated").
  public let centralState: String

  /// The state machine's current phase.
  public let phase: BLEPhaseKind

  /// Peripheral connection state name, or nil when no phase owns a peripheral.
  public let peripheralState: String?

  /// Notifications dropped because the data stream's buffer was full, since the
  /// state machine was created. Monotonic across reconnects; zero means no frame
  /// was lost between CoreBluetooth and the session.
  public let droppedNotificationCount: Int

  /// Deepest data stream backlog, in frames, since the state machine was created.
  public let notificationBufferHighWaterMark: Int

  public init(
    centralState: String,
    phase: BLEPhaseKind,
    peripheralState: String?,
    droppedNotificationCount: Int = 0,
    notificationBufferHighWaterMark: Int = 0
  ) {
    self.centralState = centralState
    self.phase = phase
    self.peripheralState = peripheralState
    self.droppedNotificationCount = droppedNotificationCount
    self.notificationBufferHighWaterMark = notificationBufferHighWaterMark
  }
}
