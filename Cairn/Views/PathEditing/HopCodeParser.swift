import Foundation

/// Pure parser for the comma-separated hex-code bulk-add entry shared by the
/// contact path editor and the trace path builder. The single source of truth
/// for both the bulk-add preview and the actual add, so the panel can never show
/// a status that differs from what tapping "Add" produces.
enum HopCodeParser {
  /// Classify each code in `input` without mutating any path.
  ///
  /// - Parameters:
  ///   - hashSize: bytes per hop; a code must be exactly `hashSize * 2` hex digits.
  ///   - existingHashes: hash-byte prefixes already in the path (for `.alreadyInPath`).
  ///   - remainingCapacity: hops still addable, or `nil` when unlimited; resolvable
  ///     codes beyond it become `.pathFull`.
  ///   - allowsRepeats: keep repeated codes and codes already in the path. A trace may
  ///     pass a repeater twice (its dedupe hashes the hop count too); a contact route may not.
  ///   - keepsUnresolved: add a code no known node matches as a key-less hop. A trace
  ///     can probe any hash; a contact route needs a known node to re-encode from.
  ///   - resolve: maps a hash prefix to a node's full public key and display name,
  ///     or `nil` when no node matches.
  static func classify(
    input: String,
    hashSize: Int,
    existingHashes: Set<Data>,
    remainingCapacity: Int?,
    allowsRepeats: Bool = false,
    keepsUnresolved: Bool = false,
    resolve: (Data) -> (publicKey: Data, name: String?)?
  ) -> [HopCodeClassification] {
    let codes = input
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
      .filter { !$0.isEmpty }

    var seen = Set<String>()
    let entries = allowsRepeats ? codes : codes.filter { seen.insert($0).inserted }

    var pathHashes = existingHashes
    var added = 0

    return entries.enumerated().map { position, code in
      guard let hashData = parseHex(code, hashSize: hashSize) else {
        return HopCodeClassification(position: position, code: code, status: .invalidFormat)
      }
      if !allowsRepeats, pathHashes.contains(hashData) {
        return HopCodeClassification(position: position, code: code, status: .alreadyInPath)
      }
      let resolved = resolve(hashData)
      if resolved == nil, !keepsUnresolved {
        return HopCodeClassification(position: position, code: code, status: .notFound)
      }
      if let remainingCapacity, added >= remainingCapacity {
        return HopCodeClassification(position: position, code: code, status: .pathFull)
      }
      added += 1
      pathHashes.insert(hashData)
      let hop = PathHop(hashBytes: hashData, publicKey: resolved?.publicKey, resolvedName: resolved?.name)
      return HopCodeClassification(position: position, code: code, status: .willAdd(hop))
    }
  }

  /// Parse a hex `code` into exactly `hashSize` bytes, or `nil` if malformed.
  private static func parseHex(_ code: String, hashSize: Int) -> Data? {
    guard code.count == hashSize * 2, code.allSatisfy(\.isHexDigit) else { return nil }
    var data = Data()
    var idx = code.startIndex
    while idx < code.endIndex {
      let next = code.index(idx, offsetBy: 2)
      guard let byte = UInt8(code[idx..<next], radix: 16) else { return nil }
      data.append(byte)
      idx = next
    }
    return data.count == hashSize ? data : nil
  }
}
