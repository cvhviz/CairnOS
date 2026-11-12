import CairnServices
import SwiftUI

struct ImportPreviewSheet: View {
  @Bindable var viewModel: AppBackupViewModel
  @Environment(\.appTheme) private var theme

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.isImporting {
          importingView
        } else if let result = viewModel.importResult {
          ImportSuccessContent(viewModel: viewModel, result: result)
        } else if let error = viewModel.sheetErrorMessage {
          errorView(message: error)
        } else if viewModel.isCancelled {
          cancelledView
        } else if let envelope = viewModel.previewEnvelope {
          previewView(envelope: envelope)
        }
      }
      .flashingNavigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Settings.Settings.Backup.Import.Preview.cancel) {
            if viewModel.isImporting {
              viewModel.cancelImport()
            } else {
              viewModel.dismissImportSheet()
            }
          }
          .disabled(viewModel.isCancellingImport)
          .keyboardShortcut(.cancelAction)
        }
      }
      .interactiveDismissDisabled(viewModel.isImporting)
      .cairnFeedback(trigger: viewModel.importResult) { _, newValue in
        guard let result = newValue else { return nil }
        return result.hasRestoredChanges ? .success : nil
      }
      .cairnFeedback(.error, trigger: viewModel.sheetErrorMessage) { _, newValue in newValue != nil }
    }
  }

  /// "Import Preview" only while the preview shows; importing and the outcomes are the import
  /// itself.
  private var navigationTitle: String {
    let isPreview = !viewModel.isImporting && viewModel.importResult == nil
      && viewModel.sheetErrorMessage == nil && !viewModel.isCancelled
    return isPreview
      ? L10n.Settings.Settings.Backup.Import.Preview.title
      : L10n.Settings.Settings.Backup.Import.title
  }

  // MARK: - Preview

  private func previewView(envelope: AppBackupEnvelope) -> some View {
    CardForm {
      CardFormSection(L10n.Settings.Settings.Backup.Import.Preview.details) {
        ValueCard(
          L10n.Settings.Settings.Backup.Import.Preview.exported,
          systemImage: "calendar",
          color: .blue,
          value: envelope.exportDate.formatted(date: .abbreviated, time: .shortened)
        )
        ValueCard(
          L10n.Settings.Settings.Backup.Import.Preview.appVersion,
          systemImage: "app.badge",
          color: .gray,
          value: "\(envelope.appVersion) (\(envelope.appBuild))"
        )
      }

      CardFormSection(L10n.Settings.Settings.Backup.Import.Preview.contents) {
        BackupCountGrid { envelope.manifest.count(for: $0) }
      }

      Label {
        Text(L10n.Settings.Settings.Backup.Import.Preview.info)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(.tint)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)

      BackupSheetButton(title: L10n.Settings.Settings.Backup.Import.Preview.button) {
        viewModel.performImport()
      }
    }
  }

  // MARK: - Importing

  private var importingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text(viewModel.isCancellingImport
        ? L10n.Settings.Settings.Backup.Import.cancelling
        : L10n.Settings.Settings.Backup.Import.progress)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Same canvas as the preview and result states, so the sheet doesn't flash between them.
    .cardCanvas(theme)
    .onAppear {
      AccessibilityNotification.Announcement(L10n.Settings.Settings.Backup.Import.progress).post()
    }
  }

  // MARK: - Cancelled

  private var cancelledView: some View {
    CardForm {
      BackupResultHero(
        systemImage: "info.circle.fill",
        tint: .secondary,
        title: L10n.Settings.Settings.Backup.Import.Cancelled.title,
        lines: [L10n.Settings.Settings.Backup.Import.Cancelled.message]
      )
      BackupSheetButton(title: L10n.Settings.Settings.Backup.Import.Success.done, isProminent: false) {
        viewModel.dismissImportSheet()
      }
    }
    .onAppear {
      AccessibilityNotification.Announcement(L10n.Settings.Settings.Backup.Import.Cancelled.title).post()
    }
  }

  // MARK: - Error

  private func errorView(message: String) -> some View {
    CardForm {
      BackupResultHero(
        systemImage: "xmark.circle.fill",
        tint: .red,
        title: L10n.Settings.Settings.Backup.Import.Error.title,
        lines: [message]
      )
      BackupSheetButton(title: L10n.Settings.Settings.Backup.Import.Error.dismiss, isProminent: false) {
        viewModel.dismissImportSheet()
      }
    }
    .onAppear {
      AccessibilityNotification.Announcement(L10n.Settings.Settings.Backup.Import.Error.title).post()
    }
  }
}
