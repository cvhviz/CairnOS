import Foundation

/// What a node answers to an anonymous owner request: the name it advertises and the
/// free-form owner text its operator configured.
public struct NodeOwnerInfo: Sendable, Equatable {
  public let nodeName: String
  public let ownerInfo: String

  public init(nodeName: String, ownerInfo: String) {
    self.nodeName = nodeName
    self.ownerInfo = ownerInfo
  }
}

/// Parses the reply to an anonymous owner request.
enum NodeNameParser {
  /// Longest name the firmware stores (`node_name[32]` including the terminator).
  static let maxNameBytes = 31

  /// Parses an owner response from binary response data.
  ///
  /// The response data layout (after the binary response parser strips the frame header):
  /// - Offset 0–3 (4 bytes): Node clock (UInt32 LE) — skipped
  /// - Offset 4+ (variable): UTF-8 `"<node name>\n<owner info>"`
  ///
  /// The sender timestamp (4 bytes) is already consumed as the tag by the binary response parser.
  ///
  /// - Parameter responseData: The `data` field from `.binaryResponse(tag:data:)`.
  /// - Throws: ``MeshCoreError/parseError(_:)`` if the response is too short or carries no name.
  static func parse(_ responseData: Data) throws -> NodeOwnerInfo {
    guard responseData.count > 4 else {
      throw MeshCoreError.parseError("Owner response too short (\(responseData.count) bytes)")
    }
    // The firmware writes a C string into a fixed buffer; stop at the first NUL.
    let textBytes = Data(responseData.dropFirst(4)).prefix { $0 != 0 }
    // Names come from operators' keyboards over a lossy radio link: decode leniently
    // so one bad byte costs a replacement character, not the whole name.
    let text = String(decoding: textBytes, as: UTF8.self)
    let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let name = parts.first.map { clean(String($0)) } ?? ""
    guard !name.isEmpty else {
      throw MeshCoreError.parseError("Owner response carries no node name")
    }
    let owner = parts.count > 1 ? clean(String(parts[1])) : ""
    return NodeOwnerInfo(nodeName: name.utf8Prefix(maxBytes: maxNameBytes), ownerInfo: owner)
  }

  /// Line breaks become spaces so multi-line owner text stays readable on one row; every other
  /// control character is dropped.
  private static func clean(_ text: String) -> String {
    let scalars = text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
      if scalar == "\n" || scalar == "\r" { return " " }
      return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
    }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
  }
}
