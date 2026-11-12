import Foundation

extension Parsers {
  // MARK: - CairnTrips

  /// Parser for a Cairn board's trip logs (firmware's
  /// `examples/companion_radio/ui-l2/net/TRIP_SYNC.md`).
  ///
  /// Integers are little-endian; strings are a length byte and that many bytes. Offsets are counted
  /// in the payload after the 0xC0 code (one less than the firmware document's).
  enum CairnTrips {
    /// A reply's head: `[sub][op][status]`.
    static let replyHeader = 3
    /// STATE / START / STOP: the head, `[flags][logs u16][points u32][start u32][name str]`.
    static let stateReply = 15
    /// LIST: the head, `[total u16][from u16][n u8]`, then the entries.
    static let listReply = 8
    /// One LIST entry after its name: start, end, points, distance, moving (u32 each), climb,
    /// descent (u16 each), flags.
    static let entryTail = 25
    /// POINTS: the head, `[total u32][from u32][n u8]`, then the points.
    static let pointsReply = 12
    static let pointBytes = 16
    /// A point without an altitude.
    static let noAltitude = Int32.min

    /// Parses a trip-log reply (the payload after 0xC0, starting with sub-command 0x09).
    static func parseReply(_ data: Data) -> MeshEvent {
      let data = Data(data)
      guard data.count >= replyHeader else {
        return .parseFailure(data: data, reason: "Trip reply too short: \(data.count) < \(replyHeader)")
      }
      guard let op = CairnTripOp(rawValue: data[1]) else {
        return .parseFailure(data: data, reason: "Unknown trip op: \(data[1])")
      }
      let status = CairnTripStatus(byte: data[2])
      switch op {
      case .state, .start, .stop:
        guard data.count >= stateReply else {
          return .parseFailure(data: data, reason: "Trip STATE reply too short: \(data.count) < \(stateReply)")
        }
        let flags = data[3]
        let start = data.readUInt32LE(at: 10)
        let nameLength = Int(data[14])
        let name = data.count >= stateReply + nameLength
          ? String(decoding: data[stateReply ..< stateReply + nameLength], as: UTF8.self) : ""
        return .cairnTripReply(.state(op: op, status: status, CairnTripState(
          isRecording: flags & 0x01 != 0,
          hasCard: flags & 0x02 != 0,
          hasFix: flags & 0x04 != 0,
          isGPSOn: flags & 0x08 != 0,
          logCount: Int(data.readUInt16LE(at: 4)),
          points: Int(data.readUInt32LE(at: 6)),
          startedAt: start == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(start)),
          name: name
        )))
      case .list:
        guard data.count >= listReply else {
          return .cairnTripReply(.list(status: status, total: 0, from: 0, entries: []))
        }
        let total = Int(data.readUInt16LE(at: 3))
        let from = Int(data.readUInt16LE(at: 5))
        let count = Int(data[7])
        var entries: [CairnTripLogEntry] = []
        var at = listReply
        for _ in 0 ..< count {
          guard at < data.count else { break }
          let length = Int(data[at])
          guard at + 1 + length + entryTail <= data.count else {
            return .parseFailure(data: data, reason: "Trip LIST entry cut short at \(at)")
          }
          let name = String(decoding: data[at + 1 ..< at + 1 + length], as: UTF8.self)
          let tail = at + 1 + length
          entries.append(CairnTripLogEntry(
            name: name,
            startedAt: Date(timeIntervalSince1970: TimeInterval(data.readUInt32LE(at: tail))),
            endedAt: Date(timeIntervalSince1970: TimeInterval(data.readUInt32LE(at: tail + 4))),
            points: Int(data.readUInt32LE(at: tail + 8)),
            distance: Double(data.readUInt32LE(at: tail + 12)),
            movingTime: TimeInterval(data.readUInt32LE(at: tail + 16)),
            climb: Double(data.readUInt16LE(at: tail + 20)),
            descent: Double(data.readUInt16LE(at: tail + 22)),
            isRecording: data[tail + 24] & 0x01 != 0
          ))
          at = tail + entryTail
        }
        return .cairnTripReply(.list(status: status, total: total, from: from, entries: entries))
      case .points:
        guard data.count >= pointsReply else {
          return .cairnTripReply(.points(status: status, total: 0, from: 0, points: []))
        }
        let total = Int(data.readUInt32LE(at: 3))
        let from = Int(data.readUInt32LE(at: 7))
        let count = Int(data[11])
        guard data.count >= pointsReply + count * pointBytes else {
          return .parseFailure(data: data, reason: "Trip POINTS reply cut short: \(data.count)")
        }
        let points = (0 ..< count).map { i -> CairnTripPoint in
          let at = pointsReply + i * pointBytes
          let altitude = data.readInt32LE(at: at + 12)
          return CairnTripPoint(
            time: Date(timeIntervalSince1970: TimeInterval(data.readUInt32LE(at: at))),
            latitude: Double(data.readInt32LE(at: at + 4)) / 1_000_000,
            longitude: Double(data.readInt32LE(at: at + 8)) / 1_000_000,
            altitude: altitude == noAltitude ? nil : Double(altitude) / 10
          )
        }
        return .cairnTripReply(.points(status: status, total: total, from: from, points: points))
      case .delete:
        return .cairnTripReply(.deleted(status: status))
      }
    }
  }
}
