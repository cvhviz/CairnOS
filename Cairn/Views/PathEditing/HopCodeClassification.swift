import Foundation

/// Outcome of a single hex code parsed from a bulk-add entry.
enum HopCodeStatus {
  /// Valid, resolves to a node, and fits within the hop cap. Carries the
  /// prebuilt hop so callers append without re-parsing or re-resolving.
  case willAdd(PathHop)
  case alreadyInPath
  case notFound // valid hex but no matching node
  case invalidFormat // wrong length or non-hex
  case pathFull // valid and resolvable but past the hop cap
}

/// One parsed code from a bulk-add entry, with its status.
struct HopCodeClassification: Identifiable {
  /// Index in the entry; with the code it keeps ids stable when a trace repeats a code.
  let position: Int
  /// The uppercased code.
  let code: String
  let status: HopCodeStatus

  var id: String {
    "\(position):\(code)"
  }

  /// True when tapping "Add" will append this code to the path.
  var willBeAdded: Bool {
    if case .willAdd = status { return true }
    return false
  }
}
