import CairnServices
import SwiftUI

/// Success content for the backup export sheet. Structural mirror of
/// `ImportSuccessContent` minus the "already here" section — export
/// has no skip concept. Lives in the Cairn target because it uses `L10n`.
struct ExportSuccessContent: View {
  let summary: AppBackupViewModel.ExportSuccessSummary
  let onDismiss: @MainActor () -> Void

  var body: some View {
    CardForm {
      BackupResultHero(
        systemImage: "checkmark.circle.fill",
        tint: .green,
        title: L10n.Settings.Settings.Backup.Export.Success.title,
        lines: [summary.filename, summary.byteCount.formatted(.byteCount(style: .file))]
      )
      CardFormSection(L10n.Settings.Settings.Backup.Export.Success.includedSection) {
        BackupCountGrid { summary.manifest.count(for: $0) }
      }
      BackupSheetButton(title: L10n.Settings.Settings.Backup.Export.Success.done) {
        onDismiss()
      }
    }
    .flashingNavigationTitle(L10n.Settings.Settings.Backup.Export.Success.title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      AccessibilityNotification.Announcement(
        L10n.Settings.Settings.Backup.Export.Success.announcement(summary.filename)
      ).post()
    }
    .cairnFeedback(.success, trigger: summary.id)
  }
}
