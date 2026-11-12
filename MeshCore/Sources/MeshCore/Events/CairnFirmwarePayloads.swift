import Foundation

/// What a Cairn touch board says about itself before an app-started update (`CMD_CAIRN_FW` STATUS).
///
/// Only the ESP32-S3 touch builds answer; other firmware replies ``ErrorCode/unsupportedCommand``.
public struct CairnFirmwareStatus: Sendable, Equatable {
  /// The board's Wi-Fi as STATUS reports it.
  public enum WiFiState: UInt8, Sendable {
    /// This build has no Wi-Fi.
    case notInBuild = 0
    case off = 1
    /// On, but not on a network (connecting, no network, out of range).
    case notConnected = 2
    case connected = 3
  }

  /// The board's Updater mode.
  public enum UpdaterState: UInt8, Sendable {
    case off = 0
    case ready = 1
    case receiving = 2
    /// Installing the image, or restarting into it.
    case installing = 3
  }

  /// The protocol version the board speaks; later versions only append fields.
  public let protocolVersion: UInt8
  /// Updater mode's Digest realm ("MeshCore L2"), which names the board.
  public let realm: String
  /// The firmware build ("Cairn 111", "Cairn dev").
  public let build: String
  /// Raw Wi-Fi state byte; see ``wifi`` for the known values.
  public let wifiRaw: UInt8
  /// The board's IPv4 address while its Wi-Fi is connected, else `nil`.
  public let ipAddress: String?
  /// Raw Updater mode byte; see ``updater`` for the known values.
  public let updaterRaw: UInt8
  /// The largest free heap block in KB (Updater mode needs about 36 KB).
  public let largestFreeHeapKB: UInt16
  /// The feature bits STATUS appends after the heap size, or `nil` on builds that predate them.
  public let features: UInt8?

  /// The board can echo messages sent from its own UI (``CairnFirmwareSubcommand/syncSent``).
  /// A hint only: the SYNC_SENT reply is the authority.
  public var supportsSyncSent: Bool {
    (features ?? 0) & 0x01 != 0
  }

  /// The board can send its chat history (``CairnFirmwareSubcommand/history``). A hint only: the
  /// HISTORY reply (or `ERR_CODE_UNSUPPORTED_CMD`) is the authority.
  public var supportsHistory: Bool {
    (features ?? 0) & 0x02 != 0
  }

  public var wifi: WiFiState? { WiFiState(rawValue: wifiRaw) }
  public var updater: UpdaterState? { UpdaterState(rawValue: updaterRaw) }

  public init(
    protocolVersion: UInt8,
    realm: String,
    build: String,
    wifiRaw: UInt8,
    ipAddress: String?,
    updaterRaw: UInt8,
    largestFreeHeapKB: UInt16,
    features: UInt8? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.realm = realm
    self.build = build
    self.wifiRaw = wifiRaw
    self.ipAddress = ipAddress
    self.updaterRaw = updaterRaw
    self.largestFreeHeapKB = largestFreeHeapKB
    self.features = features
  }
}

/// The board's immediate answer to a START (`[0xC0][0x02][status]`).
public enum CairnFirmwareStartReply: Sendable, Equatable {
  /// The board is asking its user; a ``CairnFirmwareStartResult`` push follows within 60 s.
  case asking
  /// The board's Wi-Fi isn't connected.
  case wifiNotConnected
  /// Updater mode or an online update is already running, or another request is waiting.
  case busy
  /// The board is locked, hibernating, or low on memory.
  case notNow
  /// A status this library doesn't know.
  case other(UInt8)

  public init(status: UInt8) {
    switch status {
    case 0: self = .asking
    case 2: self = .wifiNotConnected
    case 3: self = .busy
    case 4: self = .notNow
    default: self = .other(status)
    }
  }
}

/// The board's push once its user answered a START, or 60 s passed (`[0xC1][0x02][...]`).
public struct CairnFirmwareStartResult: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    /// Allowed: Updater mode starts about 500 ms later and Bluetooth goes off.
    case allowed
    case declined
    /// Updater mode failed to start; the board shows why.
    case failed
    /// Nobody answered on the board within 60 s.
    case noAnswer
    case other(UInt8)

    public init(result: UInt8) {
      switch result {
      case 0: self = .allowed
      case 1: self = .declined
      case 2: self = .failed
      case 3: self = .noAnswer
      default: self = .other(result)
      }
    }
  }

  public let outcome: Outcome
  /// Updater mode's address and login; filled only when ``outcome`` is ``Outcome/allowed``.
  public let ipAddress: String?
  public let port: UInt16
  public let user: String
  public let password: String

  public init(outcome: Outcome, ipAddress: String?, port: UInt16, user: String, password: String) {
    self.outcome = outcome
    self.ipAddress = ipAddress
    self.port = port
    self.user = user
    self.password = password
  }
}

