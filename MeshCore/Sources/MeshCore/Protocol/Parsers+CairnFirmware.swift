import Foundation

extension Parsers {
  // MARK: - CairnFirmware

  /// Parser for Cairn touch firmware's app-started update replies (0xC0) and pushes (0xC1).
  ///
  /// Strings are a length byte then that many bytes of UTF-8; integers are little-endian. A later
  /// protocol version only appends fields, so bytes past the known ones are ignored.
  enum CairnFirmware {
    /// Parses a reply to ``CommandCode/cairnFirmware`` (the payload after the 0xC0 code).
    ///
    /// ### Binary Format
    /// - Offset 0 (1 byte): Sub-command (``CairnFirmwareSubcommand``)
    /// - Offset 1 (1 byte): Status
    /// - STATUS: `[proto u8][realm str][build str][wifi u8][ip 4][updater u8][heap_kb u16]`
    /// - START, CANCEL: nothing more
    /// - SYNC_SENT: `[on u8][queued u8]`
    /// - SPECTRUM: `[op u8][...]` (``Parsers/CairnSpectrum/parseReply(_:)``)
    static func parseReply(_ data: Data) -> MeshEvent {
      guard data.count >= PacketSize.cairnFirmwareReplyMinimum else {
        return .parseFailure(
          data: data,
          reason: "CairnFirmware reply too short: \(data.count) < \(PacketSize.cairnFirmwareReplyMinimum)"
        )
      }
      let status = data[1]
      switch CairnFirmwareSubcommand(rawValue: data[0]) {
      case .status:
        guard status == 0 else {
          return .parseFailure(data: data, reason: "CairnFirmware STATUS failed: \(status)")
        }
        return parseStatus(data)
      case .start:
        return .cairnFirmwareStartReply(CairnFirmwareStartReply(status: status))
      case .cancel:
        return .cairnFirmwareCancelled
      case .history:
        guard data.count >= PacketSize.cairnHistoryReply else {
          return .parseFailure(
            data: data,
            reason: "CairnFirmware HISTORY reply too short: \(data.count) < \(PacketSize.cairnHistoryReply)"
          )
        }
        return .cairnHistoryPageReply(CairnHistoryPageReply(
          status: CairnHistoryPageReply.Status(rawValue: status) ?? .busy,
          storeID: data.readUInt32LE(at: 2),
          total: data.readUInt16LE(at: 6),
          page: data[8]
        ))
      case .spectrum:
        return Parsers.CairnSpectrum.parseReply(data)
      case .syncSent:
        guard status == 0 else {
          return .parseFailure(data: data, reason: "CairnFirmware SYNC_SENT failed: \(status)")
        }
        guard data.count >= PacketSize.cairnSyncSentReply else {
          return .parseFailure(
            data: data,
            reason: "CairnFirmware SYNC_SENT reply too short: \(data.count) < \(PacketSize.cairnSyncSentReply)"
          )
        }
        return .cairnSyncSentState(CairnSyncSentState(isOn: data[2] != 0, queued: data[3]))
      case nil:
        return .parseFailure(data: data, reason: "Unknown CairnFirmware sub-command: \(data[0])")
      }
    }

    /// Parses a push (the payload after the 0xC1 code).
    ///
    /// ### Binary Format (START result)
    /// - Offset 0 (1 byte): Sub-command, 0x02
    /// - Offset 1 (1 byte): Result
    /// - Offset 2 (4 bytes): Updater mode IPv4
    /// - Offset 6 (2 bytes): Port (UInt16 LE)
    /// - Offset 8: User (str), then password (str)
    ///
    /// Address and login are filled only for result 0; for the others they may be zero or absent.
    static func parsePush(_ data: Data) -> MeshEvent {
      guard data.count >= 2, data[0] == CairnFirmwareSubcommand.start.rawValue else {
        return .parseFailure(data: data, reason: "Unknown CairnFirmware push")
      }
      let outcome = CairnFirmwareStartResult.Outcome(result: data[1])
      var offset = 2
      var ip: String?
      var port: UInt16 = 0
      var user = ""
      var password = ""
      if data.count >= offset + 6 {
        ip = ipv4(data, at: offset); offset += 4
        port = data.readUInt16LE(at: offset); offset += 2
        user = readString(data, at: &offset) ?? ""
        password = readString(data, at: &offset) ?? ""
      }
      if outcome == .allowed, ip == nil || password.isEmpty {
        return .parseFailure(data: data, reason: "CairnFirmware START push without address or password")
      }
      return .cairnFirmwareStartResult(CairnFirmwareStartResult(
        outcome: outcome,
        ipAddress: ip,
        port: port,
        user: user,
        password: password
      ))
    }

    private static func parseStatus(_ data: Data) -> MeshEvent {
      var offset = 2
      guard data.count > offset else {
        return .parseFailure(data: data, reason: "CairnFirmware STATUS too short: \(data.count)")
      }
      let proto = data[offset]; offset += 1
      guard let realm = readString(data, at: &offset),
            let build = readString(data, at: &offset),
            data.count >= offset + PacketSize.cairnFirmwareStatusTail else {
        return .parseFailure(data: data, reason: "CairnFirmware STATUS too short: \(data.count)")
      }
      let wifi = data[offset]; offset += 1
      let ip = ipv4(data, at: offset); offset += 4
      let updater = data[offset]; offset += 1
      let heapKB = data.readUInt16LE(at: offset); offset += 2
      // Appended later: `features u8` (bit 0 = SYNC_SENT, bit 1 = HISTORY, bit 2 = SPECTRUM).
      // Absent on older builds.
      let features: UInt8? = data.count > offset ? data[offset] : nil
      return .cairnFirmwareStatus(CairnFirmwareStatus(
        protocolVersion: proto,
        realm: realm,
        build: build,
        wifiRaw: wifi,
        ipAddress: ip,
        updaterRaw: updater,
        largestFreeHeapKB: heapKB,
        features: features
      ))
    }

    /// A length byte then that many bytes of UTF-8; nil when the data ends first.
    private static func readString(_ data: Data, at offset: inout Int) -> String? {
      guard data.count > offset else { return nil }
      let length = Int(data[offset])
      guard data.count >= offset + 1 + length else { return nil }
      let bytes = Data(data[(offset + 1)..<(offset + 1 + length)])
      offset += 1 + length
      return bytes.decodingLongestValidUTF8Prefix()
    }

    /// Four address bytes in order as a dotted quad; nil for 0.0.0.0 (no address).
    private static func ipv4(_ data: Data, at offset: Int) -> String? {
      let bytes = data[offset..<(offset + 4)]
      guard bytes.contains(where: { $0 != 0 }) else { return nil }
      return bytes.map(String.init).joined(separator: ".")
    }
  }
}
