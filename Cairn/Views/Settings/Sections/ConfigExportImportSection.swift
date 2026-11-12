import CairnServices
import SwiftUI

/// Export and Import Config as a pair of cards on Settings → Backup: two pages side by side
/// rather than two rows. They read and write the connected radio, so they need it ready.
struct ConfigExportImportSection: View {
  @Environment(\.appState) private var appState

  private var isDisabled: Bool {
    appState.connectionState != .ready
  }

  var body: some View {
    // Backup isn't a radio page, so the cards can show without a radio; the footer says why
    // they're dimmed, and stays visible because it's the only cue.
    CardFormSection(
      L10n.Settings.ConfigExport.sectionTitle,
      info: L10n.Settings.ConfigExport.sectionFooter,
      footer: isDisabled ? L10n.Settings.ConfigExport.requiresRadio : nil
    ) {
      MetricTileGrid {
        tile(title: L10n.Settings.ConfigExport.export, systemImage: "square.and.arrow.up", color: .blue) {
          NodeConfigExportView()
        }
        tile(title: L10n.Settings.ConfigImport.importConfig, systemImage: "square.and.arrow.down", color: .green) {
          NodeConfigImportView()
        }
      }
    }
  }

  private func tile(
    title: String,
    systemImage: String,
    color: Color,
    @ViewBuilder destination: @escaping () -> some View
  ) -> some View {
    NavigationLink(destination: destination) {
      NavigationTile(title, systemImage: systemImage, color: color)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    // A plain-style link doesn't dim when disabled; the card has to show it.
    .opacity(isDisabled ? 0.5 : 1)
  }
}