/// The board's reply to ``CairnFirmwareSubcommand/syncSent`` (`[0xC0][0x04][0][on][queued]`).
public struct CairnSyncSentState: Sendable, Equatable {
  /// Whether this link now gets echoes of messages sent from the board's own UI.
  public let isOn: Bool
  /// How many echo and status records wait in the board's offline queue (at most 255).
  public let queued: UInt8

  public init(isOn: Bool, queued: UInt8) {
    self.isOn = isOn
    self.queued = queued
  }
}

/// A message composed and sent on the board's own UI, echoed to an app that opted in with
/// ``CairnFirmwareSubcommand/syncSent``, or a later delivery update for one.
///
/// Wire format after the code byte (0xC2 from the offline queue, 0xC3 live):
/// `[flags u8][dest 6][timestamp u32][ack u32]` then the text (kinds 0, 1) or
/// `[status u8][rtt_ms u32]` (kind 2). Integers are little-endian.
public struct RadioSentMessage: Sendable, Equatable {
  public enum Kind: UInt8, Sendable, Equatable {
    /// A direct message to the contact whose public key starts with ``destination``.
    case direct = 0
    /// A channel message on slot ``channelIndex``.
    case channel = 1
    /// A delivery update for a message echoed earlier.
    case statusUpdate = 2
  }

  /// The outcome a ``Kind/statusUpdate`` reports.
  public enum DeliveryStatus: Sendable, Equatable {
    case delivered
    /// The board gave up after its retries.
    case failed
    case other(UInt8)

    public init(rawValue: UInt8) {
      switch rawValue {
      case 1: self = .delivered
      case 2: self = .failed
      default: self = .other(rawValue)
      }
    }
  }

  /// `true` for the live push (0xC3); `false` for the offline-queue answer to a fetch (0xC2).
  public let isLive: Bool
  public let kind: Kind
  /// DM: the recipient's 6-byte public-key prefix. Channel: `[index, 0, 0, 0, 0, 0]`.
  public let destination: Data
  /// The timestamp the board put in the packet (the recipient's sender timestamp).
  public let timestamp: UInt32
  /// DM: the expected ACK CRC of the first attempt (0 for channels).
  public let ackCode: UInt32
  /// The ACK already arrived (set on a still-queued DM echo).
  public let isDelivered: Bool
  /// The message text, without the `"<node name>: "` prefix a channel message carries on air.
  /// Empty for a ``Kind/statusUpdate``.
  public let text: String
  /// The outcome of a ``Kind/statusUpdate``; `nil` for an echo.
  public let deliveryStatus: DeliveryStatus?
  /// Round-trip time in ms of a ``Kind/statusUpdate`` that reports delivered.
  public let roundTripTime: UInt32?

  /// The channel slot of a channel echo, else `nil`.
  public var channelIndex: UInt8? {
    kind == .channel ? destination.first : nil
  }

  public init(
    isLive: Bool,
    kind: Kind,
    destination: Data,
    timestamp: UInt32,
    ackCode: UInt32,
    isDelivered: Bool,
    text: String,
    deliveryStatus: DeliveryStatus? = nil,
    roundTripTime: UInt32? = nil
  ) {
    self.isLive = isLive
    self.kind = kind
    self.destination = destination
    self.timestamp = timestamp
    self.ackCode = ackCode
    self.isDelivered = isDelivered
    self.text = text
    self.deliveryStatus = deliveryStatus
    self.roundTripTime = roundTripTime
  }
}

// MARK: - Chat History

/// The board's answer to a history QUERY or PAGE.
public struct CairnHistoryPageReply: Sendable, Equatable {
  public enum Status: UInt8, Sendable {
    case ok = 0
    /// Another app's page is running: ask again shortly.
    case busy = 1
  }

  public let status: Status
  /// Names the board's numbering: a different id means the app's cursor no longer applies (start
  /// from 0).
  public let storeID: UInt32
  /// Records numbered past the request's `since_seq`.
  public let total: UInt16
  /// Records this page walks (0 for a QUERY or BUSY); fewer may arrive.
  public let page: UInt8

