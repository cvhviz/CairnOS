import Foundation

// MARK: - Path Hops

/// Splits a received packet's path into its hop hashes.
///
/// The hash size comes from the packet's own path-length byte, never from this radio's path
/// hash mode: stock clients in path hash mode 0 send 1-byte paths on the same mesh as 2- and
/// 3-byte senders, so one mesh carries all three sizes.
public enum PathHops {
  /// The hop hashes of `pathNodes`, first hop first, each `hashSize` bytes long and zero-based.
  ///
  /// - Parameters:
  ///   - pathNodes: The raw path bytes as received.
  ///   - pathLength: The encoded path-length byte that sets the hash size and hop count.
  /// - Returns: The hops, empty for a zero-hop packet, or `nil` when `pathLength` uses the
  ///   reserved mode 3 or the bytes don't match the length it encodes (a hop can't be trusted
  ///   from a short or padded path).
  public static func split(pathNodes: Data, pathLength: UInt8) -> [Data]? {
    guard let decoded = decodePathLen(pathLength), pathNodes.count == decoded.byteLength else {
      return nil
    }
    let bytes = [UInt8](pathNodes)
    let size = decoded.hashSize
    return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<$0 + size]) }
  }
}
