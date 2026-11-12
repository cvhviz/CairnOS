import Foundation
@testable import CairnServices
import Testing

@Suite("BlockedKeywords")
struct BlockedKeywordsTests {
  private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "test.blockedKeywords.\(UUID().uuidString)"
    return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
  }

  // MARK: - Matching

  @Test
  func `no keywords never match`() {
    #expect(!BlockedKeywords.matches("buy crypto now", keywords: []))
  }

  @Test(arguments: ["Buy CRYPTO now", "crypto", "get your Crypto here", "cryptocurrency tips"])
  func `matching ignores case and also hits inside longer words`(text: String) {
    #expect(BlockedKeywords.matches(text, keywords: ["crypto"]))
  }

  @Test
  func `matching ignores diacritics in both directions`() {
    #expect(BlockedKeywords.matches("Promoción especial", keywords: ["promocion"]))
    #expect(BlockedKeywords.matches("promocion especial", keywords: ["Promoción"]))
  }

  @Test(arguments: ["sp\u{200B}am", "SPAM", "\u{FF53}\u{FF50}\u{FF41}\u{FF4D}", "s\u{200D}p\u{00AD}a\u{2060}m", "\u{FEFF}spam"])
  func `matching sees through invisible characters, case and width`(text: String) {
    #expect(BlockedKeywords.matches(text, keywords: ["spam"]))
  }

  @Test
  func `invisible characters in the keyword do not stop it matching`() {
    #expect(BlockedKeywords.matches("no spam here", keywords: ["sp\u{200B}am"]))
    #expect(!BlockedKeywords.matches("anything at all", keywords: ["\u{200B}\u{200D}"]))
  }

  @Test
  func `a phrase must appear whole`() {
    #expect(BlockedKeywords.matches("free gift card inside", keywords: ["gift card"]))
    #expect(!BlockedKeywords.matches("a gift and a card", keywords: ["gift card"]))
  }

  @Test
  func `unrelated text does not match`() {
    #expect(!BlockedKeywords.matches("net check at 8", keywords: ["crypto", "gift card"]))
  }

  // MARK: - Normalization

  @Test
  func `normalizing trims, drops blanks, and removes case-insensitive duplicates in order`() {
    let normalized = BlockedKeywords.normalized(["  Crypto ", "", "   ", "spam", "CRYPTO", "Spam"])
    #expect(normalized == ["Crypto", "spam"])
  }

  @Test
  func `normalizing treats invisible and full-width spellings as duplicates`() {
    let normalized = BlockedKeywords.normalized(["spam", "sp\u{200B}am", "\u{FF53}\u{FF50}\u{FF41}\u{FF4D}", "\u{200B}"])
    #expect(normalized == ["spam"])
  }

  @Test
  func `normalizing caps keyword length`() {
    let long = String(repeating: "a", count: BlockedKeywords.maxKeywordLength + 20)
    #expect(BlockedKeywords.normalized([long]).first?.count == BlockedKeywords.maxKeywordLength)
  }

  // MARK: - Persistence and backup

  @Test
  func `save and load round trip through UserDefaults`() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(BlockedKeywords.load(from: defaults).isEmpty)
    BlockedKeywords.save([" crypto ", "gift card", "Crypto"], to: defaults)
    #expect(BlockedKeywords.load(from: defaults) == ["crypto", "gift card"])
  }

  @Test
  func `backup snapshot carries keywords and restore fills an unset list`() throws {
    let (source, sourceName) = try makeDefaults()
    defer { source.removePersistentDomain(forName: sourceName) }
    BlockedKeywords.save(["crypto", "gift card"], to: source)

    let snapshot = BackupUserDefaults.snapshot(from: source)
    #expect(snapshot.blockedKeywords == ["crypto", "gift card"])

    let decoded = try JSONDecoder().decode(BackupUserDefaults.self, from: JSONEncoder().encode(snapshot))
    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    let setKeys = decoded.restore(to: target)

    #expect(setKeys.contains(BlockedKeywords.defaultsKey))
    #expect(BlockedKeywords.load(from: target) == ["crypto", "gift card"])
  }

  @Test
  func `restore normalizes and de-duplicates the keywords it writes`() throws {
    var backup = BackupUserDefaults()
    backup.blockedKeywords = [" Spam ", "spam"]
    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }

    let setKeys = backup.restore(to: target)

    #expect(setKeys.contains(BlockedKeywords.defaultsKey))
    #expect(BlockedKeywords.load(from: target) == ["Spam"])
  }

  @Test
  func `restore leaves an existing keyword list untouched`() throws {
    var backup = BackupUserDefaults()
    backup.blockedKeywords = ["from-backup"]
    let (target, targetName) = try makeDefaults()
    defer { target.removePersistentDomain(forName: targetName) }
    BlockedKeywords.save(["already-here"], to: target)

    let setKeys = backup.restore(to: target)

    #expect(!setKeys.contains(BlockedKeywords.defaultsKey))
    #expect(BlockedKeywords.load(from: target) == ["already-here"])
  }
}
