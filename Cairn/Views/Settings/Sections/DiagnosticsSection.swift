import CairnServices
import SwiftUI

/// The Advanced fold at the foot of Settings: the stored debug log (how much there is, export it
/// to share it, or clear it) and, in debug builds, the onboarding reset. Used for support
/// requests only, so it stays one closed card until asked for, with the explanation behind an "i".
struct DiagnosticsSection: View {
  @Environment(\.appState) private var appState
  @Binding var exportedFile: ExportedLogFile?
  @State private var isExpanded = false
  @State private var isExporting = false
  @State private var showingClearLogsAlert = false
  @State private var errorMessage: String?
  /// Stored log entries; nil until counted on first open (a fetch count, so cheap).
  @State private var entryCount: Int?
  /// Set when the count throws, so the status line is hidden rather than left as a placeholder
  /// that reads like it's still loading.
  @State private var countFailed = false

  var body: some View {
    CardFormSection {
      NodeDisclosureCard(
        L10n.Tools.Tools.Category.advanced,
        systemImage: "stethoscope",
        color: .gray,
        isExpanded: $isExpanded
      ) {
        InfoButton(L10n.Settings.Diagnostics.footer, title: L10n.Settings.Diagnostics.header)
      } content: {
        if !countFailed {
          statusLine
        }

        Button {
          exportLogs()
        } label: {
          HStack(spacing: 8) {
            if isExporting {
              ProgressView()
            } else {
              Image(systemName: "square.and.arrow.up")
            }
            Text(L10n.Settings.Diagnostics.exportLogs)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isExporting)

        Button(role: .destructive) {
          showingClearLogsAlert = true
        } label: {
          Label(L10n.Settings.Diagnostics.clearLogs, systemImage: "trash")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        // Not gated on the count: entries can still be waiting in DebugLogBuffer (written to the
        // store every few seconds), so a count of 0 doesn't mean there's nothing to clear, and
        // clearing an empty log is harmless.

        #if DEBUG
          Button {
            appState.onboarding.resetOnboarding()
          } label: {
            Label("Reset Onboarding", systemImage: "arrow.counterclockwise")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .tint(.gray)
        #endif
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded { Task { await refreshCount() } }
    }
    .alert(L10n.Settings.Diagnostics.Alert.Clear.title, isPresented: $showingClearLogsAlert) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.Diagnostics.Alert.Clear.confirm, role: .destructive) {
        clearDebugLogs()
      }
    } message: {
      Text(L10n.Settings.Diagnostics.Alert.Clear.message)
    }
    .errorAlert($errorMessage)
  }

  /// What's stored, so it's clear before exporting whether there's anything to send.
  private var statusLine: some View {
    Label {
      // A placeholder of the same shape while counting, so the line doesn't jump.
      Text(L10n.Settings.Diagnostics.entryCount(entryCount ?? 0))
        .monospacedDigit()
        .redacted(reason: entryCount == nil ? .placeholder : [])
    } icon: {
      Image(systemName: "doc.text.magnifyingglass")
    }
    .font(.footnote)
    .foregroundStyle(Color.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func refreshCount() async {
    do {
      entryCount = try await appState.connectionManager.persistenceStore.countDebugLogEntries()
      countFailed = false
    } catch {
      entryCount = nil
      countFailed = true
    }
  }

  private func exportLogs() {
    let dataStore = appState.connectionManager.persistenceStore
    isExporting = true

    Task { @MainActor in
      if let url = await LogExportService.createExportFile(
        appState: appState,
        persistenceStore: dataStore
      ) {
        exportedFile = ExportedLogFile(url: url)
      } else {
        errorMessage = L10n.Settings.Diagnostics.Error.exportFailed
      }
      isExporting = false
      // Export flushes the in-memory buffer to the store, so the count may have grown.
      await refreshCount()
    }
  }

  private func clearDebugLogs() {
    let dataStore = appState.connectionManager.persistenceStore

    Task {
      do {
        try await dataStore.clearDebugLogEntries()
      } catch {
        errorMessage = error.userFacingMessage
      }
      await refreshCount()
    }
  }
}
