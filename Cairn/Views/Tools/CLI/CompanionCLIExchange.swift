import CairnServices
import Foundation

/// Sends one command to another companion and returns its reply without the tag
/// (`RemoteNodeService.sendCompanionCLICommand`). `requestID` names the command in
/// `RemoteNodeService.companionCLILateReplies()` if its reply comes after the timeout.
typealias CompanionCLISend = @MainActor (
  _ publicKey: Data,
  _ command: String,
  _ timeout: Duration,
  _ requestID: UUID
) async throws -> String

extension RemoteNodeService {
  /// This service's companion command line as the terminals' send closure.
  nonisolated var companionCLISend: CompanionCLISend {
    { [self] publicKey, command, timeout, requestID in
      try await sendCompanionCLICommand(
        publicKey: publicKey,
        command: command,
        timeout: timeout,
        requestID: requestID
      )
    }
  }
}

/// What one command to another companion's command line came back with, as one terminal line.
/// Shared by the Tools CLI's companion sessions and a contact's own command-line page, and worded
/// as the Cairn firmware's Remote commands page words it (ui-l2 `CompanionCliScreen`, `UIModel`).
enum CompanionCLIExchange {
  struct Outcome: Equatable {
    let text: String
    let type: CLIOutputType
    /// No reply came in time: the terminal keeps the line so a late reply can show under it
    /// (``CompanionCLILateLines``).
    var awaitsLateReply = false
  }

  /// Cleans and sends a command, then says what came of it. Nil when the command was cancelled
  /// (the terminal already said so).
  ///
  /// - A reply shows without the CLI's own "> " lead; "Unknown…" and "ERR…" show as errors, as
  ///   the firmware colours them.
  /// - Silence is "No reply yet · it may still arrive": that side's permission, its range and
  ///   its firmware all look the same from here, and a `set` may still have applied. A reply
  ///   that comes later shows under it (``CompanionCLILateLines``).
  /// - A restart counts as sent with or without a reply ("Sent · it restarts", with the
  ///   device's own words after it when it answered): stock firmware restarts before it answers.
  @MainActor
  static func run(_ command: String, send: @MainActor (String) async throws -> String) async -> Outcome? {
    guard let cleaned = CompanionCLICatalog.clean(command) else {
      return Outcome(text: L10n.Tools.Tools.Cli.Companion.notACommand, type: .error)
    }
    let restarts = CompanionCLICatalog.restarts(cleaned)
    do {
      let reply = try await send(cleaned)
      guard !Task.isCancelled else { return nil }
      let body = CompanionCLITag.displayText(reply)
      if restarts {
        if body.isEmpty {
          return Outcome(text: L10n.Tools.Tools.Cli.Companion.restartSent, type: .success)
        }
        if !isFailure(body) {
          return Outcome(text: L10n.Tools.Tools.Cli.Companion.restartSentReply(body), type: .success)
        }
      }
      return replyOutcome(body)
    } catch is CancellationError {
      return nil
    } catch let error as RemoteNodeError {
      if Task.isCancelled { return nil }
      switch error {
      case .timeout:
        return restarts
          ? Outcome(text: L10n.Tools.Tools.Cli.Companion.restartSent, type: .success, awaitsLateReply: true)
          : Outcome(text: L10n.Tools.Tools.Cli.Companion.noReply, type: .error, awaitsLateReply: true)
      case .cancelled:
        return nil
      default:
        if error.isUnsupportedByRadio {
          return Outcome(text: L10n.Tools.Tools.Cli.Companion.needsFirmware, type: .error)
        }
        return Outcome(text: error.localizedDescription, type: .error)
      }
    } catch {
      if Task.isCancelled { return nil }
      return Outcome(text: error.localizedDescription, type: .error)
    }
  }

  /// A reply's body as a line: "(empty reply)" for none, an error for "Unknown…" or "ERR…".
  static func replyOutcome(_ body: String) -> Outcome {
    if body.isEmpty {
      return Outcome(text: L10n.Tools.Tools.Cli.Companion.emptyReply, type: .response)
    }
    return Outcome(text: body, type: isFailure(body) ? .error : .response)
  }

  /// The firmware colours these replies as warnings.
  private static func isFailure(_ body: String) -> Bool {
    body.hasPrefix("Unknown") || body.hasPrefix("ERR")
  }

  /// The lines a companion session prints when it opens: where commands go and when it answers.
  static func bannerLines(name: String) -> [String] {
    [
      L10n.Tools.Tools.Cli.Companion.opened(name),
      L10n.Tools.Tools.Cli.Companion.note,
      L10n.Tools.Tools.Cli.Companion.hint,
    ]
  }

  /// `help`'s list of what a companion takes (the picker's catalogue, by family).
  static var helpLines: [String] {
    [
      L10n.Tools.Tools.Cli.helpCompanionHeader,
      L10n.Tools.Tools.Cli.helpCompanionList1,
      L10n.Tools.Tools.Cli.helpCompanionList2,
      L10n.Tools.Tools.Cli.helpCompanionList3,
      L10n.Tools.Tools.Cli.helpCompanionList4,
      L10n.Tools.Tools.Cli.Companion.note,
    ]
  }
}

/// The timed-out commands of one terminal whose late reply still shows under them, as the
/// firmware's Remote commands page turns a timed-out line into a LATE one
/// (ui-l2 `UIModel::onRemoteCliReply`, `ccli::LATE`).
struct CompanionCLILateLines {
  /// Commands kept at most; the service keeps each for only a minute anyway.
  private static let maxWaiting = 32

  /// The no-reply line of each timed-out command, by its request ID, oldest first, with the
  /// name of the node it went to.
  private var waiting: [(requestID: UUID, lineID: UUID, nodeName: String)] = []

  /// Keeps the line that said a command to `nodeName` had no reply, for a late reply to go under.
  mutating func watch(requestID: UUID, lineID: UUID, nodeName: String) {
    waiting.append((requestID, lineID, nodeName))
    if waiting.count > Self.maxWaiting { waiting.removeFirst() }
  }

  /// Puts a late reply under its command's no-reply line, or at the end with its node and
  /// command named when that line is gone (cleared, or scrolled out): by then the terminal
  /// may be talking to another node. False when the reply is not for one of this terminal's
  /// commands.
  @MainActor
  mutating func place(_ reply: CompanionCLILateReply, in lines: inout [CLIOutputLine]) -> Bool {
    guard let index = waiting.firstIndex(where: { $0.requestID == reply.requestID }) else { return false }
    let (_, lineID, nodeName) = waiting.remove(at: index)
    let outcome = CompanionCLIExchange.replyOutcome(CompanionCLITag.displayText(reply.text))
    if let row = lines.firstIndex(where: { $0.id == lineID }) {
      lines.insert(
        CLIOutputLine(text: L10n.Tools.Tools.Cli.Companion.lateReply(outcome.text), type: outcome.type),
        at: row + 1
      )
    } else {
      lines.append(CLIOutputLine(
        text: L10n.Tools.Tools.Cli.Companion.lateReplyFrom(nodeName, reply.command, outcome.text),
        type: outcome.type
      ))
    }
    return true
  }
}
