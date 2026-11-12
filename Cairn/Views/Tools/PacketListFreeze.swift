import Foundation

/// Holds a live, newest-first list still while the reader has scrolled away from its top, so rows
/// don't move under the finger as packets land: the frozen list is shown, and what arrived since
/// is counted for an "N new" pill that jumps back to the top and lets the list go live again.
/// Pure, so the tests can pin it.
struct PacketListFreeze<Entry: Identifiable>: Equatable where Entry.ID: Hashable {
  /// The list as it was when the reader scrolled away; nil while the list is live.
  private(set) var frozen: [Entry]?
  private var frozenIDs: Set<Entry.ID> = []

  init() {}

  var isFrozen: Bool { frozen != nil }

  /// Holds `live` still. Freezing again keeps the list already held.
  mutating func freeze(_ live: [Entry]) {
    guard frozen == nil else { return }
    frozen = live
    frozenIDs = Set(live.map(\.id))
  }

  /// Lets the list go live again.
  mutating func release() {
    frozen = nil
    frozenIDs = []
  }

  /// What to show: the held list while frozen, else `live`.
  func entries(live: [Entry]) -> [Entry] {
    frozen ?? live
  }

  /// How many entries of `live` (newest first) arrived since the list was held: the ones at its
  /// front that the held list doesn't have. 0 while live.
  func newCount(live: [Entry]) -> Int {
    guard frozen != nil else { return 0 }
    var count = 0
    for entry in live {
      guard !frozenIDs.contains(entry.id) else { break }
      count += 1
    }
    return count
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.frozenIDs == rhs.frozenIDs && (lhs.frozen == nil) == (rhs.frozen == nil)
  }
}
