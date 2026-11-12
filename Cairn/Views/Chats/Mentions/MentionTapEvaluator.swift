import Foundation
import CairnServices

/// Pure-logic core for resolving a tapped `@mention`. Lives at file scope as an
/// `enum` to enable direct unit testing without instantiating a view.
/// `MentionTapHandler` is the one-line caller that performs the navigation side
/// effect for `.navigate` outcomes and presents the picker for `.picker`.
@MainActor
enum MentionTapEvaluator {
  enum Outcome {
    case navigate(ContactDTO)
    /// The one node with the name was heard advertising but isn't saved.
    case navigateDiscovered(DiscoveredNodeDTO)
    case picker(MentionPickerContext)
  }

  static func evaluate(
    rawName: String,
    contacts: [ContactDTO],
    discoveredNodes: [DiscoveredNodeDTO] = [],
    connectedDeviceName: String?,
    radioID: UUID
  ) -> Outcome {
    let sanitized = MessageText.displayName(for: rawName)
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      return .picker(MentionPickerContext(
        name: sanitized,
        radioID: radioID,
        matches: [],
        isSelfMention: false
      ))
    }

    let isSelf: Bool = connectedDeviceName.map {
      sanitized.localizedCaseInsensitiveCompare($0) == .orderedSame
    } ?? false

    if isSelf {
      return .picker(MentionPickerContext(
        name: sanitized,
        radioID: radioID,
        matches: [],
        isSelfMention: true
      ))
    }

    let matches = SenderNodeMatcher.matches(
      name: sanitized,
      contacts: contacts,
      discoveredNodes: discoveredNodes
    )

    if matches.count == 1 {
      if let contact = matches.contacts.first { return .navigate(contact) }
      if let node = matches.discovered.first { return .navigateDiscovered(node) }
    }

    return .picker(MentionPickerContext(
      name: sanitized,
      radioID: radioID,
      matches: matches.contacts,
      isSelfMention: false,
      discoveredMatches: matches.discovered
    ))
  }
}
