import Foundation
import SwiftData

/// Whether repeaters have echoed an outgoing channel message back to this radio.
public enum ChannelEchoState: Equatable, Sendable {
  /// Echoed this many times.
  case heard(Int)
  /// Sent, nothing back yet, still inside the wait.
  case listening
  /// Sent and nothing came back within the wait: no repeater in range passed it on.
  case notHeard
}

/// How long the app waits for a sent channel message to be echoed before calling it unheard.
public enum ChannelEchoTiming {
  /// A flood is normally repeated within a few seconds; a long chain or a busy mesh can take
  /// longer, so the bubble waits this long before it says nobody repeated it.
  public static let notHeardAfter: TimeInterval = 30

  public static func state(heardRepeats: Int, sentAt: Date, now: Date) -> ChannelEchoState {
    if heardRepeats > 0 { return .heard(heardRepeats) }
    return now.timeIntervalSince(sentAt) >= notHeardAfter ? .notHeard : .listening
  }

  /// Seconds left until a still-unheard message turns `.notHeard`; zero once it has.
  public static func remaining(sentAt: Date, now: Date) -> TimeInterval {
    max(0, notHeardAfter - now.timeIntervalSince(sentAt))
  }
}

/// What the gap between the sender's stamp and this radio's reception says. MeshCore stamps a
/// message with the sender's clock in whole seconds; the gap is transit time plus clock offset,
/// so only a gap well outside what a flood takes points at the clock.
public enum MessageClockReading: Equatable, Sendable {
  /// Heard this many seconds after it was stamped: a normal trip over the mesh.
  case inTransit(TimeInterval)
  /// Stamped this many seconds after it was heard: the sender's clock runs ahead.
  case senderAhead(TimeInterval)
  /// Heard this many seconds after it was stamped, more than a flood takes: the sender's
  /// clock most likely runs behind (or the message sat in a queue).
  case senderBehind(TimeInterval)

  /// Whole-second stamps and two clocks put a few seconds of slack either way.
  public static let aheadTolerance: TimeInterval = 5
  /// Longer than any flood takes to cross a mesh.
  public static let behindThreshold: TimeInterval = 120

  public init(sent: Date, heard: Date) {
    let gap = heard.timeIntervalSince(sent)
    if gap < -Self.aheadTolerance {
      self = .senderAhead(-gap)
    } else if gap > Self.behindThreshold {
      self = .senderBehind(gap)
    } else {
      self = .inTransit(max(0, gap))
    }
  }

  public var suggestsClockOffset: Bool {
    if case .inTransit = self { return false }
    return true
  }
}

/// Picks the RX log row that recorded a received message's first copy, for the readings the
/// message row itself doesn't keep (RSSI, the live reception time).
public enum MessageReceptionMatch {
  public struct Candidate: Equatable, Sendable {
    public let pathNodes: Data
    public let pathLength: UInt8
    /// The packet's unencrypted source-hash byte (DMs), when known.
    public let sourceByte: UInt8?

    public init(pathNodes: Data, pathLength: UInt8, sourceByte: UInt8?) {
      self.pathNodes = pathNodes
      self.pathLength = pathLength
      self.sourceByte = sourceByte
    }
  }

  /// Candidates come oldest first, already narrowed to the message's channel (or DM) and
  /// sender stamp. The copy whose path matches the message's stored path wins. Without a
  /// stored path a lone candidate is taken; several could be different senders in the same
  /// second, so none is guessed.
  public static func bestIndex(
    messagePath: Data?,
    messagePathLength: UInt8,
    senderPrefixByte: UInt8?,
    candidates: [Candidate]
  ) -> Int? {
    let eligible = candidates.indices.filter { index in
      guard let senderPrefixByte, let source = candidates[index].sourceByte else { return true }
      return source == senderPrefixByte
    }
    guard let messagePath else {
      return eligible.count == 1 ? eligible.first : nil
    }
    return eligible.first { index in
      candidates[index].pathNodes == messagePath && candidates[index].pathLength == messagePathLength
    } ?? eligible.first { candidates[$0].pathNodes == messagePath }
  }
}

public extension PersistenceStore {
  /// The RX log row for a received message's first copy, or nil for outgoing messages, rows the
  /// log has since pruned, or a reception that can't be told apart from another.
  func fetchReceptionEntry(for message: MessageDTO) throws -> RxLogEntryDTO? {
    guard !message.isOutgoing else { return nil }
    let stamp = message.senderTimestamp ?? message.timestamp
    let entries: [RxLogEntryDTO]
    if let channelIndex = message.channelIndex {
      entries = try fetchRxLogEntries(radioID: message.radioID, channelIndex: channelIndex, senderTimestamp: stamp)
    } else {
      entries = try findRxLogEntry(radioID: message.radioID, channelIndex: nil, senderTimestamp: stamp).map { [$0] } ?? []
    }
    let isDM = message.channelIndex == nil
    let candidates = entries.map { entry in
      MessageReceptionMatch.Candidate(
        pathNodes: entry.pathNodes,
        pathLength: entry.pathLength,
        sourceByte: isDM && entry.packetPayload.count > 1 ? entry.packetPayload[entry.packetPayload.startIndex + 1] : nil
      )
    }
    return MessageReceptionMatch.bestIndex(
      messagePath: message.pathNodes,
      messagePathLength: message.pathLength,
      senderPrefixByte: isDM ? message.senderKeyPrefix?.first : nil,
      candidates: candidates
    ).map { entries[$0] }
  }
}

public extension PersistenceStore {
  /// Whether a message a heard packet carried is in the chats: one with its sender's timestamp, on
  /// its channel (nil: a direct message). The reverse of `fetchReceptionEntry(for:)`, for the packet
  /// sheet's check that what the app could read reached a chat.
  func hasMessage(radioID: UUID, channelIndex: UInt8?, senderTimestamp: UInt32) throws -> Bool {
    let targetRadioID = radioID
    let target: UInt32? = senderTimestamp
    let predicate = #Predicate<Message> { message in
      message.radioID == targetRadioID && message.senderTimestamp == target
    }
    return try modelContext.fetch(FetchDescriptor<Message>(predicate: predicate))
      .contains { $0.channelIndex == channelIndex }
  }
}
