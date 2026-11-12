import Foundation

/// What a remote node's admin dashboard cards last showed (radio, TX power, behavior, firmware, the
/// neighbour count and the sensors' summary), kept per node so the next visit shows them at once
/// without reading them again; a card's sheet or page reads its own when opened. Display only: no
/// setting is ever filled from it, so a sheet always edits what the node itself just reported.
public enum NodeCardCache {
  public struct Entry: Codable, Equatable, Sendable {
    public var frequency: Double?
    public var bandwidth: Double?
    public var spreadingFactor: Int?
    public var codingRate: Int?
    public var txPower: Int?
    public var repeatEnabled: Bool?
    public var floodMaxHops: Int?
    public var firmwareVersion: String?
    public var neighborCount: Int?
    public var bestNeighborSNR: Double?
    /// The Battery card's sensor line: the temperature as shown, and how many other readings.
    public var temperature: String?
    public var otherSensorCount: Int?
    public var savedAt: Date

    public init(frequency: Double? = nil, bandwidth: Double? = nil, spreadingFactor: Int? = nil,
                codingRate: Int? = nil, txPower: Int? = nil, repeatEnabled: Bool? = nil,
                floodMaxHops: Int? = nil, firmwareVersion: String? = nil, neighborCount: Int? = nil,
                bestNeighborSNR: Double? = nil, temperature: String? = nil, otherSensorCount: Int? = nil,
                savedAt: Date = Date()) {
      self.frequency = frequency
      self.bandwidth = bandwidth
      self.spreadingFactor = spreadingFactor
      self.codingRate = codingRate
      self.txPower = txPower
      self.repeatEnabled = repeatEnabled
      self.floodMaxHops = floodMaxHops
      self.firmwareVersion = firmwareVersion
      self.neighborCount = neighborCount
      self.bestNeighborSNR = bestNeighborSNR
      self.temperature = temperature
      self.otherSensorCount = otherSensorCount
      self.savedAt = savedAt
    }

    /// Nothing worth keeping.
    public var isEmpty: Bool {
      frequency == nil && txPower == nil && repeatEnabled == nil && floodMaxHops == nil && firmwareVersion == nil
        && neighborCount == nil && otherSensorCount == nil
    }
  }

  /// The key for a node: its public key's first 8 bytes in hex, as the rest of the app names nodes.
  static func key(for publicKey: Data) -> String {
    "nodeCardCache." + publicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  public static func load(publicKey: Data, defaults: UserDefaults = .standard) -> Entry? {
    guard let data = defaults.data(forKey: key(for: publicKey)) else { return nil }
    return try? JSONDecoder().decode(Entry.self, from: data)
  }

  /// Merges `entry` over what is kept (a value this visit didn't read keeps the last one) and saves it.
  public static func save(_ entry: Entry, publicKey: Data, defaults: UserDefaults = .standard) {
    guard !entry.isEmpty else { return }
    var merged = load(publicKey: publicKey, defaults: defaults) ?? Entry()
    merged.frequency = entry.frequency ?? merged.frequency
    merged.bandwidth = entry.bandwidth ?? merged.bandwidth
    merged.spreadingFactor = entry.spreadingFactor ?? merged.spreadingFactor
    merged.codingRate = entry.codingRate ?? merged.codingRate
    merged.txPower = entry.txPower ?? merged.txPower
    merged.repeatEnabled = entry.repeatEnabled ?? merged.repeatEnabled
    merged.floodMaxHops = entry.floodMaxHops ?? merged.floodMaxHops
    merged.firmwareVersion = entry.firmwareVersion ?? merged.firmwareVersion
    // The best SNR goes with its count, and the temperature with its sensors: a new reading replaces both.
    if let count = entry.neighborCount {
      merged.neighborCount = count
      merged.bestNeighborSNR = entry.bestNeighborSNR
    }
    if let others = entry.otherSensorCount {
      merged.otherSensorCount = others
      merged.temperature = entry.temperature
    }
    merged.savedAt = entry.savedAt
    guard let data = try? JSONEncoder().encode(merged) else { return }
    defaults.set(data, forKey: key(for: publicKey))
  }
}
