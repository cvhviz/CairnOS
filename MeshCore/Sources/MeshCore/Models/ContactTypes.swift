import Foundation

// MARK: - Contact Type

/// Contact type identifier for mesh network nodes.
///
/// Maps to the 1-byte type field in the firmware contact record (offset 33).
/// Values are defined by the MeshCore protocol specification.
public enum ContactType: UInt8, Sendable, Codable {
  case chat = 0x01
  case repeater = 0x02
  case room = 0x03
}

// MARK: - Contact Flags

/// Bitfield flags stored in the firmware contact record (offset 34).
///
/// - Bit 0: Favorite/pinned status
/// - Bits 1-3: Telemetry permissions (base, location, environment)
/// - Bit 4: Remote commands allowed (MeshCore 1.18)
/// - Bits 5-7: Reserved
public struct ContactFlags: OptionSet, Sendable, Equatable, Hashable, Codable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  /// Contact is marked as favorite (bit 0)
  public static let favorite = ContactFlags(rawValue: 0x01)

  /// Base telemetry permission (bit 1)
  public static let telemetryBase = ContactFlags(rawValue: 0x02)

  /// Location telemetry permission (bit 2)
  public static let telemetryLocation = ContactFlags(rawValue: 0x04)

  /// Environment telemetry permission (bit 3)
  public static let telemetryEnvironment = ContactFlags(rawValue: 0x08)

  /// They may run this radio's command line over the mesh (bit 4, firmware
  /// `ContactInfo::isRemoteCLIAllowed`, MeshCore 1.18). Set on *their* contact; whether
  /// this radio's commands run on theirs is decided by their own contact for us.
  public static let remoteCLI = ContactFlags(rawValue: 0x10)

  /// All telemetry permissions (bits 1-3)
  public static let telemetryAll: ContactFlags = [.telemetryBase, .telemetryLocation, .telemetryEnvironment]
}
