import Foundation

/// User-defined words and phrases that hide incoming channel messages.
///
/// Stored as a plain string array in `UserDefaults` rather than per-radio in
/// the database: the list is a personal preference, small, and travels with
/// the app-settings half of a backup. Reads are cheap enough to do per message,
/// so there is no cache to keep in sync with the Settings screen.
public enum BlockedKeywords {
  public static let defaultsKey = AppStorageKey.blockedKeywords.rawValue

  /// Longest keyword accepted; a channel message body cannot exceed this anyway.
  public static let maxKeywordLength = 64

  public static func load(from defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: defaultsKey) ?? []
  }

  public static func save(_ keywords: [String], to defaults: UserDefaults = .standard) {
    defaults.set(normalized(keywords), forKey: defaultsKey)
  }

  /// Trims, drops blanks, caps the length, and removes duplicates that fold to
  /// the same form (see `foldedForm`), keeping the first spelling and the order.
  public static func normalized(_ keywords: [String]) -> [String] {
    var seen = Set<String>()
    return keywords.compactMap { raw in
      let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxKeywordLength))
      let folded = foldedForm(trimmed)
      guard !folded.isEmpty, seen.insert(folded).inserted else { return nil }
      return trimmed
    }
  }

  /// Whether `text` contains any keyword. Matching ignores case, diacritics,
  /// width, compatibility forms and invisible format characters, and is a plain
  /// substring match, so a keyword also matches inside longer words.
  public static func matches(_ text: String, keywords: [String]) -> Bool {
    guard !keywords.isEmpty else { return false }
    let foldedText = foldedForm(text)
    return keywords.contains { keyword in
      let foldedKeyword = foldedForm(keyword)
      return !foldedKeyword.isEmpty && foldedText.contains(foldedKeyword)
    }
  }

  /// Compatibility-composes, drops format characters (zero-width space and
  /// joiners, soft hyphen, bidi marks) that would otherwise split a keyword
  /// without changing how the text reads, then folds case, diacritics and width.
  private static func foldedForm(_ string: String) -> String {
    let composed = string.precomposedStringWithCompatibilityMapping
    let visible: String.UnicodeScalarView = composed.unicodeScalars.filter {
      $0.properties.generalCategory != .format
    }
    return String(visible)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }
}