  public init(status: Status, storeID: UInt32, total: UInt16, page: UInt8) {
    self.status = status
    self.storeID = storeID
    self.total = total
    self.page = page
  }
}

/// One history frame as it arrived: a record's first frame, or (``Flags/continuation``) the rest
/// of its text.
public struct CairnHistoryRecord: Sendable, Equatable {
  public struct Flags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let outgoing = Flags(rawValue: 0x01)
    public static let delivered = Flags(rawValue: 0x02)
    public static let read = Flags(rawValue: 0x04)
    /// ``CairnHistoryRecord/sentAt`` is the sender's timestamp (0 means unknown otherwise).
    public static let hasSentTimestamp = Flags(rawValue: 0x08)
    /// A signed post (a room's); its author is not carried.
    public static let signed = Flags(rawValue: 0x10)
    public static let channel = Flags(rawValue: 0x20)
    public static let continuation = Flags(rawValue: 0x40)
    /// A continuation with the same `seq` follows.
    public static let more = Flags(rawValue: 0x80)
  }

  public let flags: Flags
  /// The board's number for the record, growing within a ``CairnHistoryPageReply/storeID``.
  public let seq: UInt32
  /// The peer's 6-byte key prefix (a DM, a room) or the channel's identity (a channel post).
  public let key: Data
  /// The channel slot of a channel post; nil for a DM.
  public let channelIndex: UInt8?
  /// The route it came by (the encoded path length), 0xFF unknown.
  public let pathLength: UInt8
  /// When the board stored it, by the board's clock (seconds since 1970).
  public let storedAt: UInt32
  /// The sender's timestamp when ``Flags/hasSentTimestamp``.
  public let sentAt: UInt32
  public let snrX4: Int8
  public let rssi: Int16
  /// UTF-8 bytes (a continuation's: the tail only).
  public let text: Data

  public init(
    flags: Flags, seq: UInt32, key: Data, channelIndex: UInt8?, pathLength: UInt8,
    storedAt: UInt32, sentAt: UInt32, snrX4: Int8, rssi: Int16, text: Data
  ) {
    self.flags = flags
    self.seq = seq
    self.key = key
    self.channelIndex = channelIndex
    self.pathLength = pathLength
    self.storedAt = storedAt
    self.sentAt = sentAt
    self.snrX4 = snrX4
    self.rssi = rssi
    self.text = text
  }

  /// This first frame with a continuation's tail appended (the whole record).
  func appending(_ tail: CairnHistoryRecord) -> CairnHistoryRecord {
    CairnHistoryRecord(
      flags: flags.subtracting(.more), seq: seq, key: key, channelIndex: channelIndex,
      pathLength: pathLength, storedAt: storedAt, sentAt: sentAt, snrX4: snrX4, rssi: rssi,
      text: text + tail.text
    )
  }

  /// The text as a string (a cut multi-byte character at the end dropped).
  public var string: String { text.decodingLongestValidUTF8Prefix() }
}

/// The end of a history page.
public struct CairnHistoryEnd: Sendable, Equatable {
  /// The page ended early (this app asked again before it finished); what arrived stands.
  public let aborted: Bool
  /// The board's cursor after the page: the app's next `sinceSeq`.
  public let lastSeq: UInt32
  /// Records past ``lastSeq`` still on the board.
  public let remaining: UInt16
  public let storeID: UInt32

  public init(aborted: Bool, lastSeq: UInt32, remaining: UInt16, storeID: UInt32) {
    self.aborted = aborted
    self.lastSeq = lastSeq
    self.remaining = remaining
    self.storeID = storeID
  }
}

/// A history page as collected: the reply, the whole records in order, and its end (nil when the
/// link went quiet first: resume from the last record's `seq`).
public struct CairnHistoryPage: Sendable, Equatable {
  public let reply: CairnHistoryPageReply
  public let records: [CairnHistoryRecord]
  public let end: CairnHistoryEnd?

  public init(reply: CairnHistoryPageReply, records: [CairnHistoryRecord], end: CairnHistoryEnd?) {
    self.reply = reply
    self.records = records
    self.end = end
  }

  /// Where the next page starts: the end's cursor, else the last whole record's.
  public func nextSince(after since: UInt32) -> UInt32 {
    end?.lastSeq ?? records.last?.seq ?? since
  }
}
