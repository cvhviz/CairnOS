import Foundation

/// What happened to a command that makes the radio transmit over the air
/// (``CommandCode/transmitsOverAir``, or a telemetry request for another node).
///
/// The radio reports nothing it transmits, so these events are all the app knows of what this
/// radio sent: the moment each command was written to it, then the radio's own answer to that
/// write. A request's retransmits are separate writes, each with its own id and answer.
public enum TransmissionEvent: Sendable, Equatable {
  /// The command was written to the radio at `at`. `id` is unique within the session.
  case written(id: UInt64, command: Data, at: Date)
  /// The radio answered the write `id`.
  case answered(id: UInt64, outcome: TransmissionOutcome)

  /// The id of the write this event is about.
  public var id: UInt64 {
    switch self {
    case let .written(id, _, _), let .answered(id, _):
      id
    }
  }
}

/// The radio's answer to a transmitting command.
public enum TransmissionOutcome: Sendable, Equatable {
  /// `RESP_CODE_SENT` (0x06): the radio queued the packet, flood or direct, with the ack it
  /// expects back.
  case sent(MessageSentInfo)
  /// `RESP_CODE_OK`: the radio accepted the command (a channel message, an advert, control data).
  case ok
  /// `RESP_CODE_ERR`: the radio refused the command and sent nothing.
  case rejected(code: UInt8?)
  /// No answer arrived (a timeout, or the exchange ended first): the radio may or may not have
  /// sent it.
  case unconfirmed

  /// The outcome a finished command exchange reports: `.sent` when it returned the radio's
  /// `RESP_CODE_SENT`, otherwise `.ok`.
  static func answering(_ result: some Sendable) -> TransmissionOutcome {
    if let info = result as? MessageSentInfo { return .sent(info) }
    return .ok
  }

  /// The outcome a failed command exchange reports: `.rejected` for the radio's own error,
  /// `.unconfirmed` for anything else (a timeout, a cancelled wait).
  static func failing(_ error: any Error) -> TransmissionOutcome {
    if case let .deviceError(code)? = error as? MeshCoreError { return .rejected(code: code) }
    return .unconfirmed
  }
}

/// Pairs the writes of one retransmitting exchange with the radio's answers, in order: the radio
/// answers each write once, first in first out.
struct TransmissionAnswerPairing: Sendable {
  private var unanswered: [UInt64] = []
  private var earlyAnswers: [TransmissionOutcome] = []

  /// Notes a write; returns its answer when one already arrived.
  mutating func wrote(_ id: UInt64) -> TransmissionOutcome? {
    if !earlyAnswers.isEmpty { return earlyAnswers.removeFirst() }
    unanswered.append(id)
    return nil
  }

  /// Notes an answer; returns the write it answers, or `nil` while none is waiting.
  mutating func answered(_ outcome: TransmissionOutcome) -> UInt64? {
    guard !unanswered.isEmpty else {
      earlyAnswers.append(outcome)
      return nil
    }
    return unanswered.removeFirst()
  }

  /// Ends the exchange: the writes still without an answer.
  mutating func finish() -> [UInt64] {
    defer {
      unanswered = []
      earlyAnswers = []
    }
    return unanswered
  }
}
