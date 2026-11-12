import Foundation
import CairnServices

extension String {
  /// Whether this region name represents a private region (prefixed with "$")
  var isPrivateRegion: Bool {
    hasPrefix("$")
  }
}

/// Validates region names before adding them to the device's known regions list or a repeater's
/// region table. A typed name is checked, and added, in its cleaned form (`cleanedName`).
///
/// A leading '$' (a private region) is refused on both. The companion firmware refuses it when typed
/// (`NameErr::Private`), and a repeater has no command that loads a private region's key
/// (`TransportKeyStore::saveKeysFor` has no caller), so a '$' region put there could never match
/// a packet.
enum RegionNameValidator {
  enum ValidationError: Equatable {
    case empty
    case invalidCharacters
    case privateRegion
    case tooLong(maxBytes: Int)
    case duplicate
  }

  /// The stored form of a typed name, as firmware `cleanName` (ChanScope.h) makes it: surrounding
  /// spaces and leading '#'s go, since the key puts one '#' back. Case is kept.
  static func cleanedName(_ name: String) -> String {
    var cleaned = Substring(name.trimmingCharacters(in: .whitespaces))
    while let first = cleaned.first, first == "#" || first == " " {
      cleaned = cleaned.dropFirst()
    }
    return String(cleaned)
  }

  /// Firmware `isNameChar` (ChanScope.h, and `RegionMap::is_name_char` on a repeater) byte for byte:
  /// '-', '$', '#', digits and every byte from 'A' up except DEL. That takes letters in any script
  /// (every UTF-8 byte of one is above 'A') and, on purpose, the few punctuation marks the firmware
  /// takes too ('_', '[', '~' ...): a stricter rule here refused names the radio and repeaters
  /// accept, and that Discover adds.
  static func isNameByte(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: "-") || byte == UInt8(ascii: "$") || byte == UInt8(ascii: "#")
      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      || (byte >= UInt8(ascii: "A") && byte != 0x7F)
  }

  static func validate(_ name: String, existingRegions: [String]) -> ValidationError? {
    let cleaned = cleanedName(name)
    if cleaned.isEmpty { return .empty }
    if cleaned.isPrivateRegion { return .privateRegion }
    if !cleaned.utf8.allSatisfy(isNameByte) {
      return .invalidCharacters
    }
    let maxBytes = ProtocolLimits.maxDefaultFloodScopeNameBytes
    if cleaned.utf8.count > maxBytes {
      return .tooLong(maxBytes: maxBytes)
    }
    // Firmware matches names without their leading '#', so "#socal" and "socal" are one region.
    if existingRegions.contains(where: { cleanedName($0) == cleaned }) { return .duplicate }
    return nil
  }

  static func isValid(_ name: String, existingRegions: [String]) -> Bool {
    validate(name, existingRegions: existingRegions) == nil
  }

  /// `validate` for a repeater's region table, which also refuses a trailing '^'. The `region` dump
  /// (`RegionMap::printChildRegions`) marks the home region with a '^' after its name, so "west^"
  /// would read back as "west", marked home, and `region remove west` could never find it.
  static func validateForRepeater(_ name: String, existingRegions: [String]) -> ValidationError? {
    if let error = validate(name, existingRegions: existingRegions) { return error }
    return cleanedName(name).hasSuffix("^") ? .invalidCharacters : nil
  }
}

/// One manual region add, from the typed name until the add has gone through or failed.
struct RegionAddSubmission: Equatable {
  /// Why a submitted add didn't go through.
  enum Failure: Equatable {
    /// No radio was connected to add it to.
    case notConnected
    /// The app couldn't save it with the radio's settings.
    case notSaved

    /// The failure an `addKnownRegion` error stands for: `ConnectionError.notConnected` is no
    /// radio; anything else (a persistence error) is a save that didn't happen.
    init(_ error: Error) {
      if let connectionError = error as? ConnectionError, case .notConnected = connectionError {
        self = .notConnected
      } else {
        self = .notSaved
      }
    }
  }

  var name = "" {
    didSet {
      if name != oldValue { failure = nil }
    }
  }

  private(set) var pendingName: String?
  private(set) var failure: Failure?

  var didFail: Bool {
    failure != nil
  }

  func validationError(existingRegions: [String]) -> RegionNameValidator.ValidationError? {
    // A submitted name is about to join the list, so it must not read as its own duplicate.
    guard pendingName == nil else { return nil }
    return RegionNameValidator.validate(name, existingRegions: existingRegions)
  }

  func canSubmit(existingRegions: [String]) -> Bool {
    pendingName == nil && RegionNameValidator.isValid(name, existingRegions: existingRegions)
  }

  /// Returns the cleaned name to add (`RegionNameValidator.cleanedName`), or nil when the typed
  /// name cannot be added.
  mutating func submit(existingRegions: [String]) -> String? {
    guard canSubmit(existingRegions: existingRegions) else { return nil }
    let cleaned = RegionNameValidator.cleanedName(name)
    pendingName = cleaned
    failure = nil
    return cleaned
  }

  mutating func markAdded() {
    pendingName = nil
  }

  mutating func markFailed(_ failure: Failure) {
    guard pendingName != nil else { return }
    pendingName = nil
    self.failure = failure
  }
}
