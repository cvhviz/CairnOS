import Foundation
import os

/// Drop-in replacement for Logger that uses the shared DebugLogBuffer.
/// Writes to OSLog for every level; `.info` and above also persist to SwiftData.
public struct PersistentLogger: Sendable {
  private let logger: Logger
  /// Same subsystem/category as `logger`; used only to ask whether `.debug` is
  /// enabled before building a debug message.
  private let osLog: OSLog
  private let subsystem: String
  private let category: String

  public init(subsystem: String, category: String) {
    logger = Logger(subsystem: subsystem, category: category)
    osLog = OSLog(subsystem: subsystem, category: category)
    self.subsystem = subsystem
    self.category = category
  }

  /// Debug messages are never persisted and are off by default outside a
  /// debugging session, so the message is only built when `.debug` is enabled
  /// for this subsystem; hot per-packet call sites cost one check otherwise.
  public func debug(_ message: @autoclosure () -> String) {
    guard osLog.isEnabled(type: .debug) else { return }
    let text = message()
    logger.debug("\(text)")
  }

  public func info(_ message: String) {
    logger.info("\(message)")
    persist(level: .info, message: message)
  }

  public func notice(_ message: String) {
    logger.notice("\(message)")
    persist(level: .notice, message: message)
  }

  public func warning(_ message: String) {
    logger.warning("\(message)")
    persist(level: .warning, message: message)
  }

  public func error(_ message: String) {
    logger.error("\(message)")
    persist(level: .error, message: message)
  }

  public func fault(_ message: String) {
    logger.fault("\(message)")
    persist(level: .fault, message: message)
  }

  private func persist(level: DebugLogLevel, message: String) {
    DebugLogBuffer.record(DebugLogEntryDTO(
      level: level,
      subsystem: subsystem,
      category: category,
      message: message
    ))
  }
}
