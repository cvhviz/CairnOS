import Foundation

// MARK: - Path Encoding Utilities

/// Limits for the multibyte path-length encoding, shared by ``encodePathLen(hashSize:hopCount:)``,
/// `setPathHashMode`, and the config-import path validator so the valid ranges live in one place.
public enum PathEncoding {
  /// Highest valid path hash-size mode (0 = 1-byte, 1 = 2-byte, 2 = 3-byte hashes; mode 3 is reserved).
  public static let maxPathHashMode = 2
  /// Highest hop count representable in the encoded path-length byte's lower 6 bits.
  public static let maxHopCount = 63
  /// Maximum encoded out-path length in bytes (firmware `MAX_PATH_SIZE`); firmware
  /// `isValidPathLen` rejects `hash_count * hash_size` beyond this.
  public static let maxPathBytes = 64
}

/// Decoded components of a multibyte-encoded path length byte.
public struct PathLenDecoded: Sendable {
  /// Bytes per hop hash (1, 2, or 3).
  public let hashSize: Int
  /// Number of hops in the path (0-63).
  public let hopCount: Int
  /// Total path byte length (hashSize * hopCount).
  public let byteLength: Int
}

/// Decodes a multibyte-encoded path length byte.
///
/// The encoding packs two fields into a single byte:
/// - Bits 7-6: hash size mode (0=1-byte, 1=2-byte, 2=3-byte, 3=reserved)
/// - Bits 5-0: hop count (0-63)
///
/// - Parameter encoded: The raw path length byte from the wire.
/// - Returns: Decoded components, or `nil` if mode 3 (reserved).
public func decodePathLen(_ encoded: UInt8) -> PathLenDecoded? {
  let mode = encoded >> 6
  guard mode < 3 else { return nil } // mode 3 is reserved
  let hashSize = Int(mode) + 1
  let hopCount = Int(encoded & 63)
  return PathLenDecoded(hashSize: hashSize, hopCount: hopCount, byteLength: hashSize * hopCount)
}

/// Encodes hash size and hop count into a single path length byte.
///
/// This is the inverse of ``decodePathLen(_:)``.
///
/// - Parameters:
///   - hashSize: Bytes per hop (1, 2, or 3).
///   - hopCount: Number of hops (0-63).
/// - Returns: The encoded path length byte.
public func encodePathLen(hashSize: Int, hopCount: Int) -> UInt8 {
  precondition(1...3 ~= hashSize, "hashSize must be 1, 2, or 3")
  let mode = UInt8(hashSize - 1)
  let hops = UInt8(min(hopCount, PathEncoding.maxHopCount))
  return (mode << 6) | hops
}

/// Reverses a path hop by hop, so each hop's hash bytes keep their order.
///
/// A byte-wise reversal scrambles 2- and 3-byte hashes, and the far end would then
/// route its reply to hashes no repeater owns.
///
/// - Parameters:
///   - path: The raw path bytes, first hop first.
///   - pathLength: The encoded path length byte that sets the hash size and hop count.
/// - Returns: The hops in reverse order, or empty data if `pathLength` is the reserved mode.
public func reversedPathHops(_ path: Data, pathLength: UInt8) -> Data {
  guard let decoded = decodePathLen(pathLength) else { return Data() }
  let bytes = Array(path.prefix(decoded.byteLength))
  let size = decoded.hashSize
  var reversed = Data(capacity: bytes.count)
  // Whole hops only: a short path keeps the hops it has
  for start in stride(from: (bytes.count / size - 1) * size, through: 0, by: -size) {
    reversed.append(contentsOf: bytes[start..<start + size])
  }
  return reversed
}
