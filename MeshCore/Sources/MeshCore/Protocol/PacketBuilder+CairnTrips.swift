import Foundation

// MARK: - Cairn trip logs (firmware's examples/companion_radio/ui-l2/net/TRIP_SYNC.md)

public extension PacketBuilder {
  /// The radio's recorder state: `[0xC0][0x09][0x00]`. Firmware without trip logs answers
  /// `RESP_CODE_ERR` with ``ErrorCode/unsupportedCommand``.
  static func cairnTripState() -> Data { tripHead(.state) }

  /// Starts recording a trip on the radio: `[0xC0][0x09][0x01]`.
  static func cairnTripStart() -> Data { tripHead(.start) }

  /// Stops the radio's recording: `[0xC0][0x09][0x02]`.
  static func cairnTripStop() -> Data { tripHead(.stop) }

  /// A page of the card's logs, newest first: `[0xC0][0x09][0x03][from u16][max u8]`. `from` 0 has
  /// the radio read its card again.
  static func cairnTripList(from: UInt16, max: UInt8 = 3) -> Data {
    var data = tripHead(.list)
    data.append(UInt8(from & 0xFF))
    data.append(UInt8(from >> 8))
    data.append(max)
    return data
  }

  /// A page of one log's points: `[0xC0][0x09][0x04][from u32][max u8][name str]`.
  static func cairnTripPoints(name: String, from: UInt32, max: UInt8 = 9) -> Data {
    var data = tripHead(.points)
    data.appendLittleEndian(from)
    data.append(max)
    appendName(name, to: &data)
    return data
  }

  /// Deletes a log from the radio's card: `[0xC0][0x09][0x05][name str]`.
  static func cairnTripDelete(name: String) -> Data {
    var data = tripHead(.delete)
    appendName(name, to: &data)
    return data
  }

  private static func tripHead(_ op: CairnTripOp) -> Data {
    Data([CommandCode.cairnFirmware.rawValue, CairnFirmwareSubcommand.trips, op.rawValue])
  }

  private static func appendName(_ name: String, to data: inout Data) {
    let bytes = Array(name.utf8.prefix(31))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
  }
}
