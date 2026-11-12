@testable import Cairn
@testable import CairnServices
import Testing

@Suite("RegionNameValidator")
struct RegionNameValidatorTests {
  // MARK: - Valid Names

  @Test(arguments: [
    "Europe", "UK", "France", "sample-city", "region-1"
  ])
  func `accepts standard region names`(name: String) {
    #expect(RegionNameValidator.isValid(name, existingRegions: []))
  }

  /// The firmware's own rule (`isNameChar`): letters in any script and the punctuation from 'A' up.
  @Test(arguments: ["so_cal", "Île-de-France", "Zürich", "a$b", "a#b", "[west]", "tilde~"])
  func `accepts names the firmware accepts`(name: String) {
    #expect(RegionNameValidator.isValid(name, existingRegions: []))
  }

  // MARK: - Cleaning

  @Test(arguments: [
    ("#Europe", "Europe"), ("  #socal ", "socal"), ("##bay", "bay"), ("# bay", "bay"), ("Bay#2", "Bay#2")
  ])
  func `cleans a name as the firmware does`(typed: String, cleaned: String) {
    #expect(RegionNameValidator.cleanedName(typed) == cleaned)
    #expect(RegionNameValidator.isValid(typed, existingRegions: []))
  }

  // MARK: - Invalid Names

  @Test
  func `rejects empty name`() {
    #expect(RegionNameValidator.validate("", existingRegions: []) == .empty)
  }

  @Test
  func `rejects whitespace-only name`() {
    #expect(RegionNameValidator.validate("   ", existingRegions: []) == .empty)
  }

  @Test
  func `rejects name with spaces`() {
    #expect(RegionNameValidator.validate("my region", existingRegions: []) == .invalidCharacters)
  }

  @Test(arguments: ["#", "  # ", "##"])
  func `rejects a name that is only hashes`(name: String) {
    #expect(RegionNameValidator.validate(name, existingRegions: []) == .empty)
  }

  @Test(arguments: ["hello!", "foo@bar", "a&b", "test.region", "a,b", "a/b", "tab\tname", "del\u{7F}"])
  func `rejects special characters`(name: String) {
    #expect(RegionNameValidator.validate(name, existingRegions: []) == .invalidCharacters)
  }

  @Test(arguments: ["$secret", "#$secret"])
  func `rejects private regions`(name: String) {
    #expect(RegionNameValidator.validate(name, existingRegions: []) == .privateRegion)
  }

  // MARK: - Overlong Names

  @Test
  func `accepts names at the byte cap`() {
    let maxBytes = ProtocolLimits.maxDefaultFloodScopeNameBytes
    let name = String(repeating: "a", count: maxBytes)
    #expect(name.utf8.count == maxBytes)
    #expect(RegionNameValidator.isValid(name, existingRegions: []))
  }

  @Test
  func `counts bytes, not characters, against the cap`() {
    let maxBytes = ProtocolLimits.maxDefaultFloodScopeNameBytes
    let atCap = String(repeating: "é", count: maxBytes / 2)
    #expect(RegionNameValidator.isValid(atCap, existingRegions: []))
    #expect(
      RegionNameValidator.validate(atCap + "é", existingRegions: [])
        == .tooLong(maxBytes: maxBytes)
    )
  }

  @Test
  func `checks the cap on the cleaned name`() {
    let name = "#" + String(repeating: "a", count: ProtocolLimits.maxDefaultFloodScopeNameBytes)
    #expect(RegionNameValidator.isValid(name, existingRegions: []))
  }

  @Test
  func `rejects names one byte over the cap`() {
    let maxBytes = ProtocolLimits.maxDefaultFloodScopeNameBytes
    let name = String(repeating: "a", count: maxBytes + 1)
    #expect(
      RegionNameValidator.validate(name, existingRegions: [])
        == .tooLong(maxBytes: maxBytes)
    )
  }

  // MARK: - Duplicates

  @Test
  func `rejects duplicate region name`() {
    #expect(RegionNameValidator.validate("Europe", existingRegions: ["Europe"]) == .duplicate)
  }

  @Test
  func `duplicate check ignores a leading hash on either side`() {
    #expect(RegionNameValidator.validate("#Europe", existingRegions: ["Europe"]) == .duplicate)
    #expect(RegionNameValidator.validate("Europe", existingRegions: ["#Europe"]) == .duplicate)
  }

  @Test
  func `duplicate check is case-sensitive`() {
    #expect(RegionNameValidator.isValid("europe", existingRegions: ["Europe"]))
  }

  // MARK: - isValid convenience

  @Test
  func `isValid returns true for valid name`() {
    #expect(RegionNameValidator.isValid("Europe", existingRegions: []))
  }

  @Test
  func `isValid returns false for invalid name`() {
    #expect(!RegionNameValidator.isValid("", existingRegions: []))
  }

  // MARK: - Repeater Names

  @Test(arguments: ["west^", "#west^", "a^^"])
  func `a repeater refuses a trailing caret, which its dump prints as the home marker`(name: String) {
    #expect(RegionNameValidator.validateForRepeater(name, existingRegions: []) == .invalidCharacters)
    // The companion's known regions have no such dump, so it keeps the firmware rule.
    #expect(RegionNameValidator.validate(name, existingRegions: []) == nil)
  }

  @Test
  func `a repeater takes a caret inside a name and otherwise follows validate`() {
    #expect(RegionNameValidator.validateForRepeater("a^b", existingRegions: []) == nil)
    #expect(RegionNameValidator.validateForRepeater("west", existingRegions: ["west"]) == .duplicate)
    #expect(RegionNameValidator.validateForRepeater("$west", existingRegions: []) == .privateRegion)
  }
}
