import SwiftUI

/// Replaces the composer while messages are being multi-selected.
struct MessageSelectionToolbar: View {
  let count: Int
  /// Every loaded message is already selected, so Select All has nothing to add.
  let isAllSelected: Bool
  let canDelete: Bool
  /// The selection's copy text, which Share hands to the system share sheet.
  let shareText: String
  let onSelectAll: () -> Void
  let onCopy: () -> Void
  let onForward: () -> Void
  let onDelete: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(L10n.Chats.Chats.Common.cancel, action: onCancel)

      Spacer()

      Text(L10n.Chats.Chats.Selection.count(count))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Spacer()

      HStack(spacing: 12) {
        Button(L10n.Chats.Chats.Selection.selectAll, systemImage: "checklist", action: onSelectAll)
          .disabled(isAllSelected)

        ShareLink(item: shareText) {
          Label(L10n.Chats.Chats.Selection.share, systemImage: "square.and.arrow.up")
        }
        .disabled(count == 0)

        Button(L10n.Chats.Chats.Message.Action.forward, systemImage: "arrowshape.turn.up.right", action: onForward)
          .disabled(count == 0)

        Button(L10n.Chats.Chats.Message.Action.copy, systemImage: "doc.on.doc", action: onCopy)
          .disabled(count == 0)

        Button(L10n.Chats.Chats.Action.delete, systemImage: "trash", role: .destructive, action: onDelete)
          .disabled(count == 0 || !canDelete)
      }
      .labelStyle(.iconOnly)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(.bar)
  }
}
