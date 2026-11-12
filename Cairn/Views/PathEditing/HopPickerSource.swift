import Foundation
import CairnServices

/// Data source for the shared Add-Hop picker (`AddHopPickerView`). Lets the same
/// picker drive both the contact path editor (`PathManagementViewModel`, hop-capped)
/// and the trace path builder (`TracePathViewModel`, capped by what the firmware can trace) without depending on
/// either concretely.
@MainActor
protocol HopPickerSource: AnyObject {
  var availableRepeaters: [ContactDTO] { get }
  var availableRooms: [ContactDTO] { get }
  var discoveredRepeaters: [DiscoveredNodeDTO] { get }
  var recentPublicKeys: [Data] { get }

  /// Hops currently in the path being built.
  var currentHopCount: Int { get }
  /// Maximum hops the path can hold, or `nil` when unlimited.
  var hopLimit: Int? { get }
  /// Whether no further hops can be added. Defaults to `currentHopCount >= hopLimit`.
  var isPathFull: Bool { get }
  /// Why the path is full, for the picker's max-hops state.
  var hopLimitDescription: String { get }

  /// Append a single node to the path and record it as recent.
  func appendHop(_ node: some RepeaterResolvable)
  /// Add a node where `intent` says: on the end, or in at a position. Defaults to appending,
  /// for a source whose picker only ever appends (the trace builder).
  func insertHop(_ node: some RepeaterResolvable, at intent: AddHopIntent)
  /// Whether the node is already a hop, for a path that never holds a node twice. The picker
  /// shows such a node as In path and lets it be. Defaults to false: a trace may repeat a hop.
  func isInPath(_ publicKey: Data) -> Bool
  /// Add every resolvable code from a comma-separated bulk entry, honoring the hop cap.
  func addCodes(_ input: String) -> CodeInputResult
  /// Classify a comma-separated bulk entry per code without mutating the path,
  /// for the bulk-add preview panel.
  func classifyCodes(_ input: String) -> [HopCodeClassification]

  /// Adopt a hash size inferred from a bulk paste when the source supports a
  /// per-entry override (trace). Fixed-width sources ignore it.
  func adoptHashSize(forPastedCodes input: String)
}

extension HopPickerSource {
  /// A path with no `hopLimit` is never full; otherwise it fills at the cap.
  var isPathFull: Bool {
    guard let hopLimit else { return false }
    return currentHopCount >= hopLimit
  }

  var hopLimitDescription: String {
    L10n.Contacts.Contacts.PathEdit.MaxHops.description(hopLimit ?? 0)
  }

  /// Sources with a fixed hash size (the contact path editor) take no action.
  func adoptHashSize(forPastedCodes input: String) {}

  func insertHop(_ node: some RepeaterResolvable, at intent: AddHopIntent) {
    appendHop(node)
  }

  func isInPath(_ publicKey: Data) -> Bool {
    false
  }
}
