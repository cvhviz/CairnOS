import Foundation
import CairnServices
import Observation

/// Multi-select state for one conversation's messages.
///
/// Deliberately separate from `MessageItem`: selection is transient UI state,
/// and folding it into the render item would invalidate every cached cell
/// height on each tap. Cells read this model directly instead, so toggling
/// re-renders only the rows whose selection changed.
@Observable
@MainActor
final class MessageSelectionModel {
  private(set) var isSelecting = false
  private(set) var selectedIDs: Set<UUID> = []

  var count: Int {
    selectedIDs.count
  }

  func isSelected(_ id: UUID) -> Bool {
    selectedIDs.contains(id)
  }

  /// Enters selection mode with `id` already selected.
  func begin(with id: UUID) {
    isSelecting = true
    selectedIDs = [id]
  }

  func toggle(_ id: UUID) {
    guard isSelecting else { return }
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  func end() {
    isSelecting = false
    selectedIDs = []
  }

  /// Selects every message in the timeline (`ids`), keeping selection mode on.
  func selectAll(_ ids: Set<UUID>) {
    guard isSelecting else { return }
    selectedIDs = ids
  }

  /// Drops selected ids that no longer exist (deleted here or pruned by a sync).
  func prune(keeping existingIDs: Set<UUID>) {
    guard isSelecting else { return }
    selectedIDs.formIntersection(existingIDs)
  }

  /// The selected messages in timeline order (oldest first), whatever order they were tapped in.
  func selectedMessages(in timeline: [MessageDTO]) -> [MessageDTO] {
    timeline.filter { selectedIDs.contains($0.id) }
  }

  /// Clipboard text for the selection: each message on its own line, oldest first.
  static func copyText(for messages: [MessageDTO], displayedText: (MessageDTO) -> String) -> String {
    messages.map(displayedText).joined(separator: "\n")
  }
}
