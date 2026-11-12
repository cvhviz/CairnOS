import Foundation

/// Who an advert heard on the air is from, read straight from its payload (the Traffic list's sender
/// line): `public_key(32) | timestamp(4) | signature(64) | app_data`, app_data being a flags byte (bits
/// 0-3 the node type: 1 chat, 2 repeater, 3 room, 4 sensor), then the location if 0x10 (int32 lat, int32
/// lon, little-endian, degrees x 1e6), a feature word each for 0x20 and 0x40, and the name to the end if
/// 0x80. Nil for a payload too short to be an advert.
public struct AdvertSummary: Sendable, Equatable {
  public var publicKey: Data
  /// The advert's node type (1 chat, 2 repeater, 3 room, 4 sensor); 0 = not said.
  public var nodeType: UInt8
  public var name: String?
  public var latitude: Double?
  public var longitude: Double?

  static let appDataOffset = 32 + 4 + 64

  public static func parse(_ payload: Data) -> AdvertSummary? {
    let p = [UInt8](payload)
    guard p.count > appDataOffset else { return nil }
    let flags = p[appDataOffset]
    var i = appDataOffset + 1
    var lat: Double?, lon: Double?
    func int32(_ at: Int) -> Int32 {
      Int32(bitPattern: UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24)
    }
    if flags & 0x10 != 0 {
      guard p.count >= i + 8 else { return nil }
      lat = Double(int32(i)) / 1e6
      lon = Double(int32(i + 4)) / 1e6
      i += 8
    }
    if flags & 0x20 != 0 { i += 2 }
    if flags & 0x40 != 0 { i += 2 }
    var name: String?
    if flags & 0x80 != 0, i < p.count {
      let bytes = p[i...].prefix { $0 != 0 }
      name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if name?.isEmpty == true { name = nil }
    }
    // 0,0 is "no position" in MeshCore adverts
    if lat == 0, lon == 0 { lat = nil; lon = nil }
    return AdvertSummary(publicKey: Data(p[0..<32]), nodeType: flags & 0x0F, name: name, latitude: lat, longitude: lon)
  }
}
