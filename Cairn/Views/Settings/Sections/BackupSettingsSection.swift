import CairnServices
import SwiftUI

/// Settings → Backup & Data: the app backup file, the radio's configuration
/// file, and the data export, so everything that leaves the app as a file sits together. Export and
/// import run inline from their cards; only the longer flows (the import preview, the export
/// summary, the data export page) open over it. Embeddable: a stack of `CardFormSection`s.
struct BackupSettingsSection: View {
  @Environment(\.appState) private var appState
  @State private var viewModel: AppBackupViewModel
  @State private var showExportConfirmation = false
  @State private var showFileImporter = false

  init(
    connectionManager: ConnectionManager,
    onImportRestoredData: (@MainActor () -> Void)? = nil,
    onChannelDraftSlotsAffected: (@MainActor ([UUID: Set<UInt8>]) -> Void)? = nil
  ) {
    _viewModel = State(initialValue: AppBackupViewModel(
      connectionManager: connectionManager,
      onImportRestoredData: onImportRestoredData,
      onChannelDraftSlotsAffected: onChannelDraftSlotsAffected
    ))
  }

  var body: some View {
    // One stack rather than a Group, so the alerts, sheets and file panels below attach once.
    VStack(alignment: .leading, spacing: 20) {
      CardFormSection(
        L10n.Settings.Settings.Backup.FileBackup.header,
        info: L10n.Settings.Settings.Backup.FileBackup.footer + "\n\n" + L10n.Settings.Settings.Backup.FileBackup.radioConfig,
        // Why Import is dimmed: the only cue, so it stays visible.
        footer: appState.connectionState.isConnected ? L10n.Settings.Settings.Backup.Import.disabledWhenConnected : nil
      ) {
        exportRow
        importRow
      }

      // The radio's own settings, channels and contacts: a separate file from the app backup,
      // kept beside it so every backup lives on one page.
      ConfigExportImportSection()

      CardFormSection(
        L10n.Settings.Settings.Backup.DataExport.header,
        info: L10n.Settings.Settings.Backup.DataExport.footer
      ) {
        NavigationLink {
          DataExportView()
        } label: {
          NavigationTile(L10n.Settings.Settings.DataExport.title, systemImage: "tablecells", color: .teal)
        }
        .buttonStyle(.plain)
      }
    }
    .alert(L10n.Settings.Settings.Backup.Export.Alert.title, isPresented: $showExportConfirmation) {
      Button(L10n.Settings.Settings.Backup.Export.Alert.cancel, role: .cancel) {}
      Button(L10n.Settings.Settings.Backup.Export.Alert.export) {
        viewModel.performExport()
      }
    } message: {
      Text(L10n.Settings.Settings.Backup.Export.Alert.message)
    }
    .fileExporter(
      isPresented: Binding(
        get: { viewModel.pendingExport != nil },
        // A dismissal that only writes the binding must still resolve the pending
        // export, or the export row stays wedged for the rest of the session.
        // handleExportResult is idempotent, so a later onCompletion is a no-op.
        set: { isPresented in
          if !isPresented, viewModel.pendingExport != nil {
            viewModel.handleExportResult(.failure(CocoaError(.userCancelled)))
          }
        }
      ),
      document: exportDocument,
      contentType: .cairnBackup,
      defaultFilename: viewModel.defaultExportFilename
    ) { result in
      viewModel.handleExportResult(result)
    }
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: [.cairnBackup]
    ) { result in
      viewModel.handleFileSelected(result: result)
    }
    // Mac / iPad: a backup file dragged in from Finder or Files takes the same import path.
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      // The Import row is disabled in these states, and a drop must not get around that.
      guard !appState.connectionState.isConnected else {
        viewModel.errorMessage = L10n.Settings.Settings.Backup.Import.disabledWhenConnected
        return false
      }
      guard !viewModel.isExporting, !viewModel.isImporting, !viewModel.isParsing else { return false }
      viewModel.handleFileSelected(result: .success(url))
      return true
    }
    .sheet(isPresented: Binding(
      get: { viewModel.isImportSheetActive },
      set: { if !$0 { viewModel.dismissImportSheet() } }
    )) {
      ImportPreviewSheet(viewModel: viewModel)
    }
    .sheet(item: Binding(
      get: { viewModel.exportSummary },
      set: { if $0 == nil { viewModel.dismissExportSuccess() } }
    )) { summary in
      NavigationStack {
        ExportSuccessContent(summary: summary, onDismiss: viewModel.dismissExportSuccess)
      }
    }
    .errorAlert($viewModel.errorMessage)
  }

  // MARK: - Rows

  private var exportRow: some View {
    Button {
      showExportConfirmation = true
    } label: {
      BusyActionCardLabel(
        title: viewModel.isExporting ? L10n.Settings.Settings.Backup.Export.progress : L10n.Settings.Settings.Backup.Export.title,
        subtitle: L10n.Settings.Settings.Backup.Export.subtitle,
        systemImage: "square.and.arrow.up",
        color: .blue,
        isBusy: viewModel.isExporting
      )
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isExporting || viewModel.isImporting || viewModel.isParsing)
  }

  @ViewBuilder
  private var importRow: some View {
    let isRadioConnected = appState.connectionState.isConnected
    let isBusy = viewModel.isExporting || viewModel.isImporting || viewModel.isParsing
    let content = Button {
      showFileImporter = true
    } label: {
      BusyActionCardLabel(
        title: viewModel.isParsing ? L10n.Settings.Settings.Backup.Import.parsing : L10n.Settings.Settings.Backup.Import.title,
        subtitle: L10n.Settings.Settings.Backup.Import.subtitle,
        systemImage: "square.and.arrow.down",
        color: .green,
        isBusy: viewModel.isParsing
      )
    }
    .buttonStyle(.plain)
    if isRadioConnected {
      content
        .disabled(true)
        .accessibilityHint(L10n.Settings.Settings.Backup.Import.disabledWhenConnected)
    } else {
      content.disabled(isBusy)
    }
  }

  // MARK: - Helpers

  private var exportDocument: AppBackupDocument? {
    guard let data = viewModel.pendingExport?.data else { return nil }
    return AppBackupDocument(data: data)
  }
}
